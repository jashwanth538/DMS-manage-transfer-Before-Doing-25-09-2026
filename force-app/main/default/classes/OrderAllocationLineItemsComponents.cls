public with sharing class OrderAllocationLineItemsComponents {
    @AuraEnabled(cacheable=true)
    public static Order_Allocation__c getOrderAllocationDetails(Id recordId) {
        if (recordId == null) {
            return null;
        }
        List<Order_Allocation__c> plans = [
            SELECT Id, Name, Status__c,
                   (SELECT Id, Name, Item__c, Item__r.Name, Ordered_Qty__c, Status__c,
                           Reserved_Quantity__c, Reserved_Qty_Planned__c,
                           Transfer_Qty_Received__c, Transfer_Qty_Planned__c,
                           Procurement_Qty_Received__c, Procurement_Qty_Planned__c
                    FROM Order_Allocation_Line_Items__r
                    ORDER BY Name ASC)
            FROM Order_Allocation__c
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        return plans.isEmpty() ? null : plans[0];
    }
}