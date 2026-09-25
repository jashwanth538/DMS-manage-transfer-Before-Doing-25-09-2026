trigger PurchaseRequisitionTrigger on Purchase_Requisition__c (after insert, after update) {
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            RecordSharingTriggerHandler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            RecordSharingTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}