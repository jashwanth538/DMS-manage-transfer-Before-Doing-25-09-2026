/**
 * @description Service class to retrieve Salesforce Public Groups mapped to Accounts via
 *              Account_Public_Group_Mapping__c records for the Dealer Management System (DMS).
 * @author DeepMind Antigravity
 * @date 2026-07-30
 */
public without sharing class PublicGroupService {

    /**
     * @description Returns a Map of AccountId -> Group sObject for a Set of Account IDs.
     *              Queries active Account_Public_Group_Mapping__c records and resolves the target Group sObjects.
     * @param accountIds Set of Account IDs.
     * @return Map<Id, Group> mapping AccountId -> Public Group.
     */
    public static Map<Id, Group> getGroupsForAccounts(Set<Id> accountIds) {
        Map<Id, Group> resultMap = new Map<Id, Group>();
        if (accountIds == null || accountIds.isEmpty()) {
            return resultMap;
        }

        Map<Id, List<Account_Public_Group_Mapping__c>> mappingsMap = getPublicGroupMappingsForAccounts(accountIds);
        Set<Id> groupIds = new Set<Id>();

        for (List<Account_Public_Group_Mapping__c> mappingList : mappingsMap.values()) {
            for (Account_Public_Group_Mapping__c mapping : mappingList) {
                if (String.isNotBlank(mapping.Public_Group_Id__c)) {
                    try {
                        groupIds.add((Id) mapping.Public_Group_Id__c);
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, '[DMS Public Group] Invalid Public Group Id format: ' + mapping.Public_Group_Id__c);
                    }
                }
            }
        }

        if (groupIds.isEmpty()) {
            return resultMap;
        }

        Map<Id, Group> groupsById = new Map<Id, Group>([
            SELECT Id, Name, DeveloperName, Type
            FROM Group
            WHERE Id IN :groupIds
        ]);

        for (Id accId : mappingsMap.keySet()) {
            List<Account_Public_Group_Mapping__c> mappingList = mappingsMap.get(accId);
            for (Account_Public_Group_Mapping__c mapping : mappingList) {
                if (String.isNotBlank(mapping.Public_Group_Id__c)) {
                    Id gId = (Id) mapping.Public_Group_Id__c;
                    if (groupsById.containsKey(gId)) {
                        resultMap.put(accId, groupsById.get(gId));
                        break; // Uses the primary/first active group per account for single Group mapping
                    }
                }
            }
        }

        return resultMap;
    }

    /**
     * @description Returns a Map of AccountId -> List<Account_Public_Group_Mapping__c> for a Set of Account IDs.
     * @param accountIds Set of Account IDs.
     * @return Map<Id, List<Account_Public_Group_Mapping__c>> mapping AccountId -> List of active mappings.
     */
    public static Map<Id, List<Account_Public_Group_Mapping__c>> getPublicGroupMappingsForAccounts(Set<Id> accountIds) {
        Map<Id, List<Account_Public_Group_Mapping__c>> resultMap = new Map<Id, List<Account_Public_Group_Mapping__c>>();
        if (accountIds == null || accountIds.isEmpty()) {
            System.debug(LoggingLevel.FINE, '[DMS Public Group] getPublicGroupMappingsForAccounts received empty accountIds.');
            return resultMap;
        }

        for (Id accId : accountIds) {
            if (accId != null) {
                resultMap.put(accId, new List<Account_Public_Group_Mapping__c>());
            }
        }

        System.debug('==============================');
        System.debug('ACCOUNT IDS RECEIVED');
        System.debug(accountIds);
        System.debug('==============================');

        List<Account_Public_Group_Mapping__c> mappings = [
            SELECT Id, Account__c, Account__r.Name, Public_Group_Id__c, Public_Group_Name__c, Access_Level__c, Active__c
            FROM Account_Public_Group_Mapping__c
            WHERE Account__c IN :accountIds
              AND Active__c = true
            ORDER BY CreatedDate ASC
        ];

        System.debug('==============================');
        System.debug('ROWS RETURNED = ' + mappings.size());

        for (Account_Public_Group_Mapping__c m : mappings) {
            System.debug(
                (m.Account__r != null ? m.Account__r.Name : m.Account__c) +
                ' -> ' +
                m.Public_Group_Name__c
            );
        }

        System.debug('==============================');

        for (Account_Public_Group_Mapping__c mapping : mappings) {
            if (resultMap.containsKey(mapping.Account__c)) {
                resultMap.get(mapping.Account__c).add(mapping);
            }
        }

        return resultMap;
    }
}