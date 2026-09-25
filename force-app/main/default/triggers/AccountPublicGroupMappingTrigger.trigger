trigger AccountPublicGroupMappingTrigger on Account_Public_Group_Mapping__c (after insert) {
    if (Trigger.isAfter && Trigger.isInsert) {
        RecordSharingTriggerHandler.afterInsert(Trigger.new);
    }
}