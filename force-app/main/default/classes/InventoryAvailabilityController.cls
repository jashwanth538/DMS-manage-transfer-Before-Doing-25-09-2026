public with sharing class InventoryAvailabilityController {

    @AuraEnabled(cacheable=true)
    public static List<ProductInventoryWrapper> getInventoryData(Id orderAllocationId, Id itemId, Id locationId, Id accountId) {
        List<ProductInventoryWrapper> result = new List<ProductInventoryWrapper>();

        if (orderAllocationId == null && itemId == null && locationId == null && accountId == null) {
            return result;
        }

        Id destLocId = null;
        Id supplyingAccId = null;

        // 1. Fetch Order Allocation Header to identify Supplying Account & Location if orderAllocationId is provided
        if (orderAllocationId != null) {
            List<Order_Allocation__c> oaList = [
                SELECT Id, Target_Location__c, Supplying_Account__c, Target_Location__r.Account__c
                FROM Order_Allocation__c
                WHERE Id = :orderAllocationId
                LIMIT 1
            ];

            if (!oaList.isEmpty()) {
                Order_Allocation__c oa = oaList[0];
                destLocId = oa.Target_Location__c;
                supplyingAccId = oa.Supplying_Account__c != null ? oa.Supplying_Account__c : (oa.Target_Location__r != null ? oa.Target_Location__r.Account__c : null);
            }
        }

        if (supplyingAccId == null && accountId != null) {
            supplyingAccId = accountId;
        }

        // Gather DMS target account IDs
        Set<Id> targetAccountIds = new Set<Id>();
        if (accountId != null) {
            targetAccountIds.add(accountId);
        }
        if (supplyingAccId != null) {
            targetAccountIds.add(supplyingAccId);

            List<Account> suppAccList = [
                SELECT Id, Name, Type, Dealer__c, Distributor__c, OEM__c 
                FROM Account 
                WHERE Id = :supplyingAccId 
                LIMIT 1
            ];

            if (!suppAccList.isEmpty()) {
                Account supplyingAcc = suppAccList[0];
                if (supplyingAcc.Type == 'Dealer') {
                    for (Account acc : [SELECT Id FROM Account WHERE Dealer__c = :supplyingAccId]) {
                        targetAccountIds.add(acc.Id);
                    }
                } else if (supplyingAcc.Type == 'Distributor') {
                    for (Account acc : [SELECT Id FROM Account WHERE Distributor__c = :supplyingAccId]) {
                        targetAccountIds.add(acc.Id);
                    }
                } else if (supplyingAcc.Type == 'OEM') {
                    for (Account acc : [SELECT Id FROM Account WHERE OEM__c = :supplyingAccId]) {
                        targetAccountIds.add(acc.Id);
                    }
                } else {
                    for (Account acc : [SELECT Id FROM Account WHERE Dealer__c = :supplyingAccId OR Distributor__c = :supplyingAccId OR OEM__c = :supplyingAccId]) {
                        targetAccountIds.add(acc.Id);
                    }
                }
            }
        }

        Map<Id, ProductInventoryWrapper> productToWrapperMap = new Map<Id, ProductInventoryWrapper>();
        Set<Id> productIds = new Set<Id>();

        // 2. Fetch Order Allocation Line Items or specific item to get the relevant items (products)
        if (orderAllocationId != null) {
            String lineItemQuery = 'SELECT Id, Item__c, Item__r.Name, Item__r.Item_Code__c, Item__r.Item_Family__c FROM Order_Allocation_Line_Item__c WHERE Order_Allocation__c = :orderAllocationId AND Item__c != null';
            if (itemId != null) {
                lineItemQuery += ' AND Item__c = :itemId';
            }
            List<Order_Allocation_Line_Item__c> lineItems = Database.query(lineItemQuery);

            for (Order_Allocation_Line_Item__c lineItem : lineItems) {
                productIds.add(lineItem.Item__c);
                if (!productToWrapperMap.containsKey(lineItem.Item__c)) {
                    ProductInventoryWrapper wrapper = new ProductInventoryWrapper();
                    wrapper.productId = lineItem.Item__c;
                    wrapper.productName = lineItem.Item__r.Name;
                    wrapper.productCode = lineItem.Item__r.Item_Code__c;
                    wrapper.productFamily = lineItem.Item__r.Item_Family__c;
                    wrapper.locations = new List<LocationInventoryWrapper>();
                    productToWrapperMap.put(lineItem.Item__c, wrapper);
                    result.add(wrapper);
                }
            }
        } else if (itemId != null) {
            productIds.add(itemId);
            for (Item__c itm : [SELECT Id, Name, Item_Code__c, Item_Family__c FROM Item__c WHERE Id = :itemId]) {
                ProductInventoryWrapper wrapper = new ProductInventoryWrapper();
                wrapper.productId = itm.Id;
                wrapper.productName = itm.Name;
                wrapper.productCode = itm.Item_Code__c;
                wrapper.productFamily = itm.Item_Family__c;
                wrapper.locations = new List<LocationInventoryWrapper>();
                productToWrapperMap.put(itm.Id, wrapper);
                result.add(wrapper);
            }
        }

        if (productIds.isEmpty()) {
            return result;
        }

        // 3. Fetch Inventory related to these items, filtered by target accounts & locations
        String invQuery = 'SELECT Id, Item__c, Inventory_Location__c, Inventory_Location__r.Name, Account__c, Account__r.Name, Available__c, ' +
                          'On_Hand_Qty__c, Reserved_Sale_Order__c, Reserved_Transfer__c, Damaged__c, ' +
                          'Transit_In_Quantity__c, Transit_Out_Quantity__c ' +
                          'FROM Inventory__c WHERE Item__c IN :productIds';

        if (locationId != null) {
            invQuery += ' AND Inventory_Location__c = :locationId';
        } else if (!targetAccountIds.isEmpty() || destLocId != null) {
            if (!targetAccountIds.isEmpty() && destLocId != null) {
                invQuery += ' AND (Account__c IN :targetAccountIds OR Inventory_Location__c = :destLocId)';
            } else if (!targetAccountIds.isEmpty()) {
                invQuery += ' AND Account__c IN :targetAccountIds';
            } else if (destLocId != null) {
                invQuery += ' AND Inventory_Location__c = :destLocId';
            }
        }

        List<Inventory__c> inventories = Database.query(invQuery);

        // 4. Map locations to the respective products
        for (Inventory__c inv : inventories) {
            if (productToWrapperMap.containsKey(inv.Item__c)) {
                LocationInventoryWrapper locWrapper = new LocationInventoryWrapper();
                locWrapper.locationId = inv.Inventory_Location__c;
                String displayName = (inv.Account__r != null && String.isNotBlank(inv.Account__r.Name))
                    ? inv.Account__r.Name + ' (' + inv.Inventory_Location__r.Name + ')'
                    : inv.Inventory_Location__r.Name;
                locWrapper.locationName = displayName;
                locWrapper.availableQty = (inv.Available__c != null && inv.Available__c > 0) ? inv.Available__c : 0;
                locWrapper.onHandQty = inv.On_Hand_Qty__c != null ? inv.On_Hand_Qty__c : 0;
                locWrapper.reservedSaleOrderQty = inv.Reserved_Sale_Order__c != null ? inv.Reserved_Sale_Order__c : 0;
                locWrapper.reservedTransferQty = inv.Reserved_Transfer__c != null ? inv.Reserved_Transfer__c : 0;
                locWrapper.damagedQty = inv.Damaged__c != null ? inv.Damaged__c : 0;
                locWrapper.transitInQty = inv.Transit_In_Quantity__c != null ? inv.Transit_In_Quantity__c : 0;
                locWrapper.transitOutQty = inv.Transit_Out_Quantity__c != null ? inv.Transit_Out_Quantity__c : 0;
                
                productToWrapperMap.get(inv.Item__c).locations.add(locWrapper);
            }
        }

        return result;
    }

    public class ProductInventoryWrapper {
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String productFamily { get; set; }
        @AuraEnabled public List<LocationInventoryWrapper> locations { get; set; }
    }

    public class LocationInventoryWrapper {
        @AuraEnabled public Id locationId { get; set; }
        @AuraEnabled public String locationName { get; set; }
        @AuraEnabled public Decimal availableQty { get; set; }
        @AuraEnabled public Decimal onHandQty { get; set; }
        @AuraEnabled public Decimal reservedSaleOrderQty { get; set; }
        @AuraEnabled public Decimal reservedTransferQty { get; set; }
        @AuraEnabled public Decimal damagedQty { get; set; }
        @AuraEnabled public Decimal transitInQty { get; set; }
        @AuraEnabled public Decimal transitOutQty { get; set; }
    }
}