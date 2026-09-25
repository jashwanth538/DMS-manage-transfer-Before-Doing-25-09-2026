public with sharing class InventoryDashboardController {

    public class HierarchyAccountWrapper {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String parentId { get; set; }
        @AuraEnabled public String recordTypeDeveloperName { get; set; }
        @AuraEnabled public String recordTypeName { get; set; }
    }

    public class HierarchyTabWrapper {
        @AuraEnabled public String tabId { get; set; } // 'all', 'OEM', 'Distributor', 'Dealer', 'Retailer'
        @AuraEnabled public String label { get; set; } // 'All', 'OEMs', 'Distributors', 'Dealers', 'Retailers'
        @AuraEnabled public Integer count { get; set; }
    }

    public class EnterpriseHierarchyContext {
        @AuraEnabled public String userType { get; set; }
        @AuraEnabled public List<HierarchyTabWrapper> availableTabs { get; set; }
        @AuraEnabled public List<HierarchyAccountWrapper> accounts { get; set; }
        @AuraEnabled public List<Inventory_Location__c> locations { get; set; }
        @AuraEnabled public List<String> directAccountIds { get; set; }
    }

    /**
     * Finds Public Group IDs for the current user.
     */
    public static Set<String> getUserPublicGroupIds() {
        Set<String> groupIds = new Set<String>();
        Id currentUserId = UserInfo.getUserId();

        // Query direct group memberships for current user
        for (GroupMember gm : [
            SELECT GroupId, Group.Type
            FROM GroupMember
            WHERE UserOrGroupId = :currentUserId
            AND Group.Type = 'Regular'
            WITH USER_MODE
        ]) {
            groupIds.add(String.valueOf(gm.GroupId));
        }

        return groupIds;
    }

    /**
     * Resolves accessible Account IDs mapped to current user's Public Groups.
     */
    public static Set<Id> getUserDirectMappedAccountIds() {
        Set<String> groupIds = getUserPublicGroupIds();
        Set<Id> accountIds = new Set<Id>();

        if (groupIds.isEmpty()) {
            return accountIds;
        }

        for (Account_Public_Group_Mapping__c mapping : [
            SELECT Account__c, Public_Group_Id__c, Access_Level__c, Active__c
            FROM Account_Public_Group_Mapping__c
            WHERE Active__c = true
            AND Public_Group_Id__c IN :groupIds
            AND Account__c != null
            WITH USER_MODE
        ]) {
            accountIds.add(mapping.Account__c);
        }

        return accountIds;
    }

    /**
     * Traverses Account hierarchy both upward and downward starting from mapped root accounts.
     * Fully bulkified with Sets to avoid SOQL in loops.
     */
    public static Map<Id, Account> traverseEnterpriseHierarchy(Set<Id> directAccountIds) {
        Map<Id, Account> allAccessibleAccounts = new Map<Id, Account>();

        if (directAccountIds == null || directAccountIds.isEmpty()) {
            // Fallback: If no mapping records exist for the user yet, fetch accounts accessible under sharing
            for (Account acc : [
                SELECT Id, Name, ParentId, RecordType.DeveloperName, RecordType.Name
                FROM Account
                WITH USER_MODE
                ORDER BY Name ASC
                LIMIT 500
            ]) {
                allAccessibleAccounts.put(acc.Id, acc);
            }
            return allAccessibleAccounts;
        }

        // 1. Initial direct accounts
        Map<Id, Account> directMap = new Map<Id, Account>([
            SELECT Id, Name, ParentId, RecordType.DeveloperName, RecordType.Name
            FROM Account
            WHERE Id IN :directAccountIds
            WITH USER_MODE
        ]);
        allAccessibleAccounts.putAll(directMap);

        // 2. Upward Traversal (Parent, Grandparent...)
        Set<Id> parentsToFetch = new Set<Id>();
        for (Account acc : directMap.values()) {
            if (acc.ParentId != null) {
                parentsToFetch.add(acc.ParentId);
            }
        }

        Integer upwardDepthLimit = 10;
        while (!parentsToFetch.isEmpty() && upwardDepthLimit > 0) {
            upwardDepthLimit--;
            Map<Id, Account> parentAccounts = new Map<Id, Account>([
                SELECT Id, Name, ParentId, RecordType.DeveloperName, RecordType.Name
                FROM Account
                WHERE Id IN :parentsToFetch
                WITH USER_MODE
            ]);

            parentsToFetch.clear();
            for (Account pAcc : parentAccounts.values()) {
                allAccessibleAccounts.put(pAcc.Id, pAcc);
                if (pAcc.ParentId != null && !allAccessibleAccounts.containsKey(pAcc.ParentId)) {
                    parentsToFetch.add(pAcc.ParentId);
                }
            }
        }

        // 3. Downward Traversal (Children, Grandchildren...)
        Set<Id> currentLevelParentIds = new Set<Id>(allAccessibleAccounts.keySet());
        Integer downwardDepthLimit = 10;
        while (!currentLevelParentIds.isEmpty() && downwardDepthLimit > 0) {
            downwardDepthLimit--;
            Map<Id, Account> childAccounts = new Map<Id, Account>([
                SELECT Id, Name, ParentId, RecordType.DeveloperName, RecordType.Name
                FROM Account
                WHERE ParentId IN :currentLevelParentIds
                WITH USER_MODE
            ]);

            currentLevelParentIds.clear();
            for (Account child : childAccounts.values()) {
                if (!allAccessibleAccounts.containsKey(child.Id)) {
                    allAccessibleAccounts.put(child.Id, child);
                    currentLevelParentIds.add(child.Id);
                }
            }
        }

        return allAccessibleAccounts;
    }

    /**
     * Builds the complete EnterpriseHierarchyContext.
     */
    public static EnterpriseHierarchyContext buildHierarchyContext(Map<Id, Account> accessibleAccountsMap, Set<Id> directAccountIds) {
        EnterpriseHierarchyContext context = new EnterpriseHierarchyContext();
        context.accounts = new List<HierarchyAccountWrapper>();
        context.availableTabs = new List<HierarchyTabWrapper>();
        context.locations = new List<Inventory_Location__c>();
        context.directAccountIds = new List<String>();

        if (directAccountIds != null) {
            for (Id accId : directAccountIds) {
                context.directAccountIds.add(String.valueOf(accId));
            }
        }

        if (accessibleAccountsMap.isEmpty()) {
            // Default empty "All" tab
            HierarchyTabWrapper allTab = new HierarchyTabWrapper();
            allTab.tabId = 'all';
            allTab.label = 'All';
            allTab.count = 0;
            context.availableTabs.add(allTab);
            context.userType = 'Standard';
            return context;
        }

        Map<String, Integer> typeCounts = new Map<String, Integer>();
        Boolean hasOEM = false;
        Boolean hasDistributor = false;
        Boolean hasDealer = false;
        Boolean hasRetailer = false;

        for (Account acc : accessibleAccountsMap.values()) {
            HierarchyAccountWrapper w = new HierarchyAccountWrapper();
            w.id = acc.Id;
            w.name = acc.Name;
            w.parentId = acc.ParentId;
            w.recordTypeDeveloperName = acc.RecordType != null ? acc.RecordType.DeveloperName : '';
            w.recordTypeName = acc.RecordType != null ? acc.RecordType.Name : '';
            context.accounts.add(w);

            String rType = acc.RecordType != null ? acc.RecordType.DeveloperName : '';
            if (rType == 'OEM') {
                hasOEM = true;
            } else if (rType == 'Distributor') {
                hasDistributor = true;
            } else if (rType == 'Dealer') {
                hasDealer = true;
            } else if (rType == 'Retailer') {
                hasRetailer = true;
            }

            if (String.isNotBlank(rType)) {
                typeCounts.put(rType, (typeCounts.containsKey(rType) ? typeCounts.get(rType) : 0) + 1);
            }
        }

        // Determine user type / role
        if (hasOEM) {
            context.userType = 'OEM';
        } else if (hasDistributor) {
            context.userType = 'Distributor';
        } else if (hasDealer) {
            context.userType = 'Dealer';
        } else if (hasRetailer) {
            context.userType = 'Retailer';
        } else {
            context.userType = 'Standard';
        }

        // If directAccountIds was empty (no group mapping records found), default to accounts matching user's own type
        if (context.directAccountIds.isEmpty() && context.userType != 'Standard') {
            for (Account acc : accessibleAccountsMap.values()) {
                if (acc.RecordType != null && acc.RecordType.DeveloperName == context.userType) {
                    context.directAccountIds.add(String.valueOf(acc.Id));
                }
            }
        }

        // Build dynamic tabs based on user enterprise role
        HierarchyTabWrapper allTab = new HierarchyTabWrapper();
        allTab.tabId = 'all';
        allTab.label = 'All';
        allTab.count = context.accounts.size();
        context.availableTabs.add(allTab);

        // Subordinate hierarchy tabs depending on user role:
        // OEM: Can see Distributors, Dealers, Retailers
        // Distributor: Can see Dealers, Retailers (downstream)
        // Dealer: Can see Retailers (downstream)
        // Retailer: No downstream tabs

        if (context.userType == 'OEM') {
            if (typeCounts.containsKey('Distributor') && typeCounts.get('Distributor') > 0) {
                HierarchyTabWrapper tab = new HierarchyTabWrapper();
                tab.tabId = 'Distributor';
                tab.label = 'Distributors';
                tab.count = typeCounts.get('Distributor');
                context.availableTabs.add(tab);
            }

            if (typeCounts.containsKey('Dealer') && typeCounts.get('Dealer') > 0) {
                HierarchyTabWrapper tab = new HierarchyTabWrapper();
                tab.tabId = 'Dealer';
                tab.label = 'Dealers';
                tab.count = typeCounts.get('Dealer');
                context.availableTabs.add(tab);
            }

            if (typeCounts.containsKey('Retailer') && typeCounts.get('Retailer') > 0) {
                HierarchyTabWrapper tab = new HierarchyTabWrapper();
                tab.tabId = 'Retailer';
                tab.label = 'Retailers';
                tab.count = typeCounts.get('Retailer');
                context.availableTabs.add(tab);
            }
        } else if (context.userType == 'Distributor') {
            if (typeCounts.containsKey('Dealer') && typeCounts.get('Dealer') > 0) {
                HierarchyTabWrapper tab = new HierarchyTabWrapper();
                tab.tabId = 'Dealer';
                tab.label = 'Dealers';
                tab.count = typeCounts.get('Dealer');
                context.availableTabs.add(tab);
            }

            if (typeCounts.containsKey('Retailer') && typeCounts.get('Retailer') > 0) {
                HierarchyTabWrapper tab = new HierarchyTabWrapper();
                tab.tabId = 'Retailer';
                tab.label = 'Retailers';
                tab.count = typeCounts.get('Retailer');
                context.availableTabs.add(tab);
            }
        } else if (context.userType == 'Dealer') {
            if (typeCounts.containsKey('Retailer') && typeCounts.get('Retailer') > 0) {
                HierarchyTabWrapper tab = new HierarchyTabWrapper();
                tab.tabId = 'Retailer';
                tab.label = 'Retailers';
                tab.count = typeCounts.get('Retailer');
                context.availableTabs.add(tab);
            }
        }

        // Query active locations belonging to these accessible accounts
        Set<Id> accIds = accessibleAccountsMap.keySet();
        context.locations = [
            SELECT Id, Name, Inventory_Location_Code__c, Is_Active__c, Account__c, Account__r.Name
            FROM Inventory_Location__c
            WHERE Is_Active__c = true
            AND Account__c IN :accIds
            WITH USER_MODE
            ORDER BY Name ASC
        ];

        return context;
    }

    /**
     * Retrieves all active Inventory Location IDs accessible to the user.
     */
    public static Set<Id> getUserAssignedLocationIds() {
        Set<Id> directAccIds = getUserDirectMappedAccountIds();
        Map<Id, Account> accMap = traverseEnterpriseHierarchy(directAccIds);

        Map<Id, Inventory_Location__c> activeLocs;
        if (!accMap.isEmpty()) {
            Set<Id> accIds = accMap.keySet();
            activeLocs = new Map<Id, Inventory_Location__c>([
                SELECT Id
                FROM Inventory_Location__c
                WHERE Is_Active__c = true
                AND (Account__c IN :accIds OR Account__c = null)
                WITH USER_MODE
            ]);
        } else {
            activeLocs = new Map<Id, Inventory_Location__c>([
                SELECT Id
                FROM Inventory_Location__c
                WHERE Is_Active__c = true
                WITH USER_MODE
            ]);
        }

        return activeLocs.keySet();
    }


    @AuraEnabled
    public static LWCServerCalloutWrapper getDashboardInitData() {

        LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();

        try {
            Set<Id> directAccIds = getUserDirectMappedAccountIds();
            Map<Id, Account> accMap = traverseEnterpriseHierarchy(directAccIds);
            EnterpriseHierarchyContext hierarchyContext = buildHierarchyContext(accMap, directAccIds);

            Set<Id> assignedLocationIds = getUserAssignedLocationIds();

            // Fetch active inventory locations with Account details
            List<Inventory_Location__c> locations = new List<Inventory_Location__c>();

            if (!assignedLocationIds.isEmpty()) {
                locations = [
                    SELECT Id,
                           Name,
                           Inventory_Location_Code__c,
                           Is_Active__c,
                           Account__c,
                           Account__r.Name
                    FROM Inventory_Location__c
                    WHERE Is_Active__c = true
                    AND Id IN :assignedLocationIds
                    WITH USER_MODE
                    ORDER BY Name ASC
                ];
            }

            wrapper.referenceCache.put('locations', locations);
            wrapper.referenceCache.put('hierarchyContext', hierarchyContext);

            // Fetch active items for quick selection or dropdown
            List<Item__c> items = [
                SELECT Id,
                       Name,
                       Item_Code__c,
                       Active__c
                FROM Item__c
                WHERE Active__c = true
                WITH USER_MODE
                ORDER BY Name ASC
                LIMIT 100
            ];

            wrapper.referenceCache.put('items', items);


            // Fetch overall KPI statistics
            Map<String, Decimal> stats = new Map<String, Decimal>{
                'totalOnHand' => 0,
                'totalAvailable' => 0,
                'totalReservedSaleOrder' => 0,
                'totalReservedTransfer' => 0,
                'totalInProduction' => 0,
                'totalDamaged' => 0,
                'totalTransitIn' => 0,
                'totalTransitOut' => 0
            };


            if (!assignedLocationIds.isEmpty()) {

                AggregateResult[] groupedResults = [

                    SELECT
                        SUM(On_Hand_Qty__c) totalOnHand,
                        SUM(Available__c) totalAvailable,
                        SUM(Reserved_Sale_Order__c) totalReservedSaleOrder,
                        SUM(Reserved_Transfer__c) totalReservedTransfer,
                       // SUM(In_Production__c) totalInProduction,
                        SUM(Damaged__c) totalDamaged,
                        SUM(Transit_In_Quantity__c) totalTransitIn,
                        SUM(Transit_Out_Quantity__c) totalTransitOut

                    FROM Inventory__c

                    WHERE Inventory_Location__c IN :assignedLocationIds

                    WITH USER_MODE
                ];


                if (groupedResults != null && !groupedResults.isEmpty()) {

                    AggregateResult ar = groupedResults[0];

                    stats.put(
                        'totalOnHand',
                        ar.get('totalOnHand') != null
                            ? (Decimal) ar.get('totalOnHand')
                            : 0
                    );

                    stats.put(
                        'totalAvailable',
                        ar.get('totalAvailable') != null
                            ? Math.max(0, (Decimal) ar.get('totalAvailable'))
                            : 0
                    );

                    stats.put(
                        'totalReservedSaleOrder',
                        ar.get('totalReservedSaleOrder') != null
                            ? (Decimal) ar.get('totalReservedSaleOrder')
                            : 0
                    );

                    stats.put(
                        'totalReservedTransfer',
                        ar.get('totalReservedTransfer') != null
                            ? (Decimal) ar.get('totalReservedTransfer')
                            : 0
                    );

                    stats.put(
                        'totalInProduction',
                        0
                    );

                    stats.put(
                        'totalDamaged',
                        ar.get('totalDamaged') != null
                            ? (Decimal) ar.get('totalDamaged')
                            : 0
                    );

                    stats.put(
                        'totalTransitIn',
                        ar.get('totalTransitIn') != null
                            ? (Decimal) ar.get('totalTransitIn')
                            : 0
                    );

                    stats.put(
                        'totalTransitOut',
                        ar.get('totalTransitOut') != null
                            ? (Decimal) ar.get('totalTransitOut')
                            : 0
                    );
                }
            }

            wrapper.referenceCache.put('stats', stats);

            wrapper.isSuccess = true;

        } catch (Exception e) {

            wrapper.isSuccess = false;
            wrapper.errorMsg = e.getMessage();
        }

        return wrapper;
    }


    @AuraEnabled
    public static LWCServerCalloutWrapper searchLocations(String searchKey) {

        LWCServerCalloutWrapper wrapper =
            new LWCServerCalloutWrapper();

        try {

            Set<Id> assignedLocationIds =
                getUserAssignedLocationIds();

            if (assignedLocationIds.isEmpty()) {

                wrapper.resultList =
                    new List<Inventory_Location__c>();

                wrapper.isSuccess = true;

                return wrapper;
            }


            String key =
                '%' +
                (String.isNotBlank(searchKey)
                    ? searchKey.trim()
                    : '') +
                '%';


            List<Inventory_Location__c> locations = [

                SELECT
                    Id,
                    Name,
                    Inventory_Location_Code__c

                FROM Inventory_Location__c

                WHERE Is_Active__c = true
                AND Id IN :assignedLocationIds

                AND (
                    Name LIKE :key
                    OR Inventory_Location_Code__c LIKE :key
                )

                WITH USER_MODE

                ORDER BY Name ASC

                LIMIT 15
            ];


            wrapper.resultList = locations;

            wrapper.isSuccess = true;

        } catch (Exception e) {

            wrapper.isSuccess = false;
            wrapper.errorMsg = e.getMessage();
        }

        return wrapper;
    }


    public static LWCServerCalloutWrapper searchInventories(
        String searchKey,
        String locationId,
        String statusFilter,
        String searchColumn
    ) {

        return searchInventories(
            searchKey,
            locationId,
            statusFilter,
            searchColumn,
            null,
            null,
            null
        );
    }


    public static LWCServerCalloutWrapper searchInventories(
        String searchKey,
        String locationId,
        String statusFilter,
        String searchColumn,
        String locationSearchKey
    ) {

        return searchInventories(
            searchKey,
            locationId,
            statusFilter,
            searchColumn,
            locationSearchKey,
            null,
            null
        );
    }


    @AuraEnabled
    public static LWCServerCalloutWrapper searchInventories(
        String searchKey,
        String locationId,
        String statusFilter,
        String searchColumn,
        String locationSearchKey,
        String accountId,
        String accountType
    ) {

        LWCServerCalloutWrapper wrapper =
            new LWCServerCalloutWrapper();

        try {

            Set<Id> assignedLocationIds =
                getUserAssignedLocationIds();


            if (assignedLocationIds.isEmpty()) {

                wrapper.resultList =
                    new List<Inventory__c>();

                wrapper.isSuccess = true;

                return wrapper;
            }

            // If accountId is provided, filter locations to those under this Account
            if (String.isNotBlank(accountId)) {
                Map<Id, Inventory_Location__c> accLocs = new Map<Id, Inventory_Location__c>([
                    SELECT Id FROM Inventory_Location__c
                    WHERE Is_Active__c = true
                    AND Account__c = :accountId
                    AND Id IN :assignedLocationIds
                    WITH USER_MODE
                ]);
                assignedLocationIds = accLocs.keySet();
            } else if (String.isNotBlank(accountType) && accountType != 'all') {
                // If accountType is provided (e.g. 'Distributor', 'Dealer', 'Retailer', 'OEM')
                Map<Id, Account> accMap = traverseEnterpriseHierarchy(getUserDirectMappedAccountIds());
                Set<Id> typeAccIds = new Set<Id>();
                for (Account a : accMap.values()) {
                    if (a.RecordType != null && a.RecordType.DeveloperName == accountType) {
                        typeAccIds.add(a.Id);
                    }
                }
                Map<Id, Inventory_Location__c> typeLocs = new Map<Id, Inventory_Location__c>([
                    SELECT Id FROM Inventory_Location__c
                    WHERE Is_Active__c = true
                    AND Account__c IN :typeAccIds
                    AND Id IN :assignedLocationIds
                    WITH USER_MODE
                ]);
                assignedLocationIds = typeLocs.keySet();
            }

            if (assignedLocationIds.isEmpty()) {
                wrapper.resultList = new List<Inventory__c>();
                wrapper.isSuccess = true;
                return wrapper;
            }


            String searchKeyBind =
                String.isNotBlank(searchKey)
                    ? '%' + searchKey.trim() + '%'
                    : null;


            String locationIdBind =
                String.isNotBlank(locationId)
                    ? locationId
                    : null;


            String locationSearchKeyBind =
                String.isNotBlank(locationSearchKey)
                    ? '%' + locationSearchKey.trim() + '%'
                    : null;


            String query =
                'SELECT Id, Name, Item__c, ' +
                'Item__r.Name, ' +
                'Item__r.Item_Code__c, ' +
                'Item__r.Quantity_Unit_Of_Measure__c, ' +
                'Reorder_Level__c, ' +
                'Item__r.Stock_Low_Level_Quantity__c, ' +
                'Item__r.Stock_Medium_Level_Quantity__c, ' +
                'Item__r.Stock_High_Level_Quantity__c, ' +
                'Inventory_Location__c, ' +
                'Inventory_Location__r.Name, ' +
                'Inventory_Location__r.Inventory_Location_Code__c, ' +
                'Inventory_Location__r.Account__c, ' +
                'On_Hand_Qty__c, ' +
                'Available__c, ' +
                'Damaged__c, ' +
                'Transit_In_Quantity__c, ' +
                'Transit_Out_Quantity__c, ' +
                'Reserved_Sale_Order__c, ' +
                'Reserved_Transfer__c ' +
                'FROM Inventory__c ';


            List<String> conditions =
                new List<String>();


            // Restrict to active inventory locations
            conditions.add(
                'Inventory_Location__c IN :assignedLocationIds'
            );


            // Apply searchKey filter
            if (searchKeyBind != null) {

                if (searchColumn == 'Item') {

                    conditions.add(
                        '(Item__r.Name LIKE :searchKeyBind ' +
                        'OR Item__r.Item_Code__c LIKE :searchKeyBind)'
                    );

                } else if (searchColumn == 'Location') {

                    conditions.add(
                        '(Inventory_Location__r.Name LIKE :searchKeyBind ' +
                        'OR Inventory_Location__r.Inventory_Location_Code__c LIKE :searchKeyBind)'
                    );

                } else {

                    conditions.add(
                        '(Item__r.Name LIKE :searchKeyBind ' +
                        'OR Item__r.Item_Code__c LIKE :searchKeyBind ' +
                        'OR Inventory_Location__r.Name LIKE :searchKeyBind ' +
                        'OR Inventory_Location__r.Inventory_Location_Code__c LIKE :searchKeyBind)'
                    );
                }
            }


            // Apply location filter by ID
            if (locationIdBind != null) {

                conditions.add(
                    'Inventory_Location__c = :locationIdBind'
                );
            }


            // Apply location filter by Name or Code
            if (locationSearchKeyBind != null) {

                conditions.add(
                    '(Inventory_Location__r.Name LIKE :locationSearchKeyBind ' +
                    'OR Inventory_Location__r.Inventory_Location_Code__c LIKE :locationSearchKeyBind)'
                );
            }


            if (!conditions.isEmpty()) {

                query +=
                    ' WHERE ' +
                    String.join(conditions, ' AND ');
            }


            query +=
                ' WITH USER_MODE ' +
                'ORDER BY Item__r.Name ASC, ' +
                'Inventory_Location__r.Name ASC ' +
                'LIMIT 200';


            List<Inventory__c> inventories =
                Database.query(query);


            // Apply status filters
            if (String.isNotBlank(statusFilter)) {

                List<Inventory__c> filteredInventories =
                    new List<Inventory__c>();


                for (Inventory__c inv : inventories) {

                    Decimal available =
                        (inv.Available__c != null && inv.Available__c > 0)
                            ? inv.Available__c
                            : 0;


                    Decimal lowQty =
                        inv.Item__r != null &&
                        inv.Item__r.Stock_Low_Level_Quantity__c != null
                            ? inv.Item__r.Stock_Low_Level_Quantity__c
                            : 10;


                    Decimal medQty =
                        inv.Item__r != null &&
                        inv.Item__r.Stock_Medium_Level_Quantity__c != null
                            ? inv.Item__r.Stock_Medium_Level_Quantity__c
                            : 30;


                    if (statusFilter == 'out') {

                        if (available == 0) {
                            filteredInventories.add(inv);
                        }

                    } else if (statusFilter == 'damaged') {

                        if (
                            inv.Damaged__c != null &&
                            inv.Damaged__c > 0
                        ) {
                            filteredInventories.add(inv);
                        }

                    } else if (statusFilter == 'low') {

                        if (available <= lowQty) {
                            filteredInventories.add(inv);
                        }

                    } else if (statusFilter == 'medium') {

                        if (
                            available > lowQty &&
                            available <= medQty
                        ) {
                            filteredInventories.add(inv);
                        }

                    } else if (statusFilter == 'high') {

                        if (available > medQty) {
                            filteredInventories.add(inv);
                        }
                    }
                }


                inventories = filteredInventories;
            }

            for (Inventory__c inv : inventories) {
                if (inv.Available__c != null && inv.Available__c < 0) {
                    inv.Available__c = 0;
                }
            }

            // Bulk query active Item_Price__c records for all items in result list
            Set<Id> itemIds = new Set<Id>();
            for (Inventory__c inv : inventories) {
                if (inv.Item__c != null) {
                    itemIds.add(inv.Item__c);
                }
            }

            Map<String, Decimal> itemPriceMap = new Map<String, Decimal>();
            if (!itemIds.isEmpty()) {
                for (Item_Price__c ip : [
                    SELECT Item__c, Unit_Price__c, Item_Price_Account__c, Inventory_Location__c
                    FROM Item_Price__c
                    WHERE Active__c = true
                    AND Item__c IN :itemIds
                    AND Unit_Price__c != null
                    WITH USER_MODE
                    ORDER BY LastModifiedDate DESC
                ]) {
                    // Fallback key: by Item Id
                    if (!itemPriceMap.containsKey(String.valueOf(ip.Item__c))) {
                        itemPriceMap.put(String.valueOf(ip.Item__c), ip.Unit_Price__c);
                    }
                    // Specific key: by ItemId + AccountId if available
                    if (ip.Item_Price_Account__c != null) {
                        String accKey = String.valueOf(ip.Item__c) + '_' + String.valueOf(ip.Item_Price_Account__c);
                        itemPriceMap.put(accKey, ip.Unit_Price__c);
                    }
                }
            }

            wrapper.resultList = inventories;
            wrapper.referenceCache.put('itemPriceMap', itemPriceMap);
            wrapper.isSuccess = true;

        } catch (Exception e) {

            wrapper.isSuccess = false;
            wrapper.errorMsg = e.getMessage();

            System.debug(
                'searchInventories Exception: ' +
                e.getMessage() +
                '\n' +
                e.getStackTraceString()
            );
        }

        return wrapper;
    }


    @AuraEnabled
    public static LWCServerCalloutWrapper updateInventoryStock(
        Id inventoryId,
        Decimal reserved,
        Decimal damaged,
        Decimal transitIn,
        Decimal transitOut,
        Decimal available
    ) {

        LWCServerCalloutWrapper wrapper =
            new LWCServerCalloutWrapper();

        try {

            if (inventoryId == null) {

                throw new IllegalArgumentException(
                    'Inventory ID cannot be null'
                );
            }


            Decimal safeAvailable = (available != null && available > 0) ? available : 0;
            Inventory__c inv =
                new Inventory__c(
                    Id = inventoryId,
                    Damaged__c = damaged,
                    Transit_In_Quantity__c = transitIn,
                    Transit_Out_Quantity__c = transitOut,
                    Available__c = safeAvailable
                );


            update as user inv;


            wrapper.result = inv;

            wrapper.isSuccess = true;

        } catch (Exception e) {

            wrapper.isSuccess = false;
            wrapper.errorMsg = e.getMessage();
        }

        return wrapper;
    }

}