trigger SupplyRequestTrigger on Supply_Request__c (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        SupplyRequestHelper.populateAccountsAndLocations(Trigger.new);
    } else if (Trigger.isAfter) {
        SupplyRequestHelper.shareLocationsWithUser(Trigger.new);
        if (Trigger.isInsert) {
            RecordSharingTriggerHandler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            RecordSharingTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}