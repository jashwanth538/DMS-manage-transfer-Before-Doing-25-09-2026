/**
 * @description Enterprise-grade Generic Record Sharing Inspector Controller.
 *              Provides a single entry point to inspect Apex Managed Sharing for ANY custom object
 *              (both Header and Line Item custom objects).
 *              Dynamically resolves object types, share tables, public group memberships,
 *              account mappings, parent header relationships, and diagnostics without hardcoding object names.
 * @author DeepMind Antigravity
 * @date 2026-08-04
 */
public with sharing class RecordSharingInspectorController {

    // =========================================================================
    // CONFIGURABLE: Objects whose Name/AutoNumber fields are searchable.
    // Includes all DMS Header and Line Item custom objects.
    // =========================================================================
    private static final List<String> SEARCHABLE_OBJECTS = new List<String>{
        'Account',
        'Purchase_Requisition__c',
        'Purchase_Requisition_Line__c',
        'Purchase_Order__c',
        'Purchase_Order_Line_Item__c',
        'Order_Allocation__c',
        'Order_Allocation_Line_Item__c',
        'Inventory_Reservation__c',
        'Inventory__c',
        'Inventory_Location__c',
        'GRN__c',
        'GRN_Line_Item__c',
        'Inventory_Transfer__c',
        'Item__c',
        'Supply_Request__c',
        'Item_Price__c',
        'Payable__c',
        'Receivable__c',
        'Invoice__c'
    };

    // =========================================================================
    // WRAPPER: Complete inspection result returned to LWC
    // =========================================================================
    public class InspectionResult {
        @AuraEnabled public RecordDetail recordDetail;
        @AuraEnabled public List<ShareRecordWrapper> shareRecords;
        @AuraEnabled public List<GroupMemberWrapper> groupsWithMembers;
        @AuraEnabled public List<String> effectiveUserNames;
        @AuraEnabled public List<AccountMappingWrapper> accountMappings;
        @AuraEnabled public SharingSummary summary;
        @AuraEnabled public List<DiagnosticItem> diagnostics;
        @AuraEnabled public String shareObjectApiName;
        @AuraEnabled public String shareSoql;
    }

    // =========================================================================
    // WRAPPER: Record detail information
    // =========================================================================
    public class RecordDetail {
        @AuraEnabled public String objectName;
        @AuraEnabled public String recordName;
        @AuraEnabled public String recordId;
        @AuraEnabled public String ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String createdById;
        @AuraEnabled public String createdByName;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime lastModifiedDate;
        @AuraEnabled public String accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String parentRecordId;
        @AuraEnabled public String parentRecordName;
        @AuraEnabled public String parentObjectName;
    }

    // =========================================================================
    // WRAPPER: Share record row
    // =========================================================================
    public class ShareRecordWrapper {
        @AuraEnabled public String shareId;
        @AuraEnabled public String userOrGroupId;
        @AuraEnabled public String userOrGroupName;
        @AuraEnabled public String userOrGroupType;
        @AuraEnabled public String accessLevel;
        @AuraEnabled public String rowCause;
    }

    // =========================================================================
    // WRAPPER: Public Group with its members
    // =========================================================================
    public class GroupMemberWrapper {
        @AuraEnabled public String groupId;
        @AuraEnabled public String groupName;
        @AuraEnabled public List<MemberInfo> members;
    }

    public class MemberInfo {
        @AuraEnabled public String memberId;
        @AuraEnabled public String memberName;
        @AuraEnabled public String memberType;
    }

    // =========================================================================
    // WRAPPER: Account_Public_Group_Mapping__c row
    // =========================================================================
    public class AccountMappingWrapper {
        @AuraEnabled public String mappingId;
        @AuraEnabled public String accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String publicGroupId;
        @AuraEnabled public String publicGroupName;
        @AuraEnabled public String accessLevel;
        @AuraEnabled public Boolean isActive;
    }

    // =========================================================================
    // WRAPPER: Summary counts
    // =========================================================================
    public class SharingSummary {
        @AuraEnabled public Integer totalShareRecords = 0;
        @AuraEnabled public Integer totalPublicGroups = 0;
        @AuraEnabled public Integer totalEffectiveUsers = 0;
    }

    // =========================================================================
    // WRAPPER: Diagnostic check result
    // =========================================================================
    public class DiagnosticItem {
        @AuraEnabled public String label;
        @AuraEnabled public String status;   // 'pass' or 'fail' or 'warn'
        @AuraEnabled public String message;
    }

    // =========================================================================
    // ACTION: Recalculate sharing for a specific Record Id
    // =========================================================================
    @AuraEnabled
    public static InspectionResult recalculateSharing(Id recordId) {
        if (recordId == null) {
            throw new AuraHandledException('Record ID cannot be null.');
        }
        try {
            RecordSharingService.shareRecord(recordId);
            return inspectSharing((String) recordId);
        } catch (Exception e) {
            throw new AuraHandledException('Failed to recalculate sharing: ' + e.getMessage());
        }
    }

    // =========================================================================
    // MAIN: Inspect sharing for a given search input (Record Id or Name)
    // =========================================================================
    @AuraEnabled(cacheable=false)
    public static InspectionResult inspectSharing(String searchInput) {
        if (String.isBlank(searchInput)) {
            throw new AuraHandledException('Search input cannot be empty.');
        }

        searchInput = searchInput.trim();
        InspectionResult result = new InspectionResult();
        result.shareRecords = new List<ShareRecordWrapper>();
        result.groupsWithMembers = new List<GroupMemberWrapper>();
        result.effectiveUserNames = new List<String>();
        result.accountMappings = new List<AccountMappingWrapper>();
        result.summary = new SharingSummary();
        result.diagnostics = new List<DiagnosticItem>();

        // -----------------------------------------------------------------
        // 1. RESOLVE RECORD: By Id or by Name search
        // -----------------------------------------------------------------
        Id recordId;
        Schema.SObjectType sObjType;
        SObject targetRecord;

        if (isValidSalesforceId(searchInput)) {
            // Direct ID lookup
            try {
                recordId = Id.valueOf(searchInput);
                sObjType = recordId.getSObjectType();
            } catch (Exception e) {
                throw new AuraHandledException('Invalid Salesforce Record ID: ' + searchInput);
            }
        } else {
            // Name-based search across configured objects
            Map<String, Object> searchResult = searchByName(searchInput);
            if (searchResult == null) {
                throw new AuraHandledException('No record found matching "' + searchInput + '" across configured DMS objects.');
            }
            recordId = (Id) searchResult.get('recordId');
            sObjType = (Schema.SObjectType) searchResult.get('sObjectType');
        }

        String objectApiName = sObjType.getDescribe().getName();
        String objectLabel = sObjType.getDescribe().getLabel();

        // -----------------------------------------------------------------
        // 2. QUERY RECORD DETAILS
        // -----------------------------------------------------------------
        targetRecord = queryRecordDetails(recordId, sObjType);
        if (targetRecord == null) {
            throw new AuraHandledException('Record not found or user lacks access for Id/Name: ' + searchInput);
        }

        RecordDetail detail = new RecordDetail();
        detail.objectName = objectLabel + ' (' + objectApiName + ')';
        detail.recordId = (String) recordId;
        detail.recordName = getFieldValue(targetRecord, 'Name');
        detail.ownerId = getFieldValue(targetRecord, 'OwnerId');
        detail.ownerName = getRelationFieldValue(targetRecord, 'Owner', 'Name');
        detail.createdById = getFieldValue(targetRecord, 'CreatedById');
        detail.createdByName = getRelationFieldValue(targetRecord, 'CreatedBy', 'Name');
        detail.createdDate = (Datetime) getFieldValueRaw(targetRecord, 'CreatedDate');
        detail.lastModifiedDate = (Datetime) getFieldValueRaw(targetRecord, 'LastModifiedDate');

        ShareMetadataResolver.ShareDescriptor descr = ShareMetadataResolver.getDescriptor(sObjType);

        // Check if this record is a line item with parent lookup
        if (descr != null && String.isNotBlank(descr.parentLookupFieldName)) {
            String pFieldName = descr.parentLookupFieldName;
            String pRelName = pFieldName.endsWith('__c') ? pFieldName.replace('__c', '__r') : pFieldName;
            
            detail.parentRecordId = getFieldValue(targetRecord, pFieldName);
            detail.parentRecordName = getRelationFieldValue(targetRecord, pRelName, 'Name');
            if (descr.parentObjectType != null) {
                detail.parentObjectName = descr.parentObjectType.getDescribe().getLabel() + ' (' + descr.parentObjectType.getDescribe().getName() + ')';
            }

            // Get Business Account from Parent Header
            ShareMetadataResolver.ShareDescriptor parentDescr = (descr.parentObjectType != null)
                ? ShareMetadataResolver.getDescriptor(descr.parentObjectType)
                : null;
            List<String> parentAccFields = (parentDescr != null && parentDescr.accountLookupFieldNames != null && !parentDescr.accountLookupFieldNames.isEmpty())
                ? parentDescr.accountLookupFieldNames
                : new List<String>{ 'Supplying_Account__c', 'Requesting_Account__c', 'Account__c' };

            for (String pAccField : parentAccFields) {
                String val = getRelationFieldValue(targetRecord, pRelName, pAccField);
                if (String.isNotBlank(val)) {
                    detail.accountId = val;
                    String pAccRel = pAccField.endsWith('__c') ? pAccField.replace('__c', '__r') : pAccField;
                    detail.accountName = getRelationPathValue(targetRecord, new List<String>{ pRelName, pAccRel, 'Name' });
                    break;
                }
            }
        }

        // Direct object or fallback if parent account was unpopulated
        if (String.isBlank(detail.accountId)) {
            if (sObjType == Account.SObjectType) {
                detail.accountId = (String) recordId;
                detail.accountName = detail.recordName;
            } else {
                List<String> accCandidates = (descr != null && descr.accountLookupFieldNames != null)
                    ? descr.accountLookupFieldNames
                    : new List<String>{ 'Requesting_Account__c', 'Account__c', 'From_Account__c' };

                for (String fName : accCandidates) {
                    String val = getFieldValue(targetRecord, fName);
                    if (String.isNotBlank(val)) {
                        detail.accountId = val;
                        String relName = fName.endsWith('__c') ? fName.replace('__c', '__r') : fName;
                        detail.accountName = getRelationFieldValue(targetRecord, relName, 'Name');
                        break;
                    }
                }
            }
        }
        result.recordDetail = detail;

        // -----------------------------------------------------------------
        // 3. RESOLVE & QUERY SHARE RECORDS
        // -----------------------------------------------------------------
        String shareObjApiName = (descr != null && String.isNotBlank(descr.shareObjectApiName))
            ? descr.shareObjectApiName
            : (objectApiName == 'Account' ? 'AccountShare' : objectApiName.replace('__c', '__Share'));
        
        result.shareObjectApiName = shareObjApiName;
        String parentFieldName = (descr != null && String.isNotBlank(descr.parentFieldName)) ? descr.parentFieldName : (objectApiName == 'Account' ? 'AccountId' : 'ParentId');

        result.shareSoql = objectApiName == 'Account'
            ? 'SELECT Id, AccountId, UserOrGroupId, AccountAccessLevel, RowCause FROM AccountShare WHERE AccountId = \'' + recordId + '\''
            : 'SELECT Id, ' + parentFieldName + ', UserOrGroupId, AccessLevel, RowCause FROM ' + shareObjApiName + ' WHERE ' + parentFieldName + ' = \'' + recordId + '\'';

        Schema.SObjectType shareType = Schema.getGlobalDescribe().get(shareObjApiName);
        List<SObject> shareRows = new List<SObject>();

        if (shareType != null) {
            String shareSoql = objectApiName == 'Account'
                ? 'SELECT Id, AccountId, UserOrGroupId, AccountAccessLevel, RowCause FROM AccountShare WHERE AccountId = :recordId'
                : 'SELECT Id, ' + parentFieldName + ', UserOrGroupId, AccessLevel, RowCause FROM ' + shareObjApiName + ' WHERE ' + parentFieldName + ' = :recordId';
            try {
                shareRows = Database.query(shareSoql);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[Inspector] Share query failed: ' + e.getMessage());
            }
        }

        // Collect UserOrGroupIds for resolution
        Set<Id> userOrGroupIds = new Set<Id>();
        for (SObject sr : shareRows) {
            Id uogId = (Id) sr.get('UserOrGroupId');
            if (uogId != null) {
                userOrGroupIds.add(uogId);
            }
        }

        // Resolve names: query Users and Groups
        Map<Id, String> nameMap = new Map<Id, String>();
        Map<Id, String> typeMap = new Map<Id, String>();
        if (!userOrGroupIds.isEmpty()) {
            resolveUserOrGroupNames(userOrGroupIds, nameMap, typeMap);
        }

        // Build share record wrappers
        for (SObject sr : shareRows) {
            ShareRecordWrapper sw = new ShareRecordWrapper();
            sw.shareId = (String) sr.get('Id');
            Id uogId = (Id) sr.get('UserOrGroupId');
            sw.userOrGroupId = (String) uogId;
            sw.userOrGroupName = nameMap.containsKey(uogId) ? nameMap.get(uogId) : String.valueOf(uogId);
            sw.userOrGroupType = typeMap.containsKey(uogId) ? typeMap.get(uogId) : 'Unknown';
            sw.accessLevel = (String) (objectApiName == 'Account' ? sr.get('AccountAccessLevel') : sr.get('AccessLevel'));
            sw.rowCause = (String) sr.get('RowCause');
            result.shareRecords.add(sw);
        }

        // -----------------------------------------------------------------
        // 4. PUBLIC GROUP MEMBERS & EFFECTIVE USERS
        // -----------------------------------------------------------------
        Set<Id> publicGroupIds = new Set<Id>();
        for (Id uogId : userOrGroupIds) {
            if (typeMap.containsKey(uogId) && typeMap.get(uogId) == 'Public Group') {
                publicGroupIds.add(uogId);
            }
        }

        Set<String> effectiveUserSet = new Set<String>();

        if (!publicGroupIds.isEmpty()) {
            // Query GroupMember for all public groups
            List<GroupMember> allMembers = [
                SELECT GroupId, UserOrGroupId
                FROM GroupMember
                WHERE GroupId IN :publicGroupIds
            ];

            // Collect all member Ids for name resolution
            Set<Id> memberIds = new Set<Id>();
            for (GroupMember gm : allMembers) {
                memberIds.add(gm.UserOrGroupId);
            }

            // Resolve member names
            Map<Id, String> memberNameMap = new Map<Id, String>();
            Map<Id, String> memberTypeMap = new Map<Id, String>();
            if (!memberIds.isEmpty()) {
                resolveUserOrGroupNames(memberIds, memberNameMap, memberTypeMap);
            }

            // Group names
            Map<Id, String> groupNameMap = new Map<Id, String>();
            for (Id gId : publicGroupIds) {
                if (nameMap.containsKey(gId)) {
                    groupNameMap.put(gId, nameMap.get(gId));
                }
            }

            // Build group member wrappers
            Map<Id, GroupMemberWrapper> gmwMap = new Map<Id, GroupMemberWrapper>();
            for (Id gId : publicGroupIds) {
                GroupMemberWrapper gmw = new GroupMemberWrapper();
                gmw.groupId = (String) gId;
                gmw.groupName = groupNameMap.containsKey(gId) ? groupNameMap.get(gId) : String.valueOf(gId);
                gmw.members = new List<MemberInfo>();
                gmwMap.put(gId, gmw);
            }

            for (GroupMember gm : allMembers) {
                MemberInfo mi = new MemberInfo();
                mi.memberId = (String) gm.UserOrGroupId;
                mi.memberName = memberNameMap.containsKey(gm.UserOrGroupId) ? memberNameMap.get(gm.UserOrGroupId) : String.valueOf(gm.UserOrGroupId);
                mi.memberType = memberTypeMap.containsKey(gm.UserOrGroupId) ? memberTypeMap.get(gm.UserOrGroupId) : 'Unknown';

                if (gmwMap.containsKey(gm.GroupId)) {
                    gmwMap.get(gm.GroupId).members.add(mi);
                }

                // Effective users: only count User members
                if (mi.memberType == 'User') {
                    effectiveUserSet.add(mi.memberName);
                }
            }

            result.groupsWithMembers = gmwMap.values();
        }

        // Also add direct User shares to effective users
        for (Id uogId : userOrGroupIds) {
            if (typeMap.containsKey(uogId) && typeMap.get(uogId) == 'User') {
                effectiveUserSet.add(nameMap.get(uogId));
            }
        }
        result.effectiveUserNames = new List<String>(effectiveUserSet);
        result.effectiveUserNames.sort();

        // -----------------------------------------------------------------
        // 5. ACCOUNT MAPPINGS
        // -----------------------------------------------------------------
        if (String.isNotBlank(detail.accountId)) {
            Id accountId = Id.valueOf(detail.accountId);

            // Get hierarchy accounts for full mapping context
            List<Account> hierarchy = AccountHierarchyService.getHierarchy(accountId);
            Set<Id> hierarchyAccountIds = new Set<Id>();
            for (Account acc : hierarchy) {
                hierarchyAccountIds.add(acc.Id);
            }

            if (!hierarchyAccountIds.isEmpty()) {
                List<Account_Public_Group_Mapping__c> mappings = [
                    SELECT Id, Account__c, Account__r.Name, Public_Group_Id__c,
                           Public_Group_Name__c, Access_Level__c, Active__c
                    FROM Account_Public_Group_Mapping__c
                    WHERE Account__c IN :hierarchyAccountIds
                    ORDER BY Account__r.Name ASC
                ];

                for (Account_Public_Group_Mapping__c m : mappings) {
                    AccountMappingWrapper amw = new AccountMappingWrapper();
                    amw.mappingId = m.Id;
                    amw.accountId = m.Account__c;
                    amw.accountName = m.Account__r != null ? m.Account__r.Name : String.valueOf(m.Account__c);
                    amw.publicGroupId = m.Public_Group_Id__c;
                    amw.publicGroupName = String.isNotBlank(m.Public_Group_Name__c) ? m.Public_Group_Name__c : m.Public_Group_Id__c;
                    amw.accessLevel = m.Access_Level__c;
                    amw.isActive = m.Active__c;
                    result.accountMappings.add(amw);
                }
            }
        }

        // -----------------------------------------------------------------
        // 6. SUMMARY
        // -----------------------------------------------------------------
        result.summary.totalShareRecords = result.shareRecords.size();
        result.summary.totalPublicGroups = publicGroupIds.size();
        result.summary.totalEffectiveUsers = result.effectiveUserNames.size();

        // -----------------------------------------------------------------
        // 7. DIAGNOSTICS
        // -----------------------------------------------------------------
        result.diagnostics = runDiagnostics(detail, result, shareType, objectApiName, descr);

        return result;
    }

    // =========================================================================
    // HELPER: Search by Name/AutoNumber across configured objects
    // =========================================================================
    private static Map<String, Object> searchByName(String nameValue) {
        if (String.isBlank(nameValue)) {
            return null;
        }

        String trimmed = nameValue.trim();
        String compact = trimmed.replaceAll('\\s+', '');
        String likePattern = '%' + trimmed.replaceAll('\\s+', '%') + '%';

        for (String objName : SEARCHABLE_OBJECTS) {
            Schema.SObjectType sType = Schema.getGlobalDescribe().get(objName);
            if (sType == null) {
                continue;
            }

            Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();
            Boolean hasName = fieldMap.containsKey('name');
            Boolean hasItemCode = fieldMap.containsKey('item_code__c');
            Boolean hasLocationCode = fieldMap.containsKey('inventory_location_code__c');

            List<String> orConditions = new List<String>();
            if (hasName) {
                orConditions.add('Name = :trimmed');
                orConditions.add('Name = :compact');
                orConditions.add('Name LIKE :likePattern');
            }
            if (hasItemCode) {
                orConditions.add('Item_Code__c = :trimmed');
                orConditions.add('Item_Code__c = :compact');
                orConditions.add('Item_Code__c LIKE :likePattern');
            }
            if (hasLocationCode) {
                orConditions.add('Inventory_Location_Code__c = :trimmed');
                orConditions.add('Inventory_Location_Code__c = :compact');
            }

            if (orConditions.isEmpty()) {
                continue;
            }

            String soql = 'SELECT Id FROM ' + objName + ' WHERE ' + String.join(orConditions, ' OR ') + ' LIMIT 1';
            List<SObject> rows;
            try {
                rows = Database.query(soql);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[Inspector] Name search failed on ' + objName + ': ' + e.getMessage());
                continue;
            }
            if (!rows.isEmpty()) {
                Map<String, Object> resultMap = new Map<String, Object>();
                resultMap.put('recordId', rows[0].Id);
                resultMap.put('sObjectType', sType);
                return resultMap;
            }
        }
        return null;
    }

    // =========================================================================
    // HELPER: Query record with all detail fields
    // =========================================================================
    private static SObject queryRecordDetails(Id recordId, Schema.SObjectType sType) {
        String objApiName = sType.getDescribe().getName();
        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();

        Set<String> fieldsSet = new Set<String>{ 'Id', 'Name', 'CreatedById', 'CreatedBy.Name', 'CreatedDate', 'LastModifiedDate' };

        // Only add Owner fields if present on this object (Master-Detail detail objects do NOT have OwnerId)
        if (fieldMap.containsKey('ownerid')) {
            fieldsSet.add('OwnerId');
            fieldsSet.add('Owner.Name');
        }

        ShareMetadataResolver.ShareDescriptor descr = ShareMetadataResolver.getDescriptor(sType);

        // Direct Account lookup fields
        if (descr != null && descr.accountLookupFieldNames != null) {
            for (String fName : descr.accountLookupFieldNames) {
                if (fName != 'Id' && fieldMap.containsKey(fName.toLowerCase())) {
                    fieldsSet.add(fName);
                    String relName = fName.endsWith('__c') ? fName.replace('__c', '__r') : fName;
                    fieldsSet.add(relName + '.Name');
                }
            }
        } else if (fieldMap.containsKey('account__c')) {
            fieldsSet.add('Account__c');
            fieldsSet.add('Account__r.Name');
        }

        // Parent relationship fields for Line Item objects
        if (descr != null && String.isNotBlank(descr.parentLookupFieldName) && fieldMap.containsKey(descr.parentLookupFieldName.toLowerCase())) {
            String pFieldName = descr.parentLookupFieldName;
            String pRelName = pFieldName.endsWith('__c') ? pFieldName.replace('__c', '__r') : pFieldName;
            fieldsSet.add(pFieldName);
            fieldsSet.add(pRelName + '.Name');

            ShareMetadataResolver.ShareDescriptor parentDescr = (descr.parentObjectType != null)
                ? ShareMetadataResolver.getDescriptor(descr.parentObjectType)
                : null;
            List<String> parentAccFields = (parentDescr != null && parentDescr.accountLookupFieldNames != null && !parentDescr.accountLookupFieldNames.isEmpty())
                ? parentDescr.accountLookupFieldNames
                : new List<String>{ 'Supplying_Account__c', 'Requesting_Account__c', 'Account__c' };

            for (String pAccField : parentAccFields) {
                fieldsSet.add(pRelName + '.' + pAccField);
                String pAccRel = pAccField.endsWith('__c') ? pAccField.replace('__c', '__r') : pAccField;
                fieldsSet.add(pRelName + '.' + pAccRel + '.Name');
            }
        }

        String soql = 'SELECT ' + String.join(new List<String>(fieldsSet), ', ') + ' FROM ' + objApiName + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> rows;
        try {
            rows = Database.query(soql);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[Inspector] Record query failed for ' + objApiName + ': ' + e.getMessage());
            return null;
        }
        return rows.isEmpty() ? null : rows[0];
    }

    // =========================================================================
    // HELPER: Resolve User/Group IDs to names and types
    // =========================================================================
    private static void resolveUserOrGroupNames(Set<Id> ids, Map<Id, String> nameMap, Map<Id, String> typeMap) {
        Set<Id> userIds = new Set<Id>();
        Set<Id> groupIds = new Set<Id>();

        for (Id anId : ids) {
            String prefix = String.valueOf(anId).substring(0, 3);
            if (prefix == '005') {
                userIds.add(anId);
            } else {
                groupIds.add(anId);
            }
        }

        if (!userIds.isEmpty()) {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :userIds]) {
                nameMap.put(u.Id, u.Name);
                typeMap.put(u.Id, 'User');
            }
        }

        if (!groupIds.isEmpty()) {
            for (Group g : [SELECT Id, Name, Type FROM Group WHERE Id IN :groupIds]) {
                nameMap.put(g.Id, g.Name);
                typeMap.put(g.Id, g.Type == 'Regular' ? 'Public Group' : g.Type);
            }
        }
    }

    // =========================================================================
    // HELPER: Safe field value extraction
    // =========================================================================
    private static String getFieldValue(SObject rec, String fieldName) {
        try {
            Object val = rec.get(fieldName);
            return val != null ? String.valueOf(val) : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static Object getFieldValueRaw(SObject rec, String fieldName) {
        try {
            return rec.get(fieldName);
        } catch (Exception e) {
            return null;
        }
    }

    private static String getRelationFieldValue(SObject rec, String relationName, String fieldName) {
        try {
            SObject related = rec.getSObject(relationName);
            if (related != null) {
                Object val = related.get(fieldName);
                return val != null ? String.valueOf(val) : null;
            }
        } catch (Exception e) {
            // Silently handle missing relationship
        }
        return null;
    }

    private static String getRelationPathValue(SObject rec, List<String> path) {
        if (rec == null || path == null || path.isEmpty()) return null;
        SObject current = rec;
        for (Integer i = 0; i < path.size() - 1; i++) {
            try {
                current = current.getSObject(path[i]);
                if (current == null) return null;
            } catch (Exception e) {
                return null;
            }
        }
        try {
            Object val = current.get(path[path.size() - 1]);
            return val != null ? String.valueOf(val) : null;
        } catch (Exception e) {
            return null;
        }
    }

    // =========================================================================
    // HELPER: Validate Salesforce Id format
    // =========================================================================
    private static Boolean isValidSalesforceId(String input) {
        if (String.isBlank(input)) return false;
        // 15 or 18 character Salesforce Id pattern
        return Pattern.matches('[a-zA-Z0-9]{15}|[a-zA-Z0-9]{18}', input);
    }

    // =========================================================================
    // DIAGNOSTICS ENGINE
    // =========================================================================
    private static List<DiagnosticItem> runDiagnostics(
        RecordDetail detail,
        InspectionResult result,
        Schema.SObjectType shareType,
        String objectApiName,
        ShareMetadataResolver.ShareDescriptor descr
    ) {
        List<DiagnosticItem> diags = new List<DiagnosticItem>();

        Boolean isLineItem = descr != null && String.isNotBlank(descr.parentLookupFieldName);
        String accLabel = isLineItem ? 'Parent Account Lookup' : 'Account Lookup';

        // 1. Account field populated?
        diags.add(buildDiagnostic(
            accLabel,
            String.isNotBlank(detail.accountId),
            String.isNotBlank(detail.accountId)
                ? (isLineItem ? 'Parent Account found: ' : 'Account found: ') + (String.isNotBlank(detail.accountName) ? detail.accountName : detail.accountId)
                : (isLineItem ? 'No Account found on parent header. Sharing cannot be calculated.' : 'No Account found on this record. Sharing cannot be calculated.')
        ));

        // 2. Share object exists?
        String expectedShareObjName = (descr != null && String.isNotBlank(descr.shareObjectApiName)) ? descr.shareObjectApiName : (objectApiName == 'Account' ? 'AccountShare' : objectApiName.replace('__c', '__Share'));
        diags.add(buildDiagnostic(
            'Share Object Exists',
            shareType != null,
            shareType != null
                ? 'Share object resolved: ' + expectedShareObjName
                : 'Share object NOT found: ' + expectedShareObjName + '. Check OWD is Private/Public Read-Only.'
        ));

        // 3. Share records created?
        diags.add(buildDiagnostic(
            'Share Records Created',
            result.shareRecords.size() > 0,
            result.shareRecords.size() > 0
                ? result.shareRecords.size() + ' share record(s) found.'
                : 'No share records found. Sharing may not have been triggered.'
        ));

        // 5. Account mapping exists?
        Boolean hasActiveMapping = false;
        for (AccountMappingWrapper amw : result.accountMappings) {
            if (amw.isActive == true) {
                hasActiveMapping = true;
                break;
            }
        }

        // 4. Has Manual shares (Apex Managed)?
        Boolean hasManualShares = false;
        for (ShareRecordWrapper sw : result.shareRecords) {
            if (sw.rowCause == 'Manual') {
                hasManualShares = true;
                break;
            }
        }
        String manualMessage;
        if (hasManualShares) {
            manualMessage = 'Manual (Apex Managed) share records present.';
        } else if (result.accountMappings.isEmpty()) {
            manualMessage = 'No Manual RowCause shares created: No Account_Public_Group_Mapping__c found for this Account or its parent hierarchy (check Dealer__c/Distributor__c/OEM__c on Account).';
        } else if (!hasActiveMapping) {
            manualMessage = 'No Manual RowCause shares created: All Public Group mappings in this Account hierarchy are inactive.';
        } else {
            manualMessage = 'No Manual RowCause shares found. RecordSharingService may not have fired.';
        }
        diags.add(buildDiagnostic(
            'Apex Managed Shares (Manual)',
            hasManualShares,
            manualMessage
        ));
        diags.add(buildDiagnostic(
            'Account_Public_Group_Mapping',
            result.accountMappings.size() > 0,
            result.accountMappings.size() > 0
                ? result.accountMappings.size() + ' mapping(s) found. Active: ' + (hasActiveMapping ? 'Yes' : 'NO — all mappings are inactive!')
                : 'No Account_Public_Group_Mapping__c records found for this Account hierarchy.'
        ));

        // 6. Inactive mapping warning
        if (result.accountMappings.size() > 0 && !hasActiveMapping) {
            diags.add(buildDiagnosticWarn(
                'Mapping Inactive',
                'All Account_Public_Group_Mapping__c records are inactive. Sharing will not work.'
            ));
        }

        // 7. Public groups have members?
        Boolean allGroupsHaveMembers = true;
        for (GroupMemberWrapper gmw : result.groupsWithMembers) {
            if (gmw.members == null || gmw.members.isEmpty()) {
                allGroupsHaveMembers = false;
                break;
            }
        }
        if (!result.groupsWithMembers.isEmpty()) {
            diags.add(buildDiagnostic(
                'Public Group Members',
                allGroupsHaveMembers,
                allGroupsHaveMembers
                    ? 'All Public Groups have members.'
                    : 'WARNING: One or more Public Groups have NO members. Users will not gain access.'
            ));
        }

        // 8. Effective users > 0?
        diags.add(buildDiagnostic(
            'Effective Users',
            result.effectiveUserNames.size() > 0,
            result.effectiveUserNames.size() > 0
                ? result.effectiveUserNames.size() + ' user(s) have effective access.'
                : 'No effective users detected. Only the Record Owner can access this record.'
        ));

        return diags;
    }

    private static DiagnosticItem buildDiagnostic(String label, Boolean pass, String message) {
        DiagnosticItem d = new DiagnosticItem();
        d.label = label;
        d.status = pass ? 'pass' : 'fail';
        d.message = message;
        return d;
    }

    private static DiagnosticItem buildDiagnosticWarn(String label, String message) {
        DiagnosticItem d = new DiagnosticItem();
        d.label = label;
        d.status = 'warn';
        d.message = message;
        return d;
    }
}