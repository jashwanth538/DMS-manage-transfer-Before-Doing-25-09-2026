public with sharing class Product2Service {
    
    public static void checkDuplicateProducts(List<Product2> newProducts, Map<Id, Product2> oldProductsMap) {
        Set<String> itemIdsToCheck = new Set<String>();
        List<Product2> productsToValidate = new List<Product2>();
        
        for (Product2 prod : newProducts) {
            if (String.isNotBlank(prod.Item_Id__c)) {
                Product2 oldProd = (oldProductsMap != null) ? oldProductsMap.get(prod.Id) : null;
                if (oldProd == null || oldProd.Item_Id__c != prod.Item_Id__c) {
                    itemIdsToCheck.add(prod.Item_Id__c);
                    productsToValidate.add(prod);
                }
            }
        }
        
        if (itemIdsToCheck.isEmpty()) {
            return;
        }
        
        List<Product2> duplicates = [
            SELECT Id, Item_Id__c 
            FROM Product2 
            WHERE Item_Id__c IN :itemIdsToCheck
        ];
        
        Set<String> existingItemIds = new Set<String>();
        for (Product2 dup : duplicates) {
            existingItemIds.add(dup.Item_Id__c);
        }
        
        Set<String> batchItemIds = new Set<String>();
        for (Product2 prod : productsToValidate) {
            if (existingItemIds.contains(prod.Item_Id__c) || batchItemIds.contains(prod.Item_Id__c)) {
                prod.Item_Id__c.addError('A Product with this Name and Product Code combination already exists.');
            } else {
                batchItemIds.add(prod.Item_Id__c);
            }
        }
    }

    public static void checkDuplicateItems(List<Item__c> newItems, Map<Id, Item__c> oldItemsMap) {
        Set<String> productIdsToCheck = new Set<String>();
        List<Item__c> itemsToValidate = new List<Item__c>();
        
        for (Item__c item : newItems) {
            if (String.isNotBlank(item.Product_Id__c)) {
                Item__c oldItem = (oldItemsMap != null) ? oldItemsMap.get(item.Id) : null;
                if (oldItem == null || oldItem.Product_Id__c != item.Product_Id__c) {
                    productIdsToCheck.add(item.Product_Id__c);
                    itemsToValidate.add(item);
                }
            }
        }
        
        if (productIdsToCheck.isEmpty()) {
            return;
        }
        
        List<Item__c> duplicates = [
            SELECT Id, Product_Id__c 
            FROM Item__c 
            WHERE Product_Id__c IN :productIdsToCheck
        ];
        
        Set<String> existingProductIds = new Set<String>();
        for (Item__c dup : duplicates) {
            existingProductIds.add(dup.Product_Id__c);
        }
        
        Set<String> batchProductIds = new Set<String>();
        for (Item__c item : itemsToValidate) {
            if (existingProductIds.contains(item.Product_Id__c) || batchProductIds.contains(item.Product_Id__c)) {
                item.Product_Id__c.addError('An Item with this Name and Item Code combination already exists.');
            } else {
                batchProductIds.add(item.Product_Id__c);
            }
        }
    }

    public static void syncProductsToItems(List<Product2> newProducts, Map<Id, Product2> oldProductsMap) {
        Set<String> codesToQuery = new Set<String>();
        Set<String> newCodes = new Set<String>();
        Set<String> oldCompositeIds = new Set<String>();
        Set<String> newCompositeIds = new Set<String>();
        
        for (Product2 prod : newProducts) {
            if (String.isNotBlank(prod.ProductCode)) {
                Product2 oldProd = (oldProductsMap != null) ? oldProductsMap.get(prod.Id) : null;
                String oldCode = (oldProd != null) ? oldProd.ProductCode : null;
                
                if (String.isNotBlank(prod.Item_Id__c)) {
                    newCompositeIds.add(prod.Item_Id__c);
                }
                if (oldProd != null && String.isNotBlank(oldProd.Item_Id__c)) {
                    oldCompositeIds.add(oldProd.Item_Id__c);
                }
                
                if (!SyncRecursionHandler.syncingCodes.contains(prod.ProductCode)) {
                    newCodes.add(prod.ProductCode);
                    if (String.isNotBlank(oldCode) && oldCode != prod.ProductCode) {
                        codesToQuery.add(oldCode);
                    } else {
                        codesToQuery.add(prod.ProductCode);
                    }
                }
            }
        }
        
        if (newCodes.isEmpty() && codesToQuery.isEmpty() && newCompositeIds.isEmpty() && oldCompositeIds.isEmpty()) {
            return;
        }
        
        try {
            // Add to syncing codes to prevent recursion
            SyncRecursionHandler.syncingCodes.addAll(newCodes);
            SyncRecursionHandler.syncingCodes.addAll(codesToQuery);
            
            // Query existing items by Product_Id__c (new or old composite keys) OR Item_Code__c
            List<Item__c> existingItems = [
                SELECT Id, Name, Item_Code__c, Item_Description__c, Item_Family__c, Active__c, 
                       Unit_Of_Measure__c, Default_Supply_Method__c, Base_Tax__c, Delivery_Preparation_Time__c, 
                       Reorder_Level__c, Target_Stock_Level__c, Stock_Low_Level_Quantity__c, 
                       Stock_Medium_Level_Quantity__c, Stock_High_Level_Quantity__c, Classification__c, 
                       Is_Sellable__c, Is_Inventory_Item__c, Service_Type__c, Target_Days__c, Quantity_Unit_Of_Measure__c, Product_Id__c 
                FROM Item__c 
                WHERE Product_Id__c IN :newCompositeIds OR Product_Id__c IN :oldCompositeIds OR Item_Code__c IN :codesToQuery
            ];
            
            Map<String, Item__c> itemsByCompositeId = new Map<String, Item__c>();
            Map<String, Item__c> itemsByCode = new Map<String, Item__c>();
            for (Item__c item : existingItems) {
                if (String.isNotBlank(item.Product_Id__c)) {
                    itemsByCompositeId.put(item.Product_Id__c, item);
                }
                if (String.isNotBlank(item.Item_Code__c)) {
                    itemsByCode.put(item.Item_Code__c, item);
                }
            }
            
            Map<String, Item__c> itemsToUpsertMap = new Map<String, Item__c>();
            for (Product2 prod : newProducts) {
                if (String.isNotBlank(prod.ProductCode) && (newCodes.contains(prod.ProductCode) || codesToQuery.contains(prod.ProductCode))) {
                    Product2 oldProd = (oldProductsMap != null) ? oldProductsMap.get(prod.Id) : null;
                    String oldCode = (oldProd != null) ? oldProd.ProductCode : null;
                    String oldComposite = (oldProd != null) ? oldProd.Item_Id__c : null;
                    
                    Item__c item = null;
                    
                    // Match by current composite first
                    if (String.isNotBlank(prod.Item_Id__c) && itemsByCompositeId.containsKey(prod.Item_Id__c)) {
                        item = itemsByCompositeId.get(prod.Item_Id__c);
                    }
                    // Match by old composite
                    else if (String.isNotBlank(oldComposite) && itemsByCompositeId.containsKey(oldComposite)) {
                        item = itemsByCompositeId.get(oldComposite);
                    }
                    // Match by old code
                    else if (String.isNotBlank(oldCode) && itemsByCode.containsKey(oldCode)) {
                        item = itemsByCode.get(oldCode);
                    }
                    // Match by current code
                    else if (itemsByCode.containsKey(prod.ProductCode)) {
                        item = itemsByCode.get(prod.ProductCode);
                    }
                    // Match by to-be-upserted code
                    else if (itemsToUpsertMap.containsKey(prod.ProductCode)) {
                        item = itemsToUpsertMap.get(prod.ProductCode);
                    }
                    
                    if (item == null) {
                        item = new Item__c(
                            Item_Code__c = prod.ProductCode,
                            Product_Id__c = prod.Item_Id__c
                        );
                    }
                    
                    // Use Utility class to map fields
                    Product2Utility.mapProductToItem(prod, item);
                    itemsToUpsertMap.put(prod.ProductCode, item);
                }
            }
            
            try {
                if (!itemsToUpsertMap.isEmpty()) {
                    upsert itemsToUpsertMap.values();
                }
            } catch (DmlException e) {
                List<Item__c> upsertList = itemsToUpsertMap.values();
                for (Integer i = 0; i < e.getNumDml(); i++) {
                    String failedMessage = e.getDmlMessage(i);
                    Integer index = e.getDmlIndex(i);
                    Item__c failedItem = (index >= 0 && index < upsertList.size()) ? upsertList.get(index) : null;
                    String failedCode = failedItem != null ? failedItem.Item_Code__c : null;
                    if (String.isNotBlank(failedCode)) {
                        for (Product2 prod : newProducts) {
                            if (prod.ProductCode == failedCode) {
                                prod.addError(failedMessage);
                            }
                        }
                    } else {
                        for (Product2 prod : newProducts) {
                            prod.addError(failedMessage);
                        }
                    }
                }
                throw e;
            }
        } finally {
            // Remove from syncing codes
            SyncRecursionHandler.syncingCodes.removeAll(newCodes);
            SyncRecursionHandler.syncingCodes.removeAll(codesToQuery);
        }
    }
    
    public static void syncItemsToProducts(List<Item__c> newItems, Map<Id, Item__c> oldItemsMap) {
        Set<String> codesToQuery = new Set<String>();
        Set<String> newCodes = new Set<String>();
        Set<String> oldCompositeIds = new Set<String>();
        Set<String> newCompositeIds = new Set<String>();
        
        for (Item__c item : newItems) {
            if (String.isNotBlank(item.Item_Code__c)) {
                Item__c oldItem = (oldItemsMap != null) ? oldItemsMap.get(item.Id) : null;
                String oldCode = (oldItem != null) ? oldItem.Item_Code__c : null;
                
                if (String.isNotBlank(item.Product_Id__c)) {
                    newCompositeIds.add(item.Product_Id__c);
                }
                if (oldItem != null && String.isNotBlank(oldItem.Product_Id__c)) {
                    oldCompositeIds.add(oldItem.Product_Id__c);
                }
                
                if (!SyncRecursionHandler.syncingCodes.contains(item.Item_Code__c)) {
                    newCodes.add(item.Item_Code__c);
                    if (String.isNotBlank(oldCode) && oldCode != item.Item_Code__c) {
                        codesToQuery.add(oldCode);
                    } else {
                        codesToQuery.add(item.Item_Code__c);
                    }
                }
            }
        }
        
        if (newCodes.isEmpty() && codesToQuery.isEmpty() && newCompositeIds.isEmpty() && oldCompositeIds.isEmpty()) {
            return;
        }
        
        try {
            // Add to syncing codes to prevent recursion
            SyncRecursionHandler.syncingCodes.addAll(newCodes);
            SyncRecursionHandler.syncingCodes.addAll(codesToQuery);
            
            // Query existing products by Item_Id__c (new or old composite keys) OR ProductCode
            List<Product2> existingProducts = [
                SELECT Id, Name, ProductCode, Description, Family, IsActive, 
                       Unit_Of_Measure__c, Default_Supply_Method__c, Base_Tax__c, Delivery_Preparation_Time__c, 
                       Reorder_Level__c, Target_Stock_Level__c, Stock_Low_Level_Quantity__c, 
                       Stock_Medium_Level_Quantity__c, Stock_High_Level_Quantity__c, Classification__c, 
                       Is_Sellable__c, Is_Inventory_Item__c, Service_Type__c, Target_Days__c, QuantityUnitOfMeasure, Item_Id__c 
                FROM Product2 
                WHERE Item_Id__c IN :newCompositeIds OR Item_Id__c IN :oldCompositeIds OR ProductCode IN :codesToQuery
            ];
            
            Map<String, Product2> productsByCompositeId = new Map<String, Product2>();
            Map<String, Product2> productsByCode = new Map<String, Product2>();
            for (Product2 prod : existingProducts) {
                if (String.isNotBlank(prod.Item_Id__c)) {
                    productsByCompositeId.put(prod.Item_Id__c, prod);
                }
                if (String.isNotBlank(prod.ProductCode)) {
                    productsByCode.put(prod.ProductCode, prod);
                }
            }
            
            Map<String, Product2> productsToUpsertMap = new Map<String, Product2>();
            for (Item__c item : newItems) {
                if (String.isNotBlank(item.Item_Code__c) && (newCodes.contains(item.Item_Code__c) || codesToQuery.contains(item.Item_Code__c))) {
                    Item__c oldItem = (oldItemsMap != null) ? oldItemsMap.get(item.Id) : null;
                    String oldCode = (oldItem != null) ? oldItem.Item_Code__c : null;
                    String oldComposite = (oldItem != null) ? oldItem.Product_Id__c : null;
                    
                    Product2 prod = null;
                    
                    // Match by current composite first
                    if (String.isNotBlank(item.Product_Id__c) && productsByCompositeId.containsKey(item.Product_Id__c)) {
                        prod = productsByCompositeId.get(item.Product_Id__c);
                    }
                    // Match by old composite
                    else if (String.isNotBlank(oldComposite) && productsByCompositeId.containsKey(oldComposite)) {
                        prod = productsByCompositeId.get(oldComposite);
                    }
                    // Match by old code
                    else if (String.isNotBlank(oldCode) && productsByCode.containsKey(oldCode)) {
                        prod = productsByCode.get(oldCode);
                    }
                    // Match by current code
                    else if (productsByCode.containsKey(item.Item_Code__c)) {
                        prod = productsByCode.get(item.Item_Code__c);
                    }
                    // Match by to-be-upserted code
                    else if (productsToUpsertMap.containsKey(item.Item_Code__c)) {
                        prod = productsToUpsertMap.get(item.Item_Code__c);
                    }
                    
                    if (prod == null) {
                        prod = new Product2(
                            ProductCode = item.Item_Code__c,
                            Item_Id__c = item.Product_Id__c
                        );
                    }
                    
                    // Use Utility class to map fields
                    Product2Utility.mapItemToProduct(item, prod);
                    productsToUpsertMap.put(item.Item_Code__c, prod);
                }
            }
            
            try {
                if (!productsToUpsertMap.isEmpty()) {
                    upsert productsToUpsertMap.values();
                }
            } catch (DmlException e) {
                List<Product2> upsertList = productsToUpsertMap.values();
                for (Integer i = 0; i < e.getNumDml(); i++) {
                    String failedMessage = e.getDmlMessage(i);
                    Integer index = e.getDmlIndex(i);
                    Product2 failedProd = (index >= 0 && index < upsertList.size()) ? upsertList.get(index) : null;
                    String failedCode = failedProd != null ? failedProd.ProductCode : null;
                    if (String.isNotBlank(failedCode)) {
                        for (Item__c item : newItems) {
                            if (item.Item_Code__c == failedCode) {
                                item.addError(failedMessage);
                            }
                        }
                    } else {
                        for (Item__c item : newItems) {
                            item.addError(failedMessage);
                        }
                    }
                }
                throw e;
            }
        } finally {
            // Remove from syncing codes
            SyncRecursionHandler.syncingCodes.removeAll(newCodes);
            SyncRecursionHandler.syncingCodes.removeAll(codesToQuery);
        }
    }
}