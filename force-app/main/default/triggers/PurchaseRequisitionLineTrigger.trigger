trigger PurchaseRequisitionLineTrigger on Purchase_Requisition_Line__c (after insert, after update) {
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            RecordSharingTriggerHandler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            RecordSharingTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}