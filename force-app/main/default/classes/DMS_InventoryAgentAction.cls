/**
 * @description Invocable Apex Action for the Agentforce "Maxi" subagent: Inventory Assistant.
 *              Provides high-performance, strictly read-only stock quantities, threshold configurations,
 *              Supply Requests, Inventory Reservations, Inventory Transfers, and Inventory Location search.
 *
 * Core Architectural Standards Enforced:
 * 1. Read-Only: Strictly zero DML operations (no insert/update/delete/undelete/upsert/merge).
 * 2. Enterprise Security: Declared `with sharing` and executes all queries with `AccessLevel.USER_MODE`.
 * 3. Bulkification: Safely handles bulk Invocable requests (`List<Request>`) without governor-limit breaches.
 * 4. Primitive-Only Contract: Request/Response expose ONLY primitive data types (String, Boolean, Integer).
 *    Zero complex sObject lists, Maps, or nested DTO lists exposed to Agentforce.
 * 5. Real Pagination: Deterministic ordering, total record count calculation via SOQL COUNT(),
 *    and exact page calculation (`pageNumber`, `queryLimit`, `hasMoreRecords`, `currentPage`, `totalRecords`).
 * 6. Staged Search Strategy: Exact code/ID -> Wildcard SOQL -> Tokenized search -> Lightweight fuzzy scoring.
 * 7. Threshold vs. Live Quantity Distinction: Stock threshold fields (Reorder Level, High/Med/Low Levels,
 *    Target Stock) are clearly marked as reference configurations separate from live current quantities.
 * 8. Status & Active Filtering: Sensible open/active defaults with full support for explicit status filters
 *    and `includeInactive` / `isActive`.
 *
 * @author AM Industries DMS Agentforce Team
 */
