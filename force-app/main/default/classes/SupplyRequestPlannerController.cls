public without sharing class SupplyRequestPlannerController {

    @TestVisible
    private static Set<Id> mockAccountIds = null;

    /*
     * Wrapper for each Supply Request
     */
    public class SupplyRequestWrapper {
        @AuraEnabled public Id supplyRequestId;
        @AuraEnabled public String supplyRequestName;
        @AuraEnabled public Id itemId;
        @AuraEnabled public String itemName;
        @AuraEnabled public Id requestingAccountId;
        @AuraEnabled public String requestingAccountName;
        @AuraEnabled public Id supplyingAccountId;
        @AuraEnabled public String supplyingAccountName;
        @AuraEnabled public Id sourceLocationId;
        @AuraEnabled public String sourceLocationName;
        @AuraEnabled public Id targetLocationId;
        @AuraEnabled public String targetLocationName;
        @AuraEnabled public Decimal requestedQty;
        @AuraEnabled public Date requiredDate;
        @AuraEnabled public String status;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public String subRequestType;
        @AuraEnabled public Boolean automatedSupplyRequest;
    }

    /*
     * Resolves the Account IDs for the current logged-in user via Public Group Mappings.
     * User -> GroupMember (Public Group) -> Account_Public_Group_Mapping__c -> Account
     */
    public static Set<Id> getUserAccountIds() {
        if (Test.isRunningTest() && mockAccountIds != null) {
            return new Set<Id>(mockAccountIds);
        }

        Id currentUserId = UserInfo.getUserId();

        // 1. Find Public Groups the user belongs to (Id, Name, DeveloperName)
        Set<Id> groupIds = new Set<Id>();
        Set<String> groupTokens = new Set<String>();

        for (GroupMember gm : [
            SELECT GroupId, Group.Name, Group.DeveloperName
            FROM GroupMember
            WHERE UserOrGroupId = :currentUserId
        ]) {
            groupIds.add(gm.GroupId);
            groupTokens.add(String.valueOf(gm.GroupId));
            if (gm.Group != null) {
                if (String.isNotBlank(gm.Group.Name)) {
                    groupTokens.add(gm.Group.Name);
                }
                if (String.isNotBlank(gm.Group.DeveloperName)) {
                    groupTokens.add(gm.Group.DeveloperName);
                }
            }
        }

        Set<Id> accountIds = new Set<Id>();
        if (groupIds.isEmpty()) {
            return accountIds;
        }

        // 2. Discover fields on Account_Public_Group_Mapping__c dynamically to handle schema variations
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account_Public_Group_Mapping__c.fields.getMap();
        String accountFieldName = 'Account__c';
        String activeFieldName = null;
        List<String> groupConditions = new List<String>();

        for (String fName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(fName).getDescribe();
            String lowerName = fName.toLowerCase();

            // Detect Account field
            if (lowerName == 'account__c') {
                accountFieldName = dfr.getName();
            } else if (accountFieldName == null && dfr.isCustom()) {
                for (Schema.sObjectType ref : dfr.getReferenceTo()) {
                    if (ref == Account.SObjectType) {
                        accountFieldName = dfr.getName();
                        break;
                    }
                }
            }

            // Detect Active field
            if (dfr.getType() == Schema.DisplayType.BOOLEAN) {
                if (lowerName == 'isactive__c' || lowerName == 'is_active__c' || lowerName == 'active__c') {
                    activeFieldName = dfr.getName();
                }
            }

            // Detect Group fields
            if (dfr.isCustom() && lowerName != accountFieldName.toLowerCase() && lowerName != 'id' && lowerName != 'name') {
                Boolean isGroupRef = false;
                for (Schema.sObjectType ref : dfr.getReferenceTo()) {
                    if (ref == Group.SObjectType) {
                        isGroupRef = true;
                        break;
                    }
                }
                if (isGroupRef) {
                    groupConditions.add(dfr.getName() + ' IN :groupIds');
                } else if (lowerName.contains('group')) {
                    groupConditions.add('(' + dfr.getName() + ' IN :groupIds OR ' + dfr.getName() + ' IN :groupTokens)');
                }
            }
        }

        // 3. Query Account_Public_Group_Mapping__c dynamically if matching group fields exist
        if (!groupConditions.isEmpty() && accountFieldName != null) {
            String query = 'SELECT ' + String.escapeSingleQuotes(accountFieldName) +
                           ' FROM Account_Public_Group_Mapping__c WHERE (' +
                           String.join(groupConditions, ' OR ') + ')';

            if (activeFieldName != null) {
                query += ' AND ' + String.escapeSingleQuotes(activeFieldName) + ' = true';
            }

            for (SObject mapping : Database.query(query)) {
                Id accId = (Id) mapping.get(accountFieldName);
                if (accId != null) {
                    accountIds.add(accId);
                }
            }
        }

        return accountIds;
    }

    /*
     * Fetch all pending Open Supply Requests for the supplier.
     * Displays only Open Supply Requests where the logged-in user's Account matches Supplying_Account__c.
     * Does not display Supply Requests where the logged-in user's Account is the Requesting_Account__c.
     */
    @AuraEnabled(cacheable=true)
    public static List<SupplyRequestWrapper> getPendingSupplyRequests() {
        Set<Id> accountIds = getUserAccountIds();

        if (accountIds == null || accountIds.isEmpty()) {
            return new List<SupplyRequestWrapper>();
        }

        List<Supply_Request__c> srList = [
            SELECT Id,
                Name,
                Status__c,
                Requested_Qty__c,
                Required_Date__c,
                Item__c,
                Item__r.Name,
                Requesting_Account__c,
                Requesting_Account__r.Name,
                Supplying_Account__c,
                Supplying_Account__r.Name,
                Source_Location__c,
                Source_Location__r.Name,
                Target_Location__c,
                Target_Location__r.Name,
                Sub_Request_Type__c,
                Automated_Supply_Request__c
            FROM Supply_Request__c
            WHERE Status__c = 'Open'
              AND Supplying_Account__c IN :accountIds
              AND Requesting_Account__c NOT IN :accountIds
            ORDER BY CreatedDate DESC
        ];

        List<SupplyRequestWrapper> results = new List<SupplyRequestWrapper>();

        for(Supply_Request__c sr : srList){
            SupplyRequestWrapper w = new SupplyRequestWrapper();
            w.supplyRequestId = sr.Id;
            w.supplyRequestName = sr.Name;
            w.itemId = sr.Item__c;
            w.itemName = sr.Item__r != null ? sr.Item__r.Name : '';
            w.requestingAccountId = sr.Requesting_Account__c;
            w.requestingAccountName = sr.Requesting_Account__r != null ? sr.Requesting_Account__r.Name : '';
            w.supplyingAccountId = sr.Supplying_Account__c;
            w.supplyingAccountName = sr.Supplying_Account__r != null ? sr.Supplying_Account__r.Name : '';
            w.sourceLocationId = sr.Source_Location__c;
            w.sourceLocationName = sr.Source_Location__r != null ? sr.Source_Location__r.Name : '';
            w.targetLocationId = sr.Target_Location__c;
            w.targetLocationName = sr.Target_Location__r != null ? sr.Target_Location__r.Name : '';
            w.requestedQty = sr.Requested_Qty__c;
            w.requiredDate = sr.Required_Date__c;
            w.status = sr.Status__c;
            w.recordUrl = '/' + sr.Id;
            w.subRequestType = sr.Sub_Request_Type__c;
            w.automatedSupplyRequest = sr.Automated_Supply_Request__c;
            results.add(w);
        }

        return results;
    }

    /*
     * Wrappers for Stock Availability Details
     */
    public class RequestInfoWrapper {
        @AuraEnabled public String product;
        @AuraEnabled public String supplyRequestName;
        @AuraEnabled public String requestingAccountName;
        @AuraEnabled public String requestingAccountType;
        @AuraEnabled public Decimal requestedQty;
        @AuraEnabled public Date requiredDate;
    }

    public class StockItemWrapper {
        @AuraEnabled public Id inventoryId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountType;
        @AuraEnabled public Boolean isLoggedInAccount;
        @AuraEnabled public Id locationId;
        @AuraEnabled public String locationName;
        @AuraEnabled public Decimal availableQty;
        @AuraEnabled public Decimal onHandQty;
        @AuraEnabled public Decimal reservedQty;
        @AuraEnabled public Decimal inTransitQty;
        @AuraEnabled public String stockStatus;
    }

    public class StockDetailsWrapper {
        @AuraEnabled public RequestInfoWrapper requestInfo;
        @AuraEnabled public List<StockItemWrapper> availableStockList;
    }

    /*
     * Fetch Stock Availability Details for Stock Modal based on logged-in user account & account hierarchy.
     * Excludes Requesting Account from stock availability results.
     */
    @AuraEnabled(cacheable=true)
    public static StockDetailsWrapper getStockAvailabilityDetails(Id supplyRequestId) {
        if (supplyRequestId == null) {
            throw new AuraHandledException('Supply Request Id is required.');
        }

        List<Supply_Request__c> srList = [
            SELECT Id,
                   Name,
                   Requested_Qty__c,
                   Required_Date__c,
                   Item__c,
                   Item__r.Name,
                   Requesting_Account__c,
                   Requesting_Account__r.Name,
                   Requesting_Account__r.Type,
                   Requesting_Account__r.RecordType.Name,
                   Supplying_Account__c,
                   Supplying_Account__r.Name
            FROM Supply_Request__c
            WHERE Id = :supplyRequestId
            LIMIT 1
        ];

        if (srList.isEmpty()) {
            throw new AuraHandledException('Supply Request not found.');
        }

        Supply_Request__c sr = srList[0];

        // 1. Build Request Info
        RequestInfoWrapper reqInfo = new RequestInfoWrapper();
        reqInfo.product = sr.Item__r != null ? sr.Item__r.Name : '';
        reqInfo.supplyRequestName = sr.Name;
        reqInfo.requestingAccountName = sr.Requesting_Account__r != null ? sr.Requesting_Account__r.Name : '';

        String accType = '';
        if (sr.Requesting_Account__r != null) {
            if (String.isNotBlank(sr.Requesting_Account__r.Type)) {
                accType = sr.Requesting_Account__r.Type;
            } else if (sr.Requesting_Account__r.RecordType != null && String.isNotBlank(sr.Requesting_Account__r.RecordType.Name)) {
                accType = sr.Requesting_Account__r.RecordType.Name;
            }
        }
        reqInfo.requestingAccountType = String.isNotBlank(accType) ? accType : 'Retailer';
        reqInfo.requestedQty = sr.Requested_Qty__c;
        reqInfo.requiredDate = sr.Required_Date__c;

        // 2. Determine Logged-in User Accounts & Permitted Hierarchy Accounts
        Set<Id> userAccountIds = getUserAccountIds();
        if (userAccountIds == null) {
            userAccountIds = new Set<Id>();
        }
        if (userAccountIds.isEmpty() && sr.Supplying_Account__c != null) {
            userAccountIds.add(sr.Supplying_Account__c);
        }

        Set<Id> permittedAccountIds = new Set<Id>(userAccountIds);

        // Fetch 1-level child hierarchy accounts for user's mapped account(s)
        for (Id accId : userAccountIds) {
            Set<Id> childAccs = SupplyOrderGenService.getEligibleChildAccounts(accId);
            if (childAccs != null) {
                permittedAccountIds.addAll(childAccs);
            }
        }

        // EXCLUDE Requesting Account from stock visibility results
        if (sr.Requesting_Account__c != null) {
            permittedAccountIds.remove(sr.Requesting_Account__c);
        }

        List<StockItemWrapper> stockList = new List<StockItemWrapper>();

        if (!permittedAccountIds.isEmpty() && sr.Item__c != null) {
            // Query Inventory__c for requested Item belonging to permitted accounts
            List<Inventory__c> invRecords = [
                SELECT Id,
                       Item__c,
                       Account__c,
                       Account__r.Name,
                       Account__r.Type,
                       Account__r.RecordType.Name,
                       Inventory_Location__c,
                       Inventory_Location__r.Name,
                       Inventory_Location__r.Account__c,
                       Inventory_Location__r.Account__r.Name,
                       Inventory_Location__r.Account__r.Type,
                       Inventory_Location__r.Account__r.RecordType.Name,
                       Available__c,
                       On_Hand_Qty__c,
                       Reserved_Sale_Order__c,
                       Reserved_Transfer__c,
                       Transit_In_Quantity__c,
                       Transit_Out_Quantity__c
                FROM Inventory__c
                WHERE Item__c = :sr.Item__c
                  AND (Account__c IN :permittedAccountIds OR Inventory_Location__r.Account__c IN :permittedAccountIds)
                ORDER BY Available__c DESC, CreatedDate ASC
            ];

            Set<Id> locationsProcessed = new Set<Id>();

            for (Inventory__c inv : invRecords) {
                StockItemWrapper item = new StockItemWrapper();
                item.inventoryId = inv.Id;

                Id ownerAccId = inv.Account__c != null ? inv.Account__c : (inv.Inventory_Location__r != null ? inv.Inventory_Location__r.Account__c : null);
                String ownerAccName = inv.Account__r != null ? inv.Account__r.Name : (inv.Inventory_Location__r != null && inv.Inventory_Location__r.Account__r != null ? inv.Inventory_Location__r.Account__r.Name : '—');

                String ownerAccType = 'Account';
                if (inv.Account__r != null && String.isNotBlank(inv.Account__r.Type)) {
                    ownerAccType = inv.Account__r.Type;
                } else if (inv.Account__r != null && inv.Account__r.RecordType != null && String.isNotBlank(inv.Account__r.RecordType.Name)) {
                    ownerAccType = inv.Account__r.RecordType.Name;
                } else if (inv.Inventory_Location__r != null && inv.Inventory_Location__r.Account__r != null && String.isNotBlank(inv.Inventory_Location__r.Account__r.Type)) {
                    ownerAccType = inv.Inventory_Location__r.Account__r.Type;
                }

                item.accountId = ownerAccId;
                item.accountName = ownerAccName;
                item.accountType = ownerAccType;
                item.isLoggedInAccount = userAccountIds.contains(ownerAccId);
                item.locationId = inv.Inventory_Location__c;
                item.locationName = inv.Inventory_Location__r != null ? inv.Inventory_Location__r.Name : '—';

                item.availableQty = inv.Available__c != null ? inv.Available__c : 0;
                item.onHandQty = inv.On_Hand_Qty__c != null ? inv.On_Hand_Qty__c : 0;

                Decimal reservedSO = inv.Reserved_Sale_Order__c != null ? inv.Reserved_Sale_Order__c : 0;
                Decimal reservedTF = inv.Reserved_Transfer__c != null ? inv.Reserved_Transfer__c : 0;
                item.reservedQty = reservedSO + reservedTF;

                Decimal transitIn = inv.Transit_In_Quantity__c != null ? inv.Transit_In_Quantity__c : 0;
                Decimal transitOut = inv.Transit_Out_Quantity__c != null ? inv.Transit_Out_Quantity__c : 0;
                item.inTransitQty = transitIn + transitOut;

                Decimal reqQtyVal = sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0;
                if (item.availableQty >= reqQtyVal && reqQtyVal > 0) {
                    item.stockStatus = 'In Stock';
                } else if (item.availableQty > 0) {
                    item.stockStatus = 'Low Stock';
                } else {
                    item.stockStatus = 'Out of Stock';
                }

                stockList.add(item);
                if (inv.Inventory_Location__c != null) {
                    locationsProcessed.add(inv.Inventory_Location__c);
                }
            }

            // Also check Inventory_Location__c for permitted accounts that don't have an Inventory__c record yet
            List<Inventory_Location__c> permittedLocations = [
                SELECT Id, Name, Account__c, Account__r.Name, Account__r.Type, Account__r.RecordType.Name
                FROM Inventory_Location__c
                WHERE Account__c IN :permittedAccountIds
                  AND Is_Active__c = true
                  AND Id NOT IN :locationsProcessed
                ORDER BY Name ASC
            ];

            for (Inventory_Location__c loc : permittedLocations) {
                StockItemWrapper item = new StockItemWrapper();
                item.inventoryId = null;
                item.accountId = loc.Account__c;
                item.accountName = loc.Account__r != null ? loc.Account__r.Name : '—';

                String ownerAccType = 'Account';
                if (loc.Account__r != null && String.isNotBlank(loc.Account__r.Type)) {
                    ownerAccType = loc.Account__r.Type;
                } else if (loc.Account__r != null && loc.Account__r.RecordType != null && String.isNotBlank(loc.Account__r.RecordType.Name)) {
                    ownerAccType = loc.Account__r.RecordType.Name;
                }
                item.accountType = ownerAccType;
                item.isLoggedInAccount = userAccountIds.contains(loc.Account__c);
                item.locationId = loc.Id;
                item.locationName = loc.Name;
                item.availableQty = 0;
                item.onHandQty = 0;
                item.reservedQty = 0;
                item.inTransitQty = 0;
                item.stockStatus = 'Out of Stock';

                stockList.add(item);
            }
        }

        StockDetailsWrapper response = new StockDetailsWrapper();
        response.requestInfo = reqInfo;
        response.availableStockList = stockList;

        return response;
    }

    /*
     * Wrapper for Created Order Allocation Summary
     */
    public class OrderAllocationSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id requestingAccountId;
        @AuraEnabled public String requestingAccountName;
        @AuraEnabled public Id supplyingAccountId;
        @AuraEnabled public String supplyingAccountName;
        @AuraEnabled public String status;
        @AuraEnabled public Integer lineItemCount;
        @AuraEnabled public Decimal totalQty;
        @AuraEnabled public String plannerUrl;
    }

    @AuraEnabled
    public static List<OrderAllocationSummary> confirmPlan(List<Id> supplyRequestIds) {
        if (supplyRequestIds == null || supplyRequestIds.isEmpty()) {
            throw new AuraHandledException('Please select at least one Supply Request.');
        }

        List<Supply_Request__c> srList = [
            SELECT Id,
                Name,
                Item__c,
                Requested_Qty__c,
                Status__c,
                Requesting_Account__c,
                Supplying_Account__c,
                Source_Location__c,
                Target_Location__c,
                Sub_Request_Type__c,
                Automated_Supply_Request__c,
                Required_Date__c
            FROM Supply_Request__c
            WHERE Id IN :supplyRequestIds
        ];

        if(srList.isEmpty()){
            return new List<OrderAllocationSummary>();
        }

        /*
        * Group SRs by Requesting Account
        */
        Map<Id,List<Supply_Request__c>> accountVsSR = new Map<Id,List<Supply_Request__c>>();

        for(Supply_Request__c sr : srList){
            if(!accountVsSR.containsKey(sr.Requesting_Account__c)){
                accountVsSR.put(sr.Requesting_Account__c,new List<Supply_Request__c>());
            }
            accountVsSR.get(sr.Requesting_Account__c).add(sr);
        }

        /*
        * Create OA (One per Requesting Account)
        */
        List<Order_Allocation__c> oaList = new List<Order_Allocation__c>();
        Map<Id,Order_Allocation__c> accountVsOA = new Map<Id,Order_Allocation__c>();

        for(Id accountId : accountVsSR.keySet()){
            Supply_Request__c firstSR = accountVsSR.get(accountId)[0];

            Order_Allocation__c oa = new Order_Allocation__c();
            oa.Requesting_Account__c = accountId;
            oa.Supplying_Account__c = firstSR.Supplying_Account__c;
            oa.Source_Location__c = firstSR.Source_Location__c;
            oa.Target_Location__c = firstSR.Target_Location__c;
            oa.Status__c = 'Draft';

            oaList.add(oa);
            accountVsOA.put(accountId,oa);
        }

        insert oaList;

        /*
        * Create OALI
        * Merge same Item for same Account and track Source SR references & allocations
        */
        List<Order_Allocation_Line_Item__c> oaliList = new List<Order_Allocation_Line_Item__c>();

        for(Id accountId : accountVsSR.keySet()){
            Order_Allocation__c oa = accountVsOA.get(accountId);

            // Group SRs by ItemId: ItemId -> List<Supply_Request__c>
            Map<Id, List<Supply_Request__c>> itemSRMap = new Map<Id, List<Supply_Request__c>>();

            for(Supply_Request__c sr : accountVsSR.get(accountId)){
                if (!itemSRMap.containsKey(sr.Item__c)) {
                    itemSRMap.put(sr.Item__c, new List<Supply_Request__c>());
                }
                itemSRMap.get(sr.Item__c).add(sr);
            }

            for(Id itemId : itemSRMap.keySet()){
                List<Supply_Request__c> contributingSRs = itemSRMap.get(itemId);

                Order_Allocation_Line_Item__c line = new Order_Allocation_Line_Item__c();
                line.Order_Allocation__c = oa.Id;
                line.Item__c = itemId;
                line.Status__c = 'Draft';

                List<String> srNames = new List<String>();
                List<String> srAllocations = new List<String>();
                Decimal totalQty = 0;

                for (Supply_Request__c sr : contributingSRs) {
                    String srName = String.isNotBlank(sr.Name) ? sr.Name : String.valueOf(sr.Id);
                    Decimal requestedQty = sr.Requested_Qty__c == null ? 0 : sr.Requested_Qty__c;
                    srNames.add(srName);
                    srAllocations.add(srName + ':' + requestedQty);
                    totalQty += requestedQty;
                }

                line.Ordered_Qty__c = totalQty;
                line.Source_SR_References__c = String.join(srNames, ',');
                line.Source_SR_Allocation__c = String.join(srAllocations, ',');
                line.Source_SR_Sub_Type_References__c = appendSrSubTypeReferences(line.Source_SR_Sub_Type_References__c, contributingSRs);

                oaliList.add(line);
            }
        }

        insert oaliList;

        /*
        * Create Purchase Orders (PO) & PO Line Items (POLI) for non-automated Supply Requests (Automated_Supply_Request__c == false/null)
        * and invoke FinancialRecordService to generate Invoice, Payable, and Receivable records.
        */
        List<Purchase_Order__c> posToInsert = new List<Purchase_Order__c>();
        Map<Id, Purchase_Order__c> accountVsPO = new Map<Id, Purchase_Order__c>();
        Map<Id, List<Supply_Request__c>> accountVsNonAutoSRs = new Map<Id, List<Supply_Request__c>>();

        for (Id accountId : accountVsSR.keySet()) {
            List<Supply_Request__c> nonAutoSRs = new List<Supply_Request__c>();
            for (Supply_Request__c sr : accountVsSR.get(accountId)) {
                if (sr.Automated_Supply_Request__c != true) {
                    nonAutoSRs.add(sr);
                }
            }

            if (!nonAutoSRs.isEmpty()) {
                accountVsNonAutoSRs.put(accountId, nonAutoSRs);

                Supply_Request__c firstSR = nonAutoSRs[0];
                Order_Allocation__c oa = accountVsOA.get(accountId);

                Purchase_Order__c po = new Purchase_Order__c();
                po.Requesting_Account__c = accountId;
                po.Supplying_Account__c = firstSR.Supplying_Account__c;
                po.Source_Location__c = firstSR.Source_Location__c;
                po.Target_Location__c = firstSR.Target_Location__c;
                po.Sales_Allocation__c = oa != null ? oa.Id : null;
                po.PO_Date__c = Date.today();
                po.Expected_Date__c = firstSR.Required_Date__c != null ? firstSR.Required_Date__c : Date.today().addDays(30);
                po.Status__c = 'Draft';

                posToInsert.add(po);
                accountVsPO.put(accountId, po);
            }
        }

        if (!posToInsert.isEmpty()) {
            insert posToInsert;

            List<Purchase_Order_Line_Item__c> polisToInsert = new List<Purchase_Order_Line_Item__c>();
            Map<Id, Order_Allocation_Line_Item__c> oalisToUpdateMap = new Map<Id, Order_Allocation_Line_Item__c>();

            // Map OALIs by (Order_Allocation__c + '_' + Item__c) with pricing/tax details
            Map<String, Order_Allocation_Line_Item__c> oaItemVsOaliMap = new Map<String, Order_Allocation_Line_Item__c>();
            for (Order_Allocation_Line_Item__c oali : [
                SELECT Id, Order_Allocation__c, Item__c, Unit_Price__c, Tax__c, Discount_Percent__c
                FROM Order_Allocation_Line_Item__c
                WHERE Id IN :oaliList
            ]) {
                if (oali.Order_Allocation__c != null && oali.Item__c != null) {
                    oaItemVsOaliMap.put(oali.Order_Allocation__c + '_' + oali.Item__c, oali);
                }
            }

            for (Id accountId : accountVsNonAutoSRs.keySet()) {
                Purchase_Order__c po = accountVsPO.get(accountId);
                Order_Allocation__c oa = accountVsOA.get(accountId);
                List<Supply_Request__c> nonAutoSRs = accountVsNonAutoSRs.get(accountId);

                // Group non-automated SRs by ItemId
                Map<Id, Decimal> itemVsQty = new Map<Id, Decimal>();
                for (Supply_Request__c sr : nonAutoSRs) {
                    Decimal qty = itemVsQty.containsKey(sr.Item__c) ? itemVsQty.get(sr.Item__c) : 0;
                    itemVsQty.put(sr.Item__c, qty + (sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0));
                }

                for (Id itemId : itemVsQty.keySet()) {
                    Order_Allocation_Line_Item__c matchingOali = null;
                    if (oa != null) {
                        matchingOali = oaItemVsOaliMap.get(oa.Id + '_' + itemId);
                    }

                    Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c();
                    poli.Purchase_Order__c = po.Id;
                    poli.Item__c = itemId;
                    poli.Ordered_Qty__c = itemVsQty.get(itemId);
                    poli.Unit_Price__c = (matchingOali != null && matchingOali.Unit_Price__c != null) ? matchingOali.Unit_Price__c : 0;
                    poli.Tax__c = (matchingOali != null && matchingOali.Tax__c != null) ? matchingOali.Tax__c : 0;
                    poli.Discount__c = (matchingOali != null && matchingOali.Discount_Percent__c != null) ? matchingOali.Discount_Percent__c : 0;
                    if (matchingOali != null) {
                        poli.Sales_Allocation_Line_Item__c = matchingOali.Id;
                    }
                    poli.Status__c = 'Open';

                    polisToInsert.add(poli);
                }
            }

            if (!polisToInsert.isEmpty()) {
                insert polisToInsert;

                // Update Purchase_Order_Line_Item__c reference back to Order_Allocation_Line_Item__c records
                for (Purchase_Order_Line_Item__c poli : polisToInsert) {
                    if (poli.Sales_Allocation_Line_Item__c != null) {
                        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
                            Id = poli.Sales_Allocation_Line_Item__c,
                            Purchase_Order_Line_Item__c = poli.Id
                        );
                        oalisToUpdateMap.put(oali.Id, oali);
                    }
                }

                if (!oalisToUpdateMap.isEmpty()) {
                    update oalisToUpdateMap.values();
                }
            }

            // Call FinancialRecordService to generate Invoice, Payables, Receivables
            Set<Id> createdPoIds = new Set<Id>();
            for (Purchase_Order__c po : posToInsert) {
                if (po.Id != null) {
                    createdPoIds.add(po.Id);
                }
            }

            if (!createdPoIds.isEmpty()) {
                FinancialRecordService.generateFinancialRecordsForPOs(createdPoIds);
            }
        }

        /*
        * Update Supply Request Status
        */
        for(Supply_Request__c sr : srList){
            sr.Status__c = 'Ordered';
        }

        update srList;

        /*
        * Query Created OAs to return complete details and Planner links
        */
        List<Order_Allocation__c> createdOAs = [
            SELECT Id,
                   Name,
                   Requesting_Account__c,
                   Requesting_Account__r.Name,
                   Supplying_Account__c,
                   Supplying_Account__r.Name,
                   Status__c
            FROM Order_Allocation__c
            WHERE Id IN :oaList
            ORDER BY Name ASC
        ];

        Map<Id, Decimal> oaVsTotalQty = new Map<Id, Decimal>();
        Map<Id, Integer> oaVsLineCount = new Map<Id, Integer>();

        for (Order_Allocation_Line_Item__c li : oaliList) {
            Decimal currentQty = oaVsTotalQty.containsKey(li.Order_Allocation__c) ? oaVsTotalQty.get(li.Order_Allocation__c) : 0;
            oaVsTotalQty.put(li.Order_Allocation__c, currentQty + (li.Ordered_Qty__c != null ? li.Ordered_Qty__c : 0));

            Integer currentCount = oaVsLineCount.containsKey(li.Order_Allocation__c) ? oaVsLineCount.get(li.Order_Allocation__c) : 0;
            oaVsLineCount.put(li.Order_Allocation__c, currentCount + 1);
        }

        List<OrderAllocationSummary> results = new List<OrderAllocationSummary>();
        for (Order_Allocation__c oa : createdOAs) {
            OrderAllocationSummary summary = new OrderAllocationSummary();
            summary.id = oa.Id;
            summary.name = oa.Name;
            summary.requestingAccountId = oa.Requesting_Account__c;
            summary.requestingAccountName = oa.Requesting_Account__r != null ? oa.Requesting_Account__r.Name : '';
            summary.supplyingAccountId = oa.Supplying_Account__c;
            summary.supplyingAccountName = oa.Supplying_Account__r != null ? oa.Supplying_Account__r.Name : '';
            summary.status = oa.Status__c;
            summary.lineItemCount = oaVsLineCount.containsKey(oa.Id) ? oaVsLineCount.get(oa.Id) : 0;
            summary.totalQty = oaVsTotalQty.containsKey(oa.Id) ? oaVsTotalQty.get(oa.Id) : 0;
            summary.plannerUrl = '/lightning/n/Sales_Allocation_Planner?c__recordId=' + oa.Id + '&c__planNumber=' + EncodingUtil.urlEncode(oa.Name != null ? oa.Name : '', 'UTF-8');
            results.add(summary);
        }

        return results;
    }

    /**
     * Formats and appends a single SR Number and Sub Request Type reference to an existing reference string.
     * Format: 'SR Number : Sub Request Type' (e.g. 'SR-001 : Dealer to Retailer')
     * Preserves existing references, separates multiple entries by a comma and space (', '),
     * and ensures duplicate SR Number entries are not added again.
     *
     * @param existingRefs Existing reference string (can be null/empty)
     * @param srName       SR Number or Name (e.g. 'SR-001')
     * @param subType      Sub Request Type (e.g. 'Dealer to Retailer')
     * @return Formatted reference string
     */
    public static String appendSrSubTypeReference(String existingRefs, String srName, String subType) {
        if (String.isBlank(srName)) {
            return existingRefs;
        }

        String cleanSrName = srName.trim();
        String cleanSubType = String.isNotBlank(subType) ? subType.trim() : '';
        String newEntry = cleanSrName + ' : ' + cleanSubType;
        String targetSrUpper = cleanSrName.toUpperCase();

        List<String> entries = new List<String>();
        Boolean found = false;

        if (String.isNotBlank(existingRefs)) {
            for (String part : existingRefs.split(',')) {
                String trimmed = part.trim();
                if (String.isBlank(trimmed)) {
                    continue;
                }

                String existingSrName = trimmed.contains(':') ? trimmed.split(':')[0].trim() : trimmed;
                if (existingSrName.equalsIgnoreCase(targetSrUpper)) {
                    found = true;
                    // If existing entry had an empty subtype but new subtype is provided, enrich it
                    if (trimmed.endsWith(':') && String.isNotBlank(cleanSubType)) {
                        entries.add(newEntry);
                    } else {
                        entries.add(trimmed);
                    }
                } else {
                    entries.add(trimmed);
                }
            }
        }

        if (!found) {
            entries.add(newEntry);
        }

        return String.join(entries, ', ');
    }

    /**
     * Formats and appends multiple SR Number and Sub Request Type references to an existing reference string.
     *
     * @param existingRefs Existing reference string (can be null/empty)
     * @param srs          List of Supply_Request__c records
     * @return Formatted comma-separated reference string
     */
    public static String appendSrSubTypeReferences(String existingRefs, List<Supply_Request__c> srs) {
        String result = existingRefs;
        if (srs != null) {
            for (Supply_Request__c sr : srs) {
                if (sr != null) {
                    String srName = String.isNotBlank(sr.Name) ? sr.Name : String.valueOf(sr.Id);
                    result = appendSrSubTypeReference(result, srName, sr.Sub_Request_Type__c);
                }
            }
        }
        return result;
    }
}