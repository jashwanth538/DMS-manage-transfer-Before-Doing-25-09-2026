trigger OrderAllocationTrigger on Order_Allocation__c (after insert, after update) {
    System.debug(LoggingLevel.INFO, '[DMS Trigger] OrderAllocationTrigger fired | Action=' + (Trigger.isInsert ? 'INSERT' : 'UPDATE') + ' | Record Count=' + (Trigger.new != null ? Trigger.new.size() : 0));
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            System.debug(LoggingLevel.INFO, '[DMS Trigger] Delegating to RecordSharingTriggerHandler.afterInsert...');
            RecordSharingTriggerHandler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            System.debug(LoggingLevel.INFO, '[DMS Trigger] Delegating to RecordSharingTriggerHandler.afterUpdate...');
            RecordSharingTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}