/**
 * @description Enterprise-grade, reusable Apex Managed Sharing engine for the Dealer Management System (DMS).
 *              Dynamically creates SObject__Share records for custom objects by evaluating the business Account
 *              (Requesting_Account__c, Account__c, From_Account__c/To_Account__c, or parent header Account),
 *              traversing the Account Hierarchy (Child -> Dealer -> Distributor -> OEM), and sharing with mapped Public Groups.
 *              Runs 'without sharing' (System Mode) to ensure full visibility into organizational hierarchies.
 * @author DeepMind Antigravity
 * @date 2026-08-11
 */
public without sharing class RecordSharingService {

    /**
     * @description Resolves the primary Account lookup field API name for a given SObjectType.
     *              Maintained for backward compatibility.
     * @param sType SObjectType of the target record.
     * @return String API name of the primary Account lookup field (e.g., 'Requesting_Account__c' or 'Account__c').
     */
    public static String getAccountFieldName(Schema.SObjectType sType) {
        if (sType == null) {
            return 'Account__c';
        }
        if (sType.getDescribe().getName() == 'Account') {
            return 'Id';
        }
        ShareMetadataResolver.ShareDescriptor descr = ShareMetadataResolver.getDescriptor(sType);
        if (descr != null && String.isNotBlank(descr.accountLookupFieldName)) {
            return descr.accountLookupFieldName;
        }
        return 'Account__c';
    }

    /**
     * @description Share a single record with Public Groups across its Account Hierarchy.
     * @param recordId Id of the record to share.
     * @param accountId Id of the business Account associated with the record.
     * @param objectType SObjectType of the record.
     */
    public static void shareRecord(Id recordId, Id accountId, Schema.SObjectType objectType) {
        if (recordId == null || accountId == null || objectType == null) {
            System.debug(LoggingLevel.WARN, '[DMS Sharing] shareRecord received null arguments.');
            return;
        }
        String accountFieldName = getAccountFieldName(objectType);
        SObject stubRecord = objectType.newSObject(recordId);
        stubRecord.put(accountFieldName, accountId);
        shareRecords(new List<SObject>{ stubRecord });
    }

    /**
     * @description Overloaded share single record method taking SObject directly.
     * @param record SObject record containing Id and Account lookup field.
     */
    public static void shareRecord(SObject record) {
        if (record == null || record.Id == null) {
            System.debug(LoggingLevel.WARN, '[DMS Sharing] shareRecord received null or uninserted SObject record.');
            return;
        }
        shareRecords(new List<SObject>{ record });
    }

    /**
     * @description Share a single record by its Salesforce Record ID.
     *              Dynamically queries the record and its account lookup fields, then delegates to shareRecords.
     * @param recordId Salesforce Record ID.
     */
    public static void shareRecord(Id recordId) {
        if (recordId == null) {
            System.debug(LoggingLevel.WARN, '[DMS Sharing] shareRecord received null recordId.');
            return;
        }
        Schema.SObjectType sType = recordId.getSObjectType();
        ShareMetadataResolver.ShareDescriptor descr = ShareMetadataResolver.getDescriptor(sType);
        Set<String> fieldsToQuery = new Set<String>{ 'Id' };
        if (descr != null && descr.accountLookupFieldNames != null) {
            for (String f : descr.accountLookupFieldNames) {
                if (f != 'Id') {
                    fieldsToQuery.add(f);
                }
            }
        } else {
            fieldsToQuery.add('Account__c');
            fieldsToQuery.add('Requesting_Account__c');
        }
        if (descr != null && String.isNotBlank(descr.parentLookupFieldName)) {
            fieldsToQuery.add(descr.parentLookupFieldName);
        }
        String objName = sType.getDescribe().getName();
        String soql = 'SELECT ' + String.join(new List<String>(fieldsToQuery), ', ') + ' FROM ' + objName + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> records = Database.query(soql);
        if (!records.isEmpty()) {
            shareRecords(records);
        }
    }

    /**
     * @description Core bulkified sharing method for any List of custom SObjects.
     *              Flow:
     *              1. Resolve target Business Account IDs for each record (direct fields or parent headers)
     *              2. Traverse Account Hierarchy (Child -> Dealer -> Distributor -> OEM)
     *              3. Find Public Groups for ALL accounts in the hierarchy
     *              4. Create Share Records (one per hierarchy-level Public Group)
     *              5. Insert Share Records via Database.insert()
     * @param records List of SObject records to calculate and apply Apex Managed Sharing for.
     */
    public static void shareRecords(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[DMS Sharing] shareRecords received empty records list.');
            return;
        }

        System.debug(LoggingLevel.INFO, '[DMS Sharing] --- START SHARING CALCULATION for ' + records.size() + ' record(s) ---');

        // =====================================================================
        // STEP 1: Collect Records & Resolve Target Business Accounts
        // =====================================================================
        Map<Id, SObject> validRecordsMap = new Map<Id, SObject>();
        Map<Id, Set<Id>> recordToAccountIdsMap = new Map<Id, Set<Id>>();
        Set<Id> allTargetAccountIds = new Set<Id>();

        // Line item records requiring parent header lookup resolution
        Map<Schema.SObjectType, Map<Id, List<SObject>>> lineItemsByParentType = new Map<Schema.SObjectType, Map<Id, List<SObject>>>();

        for (SObject rec : records) {
            if (rec == null || rec.Id == null) {
                continue;
            }
            Schema.SObjectType sType = rec.getSObjectType();
            String objName = sType.getDescribe().getName();

            // Skip non-custom objects unless Account
            if (!objName.endsWith('__c') && objName != 'Account') {
                System.debug(LoggingLevel.FINE, '[DMS Sharing] Skipping non-custom sObject: ' + objName);
                continue;
            }

            ShareMetadataResolver.ShareDescriptor descr = ShareMetadataResolver.getDescriptor(sType);
            
            // Check if this record is a Line Item object requiring parent header lookup
            if (descr != null && String.isNotBlank(descr.parentLookupFieldName) && descr.parentObjectType != null) {
                Id parentId = null;
                try {
                    parentId = (Id) rec.get(descr.parentLookupFieldName);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, '[DMS Sharing] Could not read parent field ' + descr.parentLookupFieldName + ' on ' + objName + ': ' + e.getMessage());
                }

                if (parentId != null) {
                    validRecordsMap.put(rec.Id, rec);
                    if (!lineItemsByParentType.containsKey(descr.parentObjectType)) {
                        lineItemsByParentType.put(descr.parentObjectType, new Map<Id, List<SObject>>());
                    }
                    Map<Id, List<SObject>> parentMap = lineItemsByParentType.get(descr.parentObjectType);
                    if (!parentMap.containsKey(parentId)) {
                        parentMap.put(parentId, new List<SObject>());
                    }
                    parentMap.get(parentId).add(rec);
                } else {
                    System.debug(LoggingLevel.INFO, '[DMS Sharing] Record ' + rec.Id + ' has null parent ' + descr.parentLookupFieldName + '. Skipping.');
                }
                continue;
            }

            // Direct object: extract Account IDs from configured lookup fields
            Set<Id> recordAccIds = extractAccountIds(rec, descr);
            if (!recordAccIds.isEmpty()) {
                validRecordsMap.put(rec.Id, rec);
                recordToAccountIdsMap.put(rec.Id, recordAccIds);
                allTargetAccountIds.addAll(recordAccIds);
            } else {
                System.debug(LoggingLevel.INFO, '[DMS Sharing] Record ' + rec.Id + ' (' + objName + ') has no populated Account fields. Skipping.');
            }
        }

        // Resolve line item parent headers
        if (!lineItemsByParentType.isEmpty()) {
            resolveLineItemParents(lineItemsByParentType, recordToAccountIdsMap, allTargetAccountIds);
        }

        System.debug(LoggingLevel.INFO, '[DMS Sharing] Step 1: Valid Records Count = ' + validRecordsMap.size());
        System.debug(LoggingLevel.INFO, '[DMS Sharing] Step 1: Target Account IDs Count = ' + allTargetAccountIds.size());

        if (validRecordsMap.isEmpty() || allTargetAccountIds.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[DMS Sharing] EXIT EARLY at Step 1: No valid custom objects or non-null Account IDs found.');
            return;
        }

        // =====================================================================
        // STEP 2: Traverse Account Hierarchy
        // =====================================================================
        Map<Id, List<Account>> accountHierarchyMap = AccountHierarchyService.getParentHierarchyMap(allTargetAccountIds);

        // =====================================================================
        // STEP 3: Find Public Groups for ALL accounts in the hierarchy
        // =====================================================================
        Set<Id> allHierarchyAccountIds = new Set<Id>();
        for (List<Account> hierarchy : accountHierarchyMap.values()) {
            for (Account acc : hierarchy) {
                allHierarchyAccountIds.add(acc.Id);
            }
        }

        Map<Id, List<Account_Public_Group_Mapping__c>> groupMappingsByAccount = PublicGroupService.getPublicGroupMappingsForAccounts(allHierarchyAccountIds);

        // =====================================================================
        // STEP 4: Create Share Records
        // Group valid records by SObjectType for share object creation
        // =====================================================================
        Map<Schema.SObjectType, List<SObject>> recordsByObjectType = new Map<Schema.SObjectType, List<SObject>>();
        for (SObject rec : validRecordsMap.values()) {
            Schema.SObjectType sType = rec.getSObjectType();
            if (!recordsByObjectType.containsKey(sType)) {
                recordsByObjectType.put(sType, new List<SObject>());
            }
            recordsByObjectType.get(sType).add(rec);
        }

        List<SObject> allSharesToInsert = new List<SObject>();

        for (Schema.SObjectType sType : recordsByObjectType.keySet()) {
            List<SObject> objectRecords = recordsByObjectType.get(sType);
            String objApiName = sType.getDescribe().getName();
            ShareMetadataResolver.ShareDescriptor descr = ShareMetadataResolver.getDescriptor(sType);

            String shareObjApiName = (descr != null && String.isNotBlank(descr.shareObjectApiName)) ? descr.shareObjectApiName : (objApiName == 'Account' ? 'AccountShare' : objApiName.replace('__c', '__Share'));
            Schema.SObjectType shareSObjectType = Schema.getGlobalDescribe().get(shareObjApiName);

            if (shareSObjectType == null) {
                System.debug(LoggingLevel.WARN, '[DMS Sharing] Share sObject is NULL for ' + objApiName + '. Check if Org-Wide Defaults (OWD) is Private/Public Read-Only and Apex Sharing is enabled!');
                continue;
            }

            String parentFieldName = (descr != null && String.isNotBlank(descr.parentFieldName)) ? descr.parentFieldName : 'ParentId';
            String accessFieldName = (descr != null && String.isNotBlank(descr.accessFieldName)) ? descr.accessFieldName : 'AccessLevel';

            Map<String, SObject> newSharesMap = new Map<String, SObject>();

            for (SObject rec : objectRecords) {
                Set<Id> recordAccIds = recordToAccountIdsMap.get(rec.Id);
                if (recordAccIds == null || recordAccIds.isEmpty()) {
                    continue;
                }

                for (Id accId : recordAccIds) {
                    List<Account> hierarchy = accountHierarchyMap.get(accId);
                    if (hierarchy == null || hierarchy.isEmpty()) {
                        continue;
                    }

                    for (Account hAcc : hierarchy) {
                        List<Account_Public_Group_Mapping__c> mappings = groupMappingsByAccount.get(hAcc.Id);
                        if (mappings == null || mappings.isEmpty()) {
                            continue;
                        }

                        for (Account_Public_Group_Mapping__c mapping : mappings) {
                            if (String.isBlank(mapping.Public_Group_Id__c)) {
                                continue;
                            }

                            Id groupId = (Id) mapping.Public_Group_Id__c;
                            String accessLevel = translateAccessLevel(mapping.Access_Level__c);
                            String uniqueKey = rec.Id + '_' + groupId;

                            if (!newSharesMap.containsKey(uniqueKey)) {
                                SObject shareRec = shareSObjectType.newSObject();
                                if (objApiName == 'Account') {
                                    shareRec.put('AccountId', rec.Id);
                                    shareRec.put('UserOrGroupId', groupId);
                                    shareRec.put('AccountAccessLevel', accessLevel);
                                    shareRec.put('OpportunityAccessLevel', 'None');
                                    shareRec.put('CaseAccessLevel', 'None');
                                } else {
                                    shareRec.put(parentFieldName, rec.Id);
                                    shareRec.put('UserOrGroupId', groupId);
                                    shareRec.put(accessFieldName, accessLevel);
                                    if (descr == null || descr.isRowCauseWriteable == null || descr.isRowCauseWriteable) {
                                        shareRec.put('RowCause', 'Manual');
                                    }
                                }

                                newSharesMap.put(uniqueKey, shareRec);
                                System.debug(LoggingLevel.INFO, '[DMS Sharing] ADD SHARE RECORD: Key = ' + uniqueKey + ' | GroupId = ' + groupId + ' | AccessLevel = ' + accessLevel);
                            }
                        }
                    }
                }
            }

            if (!newSharesMap.isEmpty()) {
                allSharesToInsert.addAll(newSharesMap.values());
            }
        }

        // =====================================================================
        // STEP 5: Insert Share Records
        // =====================================================================
        System.debug(LoggingLevel.INFO, '[DMS Sharing] Step 5: TOTAL Shares to Insert across all objects = ' + allSharesToInsert.size());

        if (!allSharesToInsert.isEmpty()) {
            List<Database.SaveResult> results = Database.insert(allSharesToInsert, false);
            Integer successCount = 0;
            Integer errorCount = 0;

            for (Integer i = 0; i < results.size(); i++) {
                Database.SaveResult sr = results[i];
                if (sr.isSuccess()) {
                    successCount++;
                } else {
                    errorCount++;
                    for (Database.Error err : sr.getErrors()) {
                        if (err.getStatusCode() != StatusCode.DUPLICATE_VALUE) {
                            System.debug(LoggingLevel.ERROR, '[DMS Sharing] Apex Sharing Insert Error: ' + err.getStatusCode() + ' - ' + err.getMessage());
                        } else {
                            System.debug(LoggingLevel.FINE, '[DMS Sharing] Duplicate share record harmlessly skipped.');
                        }
                    }
                }
            }
            System.debug(LoggingLevel.INFO, '[DMS Sharing] Step 5 DML RESULT: Success = ' + successCount + ' | Failures/Duplicates = ' + errorCount);
        } else {
            System.debug(LoggingLevel.WARN, '[DMS Sharing] EXIT AT STEP 5: allSharesToInsert is EMPTY! No share records were generated.');
        }
    }

    /**
     * @description Extracts non-null Account IDs from record fields defined in descriptor.
     */
    private static Set<Id> extractAccountIds(SObject rec, ShareMetadataResolver.ShareDescriptor descr) {
        Set<Id> accIds = new Set<Id>();
        if (rec == null) return accIds;

        List<String> fieldCandidates = new List<String>();
        if (descr != null && descr.accountLookupFieldNames != null && !descr.accountLookupFieldNames.isEmpty()) {
            fieldCandidates.addAll(descr.accountLookupFieldNames);
        } else if (descr != null && String.isNotBlank(descr.accountLookupFieldName)) {
            fieldCandidates.add(descr.accountLookupFieldName);
        } else {
            fieldCandidates.add('Requesting_Account__c');
            fieldCandidates.add('Account__c');
        }

        for (String fName : fieldCandidates) {
            try {
                Id val = (Id) rec.get(fName);
                if (val != null) {
                    accIds.add(val);
                }
            } catch (Exception e) {
                // Field doesn't exist on this record, ignore
            }
        }
        return accIds;
    }

    /**
     * @description Queries parent header records for line item objects and maps parent business accounts.
     */
    private static void resolveLineItemParents(
        Map<Schema.SObjectType, Map<Id, List<SObject>>> lineItemsByParentType,
        Map<Id, Set<Id>> recordToAccountIdsMap,
        Set<Id> allTargetAccountIds
    ) {
        for (Schema.SObjectType parentType : lineItemsByParentType.keySet()) {
            Map<Id, List<SObject>> parentToLineItems = lineItemsByParentType.get(parentType);
            Set<Id> parentIds = parentToLineItems.keySet();
            if (parentIds.isEmpty()) continue;

            ShareMetadataResolver.ShareDescriptor parentDescr = ShareMetadataResolver.getDescriptor(parentType);
            String parentObjName = parentType.getDescribe().getName();

            // Build dynamic SOQL query for parent header records
            Set<String> fieldsToQuery = new Set<String>{ 'Id' };
            if (parentDescr != null && parentDescr.accountLookupFieldNames != null) {
                for (String f : parentDescr.accountLookupFieldNames) {
                    fieldsToQuery.add(f);
                }
            } else {
                fieldsToQuery.add('Requesting_Account__c');
                fieldsToQuery.add('Account__c');
            }

            String query = 'SELECT ' + String.join(new List<String>(fieldsToQuery), ', ') +
                           ' FROM ' + parentObjName +
                           ' WHERE Id IN :parentIds';

            try {
                List<SObject> parents = Database.query(query);
                for (SObject p : parents) {
                    Set<Id> parentAccIds = extractAccountIds(p, parentDescr);
                    List<SObject> childItems = parentToLineItems.get(p.Id);
                    if (childItems != null && !parentAccIds.isEmpty()) {
                        for (SObject child : childItems) {
                            if (!recordToAccountIdsMap.containsKey(child.Id)) {
                                recordToAccountIdsMap.put(child.Id, new Set<Id>());
                            }
                            recordToAccountIdsMap.get(child.Id).addAll(parentAccIds);
                            allTargetAccountIds.addAll(parentAccIds);
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[DMS Sharing] Error querying parent header records for ' + parentObjName + ': ' + e.getMessage());
            }
        }
    }

    /**
     * @description Helper to translate Account_Public_Group_Mapping__c.Access_Level__c to SObject__Share.AccessLevel.
     */
    private static String translateAccessLevel(String accessLevel) {
        if (String.isBlank(accessLevel)) {
            return 'Read';
        }
        if (accessLevel.equalsIgnoreCase('Edit') || accessLevel.equalsIgnoreCase('Full Access') || accessLevel.equalsIgnoreCase('FullAccess')) {
            return 'Edit';
        }
        return 'Read';
    }
}