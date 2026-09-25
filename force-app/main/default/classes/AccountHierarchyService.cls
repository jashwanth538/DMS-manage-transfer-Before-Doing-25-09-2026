/**
 * @description Service class to traverse and manage Account Hierarchies (Child -> Parent -> ... -> Root OEM)
 *              for the Dealer Management System (DMS).
 * @author DeepMind Antigravity
 * @date 2026-07-30
 */
public without sharing class AccountHierarchyService {

    /**
     * @description Returns the complete hierarchy starting from the child account up to the root OEM account.
     *              Example return order: Retailer A1 -> Dealer A -> Hyderabad Distributor -> Tata Motors.
     * @param accountId Starting Account ID.
     * @return List<Account> ordered from child to root.
     */
    public static List<Account> getHierarchy(Id accountId) {
        if (accountId == null) {
            return new List<Account>();
        }
        Map<Id, List<Account>> resultMap = getParentHierarchyMap(new Set<Id>{ accountId });
        return resultMap.containsKey(accountId) ? resultMap.get(accountId) : new List<Account>();
    }

    /**
     * @description Returns only the parent/ancestor accounts of the given accountId (excluding the child itself).
     * @param accountId Starting Account ID.
     * @return List<Account> ordered from immediate parent to root.
     */
    public static List<Account> getParentAccounts(Id accountId) {
        List<Account> fullHierarchy = getHierarchy(accountId);
        if (fullHierarchy.size() <= 1) {
            return new List<Account>();
        }
        // Exclude the starting child account at index 0
        List<Account> parentAccounts = new List<Account>();
        for (Integer i = 1; i < fullHierarchy.size(); i++) {
            parentAccounts.add(fullHierarchy[i]);
        }
        return parentAccounts;
    }

    /**
     * @description Bulk-safe method to traverse Account hierarchies for a Set of Account IDs.
     *              Uses iterative SOQL batches without SOQL in loops.
     * @param accountIds Set of starting Account IDs.
     * @return Map<Id, List<Account>> mapping starting AccountId -> List<Account> (ordered child to root).
     */
    public static Map<Id, List<Account>> getParentHierarchyMap(Set<Id> accountIds) {
        Map<Id, List<Account>> resultMap = new Map<Id, List<Account>>();
        if (accountIds == null || accountIds.isEmpty()) {
            System.debug(LoggingLevel.FINE, '[DMS Hierarchy] getParentHierarchyMap received empty accountIds.');
            return resultMap;
        }

        System.debug(LoggingLevel.INFO, '[DMS Hierarchy] Starting lookup-based hierarchy resolution for Account IDs: ' + accountIds);

        // Remove nulls and initialize resultMap
        Set<Id> cleanAccountIds = new Set<Id>();
        for (Id accId : accountIds) {
            if (accId != null) {
                cleanAccountIds.add(accId);
                resultMap.put(accId, new List<Account>());
            }
        }

        if (cleanAccountIds.isEmpty()) {
            return resultMap;
        }

        // Query accounts and their immediate lookup hierarchies directly
        List<Account> accounts = [
            SELECT Id, Name, Type,
                   Dealer__c, Dealer__r.Name, Dealer__r.Type,
                   Distributor__c, Distributor__r.Name, Distributor__r.Type,
                   OEM__c, OEM__r.Name, OEM__r.Type
            FROM Account
            WHERE Id IN :cleanAccountIds
        ];

        for (Account acc : accounts) {
            List<Account> chain = new List<Account>();
            Set<Id> addedIds = new Set<Id>();

            // 1. Current Account
            chain.add(new Account(Id = acc.Id, Name = acc.Name, Type = acc.Type));
            addedIds.add(acc.Id);

            // 2. Dealer (if populated and not already in chain)
            if (acc.Dealer__c != null && !addedIds.contains(acc.Dealer__c)) {
                addedIds.add(acc.Dealer__c);
                chain.add(new Account(
                    Id = acc.Dealer__c,
                    Name = acc.Dealer__r.Name,
                    Type = acc.Dealer__r.Type
                ));
            }

            // 3. Distributor (if populated and not already in chain)
            if (acc.Distributor__c != null && !addedIds.contains(acc.Distributor__c)) {
                addedIds.add(acc.Distributor__c);
                chain.add(new Account(
                    Id = acc.Distributor__c,
                    Name = acc.Distributor__r.Name,
                    Type = acc.Distributor__r.Type
                ));
            }

            // 4. OEM (if populated and not already in chain)
            if (acc.OEM__c != null && !addedIds.contains(acc.OEM__c)) {
                addedIds.add(acc.OEM__c);
                chain.add(new Account(
                    Id = acc.OEM__c,
                    Name = acc.OEM__r.Name,
                    Type = acc.OEM__r.Type
                ));
            }

            resultMap.put(acc.Id, chain);
            System.debug(LoggingLevel.INFO, '[DMS Hierarchy] Account ' + acc.Id + ' Chain Length = ' + chain.size() + ' | Hierarchy Chain = ' + chain);
        }

        return resultMap;
    }
}