public with sharing class DMS_InventoryAgentAction {

    // -------------------------------------------------------------------------
    // CONSTANTS: Action Types & Pagination Limits
    // -------------------------------------------------------------------------
    public static final String ACTION_GET_STOCK                 = 'GET_STOCK';
    public static final String ACTION_LIST_LOW_STOCK            = 'LIST_LOW_STOCK';
    public static final String ACTION_GET_SUPPLY_REQUEST_STATUS = 'GET_SUPPLY_REQUEST_STATUS';
    public static final String ACTION_GET_RESERVATION_STATUS    = 'GET_RESERVATION_STATUS';
    public static final String ACTION_GET_TRANSFER_STATUS       = 'GET_TRANSFER_STATUS';
    public static final String ACTION_LIST_INVENTORY_LOCATIONS  = 'LIST_INVENTORY_LOCATIONS';

    public static final Integer DEFAULT_PAGE_SIZE               = 25;
    public static final Integer MAX_PAGE_SIZE                   = 100;

    // Closed / terminal status sets for default open-record filtering
    public static final Set<String> CLOSED_SUPPLY_REQUEST_STATUSES = new Set<String>{
        'Completed', 'Cancelled', 'Received'
    };
    public static final Set<String> CLOSED_RESERVATION_STATUSES = new Set<String>{
        'Consumed', 'Released', 'Cancelled'
    };
    public static final Set<String> CLOSED_TRANSFER_STATUSES = new Set<String>{
        'Received', 'Cancelled'
    };

    // -------------------------------------------------------------------------
    // INVOCABLE ENTRY POINT (BULK-SAFE)
    // -------------------------------------------------------------------------
    /**
     * @description Invocable entry point for Agentforce / Flow execution.
     * @param requests List of user request parameters passed by the subagent.
     * @return List<Response> Parallel list of primitive responses.
     */
    @InvocableMethod(
        label='DMS Inventory Assistant Action'
        description='Query stock levels, low-stock alerts, Supply Requests, Reservations, Transfers, and Locations for the Inventory Assistant.'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();

        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        for (Request req : requests) {
            try {
                responses.add(processSingleRequest(req));
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR, 'DMS_InventoryAgentAction error: ' + ex.getTypeName() + ': ' + ex.getMessage() + ' at ' + ex.getStackTraceString());
                Response errResp = new Response();
                errResp.isSuccess = false;
                errResp.actionExecuted = (req != null && String.isNotBlank(req.actionType)) ? req.actionType : 'UNKNOWN';
                errResp.message = 'Unable to retrieve the requested inventory information right now.';
                errResp.summary = 'An unexpected technical issue occurred while retrieving inventory information. Please try again or refine your query.';
                errResp.totalRecords = 0;
                errResp.currentPage = 1;
                errResp.hasMoreRecords = false;
                errResp.jsonResponse = JSON.serialize(new Map<String, Object>{
                    'status' => 'ERROR',
                    'message' => 'Unable to complete the query at this time.'
                });
                responses.add(errResp);
            }
        }

        return responses;
    }

    // -------------------------------------------------------------------------
    // REQUEST DISPATCHER & INTENT INFERENCE
    // -------------------------------------------------------------------------
    /**
     * @description Dispatches a single request after validating and normalizing inputs.
     */
    private static Response processSingleRequest(Request req) {
        if (req == null) {
            req = new Request();
        }

        // Normalize pagination parameters
        Integer limitCount = (req.queryLimit != null && req.queryLimit > 0) ? Math.min(req.queryLimit, MAX_PAGE_SIZE) : DEFAULT_PAGE_SIZE;
        Integer pageNum = (req.pageNumber != null && req.pageNumber > 0) ? req.pageNumber : 1;
        req.queryLimit = limitCount;
        req.pageNumber = pageNum;

        // Reconcile isActive alias with includeInactive
        if (req.includeInactive == null && req.isActive != null) {
            req.includeInactive = !req.isActive;
        }

        String action = normalizeActionType(req);

        if (String.isBlank(action)) {
            Response valResp = new Response();
            valResp.isSuccess = false;
            valResp.actionExecuted = 'NONE';
            valResp.message = 'Missing action type. Please specify GET_STOCK, LIST_LOW_STOCK, GET_SUPPLY_REQUEST_STATUS, GET_RESERVATION_STATUS, GET_TRANSFER_STATUS, or LIST_INVENTORY_LOCATIONS.';
            valResp.summary = 'Please specify what you would like to do: check stock, view low stock, check supply requests, reservations, transfers, or list locations.';
            valResp.totalRecords = 0;
            valResp.currentPage = pageNum;
            valResp.hasMoreRecords = false;
            valResp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'INVALID_INPUT' });
            return valResp;
        }

        if (action == ACTION_GET_STOCK) {
            return handleGetStock(req);
        } else if (action == ACTION_LIST_LOW_STOCK) {
            return handleListLowStock(req);
        } else if (action == ACTION_GET_SUPPLY_REQUEST_STATUS) {
            return handleSupplyRequestStatus(req);
        } else if (action == ACTION_GET_RESERVATION_STATUS) {
            return handleReservationStatus(req);
        } else if (action == ACTION_GET_TRANSFER_STATUS) {
            return handleTransferStatus(req);
        } else if (action == ACTION_LIST_INVENTORY_LOCATIONS) {
            return handleListLocations(req);
        } else {
            Response unsupResp = new Response();
            unsupResp.isSuccess = false;
            unsupResp.actionExecuted = action;
            unsupResp.message = 'Unsupported Inventory request: ' + action;
            unsupResp.summary = 'The requested action "' + action + '" is not supported. Supported actions are GET_STOCK, LIST_LOW_STOCK, GET_SUPPLY_REQUEST_STATUS, GET_RESERVATION_STATUS, GET_TRANSFER_STATUS, and LIST_INVENTORY_LOCATIONS.';
            unsupResp.totalRecords = 0;
            unsupResp.currentPage = pageNum;
            unsupResp.hasMoreRecords = false;
            unsupResp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'UNSUPPORTED_ACTION' });
            return unsupResp;
        }
    }

    /**
     * @description Normalizes explicit actionType or infers intent from supplied parameters.
     */
    private static String normalizeActionType(Request req) {
        if (String.isNotBlank(req.actionType)) {
            String upper = req.actionType.trim().toUpperCase();
            if (upper.contains('LOW') && upper.contains('STOCK')) {
                return ACTION_LIST_LOW_STOCK;
            }
            if (upper.contains('SUPPLY') || upper.contains('SR')) {
                return ACTION_GET_SUPPLY_REQUEST_STATUS;
            }
            if (upper.contains('RESERV')) {
                return ACTION_GET_RESERVATION_STATUS;
            }
            if (upper.contains('TRANSFER')) {
                return ACTION_GET_TRANSFER_STATUS;
            }
            if (upper.contains('LOCATION') || upper.contains('WAREHOUSE') || upper.contains('DEPOT')) {
                return ACTION_LIST_INVENTORY_LOCATIONS;
            }
            if (upper.contains('STOCK') || upper.contains('INVENT') || upper.contains('ON_HAND') || upper.contains('AVAIL')) {
                return ACTION_GET_STOCK;
            }
            return upper;
        }

        // Automatic inference when actionType is omitted
        if (String.isNotBlank(req.requestType)) {
            return ACTION_GET_SUPPLY_REQUEST_STATUS;
        }
        if (String.isNotBlank(req.itemName) || String.isNotBlank(req.itemCode) || String.isNotBlank(req.sku)) {
            return ACTION_GET_STOCK;
        }
        if (String.isNotBlank(req.inventoryLocationName) && String.isBlank(req.accountName)) {
            return ACTION_LIST_INVENTORY_LOCATIONS;
        }

        return ACTION_GET_STOCK;
    }

    // -------------------------------------------------------------------------
    // USE CASE 1: GET STOCK (ITEM ONLY, ITEM+LOCATION, ITEM+ACCOUNT, LIST ALL)
    // -------------------------------------------------------------------------
    /**
     * @description Queries Inventory__c stock records for resolved Item, Location, Account, or broad stock list.
     */
    private static Response handleGetStock(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_STOCK;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));

        // 1. Resolve Account if provided
        Account resolvedAccount = null;
        List<Account> accountCandidates = new List<Account>();
        if (String.isNotBlank(req.accountName)) {
            accountCandidates = resolveAccountCandidates(req.accountName.trim());
            if (!accountCandidates.isEmpty()) {
                resolvedAccount = accountCandidates[0];
            }
            if (accountCandidates.size() > 1 && !accountCandidates[0].Name.equalsIgnoreCase(req.accountName.trim())) {
                resp.isSuccess = true;
                resp.totalRecords = accountCandidates.size();
                resp.hasMoreRecords = false;
                resp.message = 'Multiple Accounts matched "' + req.accountName + '". Please select one.';
                resp.summary = buildMultipleAccountsSummary(accountCandidates);
                resp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'AMBIGUOUS_ACCOUNT', 'candidates' => accountCandidates });
                return resp;
            }
            if (accountCandidates.isEmpty()) {
                resp.isSuccess = true;
                resp.totalRecords = 0;
                resp.hasMoreRecords = false;
                resp.message = 'No matching Account was found for "' + req.accountName + '".';
                resp.summary = 'No Account record was found matching "' + req.accountName + '".';
                resp.jsonResponse = buildStockJson(new List<Inventory__c>(), 0, 1, false, false);
                return resp;
            }
        }

        // 2. Resolve Inventory Location if provided
        Inventory_Location__c resolvedLocation = null;
        List<Inventory_Location__c> locationCandidates = new List<Inventory_Location__c>();
        if (String.isNotBlank(req.inventoryLocationName)) {
            locationCandidates = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locationCandidates.isEmpty()) {
                resolvedLocation = locationCandidates[0];
            }
            if (locationCandidates.size() > 1 && !locationCandidates[0].Name.equalsIgnoreCase(req.inventoryLocationName.trim())) {
                resp.isSuccess = true;
                resp.totalRecords = locationCandidates.size();
                resp.hasMoreRecords = false;
                resp.message = 'Multiple Inventory Locations matched "' + req.inventoryLocationName + '". Please select one.';
                resp.summary = buildMultipleLocationsSummary(locationCandidates);
                resp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'AMBIGUOUS_LOCATION', 'candidates' => locationCandidates });
                return resp;
            }
            if (locationCandidates.isEmpty()) {
                resp.isSuccess = true;
                resp.totalRecords = 0;
                resp.hasMoreRecords = false;
                resp.message = 'No matching Inventory Location was found for "' + req.inventoryLocationName + '".';
                resp.summary = 'No Inventory Location was found matching "' + req.inventoryLocationName + '".';
                resp.jsonResponse = buildStockJson(new List<Inventory__c>(), 0, 1, false, false);
                return resp;
            }
        }

        // 3. Resolve Target Item if provided
        Item__c targetItem = null;
        Boolean itemResolved = false;
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch, req.includeInactive == true);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);

            if (scoredItems.isEmpty()) {
                resp.isSuccess = true;
                resp.totalRecords = 0;
                resp.hasMoreRecords = false;
                resp.message = 'No matching Item was found for "' + itemSearch + '".';
                resp.summary = 'No matching Item was found for "' + itemSearch + '". Please verify the Item name or code.';
                resp.jsonResponse = buildStockJson(new List<Inventory__c>(), 0, 1, false, false);
                return resp;
            }

            if (scoredItems.size() > 1 && scoredItems[0].score < 95 && Math.abs(scoredItems[0].score - scoredItems[1].score) < 5) {
                resp.isSuccess = true;
                resp.totalRecords = scoredItems.size();
                resp.hasMoreRecords = false;
                resp.message = 'Multiple Items matched "' + itemSearch + '". Please select one.';
                resp.summary = buildMultipleItemsSummary(scoredItems);
                resp.jsonResponse = JSON.serialize(new Map<String, Object>{
                    'type' => 'multipleMatches',
                    'candidates' => extractItemCandidateMaps(scoredItems)
                });
                return resp;
            }

            targetItem = scoredItems[0].item;
            itemResolved = true;
        }

        // 4. Build Dynamic Query on Inventory__c
        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        if (targetItem != null) {
            binds.put('itemId', targetItem.Id);
            whereClauses.add('Item__c = :itemId');
        }
        if (resolvedLocation != null) {
            binds.put('locId', resolvedLocation.Id);
            whereClauses.add('Inventory_Location__c = :locId');
        }
        if (resolvedAccount != null) {
            binds.put('accId', resolvedAccount.Id);
            whereClauses.add('Account__c = :accId');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Inventory__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Inventory_Location__c, Inventory_Location__r.Name, Inventory_Location__r.Inventory_Location_Code__c, ' +
                                  'Account__c, Account__r.Name, ' +
                                  'Available__c, Damaged__c, Reserved__c, Reserved_Sale_Order__c, Reserved_Transfer__c, ' +
                                  'Transit_In_Quantity__c, Transit_Out_Quantity__c, On_Hand_Qty__c, ' +
                                  'Reorder_Level__c, Stock_Low_Level_Quantity__c, Stock_Medium_Level_Quantity__c, ' +
                                  'Stock_High_Level_Quantity__c, Target_Stock_Level__c ' +
                           'FROM Inventory__c ' +
                           whereStr +
                           'ORDER BY Item__r.Name ASC, Inventory_Location__r.Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Inventory__c> stockRecords = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + stockRecords.size() < totalCount);

        if (stockRecords.isEmpty()) {
            if (targetItem != null) {
                String filterDesc = '';
                if (resolvedLocation != null) filterDesc += ' at Location "' + resolvedLocation.Name + '"';
                if (resolvedAccount != null) filterDesc += ' for Account "' + resolvedAccount.Name + '"';
                resp.message = 'The Item was found, but no Inventory record exists' + filterDesc + '.';
                resp.summary = 'The Item "' + targetItem.Name + '" was found, but no inventory stock record exists' + filterDesc + '.';
            } else {
                resp.message = 'No Inventory stock records were found matching your criteria.';
                resp.summary = 'No Inventory stock records were found matching the specified filters.';
            }
            resp.jsonResponse = buildStockJson(new List<Inventory__c>(), totalCount, req.pageNumber, false, itemResolved);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Inventory stock record(s).';
        resp.summary = buildStockSummary(stockRecords, targetItem, resolvedLocation, resolvedAccount, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildStockJson(stockRecords, totalCount, req.pageNumber, resp.hasMoreRecords, itemResolved);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 2: LIST LOW STOCK
    // -------------------------------------------------------------------------
    /**
     * @description Returns Inventory records where Available or On-Hand is at or below Reorder Level or Low-Stock Level.
     */
    private static Response handleListLowStock(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_LIST_LOW_STOCK;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));

        // Optional Location filter
        Inventory_Location__c resolvedLocation = null;
        if (String.isNotBlank(req.inventoryLocationName)) {
            List<Inventory_Location__c> locs = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locs.isEmpty()) {
                resolvedLocation = locs[0];
            }
        }

        // Optional Account filter
        Account resolvedAccount = null;
        if (String.isNotBlank(req.accountName)) {
            List<Account> accs = resolveAccountCandidates(req.accountName.trim());
            if (!accs.isEmpty()) {
                resolvedAccount = accs[0];
            }
        }

        // Optional Item filter
        Item__c targetItem = null;
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch, req.includeInactive == true);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                targetItem = scoredItems[0].item;
            }
        }

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        if (targetItem != null) {
            binds.put('itemId', targetItem.Id);
            whereClauses.add('Item__c = :itemId');
        }
        if (resolvedLocation != null) {
            binds.put('locId', resolvedLocation.Id);
            whereClauses.add('Inventory_Location__c = :locId');
        }
        if (resolvedAccount != null) {
            binds.put('accId', resolvedAccount.Id);
            whereClauses.add('Account__c = :accId');
        }

        // Low stock threshold condition: Reorder_Level__c > 0 or Stock_Low_Level_Quantity__c > 0
        // We will fetch inventory records matching location/item/account and filter by threshold in Apex/SOQL
        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String querySoql = 'SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Inventory_Location__c, Inventory_Location__r.Name, Inventory_Location__r.Inventory_Location_Code__c, ' +
                                  'Account__c, Account__r.Name, ' +
                                  'Available__c, Damaged__c, Reserved__c, Reserved_Sale_Order__c, Reserved_Transfer__c, ' +
                                  'Transit_In_Quantity__c, Transit_Out_Quantity__c, On_Hand_Qty__c, ' +
                                  'Reorder_Level__c, Stock_Low_Level_Quantity__c, Stock_Medium_Level_Quantity__c, ' +
                                  'Stock_High_Level_Quantity__c, Target_Stock_Level__c ' +
                           'FROM Inventory__c ' +
                           whereStr +
                           'ORDER BY Item__r.Name ASC, Inventory_Location__r.Name ASC, Id ASC LIMIT 200';

        List<Inventory__c> allCandidates = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        // Filter for low stock: Available <= Reorder_Level or Available <= Stock_Low_Level_Quantity
        List<Inventory__c> lowStockRecords = new List<Inventory__c>();
        for (Inventory__c inv : allCandidates) {
            Decimal avail = (inv.Available__c != null) ? inv.Available__c : 0;
            Decimal reorder = (inv.Reorder_Level__c != null) ? inv.Reorder_Level__c : 0;
            Decimal lowLevel = (inv.Stock_Low_Level_Quantity__c != null) ? inv.Stock_Low_Level_Quantity__c : 0;

            if ((reorder > 0 && avail <= reorder) || (lowLevel > 0 && avail <= lowLevel)) {
                lowStockRecords.add(inv);
            }
        }

        Integer totalCount = lowStockRecords.size();
        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = (offsetVal + queryLim < totalCount);

        List<Inventory__c> pagedRecords = new List<Inventory__c>();
        for (Integer i = offsetVal; i < Math.min(offsetVal + queryLim, totalCount); i++) {
            pagedRecords.add(lowStockRecords[i]);
        }

        if (pagedRecords.isEmpty()) {
            resp.message = 'No low stock items found.';
            resp.summary = 'Great news! All checked items are currently above their reorder and low-stock threshold levels.';
            resp.jsonResponse = buildLowStockJson(pagedRecords, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' low stock Item(s) at or below reorder threshold.';
        resp.summary = buildLowStockSummary(pagedRecords, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildLowStockJson(pagedRecords, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 3: GET SUPPLY REQUEST STATUS
    // -------------------------------------------------------------------------
    /**
     * @description Lists and searches Supply_Request__c records with status and entity filters.
     */
    private static Response handleSupplyRequestStatus(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_SUPPLY_REQUEST_STATUS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        // 1. Item Filter
        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch, true);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                binds.put('itemId', scoredItems[0].item.Id);
                whereClauses.add('Item__c = :itemId');
            }
        }

        // 2. Location Filter (Source or Target)
        if (String.isNotBlank(req.inventoryLocationName)) {
            List<Inventory_Location__c> locs = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locs.isEmpty()) {
                binds.put('locId', locs[0].Id);
                whereClauses.add('(Source_Location__c = :locId OR Target_Location__c = :locId)');
            }
        }

        // 3. Account Filter (Requesting, Supplying, or Reference)
        if (String.isNotBlank(req.accountName)) {
            List<Account> accs = resolveAccountCandidates(req.accountName.trim());
            if (!accs.isEmpty()) {
                binds.put('accId', accs[0].Id);
                whereClauses.add('(Requesting_Account__c = :accId OR Supplying_Account__c = :accId OR Reference_Account__c = :accId)');
            }
        }

        // 4. Status Filter (Default to open statuses if blank)
        if (String.isNotBlank(req.status)) {
            binds.put('statusVal', req.status.trim());
            whereClauses.add('Status__c = :statusVal');
        } else if (req.includeInactive != true) {
            binds.put('closedStatuses', CLOSED_SUPPLY_REQUEST_STATUSES);
            whereClauses.add('Status__c NOT IN :closedStatuses');
        }

        // 5. Request Type Filter
        if (String.isNotBlank(req.requestType)) {
            binds.put('reqType', req.requestType.trim());
            whereClauses.add('Request_Type__c = :reqType');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Supply_Request__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Source_Location__c, Source_Location__r.Name, Target_Location__c, Target_Location__r.Name, ' +
                                  'Requesting_Account__c, Requesting_Account__r.Name, Supplying_Account__c, Supplying_Account__r.Name, ' +
                                  'Reference_Account__c, Reference_Account__r.Name, ' +
                                  'Request_Type__c, Sub_Request_Type__c, Supply_Method__c, Status__c, ' +
                                  'Requested_Qty__c, Received_Qty__c, Remaining_Quantity__c, Required_Date__c, Automated_Supply_Request__c ' +
                           'FROM Supply_Request__c ' +
                           whereStr +
                           'ORDER BY CreatedDate DESC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Supply_Request__c> records = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + records.size() < totalCount);

        if (records.isEmpty()) {
            resp.message = 'No matching Supply Requests were found.';
            resp.summary = 'No Supply Request records were found matching your specified criteria.';
            resp.jsonResponse = buildSupplyRequestJson(records, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Supply Request(s).';
        resp.summary = buildSupplyRequestSummary(records, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildSupplyRequestJson(records, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 4: GET RESERVATION STATUS
    // -------------------------------------------------------------------------
    /**
     * @description Lists and searches Inventory_Reservation__c records with status and entity filters.
     */
    private static Response handleReservationStatus(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_RESERVATION_STATUS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        // 1. Item Filter
        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch, true);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                binds.put('itemId', scoredItems[0].item.Id);
                whereClauses.add('Item__c = :itemId');
            }
        }

        // 2. Location Filter
        if (String.isNotBlank(req.inventoryLocationName)) {
            List<Inventory_Location__c> locs = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locs.isEmpty()) {
                binds.put('locId', locs[0].Id);
                whereClauses.add('Inventory_Location__c = :locId');
            }
        }

        // 3. Account Filter (Requesting or Supplying)
        if (String.isNotBlank(req.accountName)) {
            List<Account> accs = resolveAccountCandidates(req.accountName.trim());
            if (!accs.isEmpty()) {
                binds.put('accId', accs[0].Id);
                whereClauses.add('(Requesting_Account__c = :accId OR Supplying_Account__c = :accId)');
            }
        }

        // 4. Status Filter (Default to open if blank)
        if (String.isNotBlank(req.status)) {
            binds.put('statusVal', req.status.trim());
            whereClauses.add('Status__c = :statusVal');
        } else if (req.includeInactive != true) {
            binds.put('closedStatuses', CLOSED_RESERVATION_STATUSES);
            whereClauses.add('Status__c NOT IN :closedStatuses');
        }

        // 5. Request Type Filter
        if (String.isNotBlank(req.requestType)) {
            binds.put('reqType', req.requestType.trim());
            whereClauses.add('Request_Type__c = :reqType');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Inventory_Reservation__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Inventory_Location__c, Inventory_Location__r.Name, ' +
                                  'Requesting_Account__c, Requesting_Account__r.Name, ' +
                                  'Supplying_Account__c, Supplying_Account__r.Name, ' +
                                  'Request_Type__c, Status__c, Requested_Qty__c, Reserved_Qty__c, ' +
                                  'Reservation_Date__c, Expiry_Date__c ' +
                           'FROM Inventory_Reservation__c ' +
                           whereStr +
                           'ORDER BY CreatedDate DESC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Inventory_Reservation__c> records = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + records.size() < totalCount);

        if (records.isEmpty()) {
            resp.message = 'No matching Inventory Reservations were found.';
            resp.summary = 'No Inventory Reservation records were found matching your criteria.';
            resp.jsonResponse = buildReservationJson(records, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Inventory Reservation(s).';
        resp.summary = buildReservationSummary(records, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildReservationJson(records, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 5: GET TRANSFER STATUS
    // -------------------------------------------------------------------------
    /**
     * @description Lists and searches Inventory_Transfer__c records with status, location, and account filters.
     */
    private static Response handleTransferStatus(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_TRANSFER_STATUS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        // 1. Item Filter
        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch, true);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                binds.put('itemId', scoredItems[0].item.Id);
                whereClauses.add('Item__c = :itemId');
            }
        }

        // 2. Location Filter (Source or Destination)
        if (String.isNotBlank(req.inventoryLocationName)) {
            List<Inventory_Location__c> locs = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locs.isEmpty()) {
                binds.put('locId', locs[0].Id);
                whereClauses.add('(Source_Inventory_Location__c = :locId OR Destination_Inventory_Location__c = :locId)');
            }
        }

        // 3. Account Filter (Account, From_Account, or To_Account)
        if (String.isNotBlank(req.accountName)) {
            List<Account> accs = resolveAccountCandidates(req.accountName.trim());
            if (!accs.isEmpty()) {
                binds.put('accId', accs[0].Id);
                whereClauses.add('(Account__c = :accId OR From_Account__c = :accId OR To_Account__c = :accId)');
            }
        }

        // 4. Status Filter (Default to open if blank)
        if (String.isNotBlank(req.status)) {
            binds.put('statusVal', req.status.trim());
            whereClauses.add('Status__c = :statusVal');
        } else if (req.includeInactive != true) {
            binds.put('closedStatuses', CLOSED_TRANSFER_STATUSES);
            whereClauses.add('Status__c NOT IN :closedStatuses');
        }

        // 5. Request Type Filter
        if (String.isNotBlank(req.requestType)) {
            binds.put('reqType', req.requestType.trim());
            whereClauses.add('Request_Type__c = :reqType');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Inventory_Transfer__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Source_Inventory_Location__c, Source_Inventory_Location__r.Name, ' +
                                  'Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name, ' +
                                  'Account__c, Account__r.Name, From_Account__c, From_Account__r.Name, To_Account__c, To_Account__r.Name, ' +
                                  'Request_Type__c, Status__c, Transfer_Qty__c, In_Transit_Qty__c, Received_Qty__c, ' +
                                  'Requested_Date__c, Required_Date__c, Shipped_Date__c, Received_Date__c ' +
                           'FROM Inventory_Transfer__c ' +
                           whereStr +
                           'ORDER BY CreatedDate DESC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Inventory_Transfer__c> records = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + records.size() < totalCount);

        if (records.isEmpty()) {
            resp.message = 'No matching Inventory Transfers were found.';
            resp.summary = 'No Inventory Transfer records were found matching your criteria.';
            resp.jsonResponse = buildTransferJson(records, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Inventory Transfer(s).';
        resp.summary = buildTransferSummary(records, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildTransferJson(records, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 6: LIST INVENTORY LOCATIONS
    // -------------------------------------------------------------------------
    /**
     * @description Lists and searches Inventory_Location__c records.
     */
    private static Response handleListLocations(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_LIST_INVENTORY_LOCATIONS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        Boolean includeInactive = (req.includeInactive == true);
        if (!includeInactive) {
            whereClauses.add('Is_Active__c = true');
        }

        if (String.isNotBlank(req.inventoryLocationName)) {
            binds.put('locName', '%' + req.inventoryLocationName.trim() + '%');
            binds.put('locCode', req.inventoryLocationName.trim());
            whereClauses.add('(Name LIKE :locName OR Inventory_Location_Code__c = :locCode)');
        }

        if (String.isNotBlank(req.accountName)) {
            List<Account> accs = resolveAccountCandidates(req.accountName.trim());
            if (!accs.isEmpty()) {
                binds.put('accId', accs[0].Id);
                whereClauses.add('Account__c = :accId');
            }
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Inventory_Location__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Inventory_Location_Code__c, Account__c, Account__r.Name, Is_Active__c ' +
                           'FROM Inventory_Location__c ' +
                           whereStr +
                           'ORDER BY Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Inventory_Location__c> records = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + records.size() < totalCount);

        if (records.isEmpty()) {
            resp.message = 'No matching Inventory Locations were found.';
            resp.summary = 'No Inventory Locations were found matching the specified search criteria.';
            resp.jsonResponse = buildLocationJson(records, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Inventory Location(s).';
        resp.summary = buildLocationSummary(records, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildLocationJson(records, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // STAGED SEARCH & FUZZY MATCHING HELPERS
    // -------------------------------------------------------------------------
    /**
     * @description Queries bounded Item candidates using selective SOQL filters.
     */
    private static List<Item__c> queryItemCandidates(String term, Boolean includeInactive) {
        String clean = normalizeText(term);
        if (String.isBlank(clean)) {
            return new List<Item__c>();
        }

        Map<String, Object> binds = new Map<String, Object>{
            'exactCode' => term.trim(),
            'likeTerm' => '%' + term.trim() + '%'
        };

        String activeFilter = includeInactive ? '' : 'AND Active__c = true ';

        String soql = 'SELECT Id, Name, Item_Code__c, Active__c ' +
                      'FROM Item__c ' +
                      'WHERE (Item_Code__c = :exactCode OR Name LIKE :likeTerm OR Item_Code__c LIKE :likeTerm) ' +
                      activeFilter +
                      'ORDER BY Name ASC, Id ASC LIMIT 50';

        List<Item__c> results = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);

        if (results.isEmpty()) {
            List<String> tokens = extractSignificantTokens(term);
            if (!tokens.isEmpty()) {
                Map<String, Object> tokenBinds = new Map<String, Object>();
                List<String> orClauses = new List<String>();
                for (Integer i = 0; i < tokens.size(); i++) {
                    String bindKey = 'tk' + i;
                    tokenBinds.put(bindKey, '%' + tokens[i] + '%');
                    orClauses.add('(Name LIKE :' + bindKey + ' OR Item_Code__c LIKE :' + bindKey + ')');
                }
                String fallbackSoql = 'SELECT Id, Name, Item_Code__c, Active__c ' +
                                      'FROM Item__c ' +
                                      'WHERE (' + String.join(orClauses, ' OR ') + ') ' +
                                      activeFilter +
                                      'ORDER BY Name ASC, Id ASC LIMIT 50';
                results = Database.queryWithBinds(fallbackSoql, tokenBinds, AccessLevel.USER_MODE);
            }
        }

        return results;
    }

    /**
     * @description Scores candidate Items deterministically based on match confidence (0-100).
     */
    private static List<ScoredItem> scoreAndRankItems(List<Item__c> items, String queryTerm) {
        List<ScoredItem> scored = new List<ScoredItem>();
        String normQuery = normalizeText(queryTerm);

        for (Item__c item : items) {
            Integer score = calculateMatchScore(item, queryTerm, normQuery);
            scored.add(new ScoredItem(item, score));
        }

        scored.sort(); // Sorts descending by score
        return scored;
    }

    private static Integer calculateMatchScore(Item__c item, String queryTerm, String normQuery) {
        String itemName = item.Name != null ? item.Name : '';
        String itemCode = item.Item_Code__c != null ? item.Item_Code__c : '';
        String normName = normalizeText(itemName);
        String normCode = normalizeText(itemCode);

        if (itemCode.equalsIgnoreCase(queryTerm.trim())) return 100;
        if (itemName.equalsIgnoreCase(queryTerm.trim())) return 98;
        if (normName.equals(normQuery) || normCode.equals(normQuery)) return 95;
        if (normName.startsWith(normQuery)) return 90;
        if (normName.contains(normQuery) || normQuery.contains(normName)) return 85;

        List<String> queryTokens = extractSignificantTokens(queryTerm);
        List<String> itemTokens = extractSignificantTokens(itemName);
        if (!queryTokens.isEmpty() && !itemTokens.isEmpty()) {
            Integer matchCount = 0;
            for (String qTok : queryTokens) {
                for (String iTok : itemTokens) {
                    if (iTok.contains(qTok) || qTok.contains(iTok)) {
                        matchCount++;
                        break;
                    }
                }
            }
            if (matchCount == queryTokens.size()) return 80;
            if (matchCount > 0) return 50 + (matchCount * 10);
        }

        Integer dist = normName.getLevenshteinDistance(normQuery);
        if (dist <= 3) return Math.max(40, 75 - (dist * 10));

        return 30;
    }

    private static List<Account> resolveAccountCandidates(String accName) {
        Map<String, Object> binds = new Map<String, Object>{
            'nameTerm' => '%' + accName.trim() + '%'
        };
        List<Account> matches = Database.queryWithBinds(
            'SELECT Id, Name FROM Account WHERE Name LIKE :nameTerm ORDER BY Name ASC LIMIT 5',
            binds,
            AccessLevel.USER_MODE
        );

        if (matches.isEmpty()) {
            List<String> tokens = extractSignificantTokens(accName);
            if (!tokens.isEmpty()) {
                Map<String, Object> tokenBinds = new Map<String, Object>();
                List<String> orClauses = new List<String>();
                for (Integer i = 0; i < tokens.size(); i++) {
                    String key = 't' + i;
                    tokenBinds.put(key, '%' + tokens[i] + '%');
                    orClauses.add('Name LIKE :' + key);
                }
                String soql = 'SELECT Id, Name FROM Account WHERE ' + String.join(orClauses, ' OR ') + ' ORDER BY Name ASC LIMIT 5';
                matches = Database.queryWithBinds(soql, tokenBinds, AccessLevel.USER_MODE);
            }
        }

        return matches;
    }

    private static List<Inventory_Location__c> resolveLocationCandidates(String locName) {
        Map<String, Object> binds = new Map<String, Object>{
            'exactCode' => locName.trim(),
            'nameTerm' => '%' + locName.trim() + '%'
        };
        List<Inventory_Location__c> matches = Database.queryWithBinds(
            'SELECT Id, Name, Inventory_Location_Code__c, Is_Active__c, Account__c FROM Inventory_Location__c ' +
            'WHERE Inventory_Location_Code__c = :exactCode OR Name LIKE :nameTerm ORDER BY Name ASC LIMIT 5',
            binds,
            AccessLevel.USER_MODE
        );

        if (matches.isEmpty()) {
            List<String> tokens = extractSignificantTokens(locName);
            if (!tokens.isEmpty()) {
                Map<String, Object> tokenBinds = new Map<String, Object>();
                List<String> orClauses = new List<String>();
                for (Integer i = 0; i < tokens.size(); i++) {
                    String key = 't' + i;
                    tokenBinds.put(key, '%' + tokens[i] + '%');
                    orClauses.add('Name LIKE :' + key);
                }
                String soql = 'SELECT Id, Name, Inventory_Location_Code__c, Is_Active__c, Account__c FROM Inventory_Location__c WHERE ' + String.join(orClauses, ' OR ') + ' ORDER BY Name ASC LIMIT 5';
                matches = Database.queryWithBinds(soql, tokenBinds, AccessLevel.USER_MODE);
            }
        }

        return matches;
    }

    private static String normalizeText(String raw) {
        if (String.isBlank(raw)) return '';
        String cleaned = raw.replaceAll('[^a-zA-Z0-9\\.]', ' ');
        return cleaned.replaceAll('\\s+', ' ').trim().toLowerCase();
    }

    private static List<String> extractSignificantTokens(String raw) {
        List<String> tokens = new List<String>();
        if (String.isBlank(raw)) return tokens;
        Set<String> stopWords = new Set<String>{
            'the', 'and', 'for', 'with', 'item', 'stock', 'inventory', 'location', 'show', 'give', 'list', 'about'
        };
        for (String word : raw.split('[\\s,.-]+')) {
            String clean = word.trim().toLowerCase();
            if (clean.length() >= 3 && !stopWords.contains(clean)) {
                tokens.add(clean);
            }
        }
        return tokens;
    }

    private static List<Map<String, Object>> extractItemCandidateMaps(List<ScoredItem> scoredList) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (ScoredItem si : scoredList) {
            listMap.add(new Map<String, Object>{
                'itemName' => si.item.Name,
                'itemCode' => si.item.Item_Code__c,
                'id' => si.item.Id
            });
        }
        return listMap;
    }

    // -------------------------------------------------------------------------
    // SUMMARY & JSON BUILDERS (STRICTLY PRIMITIVES & COMPACT JSON)
    // -------------------------------------------------------------------------
    private static String buildStockSummary(List<Inventory__c> stockList, Item__c item, Inventory_Location__c loc, Account acc, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        String title = (item != null) ? 'Stock for ' + item.Name : 'Inventory Stock Records';
        lines.add('### ' + title + ' (' + stockList.size() + ' of ' + totalCount + ' records)');
        if (loc != null) lines.add('**Location Filter**: ' + loc.Name);
        if (acc != null) lines.add('**Account Filter**: ' + acc.Name);
        lines.add('');

        for (Inventory__c inv : stockList) {
            String itemLabel = (inv.Item__r != null) ? inv.Item__r.Name : 'Item';
            String locLabel = (inv.Inventory_Location__r != null) ? inv.Inventory_Location__r.Name : 'Unknown Location';
            lines.add('- **' + itemLabel + '** @ ' + locLabel);
            lines.add('  - **Current**: On Hand: ' + inv.On_Hand_Qty__c + ' | Available: ' + inv.Available__c + ' | Reserved: ' + inv.Reserved__c + ' (SO: ' + inv.Reserved_Sale_Order__c + ', Transfer: ' + inv.Reserved_Transfer__c + ') | Damaged: ' + inv.Damaged__c + ' | In-Transit (In/Out): ' + inv.Transit_In_Quantity__c + '/' + inv.Transit_Out_Quantity__c);
            lines.add('  - *Thresholds*: Reorder Level: ' + inv.Reorder_Level__c + ' | Target Stock: ' + inv.Target_Stock_Level__c + ' | Low/Med/High: ' + inv.Stock_Low_Level_Quantity__c + '/' + inv.Stock_Medium_Level_Quantity__c + '/' + inv.Stock_High_Level_Quantity__c);
        }
        lines.add('');
        if (hasMore) {
            lines.add('*(More records available. Ask for "page ' + (pageNum + 1) + '" or specify a location/item to refine.)*');
        }
        return String.join(lines, '\n');
    }

    private static String buildLowStockSummary(List<Inventory__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Low Stock Alert (' + records.size() + ' of ' + totalCount + ' items below reorder/low threshold)');
        lines.add('');
        for (Inventory__c inv : records) {
            String itemLabel = (inv.Item__r != null) ? inv.Item__r.Name : 'Item';
            String locLabel = (inv.Inventory_Location__r != null) ? inv.Inventory_Location__r.Name : 'Unknown Location';
            lines.add('- **' + itemLabel + '** @ ' + locLabel);
            lines.add('  - Available: **' + inv.Available__c + '** | Reorder Level: ' + inv.Reorder_Level__c + ' | Low Stock Threshold: ' + inv.Stock_Low_Level_Quantity__c + ' | On Hand: ' + inv.On_Hand_Qty__c);
        }
        lines.add('');
        if (hasMore) {
            lines.add('*(More low stock records available. Ask for "page ' + (pageNum + 1) + '".)*');
        }
        return String.join(lines, '\n');
    }

    private static String buildSupplyRequestSummary(List<Supply_Request__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Supply Requests (' + records.size() + ' of ' + totalCount + ' records)');
        lines.add('');
        for (Supply_Request__c sr : records) {
            String itemLabel = (sr.Item__r != null) ? sr.Item__r.Name : 'N/A';
            String fromLoc = (sr.Source_Location__r != null) ? sr.Source_Location__r.Name : 'N/A';
            String toLoc = (sr.Target_Location__r != null) ? sr.Target_Location__r.Name : 'N/A';
            lines.add('- **' + sr.Name + '** (' + sr.Status__c + ') - ' + itemLabel);
            lines.add('  - Route: From ' + fromLoc + ' → To ' + toLoc + ' | Type: ' + sr.Request_Type__c + ' | Supply Method: ' + sr.Supply_Method__c);
            lines.add('  - Quantities: Requested: ' + sr.Requested_Qty__c + ' | Received: ' + sr.Received_Qty__c + ' | Remaining: ' + sr.Remaining_Quantity__c);
        }
        lines.add('');
        if (hasMore) lines.add('*(More Supply Requests available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildReservationSummary(List<Inventory_Reservation__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Inventory Reservations (' + records.size() + ' of ' + totalCount + ' records)');
        lines.add('');
        for (Inventory_Reservation__c res : records) {
            String itemLabel = (res.Item__r != null) ? res.Item__r.Name : 'N/A';
            String locLabel = (res.Inventory_Location__r != null) ? res.Inventory_Location__r.Name : 'N/A';
            lines.add('- **' + res.Name + '** (' + res.Status__c + ') - ' + itemLabel + ' @ ' + locLabel);
            lines.add('  - Requested Qty: ' + res.Requested_Qty__c + ' | Reserved Qty: ' + res.Reserved_Qty__c + ' | Expiry Date: ' + (res.Expiry_Date__c != null ? String.valueOf(res.Expiry_Date__c) : 'None'));
        }
        lines.add('');
        if (hasMore) lines.add('*(More Inventory Reservations available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildTransferSummary(List<Inventory_Transfer__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Inventory Transfers (' + records.size() + ' of ' + totalCount + ' records)');
        lines.add('');
        for (Inventory_Transfer__c tr : records) {
            String itemLabel = (tr.Item__r != null) ? tr.Item__r.Name : 'N/A';
            String srcLoc = (tr.Source_Inventory_Location__r != null) ? tr.Source_Inventory_Location__r.Name : 'N/A';
            String dstLoc = (tr.Destination_Inventory_Location__r != null) ? tr.Destination_Inventory_Location__r.Name : 'N/A';
            lines.add('- **' + tr.Name + '** (' + tr.Status__c + ') - ' + itemLabel);
            lines.add('  - Route: From ' + srcLoc + ' → To ' + dstLoc + ' | Transfer Qty: ' + tr.Transfer_Qty__c + ' | In-Transit: ' + tr.In_Transit_Qty__c + ' | Received: ' + tr.Received_Qty__c);
        }
        lines.add('');
        if (hasMore) lines.add('*(More Inventory Transfers available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildLocationSummary(List<Inventory_Location__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Inventory Locations (' + records.size() + ' of ' + totalCount + ' locations)');
        lines.add('');
        for (Inventory_Location__c loc : records) {
            String accLabel = (loc.Account__r != null) ? loc.Account__r.Name : 'None';
            lines.add('- **' + loc.Name + '** (Code: ' + (loc.Inventory_Location_Code__c != null ? loc.Inventory_Location_Code__c : 'N/A') + ')');
            lines.add('  - Account: ' + accLabel + ' | Active: ' + (loc.Is_Active__c ? 'Yes' : 'No'));
        }
        lines.add('');
        if (hasMore) lines.add('*(More Locations available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildStockJson(List<Inventory__c> stockList, Integer totalCount, Integer pageNum, Boolean hasMore, Boolean itemResolved) {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Inventory__c inv : stockList) {
            records.add(new Map<String, Object>{
                'itemName' => (inv.Item__r != null) ? inv.Item__r.Name : null,
                'itemCode' => (inv.Item__r != null) ? inv.Item__r.Item_Code__c : null,
                'inventoryLocationName' => (inv.Inventory_Location__r != null) ? inv.Inventory_Location__r.Name : null,
                'inventoryLocationCode' => (inv.Inventory_Location__r != null) ? inv.Inventory_Location__r.Inventory_Location_Code__c : null,
                'accountName' => (inv.Account__r != null) ? inv.Account__r.Name : null,
                'current' => new Map<String, Object>{
                    'onHand' => inv.On_Hand_Qty__c,
                    'available' => inv.Available__c,
                    'reserved' => inv.Reserved__c,
                    'reservedSaleOrder' => inv.Reserved_Sale_Order__c,
                    'reservedTransfer' => inv.Reserved_Transfer__c,
                    'damaged' => inv.Damaged__c,
                    'transitIn' => inv.Transit_In_Quantity__c,
                    'transitOut' => inv.Transit_Out_Quantity__c
                },
                'thresholds' => new Map<String, Object>{
                    'reorderLevel' => inv.Reorder_Level__c,
                    'stockLowLevel' => inv.Stock_Low_Level_Quantity__c,
                    'stockMediumLevel' => inv.Stock_Medium_Level_Quantity__c,
                    'stockHighLevel' => inv.Stock_High_Level_Quantity__c,
                    'targetStockLevel' => inv.Target_Stock_Level__c
                }
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'stock',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'itemResolved' => itemResolved,
            'records' => records
        });
    }

    private static String buildLowStockJson(List<Inventory__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Inventory__c inv : records) {
            listMap.add(new Map<String, Object>{
                'itemName' => (inv.Item__r != null) ? inv.Item__r.Name : null,
                'itemCode' => (inv.Item__r != null) ? inv.Item__r.Item_Code__c : null,
                'inventoryLocationName' => (inv.Inventory_Location__r != null) ? inv.Inventory_Location__r.Name : null,
                'available' => inv.Available__c,
                'onHand' => inv.On_Hand_Qty__c,
                'reorderLevel' => inv.Reorder_Level__c,
                'stockLowLevel' => inv.Stock_Low_Level_Quantity__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'lowStock',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'comparisonThreshold' => 'Available <= Reorder_Level__c OR Available <= Stock_Low_Level_Quantity__c',
            'records' => listMap
        });
    }

    private static String buildSupplyRequestJson(List<Supply_Request__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Supply_Request__c sr : records) {
            listMap.add(new Map<String, Object>{
                'name' => sr.Name,
                'itemName' => (sr.Item__r != null) ? sr.Item__r.Name : null,
                'itemCode' => (sr.Item__r != null) ? sr.Item__r.Item_Code__c : null,
                'sourceLocation' => (sr.Source_Location__r != null) ? sr.Source_Location__r.Name : null,
                'targetLocation' => (sr.Target_Location__r != null) ? sr.Target_Location__r.Name : null,
                'requestingAccount' => (sr.Requesting_Account__r != null) ? sr.Requesting_Account__r.Name : null,
                'supplyingAccount' => (sr.Supplying_Account__r != null) ? sr.Supplying_Account__r.Name : null,
                'referenceAccount' => (sr.Reference_Account__r != null) ? sr.Reference_Account__r.Name : null,
                'requestType' => sr.Request_Type__c,
                'subRequestType' => sr.Sub_Request_Type__c,
                'supplyMethod' => sr.Supply_Method__c,
                'status' => sr.Status__c,
                'requestedQty' => sr.Requested_Qty__c,
                'receivedQty' => sr.Received_Qty__c,
                'remainingQuantity' => sr.Remaining_Quantity__c,
                'requiredDate' => sr.Required_Date__c,
                'automatedSupplyRequest' => sr.Automated_Supply_Request__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'supplyRequests',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
    }

    private static String buildReservationJson(List<Inventory_Reservation__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Inventory_Reservation__c res : records) {
            listMap.add(new Map<String, Object>{
                'name' => res.Name,
                'itemName' => (res.Item__r != null) ? res.Item__r.Name : null,
                'itemCode' => (res.Item__r != null) ? res.Item__r.Item_Code__c : null,
                'inventoryLocationName' => (res.Inventory_Location__r != null) ? res.Inventory_Location__r.Name : null,
                'requestingAccount' => (res.Requesting_Account__r != null) ? res.Requesting_Account__r.Name : null,
                'supplyingAccount' => (res.Supplying_Account__r != null) ? res.Supplying_Account__r.Name : null,
                'requestType' => res.Request_Type__c,
                'status' => res.Status__c,
                'requestedQty' => res.Requested_Qty__c,
                'reservedQty' => res.Reserved_Qty__c,
                'reservationDate' => res.Reservation_Date__c,
                'expiryDate' => res.Expiry_Date__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'reservations',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
    }

    private static String buildTransferJson(List<Inventory_Transfer__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Inventory_Transfer__c tr : records) {
            listMap.add(new Map<String, Object>{
                'name' => tr.Name,
                'itemName' => (tr.Item__r != null) ? tr.Item__r.Name : null,
                'itemCode' => (tr.Item__r != null) ? tr.Item__r.Item_Code__c : null,
                'sourceInventoryLocation' => (tr.Source_Inventory_Location__r != null) ? tr.Source_Inventory_Location__r.Name : null,
                'destinationInventoryLocation' => (tr.Destination_Inventory_Location__r != null) ? tr.Destination_Inventory_Location__r.Name : null,
                'accountName' => (tr.Account__r != null) ? tr.Account__r.Name : null,
                'fromAccount' => (tr.From_Account__r != null) ? tr.From_Account__r.Name : null,
                'toAccount' => (tr.To_Account__r != null) ? tr.To_Account__r.Name : null,
                'requestType' => tr.Request_Type__c,
                'status' => tr.Status__c,
                'transferQty' => tr.Transfer_Qty__c,
                'inTransitQty' => tr.In_Transit_Qty__c,
                'receivedQty' => tr.Received_Qty__c,
                'requestedDate' => tr.Requested_Date__c,
                'requiredDate' => tr.Required_Date__c,
                'shippedDate' => tr.Shipped_Date__c,
                'receivedDate' => tr.Received_Date__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'transfers',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
    }

    private static String buildLocationJson(List<Inventory_Location__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Inventory_Location__c loc : records) {
            listMap.add(new Map<String, Object>{
                'name' => loc.Name,
                'code' => loc.Inventory_Location_Code__c,
                'accountName' => (loc.Account__r != null) ? loc.Account__r.Name : null,
                'isActive' => loc.Is_Active__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'inventoryLocations',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
    }

    private static String buildMultipleItemsSummary(List<ScoredItem> candidates) {
        List<String> lines = new List<String>();
        lines.add('Found multiple matching Items:');
        for (Integer i = 0; i < Math.min(candidates.size(), 5); i++) {
            lines.add((i + 1) + '. ' + candidates[i].item.Name + (candidates[i].item.Item_Code__c != null ? ' (' + candidates[i].item.Item_Code__c + ')' : ''));
        }
        lines.add('');
        lines.add('Which Item would you like inventory for?');
        return String.join(lines, '\n');
    }

    private static String buildMultipleAccountsSummary(List<Account> accounts) {
        List<String> lines = new List<String>();
        lines.add('Found multiple matching Accounts:');
        for (Integer i = 0; i < accounts.size(); i++) {
            lines.add((i + 1) + '. ' + accounts[i].Name);
        }
        lines.add('');
        lines.add('Which Account would you like inventory for?');
        return String.join(lines, '\n');
    }

    private static String buildMultipleLocationsSummary(List<Inventory_Location__c> locations) {
        List<String> lines = new List<String>();
        lines.add('Found multiple matching Inventory Locations:');
        for (Integer i = 0; i < locations.size(); i++) {
            lines.add((i + 1) + '. ' + locations[i].Name + (locations[i].Inventory_Location_Code__c != null ? ' (' + locations[i].Inventory_Location_Code__c + ')' : ''));
        }
        lines.add('');
        lines.add('Which Location would you like inventory for?');
        return String.join(lines, '\n');
    }

    // -------------------------------------------------------------------------
    // INNER CLASSES
    // -------------------------------------------------------------------------
    public class ScoredItem implements Comparable {
        public Item__c item;
        public Integer score;

        public ScoredItem(Item__c itm, Integer sc) {
            this.item = itm;
            this.score = sc;
        }

        public Integer compareTo(Object other) {
            ScoredItem otherScored = (ScoredItem) other;
            if (this.score == otherScored.score) {
                return (this.item.Name != null ? this.item.Name : '').compareTo(otherScored.item.Name != null ? otherScored.item.Name : '');
            }
            return (otherScored.score - this.score);
        }
    }

    public class Request {
        @InvocableVariable(
            label='Action Type'
            description='Action to perform: GET_STOCK, LIST_LOW_STOCK, GET_SUPPLY_REQUEST_STATUS, GET_RESERVATION_STATUS, GET_TRANSFER_STATUS, or LIST_INVENTORY_LOCATIONS.'
            required=true
        )
        public String actionType;

        @InvocableVariable(label='Item Name' description='Item Name or search phrase (supports fuzzy/partial matching)')
        public String itemName;

        @InvocableVariable(label='Item Code' description='Exact or partial Item Code (e.g., ITEM-ENG-500)')
        public String itemCode;

        @InvocableVariable(label='SKU' description='Stock Keeping Unit or Item Code')
        public String sku;

        @InvocableVariable(label='Inventory Location Name' description='Warehouse / Depot Location Name or Code (e.g., Hyderabad, LOC-HYD)')
        public String inventoryLocationName;

        @InvocableVariable(label='Account Name' description='Customer, Dealer, or Supplying Account name')
        public String accountName;

        @InvocableVariable(label='Status' description='Status filter for Supply Requests, Reservations, or Transfers')
        public String status;

        @InvocableVariable(label='Request Type' description='Request Type filter (e.g., Stock Replenishment, Customer Demand, Manual Request)')
        public String requestType;

        @InvocableVariable(label='Include Inactive' description='Set true to include closed/cancelled records or inactive locations (default false)')
        public Boolean includeInactive;

        @InvocableVariable(label='Is Active' description='Alias for includeInactive (true for active only, false for inactive)')
        public Boolean isActive;

        @InvocableVariable(label='Query Limit' description='Maximum records per page (default 25, max 100)')
        public Integer queryLimit;

        @InvocableVariable(label='Page Number' description='Page number for pagination (starts at 1)')
        public Integer pageNumber;
    }

    public class Response {
        @InvocableVariable(label='Is Success' description='True if operation completed successfully')
        public Boolean isSuccess;

        @InvocableVariable(label='Action Executed' description='The action type executed')
        public String actionExecuted;

        @InvocableVariable(label='Message' description='High-level summary message')
        public String message;

        @InvocableVariable(label='Summary' description='Detailed natural-language formatted text for the user')
        public String summary;

        @InvocableVariable(label='JSON Response' description='Structured compact JSON representation of records and pagination metadata')
        public String jsonResponse;

        @InvocableVariable(label='Total Records' description='Total count of all matching records in Salesforce')
        public Integer totalRecords;

        @InvocableVariable(label='Current Page' description='Current page number returned')
        public Integer currentPage;

        @InvocableVariable(label='Has More Records' description='True if additional pages are available')
        public Boolean hasMoreRecords;
    }
}