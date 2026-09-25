public with sharing class ItemTriggerHandler extends BaseTriggerHandler {
    public override void beforeInsert(List<SObject> newRecords) {
        for (Item__c item : (List<Item__c>) newRecords) {
            item.Product_Id__c = (String.isNotBlank(item.Name) && String.isNotBlank(item.Item_Code__c)) ? (item.Name + '-' + item.Item_Code__c) : '';
        }
        Product2Service.checkDuplicateItems((List<Item__c>) newRecords, null);
    }
    
    public override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {
        for (Item__c item : (List<Item__c>) newRecords) {
            item.Product_Id__c = (String.isNotBlank(item.Name) && String.isNotBlank(item.Item_Code__c)) ? (item.Name + '-' + item.Item_Code__c) : '';
        }
        Product2Service.checkDuplicateItems((List<Item__c>) newRecords, (Map<Id, Item__c>) oldMap);
    }

    public override void afterInsert(List<SObject> newRecords, Map<Id, SObject> newMap) {
        Product2Service.syncItemsToProducts((List<Item__c>) newRecords, null);
        RecordSharingTriggerHandler.afterInsert(newRecords);
    }
    
    public override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {
        Product2Service.syncItemsToProducts((List<Item__c>) newRecords, (Map<Id, Item__c>) oldMap);
    }
}