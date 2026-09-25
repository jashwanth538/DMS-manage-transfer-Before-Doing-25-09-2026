public with sharing class InventoryTriggerHandler {

    public void beforeInsert(List<Inventory__c> newRecords) {
    }

    public void beforeUpdate(List<Inventory__c> newRecords, Map<Id, Inventory__c> oldMap, Map<Id, Inventory__c> newMap) {
    }

    public void afterInsert(List<Inventory__c> newRecords, Map<Id, Inventory__c> newMap) {
        InventoryService.handleReplenishment(newRecords, null);
    }

    public void afterUpdate(List<Inventory__c> newRecords, Map<Id, Inventory__c> oldMap, Map<Id, Inventory__c> newMap) {
        InventoryService.handleReplenishment(newRecords, oldMap);
    }
}