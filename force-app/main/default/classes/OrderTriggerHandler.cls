public with sharing class OrderTriggerHandler extends BaseTriggerHandler {
    
    public override void afterInsert(List<SObject> newRecords, Map<Id, SObject> newMap) {
        OrderService.handleAfterInsert((List<Order>) newRecords);
    }
    
    public override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {
        OrderService.handleAfterUpdate((List<Order>) newRecords, (Map<Id, Order>) oldMap);
    }
}