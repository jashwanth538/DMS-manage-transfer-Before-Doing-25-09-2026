trigger PurchaseOrderTrigger on Purchase_Order__c (after insert, after update) {
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            RecordSharingTriggerHandler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            RecordSharingTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}