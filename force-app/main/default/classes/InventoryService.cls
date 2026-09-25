public without sharing class InventoryService {
    
    public static void populateLevelsFromItem(List<Inventory__c> newRecords) {
        Set<Id> itemIds = new Set<Id>();
        for (Inventory__c inv : newRecords) {
            if (inv.Item__c != null) {
                itemIds.add(inv.Item__c);
            }
        }
        
        if (itemIds.isEmpty()) {
            return;
        }
        
        // Use Selector Layer
        Map<Id, Item__c> itemsMap = ItemSelector.getItemsByIds(itemIds);
        
        for (Inventory__c inv : newRecords) {
            if (inv.Item__c != null && itemsMap.containsKey(inv.Item__c)) {
                Item__c relatedItem = itemsMap.get(inv.Item__c);
                inv.Reorder_Level__c = relatedItem.Reorder_Level__c;
                inv.Target_Stock_Level__c = relatedItem.Target_Stock_Level__c;
                inv.Stock_Low_Level_Quantity__c = relatedItem.Stock_Low_Level_Quantity__c;
                inv.Stock_Medium_Level_Quantity__c = relatedItem.Stock_Medium_Level_Quantity__c;
                inv.Stock_High_Level_Quantity__c = relatedItem.Stock_High_Level_Quantity__c;
            }
        }
    }
    
    public static void handleReplenishment(List<Inventory__c> newRecords, Map<Id, Inventory__c> oldMap) {
        // Prevent duplicate execution of replenishment in the same transaction using Recursion Handler
        if (TriggerRecursionHandler.hasRun('InventoryReplenishment')) {
            return;
        }
        
        List<Inventory__c> inventoriesToReplenish = new List<Inventory__c>();
        Set<Id> itemIds = new Set<Id>();
        Set<Id> locationIds = new Set<Id>();
        
        for (Inventory__c inv : newRecords) {
            Decimal available = inv.Available__c != null ? inv.Available__c : 0;
            System.debug(LoggingLevel.INFO, 'Evaluating Inventory record: ' + inv.Id + 
                ' | Available__c: ' + available + 
                ' | Reorder_Level__c: ' + inv.Reorder_Level__c + 
                ' | Target_Stock_Level__c: ' + inv.Target_Stock_Level__c);
            
            // Check if Available__c (or 0 if null) is less than Reorder_Level__c
            if (inv.Reorder_Level__c != null && inv.Target_Stock_Level__c != null) {
                if (available < inv.Reorder_Level__c) {
                    inventoriesToReplenish.add(inv);
                    if (inv.Item__c != null) {
                        itemIds.add(inv.Item__c);
                    }
                    if (inv.Inventory_Location__c != null) {
                        locationIds.add(inv.Inventory_Location__c);
                    }
                    System.debug(LoggingLevel.INFO, 'Inventory qualified for replenishment: ' + inv.Id);
                } else {
                    System.debug(LoggingLevel.INFO, 'Inventory skipped (Available__c >= Reorder_Level__c): Available=' + available + ', ReorderLevel=' + inv.Reorder_Level__c);
                }
            } else {
                System.debug(LoggingLevel.WARN, 'Inventory skipped due to missing required fields: Available__c=' + available + ', Reorder_Level__c=' + inv.Reorder_Level__c + ', Target_Stock_Level__c=' + inv.Target_Stock_Level__c);
            }
        }
        
        if (inventoriesToReplenish.isEmpty()) {
            System.debug(LoggingLevel.INFO, 'No inventory records qualified for replenishment. Exiting handleReplenishment.');
            return;
        }
        
        // Mark as run to prevent recursion
        TriggerRecursionHandler.markRun('InventoryReplenishment');
        
        // Use Selector Layer to query existing active requests
        List<Supply_Request__c> existingRequests = SupplyRequestSelector.getActiveRequests(itemIds, locationIds);
        
        Map<String, Supply_Request__c> keyToRequest = new Map<String, Supply_Request__c>();
        for (Supply_Request__c sr : existingRequests) {
            String key = InventoryUtility.generateReplenishmentKey(sr.Item__c, sr.Target_Location__c, sr.Requesting_Account__c, sr.Request_Type__c);
            if (!keyToRequest.containsKey(key)) {
                keyToRequest.put(key, sr);
            }
        }
        
        Map<Id, Item__c> itemsMap = ItemSelector.getItemsByIds(itemIds);
        
        List<Supply_Request__c> newRequestsToInsert = new List<Supply_Request__c>();
        Map<Id, Supply_Request__c> requestsToUpdateMap = new Map<Id, Supply_Request__c>();
        
        for (Inventory__c inv : inventoriesToReplenish) {
            String key = InventoryUtility.generateReplenishmentKey(inv.Item__c, inv.Inventory_Location__c, inv.Account__c, 'Stock Replenishment');
            Decimal available = inv.Available__c != null ? inv.Available__c : 0;
            Decimal requestedQty = inv.Target_Stock_Level__c - available;
            
            if (requestedQty > 0) {
                if (keyToRequest.containsKey(key)) {
                    Supply_Request__c sr = keyToRequest.get(key);
                    if (sr.Id != null) {
                        Decimal minQty = sr.Received_Qty__c != null ? sr.Received_Qty__c : 0;
                        Decimal finalQty = Math.max(requestedQty, minQty);
                        if (sr.Requested_Qty__c != finalQty) {
                            sr.Requested_Qty__c = finalQty;
                            requestsToUpdateMap.put(sr.Id, sr);
                        }
                    } else {
                        sr.Requested_Qty__c = requestedQty;
                    }
                } else {
                    String supplyMethod = null;
                    if (inv.Item__c != null && itemsMap.containsKey(inv.Item__c)) {
                        Item__c item = itemsMap.get(inv.Item__c);
                        if (item.Default_Supply_Method__c == 'Purchase') {
                            supplyMethod = 'Purchase';
                        } else if (item.Default_Supply_Method__c == 'Manufacture') {
                            supplyMethod = 'Manufacture';
                        } else if (item.Default_Supply_Method__c == 'Both') {
                            supplyMethod = 'Undecided';
                        }
                    }

                    Supply_Request__c newSR = new Supply_Request__c(
                        Item__c = inv.Item__c,
                        Target_Location__c = inv.Inventory_Location__c,
                        Requesting_Account__c = inv.Account__c,
                        Requested_Qty__c = requestedQty,
                        Request_Type__c = 'Stock Replenishment',
                        Status__c = 'Open',
                        Supply_Method__c = supplyMethod
                    );
                    newRequestsToInsert.add(newSR);
                    keyToRequest.put(key, newSR);
                }
            }
        }
        
        if (!newRequestsToInsert.isEmpty()) {
            insert newRequestsToInsert;
        }
        if (!requestsToUpdateMap.isEmpty()) {
            update requestsToUpdateMap.values();
        }
    }
}