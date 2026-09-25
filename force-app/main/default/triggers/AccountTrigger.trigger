trigger AccountTrigger on Account (after insert, after update) {
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            RecordSharingTriggerHandler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            RecordSharingTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}