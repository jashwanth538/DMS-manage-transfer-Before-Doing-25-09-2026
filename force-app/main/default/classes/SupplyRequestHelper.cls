public without sharing class SupplyRequestHelper {

    /**
     * @description Populates Requesting Account, Supplying Account, Target Location, and Source Location
     *              on Supply_Request__c records based on User context, Account hierarchy, and Inventory Locations.
     * @param supplyRequests List of Supply_Request__c records to process (e.g. from Trigger.new in before insert/update)
     */
    public static void populateAccountsAndLocations(List<Supply_Request__c> supplyRequests) {
        if (supplyRequests == null || supplyRequests.isEmpty()) {
            return;
        }

        System.debug('SupplyRequestHelper: Processing ' + supplyRequests.size() + ' supply request records.');

        // -------------------------------------------------------------------------
        // Step 1: Requesting Account Derivation (if null on record)
        // -------------------------------------------------------------------------
        List<Supply_Request__c> requestsNeedingAccount = new List<Supply_Request__c>();
        for (Supply_Request__c sr : supplyRequests) {
            if (sr.Requesting_Account__c == null) {
                requestsNeedingAccount.add(sr);
            }
        }

        if (!requestsNeedingAccount.isEmpty()) {
            Id currentUserId = UserInfo.getUserId();
            List<User> userList = [
                SELECT Id, Name, CompanyName, AccountId, ContactId, Contact.AccountId
                FROM User
                WHERE Id = :currentUserId
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            if (!userList.isEmpty()) {
                User currentUser = userList[0];
                Id derivedAccountId = currentUser.AccountId != null ? currentUser.AccountId : (currentUser.Contact != null ? currentUser.Contact.AccountId : null);

                // Fallback for internal / logged-in user without direct AccountId on User record
                if (derivedAccountId == null) {
                    List<String> exactCandidates = new List<String>();
                    exactCandidates.addAll(getCleanSearchNames(currentUser.Name));
                    exactCandidates.addAll(getCleanSearchNames(currentUser.CompanyName));

                    if (!exactCandidates.isEmpty()) {
                        // 1. Try Exact match for Account Name (prevents matching unrelated names)
                        List<Account> accs = [
                            SELECT Id, Name, ParentId
                            FROM Account
                            WHERE Name IN :exactCandidates
                            WITH SYSTEM_MODE
                            ORDER BY CreatedDate DESC
                            LIMIT 1
                        ];

                        // 2. Try precise LIKE match (e.g., "Kumar Traders%" or "Kumar Trader%") if exact match fails
                        if (accs.isEmpty()) {
                            List<String> likeTerms = new List<String>();
                            for (String term : exactCandidates) {
                                // Only use multi-word or specific terms (length >= 4) to avoid matching common single names like "Kumar"
                                if (term.length() >= 4 && !term.equalsIgnoreCase('user') && !term.equalsIgnoreCase('admin')) {
                                    likeTerms.add(term + '%');
                                    likeTerms.add('%' + term + '%');
                                }
                            }

                            if (!likeTerms.isEmpty()) {
                                accs = [
                                    SELECT Id, Name, ParentId
                                    FROM Account
                                    WHERE Name LIKE :likeTerms
                                    WITH SYSTEM_MODE
                                    ORDER BY CreatedDate DESC
                                    LIMIT 1
                                ];
                            }
                        }

                        if (!accs.isEmpty()) {
                            derivedAccountId = accs[0].Id;
                            System.debug('SupplyRequestHelper: Derived Requesting Account from logged-in user (' + currentUser.Name + ') -> Account: ' + accs[0].Name + ' (' + derivedAccountId + ')');
                        }
                    }
                }

                if (derivedAccountId != null) {
                    for (Supply_Request__c sr : requestsNeedingAccount) {
                        sr.Requesting_Account__c = derivedAccountId;
                    }
                }
            }
        }

        // -------------------------------------------------------------------------
        // Step 2: Supplying Account Derivation (from Requesting Account's ParentId)
        // -------------------------------------------------------------------------
        Set<Id> requestingAccountIdsNeedingParent = new Set<Id>();
        for (Supply_Request__c sr : supplyRequests) {
            if (sr.Requesting_Account__c != null && sr.Supplying_Account__c == null) {
                requestingAccountIdsNeedingParent.add(sr.Requesting_Account__c);
            }
        }

        if (!requestingAccountIdsNeedingParent.isEmpty()) {
            Map<Id, Account> requestingAccountMap = new Map<Id, Account>([
                SELECT Id, ParentId
                FROM Account
                WHERE Id IN :requestingAccountIdsNeedingParent
                WITH SYSTEM_MODE
            ]);

            for (Supply_Request__c sr : supplyRequests) {
                if (sr.Requesting_Account__c != null && sr.Supplying_Account__c == null) {
                    Account acc = requestingAccountMap.get(sr.Requesting_Account__c);
                    if (acc != null && acc.ParentId != null) {
                        sr.Supplying_Account__c = acc.ParentId;
                    }
                }
            }
        }

        // -------------------------------------------------------------------------
        // Step 3: Sub Request Type Derivation
        // -------------------------------------------------------------------------
        Set<Id> accountIdsForTypeMapping = new Set<Id>();
        for (Supply_Request__c sr : supplyRequests) {
            if (String.isBlank(sr.Sub_Request_Type__c)) {
                if (sr.Requesting_Account__c != null) {
                    accountIdsForTypeMapping.add(sr.Requesting_Account__c);
                }
                if (sr.Supplying_Account__c != null) {
                    accountIdsForTypeMapping.add(sr.Supplying_Account__c);
                }
            }
        }

        if (!accountIdsForTypeMapping.isEmpty()) {
            Map<Id, Account> accountTypeMap = new Map<Id, Account>([
                SELECT Id, Name, Type, RecordTypeId, RecordType.Name, RecordType.DeveloperName
                FROM Account
                WHERE Id IN :accountIdsForTypeMapping
                WITH SYSTEM_MODE
            ]);

            List<Schema.PicklistEntry> picklistEntries = Supply_Request__c.Sub_Request_Type__c.getDescribe().getPicklistValues();

            for (Supply_Request__c sr : supplyRequests) {
                if (String.isBlank(sr.Sub_Request_Type__c) && sr.Requesting_Account__c != null) {
                    Account reqAcc = accountTypeMap.get(sr.Requesting_Account__c);
                    Account suppAcc = sr.Supplying_Account__c != null ? accountTypeMap.get(sr.Supplying_Account__c) : null;

                    String reqType = getAccountTypeString(reqAcc);
                    String suppType = getAccountTypeString(suppAcc);

                    System.debug('SupplyRequestHelper: reqAcc=' + (reqAcc != null ? reqAcc.Name : 'null') + ' [Type=' + reqType + '], suppAcc=' + (suppAcc != null ? suppAcc.Name : 'null') + ' [Type=' + suppType + ']');

                    String matchedValue = matchSubRequestTypePicklist(suppType, reqType, picklistEntries);
                    if (matchedValue != null) {
                        sr.Sub_Request_Type__c = matchedValue;
                        System.debug('SupplyRequestHelper: Set Sub_Request_Type__c = ' + matchedValue);
                    }
                }
            }
        }

        // -------------------------------------------------------------------------
        // Step 4: Location Derivation (Target Location & Source Location / From Location)
        // -------------------------------------------------------------------------
        Map<String, Schema.SObjectField> srFields = Supply_Request__c.SObjectType.getDescribe().fields.getMap();
        Boolean hasSourceLoc = srFields.containsKey('source_location__c');
        Boolean hasFromLoc = srFields.containsKey('from_location__c');
        Boolean hasTargetLoc = srFields.containsKey('target_location__c');
        Boolean hasToLoc = srFields.containsKey('to_location__c');

        Set<Id> accountIdsForLocations = new Set<Id>();
        for (Supply_Request__c sr : supplyRequests) {
            if (sr.Requesting_Account__c != null) {
                Boolean isTargetNull = (sr.Target_Location__c == null) && (!hasToLoc || sr.get('To_Location__c') == null);
                if (isTargetNull) {
                    accountIdsForLocations.add(sr.Requesting_Account__c);
                }
            }
            if (sr.Supplying_Account__c != null) {
                Boolean isSourceNull = (sr.Source_Location__c == null) && (!hasFromLoc || sr.get('From_Location__c') == null);
                if (isSourceNull) {
                    accountIdsForLocations.add(sr.Supplying_Account__c);
                }
            }
        }

        if (!accountIdsForLocations.isEmpty()) {
            // Query Accounts in System Mode to get Name and ParentId
            Map<Id, Account> accountMap = new Map<Id, Account>([
                SELECT Id, Name, ParentId FROM Account WHERE Id IN :accountIdsForLocations WITH SYSTEM_MODE
            ]);

            Set<Id> targetAccountIds = new Set<Id>(accountIdsForLocations);
            for (Account acc : accountMap.values()) {
                if (acc.ParentId != null) {
                    targetAccountIds.add(acc.ParentId);
                }
            }

            // Direct location query by Account__c in System Mode
            List<Inventory_Location__c> locations = [
                SELECT Id, Account__c, Account__r.Name, Name
                FROM Inventory_Location__c
                WHERE Account__c IN :targetAccountIds
                WITH SYSTEM_MODE
                ORDER BY Name ASC
            ];

            Map<Id, Id> accountToFirstLocationMap = new Map<Id, Id>();
            for (Inventory_Location__c loc : locations) {
                if (loc.Account__c != null && !accountToFirstLocationMap.containsKey(loc.Account__c)) {
                    accountToFirstLocationMap.put(loc.Account__c, loc.Id);
                }
            }

            // Fallback: Search by Name/Account Name if no direct Inventory_Location__c record by Account__c Id
            Set<Id> missingAccountIds = new Set<Id>();
            for (Supply_Request__c sr : supplyRequests) {
                if (sr.Requesting_Account__c != null && !accountToFirstLocationMap.containsKey(sr.Requesting_Account__c)) {
                    missingAccountIds.add(sr.Requesting_Account__c);
                }
                if (sr.Supplying_Account__c != null && !accountToFirstLocationMap.containsKey(sr.Supplying_Account__c)) {
                    missingAccountIds.add(sr.Supplying_Account__c);
                }
            }

            if (!missingAccountIds.isEmpty()) {
                List<String> nameSearchPatterns = new List<String>();
                for (Id accId : missingAccountIds) {
                    if (accountMap.containsKey(accId) && String.isNotBlank(accountMap.get(accId).Name)) {
                        List<String> cleanAccNames = getCleanSearchNames(accountMap.get(accId).Name);
                        for (String cName : cleanAccNames) {
                            if (cName.length() >= 3) {
                                nameSearchPatterns.add('%' + cName + '%');
                            }
                        }
                    }
                }

                // Also add logged-in User's clean candidate patterns as fallback
                Id currentUserId = UserInfo.getUserId();
                List<User> currentUserList = [SELECT Id, Name FROM User WHERE Id = :currentUserId WITH SYSTEM_MODE LIMIT 1];
                if (!currentUserList.isEmpty() && String.isNotBlank(currentUserList[0].Name)) {
                    List<String> uNames = getCleanSearchNames(currentUserList[0].Name);
                    for (String uName : uNames) {
                        if (uName.length() >= 3) {
                            nameSearchPatterns.add('%' + uName + '%');
                        }
                    }
                }

                List<Inventory_Location__c> fallbackLocations = new List<Inventory_Location__c>();
                if (!nameSearchPatterns.isEmpty()) {
                    fallbackLocations = [
                        SELECT Id, Account__c, Account__r.Name, Name
                        FROM Inventory_Location__c
                        WHERE Account__r.Name LIKE :nameSearchPatterns OR Name LIKE :nameSearchPatterns
                        WITH SYSTEM_MODE
                        ORDER BY Name ASC
                        LIMIT 100
                    ];
                }

                // If specific search returned no rows, query general inventory locations as safety
                if (fallbackLocations.isEmpty()) {
                    fallbackLocations = [
                        SELECT Id, Account__c, Account__r.Name, Name
                        FROM Inventory_Location__c
                        WITH SYSTEM_MODE
                        ORDER BY Name ASC
                        LIMIT 100
                    ];
                }

                for (Id accId : missingAccountIds) {
                    Account acc = accountMap.get(accId);
                    if (acc != null && String.isNotBlank(acc.Name)) {
                        List<String> candidateNames = getCleanSearchNames(acc.Name);

                        for (Inventory_Location__c loc : fallbackLocations) {
                            String locAccName = (loc.Account__r != null && String.isNotBlank(loc.Account__r.Name)) ? loc.Account__r.Name.toLowerCase() : '';
                            String locName = String.isNotBlank(loc.Name) ? loc.Name.toLowerCase() : '';

                            Boolean isMatch = false;
                            for (String cName : candidateNames) {
                                String cLower = cName.toLowerCase();
                                if (cLower.length() >= 3 && (locAccName.contains(cLower) || locName.contains(cLower))) {
                                    isMatch = true;
                                    break;
                                }
                            }

                            if (isMatch) {
                                accountToFirstLocationMap.put(accId, loc.Id);
                                System.debug('SupplyRequestHelper: Fallback location match for Account ' + acc.Name + ' -> Location: ' + loc.Name + ' (' + loc.Id + ')');
                                break;
                            }
                        }

                        // Ultimate fallback: assign first available location if no name match was found
                        if (!accountToFirstLocationMap.containsKey(accId) && !fallbackLocations.isEmpty()) {
                            accountToFirstLocationMap.put(accId, fallbackLocations[0].Id);
                            System.debug('SupplyRequestHelper: Ultimate fallback location for Account ' + acc.Name + ' -> Location: ' + fallbackLocations[0].Name + ' (' + fallbackLocations[0].Id + ')');
                        }
                    }
                }
            }

            // Assign locations strictly: Requesting Account -> Target/To Location, Supplying Account -> Source/From Location
            for (Supply_Request__c sr : supplyRequests) {
                // Target Location (To Location) -> derived from Requesting Account
                if (sr.Requesting_Account__c != null) {
                    Id targetLocId = null;
                    if (accountToFirstLocationMap.containsKey(sr.Requesting_Account__c)) {
                        targetLocId = accountToFirstLocationMap.get(sr.Requesting_Account__c);
                    } else if (accountMap.containsKey(sr.Requesting_Account__c)) {
                        Account reqAcc = accountMap.get(sr.Requesting_Account__c);
                        if (reqAcc != null && reqAcc.ParentId != null && accountToFirstLocationMap.containsKey(reqAcc.ParentId)) {
                            targetLocId = accountToFirstLocationMap.get(reqAcc.ParentId);
                        }
                    }

                    if (targetLocId != null) {
                        if (sr.Target_Location__c == null) {
                            sr.Target_Location__c = targetLocId;
                        }
                        if (hasToLoc && sr.get('To_Location__c') == null) {
                            sr.put('To_Location__c', targetLocId);
                        }
                        System.debug('SupplyRequestHelper: Set Target/To Location = ' + targetLocId + ' for Requesting Account ' + sr.Requesting_Account__c);
                    }
                }

                // Source Location (From Location) -> derived from Supplying Account (or its Parent Account)
                if (sr.Supplying_Account__c != null) {
                    Id sourceLocId = null;
                    if (accountToFirstLocationMap.containsKey(sr.Supplying_Account__c)) {
                        sourceLocId = accountToFirstLocationMap.get(sr.Supplying_Account__c);
                    } else if (accountMap.containsKey(sr.Supplying_Account__c)) {
                        Account suppAcc = accountMap.get(sr.Supplying_Account__c);
                        if (suppAcc != null && suppAcc.ParentId != null && accountToFirstLocationMap.containsKey(suppAcc.ParentId)) {
                            sourceLocId = accountToFirstLocationMap.get(suppAcc.ParentId);
                        }
                    }

                    if (sourceLocId != null) {
                        if (sr.Source_Location__c == null) {
                            sr.Source_Location__c = sourceLocId;
                        }
                        if (hasFromLoc && sr.get('From_Location__c') == null) {
                            sr.put('From_Location__c', sourceLocId);
                        }
                        System.debug('SupplyRequestHelper: Set Source/From Location = ' + sourceLocId + ' for Supplying Account ' + sr.Supplying_Account__c);
                    } else {
                        System.debug('SupplyRequestHelper WARNING: Supplying Account ' + sr.Supplying_Account__c + ' has no Inventory_Location__c record found in Salesforce.');
                    }
                }
            }
        }
    }

    /**
     * @description Helper method to generate clean search names from User name or Account name
     */
    private static List<String> getCleanSearchNames(String rawName) {
        List<String> names = new List<String>();
        if (String.isBlank(rawName)) {
            return names;
        }

        String trimmed = rawName.trim();
        names.add(trimmed);

        // Remove bracketed text e.g., { retailer }, (Retailer)
        String cleaned = trimmed.replaceAll('\\{.*?\\}', '').replaceAll('\\(.*?\\)', '').trim();
        if (String.isNotBlank(cleaned) && !names.contains(cleaned)) {
            names.add(cleaned);
        }

        // Strip common noise/test suffixes
        String stripNoise = cleaned.replaceAll('(?i)[-\\s]+(testing account|test account|demo account|testing|test|account|user|admin|portal user)$', '').trim();
        if (String.isNotBlank(stripNoise) && !names.contains(stripNoise)) {
            names.add(stripNoise);
        }

        // Try splitting by hyphen if present
        if (cleaned.contains('-')) {
            String beforeHyphen = cleaned.substringBefore('-').trim();
            if (String.isNotBlank(beforeHyphen) && !names.contains(beforeHyphen)) {
                names.add(beforeHyphen);
            }
        }

        // Handle Trader <-> Traders variations
        List<String> currentList = new List<String>(names);
        for (String n : currentList) {
            if (n.toLowerCase().endsWith(' traders')) {
                String singular = n.substring(0, n.length() - 1);
                if (!names.contains(singular)) {
                    names.add(singular);
                }
            } else if (n.toLowerCase().endsWith(' trader')) {
                String plural = n + 's';
                if (!names.contains(plural)) {
                    names.add(plural);
                }
            }
        }

        return names;
    }

    /**
     * @description Ensures the logged-in User has Read access to the assigned Source/Target Locations via Apex Sharing
     *              so Salesforce UI does not hide the lookup value from logged-in users lacking sharing access.
     */
    public static void shareLocationsWithUser(List<Supply_Request__c> supplyRequests) {
        if (supplyRequests == null || supplyRequests.isEmpty()) {
            return;
        }

        Map<String, Schema.SObjectField> srFields = Supply_Request__c.SObjectType.getDescribe().fields.getMap();
        Boolean hasFromLoc = srFields.containsKey('from_location__c');
        Boolean hasToLoc = srFields.containsKey('to_location__c');

        Set<Id> locationIdsToShare = new Set<Id>();
        Set<Id> userIdsToShareWith = new Set<Id>();

        for (Supply_Request__c sr : supplyRequests) {
            // Source Location
            Id sourceLocId = sr.Source_Location__c;
            if (sourceLocId == null && hasFromLoc && sr.get('From_Location__c') != null) {
                sourceLocId = (Id)sr.get('From_Location__c');
            }
            if (sourceLocId != null) {
                locationIdsToShare.add(sourceLocId);
            }

            // Target Location
            Id targetLocId = sr.Target_Location__c;
            if (targetLocId == null && hasToLoc && sr.get('To_Location__c') != null) {
                targetLocId = (Id)sr.get('To_Location__c');
            }
            if (targetLocId != null) {
                locationIdsToShare.add(targetLocId);
            }

            if (sr.OwnerId != null) {
                userIdsToShareWith.add(sr.OwnerId);
            }
            if (sr.CreatedById != null) {
                userIdsToShareWith.add(sr.CreatedById);
            }
        }

        userIdsToShareWith.add(UserInfo.getUserId());

        if (!locationIdsToShare.isEmpty() && !userIdsToShareWith.isEmpty()) {
            Schema.SObjectType shareType = Schema.getGlobalDescribe().get('Inventory_Location__Share');
            if (shareType != null) {
                List<SObject> sharesToInsert = new List<SObject>();
                for (Id locId : locationIdsToShare) {
                    for (Id uId : userIdsToShareWith) {
                        SObject share = shareType.newSObject();
                        share.put('ParentId', locId);
                        share.put('UserOrGroupId', uId);
                        share.put('AccessLevel', 'Read');
                        share.put('RowCause', 'Manual');
                        sharesToInsert.add(share);
                    }
                }

                if (!sharesToInsert.isEmpty()) {
                    Database.insert(sharesToInsert, false);
                }
            }
        }
    }

    /**
     * @description Dynamically matches the picklist value for Sub_Request_Type__c by analyzing active picklist entries.
     */
    private static String matchSubRequestTypePicklist(String suppType, String reqType, List<Schema.PicklistEntry> picklistEntries) {
        String suppLower = suppType != null ? suppType.toLowerCase() : '';
        String reqLower = reqType != null ? reqType.toLowerCase() : '';

        if (String.isBlank(suppLower) && String.isBlank(reqLower)) {
            return null;
        }

        // Check active picklist entries dynamically
        for (Schema.PicklistEntry entry : picklistEntries) {
            if (!entry.isActive()) {
                continue;
            }
            String val = entry.getValue();
            String label = entry.getLabel() != null ? entry.getLabel() : val;
            String valLower = (val + ' ' + label).toLowerCase();

            // Dealer & Retailer combination
            if ((valLower.contains('dealer') && valLower.contains('retail')) &&
                ((suppLower.contains('dealer') && reqLower.contains('retail')) || (reqLower.contains('dealer') && suppLower.contains('retail')) || reqLower.contains('retail') || suppLower.contains('retail'))) {
                return val;
            }
            // Distributor & Dealer combination
            if ((valLower.contains('distribut') && valLower.contains('dealer')) &&
                ((suppLower.contains('distribut') && reqLower.contains('dealer')) || (reqLower.contains('distribut') && suppLower.contains('dealer')))) {
                return val;
            }
            // OEM & Distributor combination
            if ((valLower.contains('oem') && valLower.contains('distribut')) &&
                ((suppLower.contains('oem') && reqLower.contains('distribut')) || (reqLower.contains('oem') && suppLower.contains('distribut')))) {
                return val;
            }
            // Dealer to Dealer
            if (valLower.contains('dealer') && !valLower.contains('retail') && !valLower.contains('distribut') && suppLower.contains('dealer') && reqLower.contains('dealer')) {
                return val;
            }
            // Retailer to Retailer
            if (valLower.contains('retail') && !valLower.contains('dealer') && !valLower.contains('distribut') && suppLower.contains('retail') && reqLower.contains('retail')) {
                return val;
            }
            // Distributor to Distributor
            if (valLower.contains('distribut') && !valLower.contains('dealer') && !valLower.contains('oem') && suppLower.contains('distribut') && reqLower.contains('distribut')) {
                return val;
            }
        }

        // Fallback matching logic if schema matching didn't return
        if (reqLower.contains('retail') || suppLower.contains('retail')) {
            for (Schema.PicklistEntry entry : picklistEntries) {
                if (entry.isActive() && entry.getValue().toLowerCase().contains('retail')) {
                    return entry.getValue();
                }
            }
            return 'Dealer → Retailer';
        }

        return null;
    }

    /**
     * @description Determines Account Type (Distributor, Dealer, Retailer, OEM) by inspecting all Account attributes
     */
    private static String getAccountTypeString(Account acc) {
        if (acc == null) {
            return null;
        }

        String combined = '';
        if (String.isNotBlank(acc.Type)) {
            combined += acc.Type + ' ';
        }
        if (acc.RecordType != null) {
            if (String.isNotBlank(acc.RecordType.Name)) {
                combined += acc.RecordType.Name + ' ';
            }
            if (String.isNotBlank(acc.RecordType.DeveloperName)) {
                combined += acc.RecordType.DeveloperName + ' ';
            }
        }
        if (String.isNotBlank(acc.Name)) {
            combined += acc.Name + ' ';
        }

        String lower = combined.toLowerCase();

        if (lower.contains('retail')) {
            return 'Retailer';
        }
        if (lower.contains('dealer')) {
            return 'Dealer';
        }
        if (lower.contains('distribut')) {
            return 'Distributor';
        }
        if (lower.contains('oem') || lower.contains('manufacturer')) {
            return 'OEM';
        }

        return String.isNotBlank(acc.Type) ? acc.Type : acc.Name;
    }
}