/**
 * @description Generic Trigger Handler for Apex Managed Sharing in the Dealer Management System (DMS).
 *              Delegates sharing record creation directly to RecordSharingService.
 * @author DeepMind Antigravity
 * @date 2026-07-31
 */
public with sharing class RecordSharingTriggerHandler {

    /**
     * @description Handler method for after insert triggers across any custom object.
     * @param records List of newly inserted SObject records (Trigger.new).
     */
    public static void afterInsert(List<SObject> records) {
        System.debug(LoggingLevel.INFO, '[DMS Handler] afterInsert called with ' + (records != null ? records.size() : 0) + ' record(s).');
        if (records == null || records.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[DMS Handler] afterInsert received empty or null records list.');
            return;
        }
        RecordSharingService.shareRecords(records);
    }

    /**
     * @description Handler method for after update triggers. Recalculates sharing when an Account lookup or parent relationship field changes.
     * @param newRecords List of updated SObject records (Trigger.new).
     * @param oldMap Map of previous SObject state (Trigger.oldMap).
     */
    public static void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
        System.debug(LoggingLevel.INFO, '[DMS Handler] afterUpdate called with ' + (newRecords != null ? newRecords.size() : 0) + ' record(s).');
        if (newRecords == null || newRecords.isEmpty() || oldMap == null || oldMap.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[DMS Handler] afterUpdate received empty newRecords or oldMap.');
            return;
        }

        List<SObject> changedRecords = new List<SObject>();
        for (SObject newRec : newRecords) {
            if (newRec == null || newRec.Id == null) {
                continue;
            }
            SObject oldRec = oldMap.get(newRec.Id);
            if (oldRec == null) {
                continue;
            }

            ShareMetadataResolver.ShareDescriptor descr = ShareMetadataResolver.getDescriptor(newRec.getSObjectType());
            Boolean hasChanged = false;
            if (descr != null && descr.changeTrackingFields != null && !descr.changeTrackingFields.isEmpty()) {
                for (String fieldName : descr.changeTrackingFields) {
                    try {
                        if (newRec.get(fieldName) != oldRec.get(fieldName)) {
                            hasChanged = true;
                            break;
                        }
                    } catch (Exception e) {
                        // Field not populated/present on this record
                    }
                }
            } else {
                // Fallback field check
                try {
                    if (newRec.get('Requesting_Account__c') != oldRec.get('Requesting_Account__c') ||
                        newRec.get('Account__c') != oldRec.get('Account__c')) {
                        hasChanged = true;
                    }
                } catch (Exception e) {}
            }

            if (hasChanged) {
                changedRecords.add(newRec);
            }
        }

        if (!changedRecords.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[DMS Handler] Recalculating sharing for ' + changedRecords.size() + ' record(s) with changed account/parent fields.');
            RecordSharingService.shareRecords(changedRecords);
        } else {
            System.debug(LoggingLevel.FINE, '[DMS Handler] No account relationship fields changed on update.');
        }
    }
}