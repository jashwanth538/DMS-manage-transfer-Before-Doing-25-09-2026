public with sharing class SupplyRequestSelector {
    public static List<Supply_Request__c> getActiveRequests(Set<Id> itemIds, Set<Id> locationIds) {
        if (itemIds == null || itemIds.isEmpty() || locationIds == null || locationIds.isEmpty()) {
            return new List<Supply_Request__c>();
        }
        return [
            SELECT Id, Item__c, Source_Location__c, Target_Location__c, Requesting_Account__c, Requested_Qty__c, Status__c, Received_Qty__c, Request_Type__c
            FROM Supply_Request__c
            WHERE Item__c IN :itemIds
              AND Target_Location__c IN :locationIds
              AND Status__c = 'Open'
        ];
    }
}