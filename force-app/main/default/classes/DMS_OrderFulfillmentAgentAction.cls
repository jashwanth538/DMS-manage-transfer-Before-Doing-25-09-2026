/**
 * @description Invocable Apex Action for the Agentforce "Maxi" subagent: Order Fulfillment Assistant.
 *              Provides high-performance, strictly read-only Sales Allocation (Order_Allocation__c)
 *              and Purchase Order (Purchase_Order__c) tracking at header and line-item levels.
 *
 * Core Architectural Standards Enforced:
 * 1. Read-Only: Strictly zero DML operations (no insert/update/delete/undelete/upsert/merge).
 * 2. Enterprise Security: Declared `with sharing` and executes all queries with `AccessLevel.USER_MODE`.
 * 3. Bulkification: Safely handles bulk Invocable requests (`List<Request>`) without governor-limit breaches.
 * 4. Primitive-Only Contract: Request/Response expose ONLY primitive data types (String, Boolean, Integer).
 *    Zero complex sObject lists, Maps, or nested DTO lists exposed to Agentforce.
 * 5. Real Pagination: Deterministic ordering, total record count calculation via SOQL COUNT(),
 *    and exact page calculation (`pageNumber`, `queryLimit`, `hasMoreRecords`, `currentPage`, `totalRecords`).
 * 6. Staged Search Strategy: Exact code/number lookup -> Wildcard SOQL -> Tokenized search -> Lightweight fuzzy scoring.
 * 7. Multi-Role Account & Location Matching: Seamlessly matches Requesting, Supplying, and Customer/Reference accounts,
 *    as well as Source and Target inventory locations.
 * 8. Line Details Validation: Requires documentNumber or Item filter to prevent uncontrolled bulk line dumps.
 *
 * @author AM Industries DMS Agentforce Team
 */
public with sharing class DMS_OrderFulfillmentAgentAction {

    // -------------------------------------------------------------------------
    // CONSTANTS: Action Types & Pagination Limits
    // -------------------------------------------------------------------------
    public static final String ACTION_GET_SALES_ALLOCATION_STATUS       = 'GET_SALES_ALLOCATION_STATUS';
    public static final String ACTION_GET_SALES_ALLOCATION_LINE_DETAILS = 'GET_SALES_ALLOCATION_LINE_DETAILS';
    public static final String ACTION_GET_PURCHASE_ORDER_STATUS         = 'GET_PURCHASE_ORDER_STATUS';
    public static final String ACTION_GET_PURCHASE_ORDER_LINE_DETAILS   = 'GET_PURCHASE_ORDER_LINE_DETAILS';

    public static final Integer DEFAULT_PAGE_SIZE                       = 25;
    public static final Integer MAX_PAGE_SIZE                           = 100;

    // -------------------------------------------------------------------------
    // INVOCABLE ENTRY POINT (BULK-SAFE)
    // -------------------------------------------------------------------------
    /**
     * @description Invocable entry point for Agentforce / Flow execution.
     * @param requests List of user request parameters passed by the subagent.
     * @return List<Response> Parallel list of primitive responses.
     */
    @InvocableMethod(
        label='DMS Order Fulfillment Assistant Action'
        description='Query Sales Allocation and Purchase Order header status and line-item details for the Order Fulfillment Assistant.'
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
                System.debug(LoggingLevel.ERROR, 'DMS_OrderFulfillmentAgentAction error: ' + ex.getTypeName() + ': ' + ex.getMessage() + ' at ' + ex.getStackTraceString());
                Response errResp = new Response();
                errResp.isSuccess = false;
                errResp.actionExecuted = (req != null && String.isNotBlank(req.actionType)) ? req.actionType : 'UNKNOWN';
                errResp.message = 'Unable to retrieve the requested order information right now.';
                errResp.summary = 'An unexpected technical issue occurred while retrieving order fulfillment information. Please try again or refine your query.';
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

        String action = normalizeActionType(req);

        if (String.isBlank(action)) {
            Response valResp = new Response();
            valResp.isSuccess = false;
            valResp.actionExecuted = 'NONE';
            valResp.message = 'Missing action type. Please specify GET_SALES_ALLOCATION_STATUS, GET_SALES_ALLOCATION_LINE_DETAILS, GET_PURCHASE_ORDER_STATUS, or GET_PURCHASE_ORDER_LINE_DETAILS.';
            valResp.summary = 'Please specify what you would like to do: check Sales Allocation status or line items, or check Purchase Order status or line items.';
            valResp.totalRecords = 0;
            valResp.currentPage = pageNum;
            valResp.hasMoreRecords = false;
            valResp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'INVALID_INPUT' });
            return valResp;
        }

        if (action == ACTION_GET_SALES_ALLOCATION_STATUS) {
            return handleSalesAllocationStatus(req);
        } else if (action == ACTION_GET_SALES_ALLOCATION_LINE_DETAILS) {
            return handleSalesAllocationLineDetails(req);
        } else if (action == ACTION_GET_PURCHASE_ORDER_STATUS) {
            return handlePurchaseOrderStatus(req);
        } else if (action == ACTION_GET_PURCHASE_ORDER_LINE_DETAILS) {
            return handlePurchaseOrderLineDetails(req);
        } else {
            Response unsupResp = new Response();
            unsupResp.isSuccess = false;
            unsupResp.actionExecuted = action;
            unsupResp.message = 'Unsupported Order Fulfillment request: ' + action;
            unsupResp.summary = 'The requested action "' + action + '" is not supported. Supported actions are GET_SALES_ALLOCATION_STATUS, GET_SALES_ALLOCATION_LINE_DETAILS, GET_PURCHASE_ORDER_STATUS, and GET_PURCHASE_ORDER_LINE_DETAILS.';
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
            if (upper.contains('ALLOCATION') || upper.contains('SALES_ALLOC') || upper.contains('OA')) {
                if (upper.contains('LINE') || upper.contains('ITEM')) {
                    return ACTION_GET_SALES_ALLOCATION_LINE_DETAILS;
                }
                return ACTION_GET_SALES_ALLOCATION_STATUS;
            }
            if (upper.contains('PURCHASE') || upper.contains('PO')) {
                if (upper.contains('LINE') || upper.contains('ITEM')) {
                    return ACTION_GET_PURCHASE_ORDER_LINE_DETAILS;
                }
                return ACTION_GET_PURCHASE_ORDER_STATUS;
            }
            return upper;
        }

        // Automatic inference when actionType is omitted
        if (String.isNotBlank(req.documentNumber)) {
            String doc = req.documentNumber.trim().toUpperCase();
            if (doc.startsWith('PO') || doc.contains('PURCHASE')) {
                return ACTION_GET_PURCHASE_ORDER_STATUS;
            }
            if (doc.startsWith('SA') || doc.startsWith('OA') || doc.contains('ALLOC')) {
                return ACTION_GET_SALES_ALLOCATION_STATUS;
            }
        }

        return ACTION_GET_SALES_ALLOCATION_STATUS;
    }

    // -------------------------------------------------------------------------
    // USE CASE 1: GET SALES ALLOCATION STATUS (HEADER LEVEL)
    // -------------------------------------------------------------------------
    /**
     * @description Retrieves header-level Sales Allocation records (Order_Allocation__c).
     */
    private static Response handleSalesAllocationStatus(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_SALES_ALLOCATION_STATUS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        // 1. Document Number / Name
        if (String.isNotBlank(req.documentNumber)) {
            String doc = req.documentNumber.trim();
            binds.put('docExact', doc);
            binds.put('docLike', '%' + doc + '%');
            whereClauses.add('(Name = :docExact OR Name LIKE :docLike)');
        }

        // 2. Account Filter (Requesting, Supplying, or Customer)
        if (String.isNotBlank(req.accountName)) {
            List<Account> accs = resolveAccountCandidates(req.accountName.trim());
            if (!accs.isEmpty()) {
                binds.put('accId', accs[0].Id);
                whereClauses.add('(Requesting_Account__c = :accId OR Supplying_Account__c = :accId OR Customer__c = :accId)');
            }
        }

        // 3. Location Filter (Source or Target)
        if (String.isNotBlank(req.inventoryLocationName)) {
            List<Inventory_Location__c> locs = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locs.isEmpty()) {
                binds.put('locId', locs[0].Id);
                whereClauses.add('(Source_Location__c = :locId OR Target_Location__c = :locId)');
            }
        }

        // 4. Item Filter (via child line items)
        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                binds.put('itemId', scoredItems[0].item.Id);
                whereClauses.add('Id IN (SELECT Order_Allocation__c FROM Order_Allocation_Line_Item__c WHERE Item__c = :itemId)');
            }
        }

        // 5. Status Filter
        if (String.isNotBlank(req.status)) {
            binds.put('statusVal', req.status.trim());
            whereClauses.add('Status__c = :statusVal');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Order_Allocation__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Status__c, Requesting_Account__c, Requesting_Account__r.Name, ' +
                                  'Supplying_Account__c, Supplying_Account__r.Name, Customer__c, Customer__r.Name, ' +
                                  'Source_Location__c, Source_Location__r.Name, Target_Location__c, Target_Location__r.Name, ' +
                                  'Order_Allocation_Method__c, Order_Allocation_Date__c, Confirmed_Date__c, ' +
                                  'Confirmed_Plan_Date__c, Ready_to_Ship_Date__c, Shipped_Date__c, Order_Activated_Date__c, ' +
                                  'Sale_Order__c, Sale_Order__r.OrderNumber, Sale_Order_Reference__c, Order_Reference__c, Type__c, ' +
                                  'Subtotal__c, Discount_Amount__c, Tax_Amount__c, Total_Additional_Cost__c, ' +
                                  'Total_Loading_and_Unloading_Charges__c, Total_Transfer_Cost__c, Grand_Total__c ' +
                           'FROM Order_Allocation__c ' +
                           whereStr +
                           'ORDER BY CreatedDate DESC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Order_Allocation__c> records = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + records.size() < totalCount);

        if (records.isEmpty()) {
            resp.message = 'No matching Sales Allocations were found.';
            resp.summary = 'No Sales Allocation records were found matching your criteria.';
            resp.jsonResponse = buildSalesAllocationJson(records, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Sales Allocation(s).';
        resp.summary = buildSalesAllocationSummary(records, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildSalesAllocationJson(records, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 2: GET SALES ALLOCATION LINE DETAILS
    // -------------------------------------------------------------------------
    /**
     * @description Retrieves line-item level details for Sales Allocation(s) (Order_Allocation_Line_Item__c).
     */
    private static Response handleSalesAllocationLineDetails(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_SALES_ALLOCATION_LINE_DETAILS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));

        // Validation: Must provide documentNumber or Item filter to prevent uncontrolled full-database line dump
        if (String.isBlank(req.documentNumber) && String.isBlank(itemSearch)) {
            resp.isSuccess = false;
            resp.message = 'Please provide a Sales Allocation Document Number (e.g., SA-0001) or an Item filter to retrieve line item details.';
            resp.summary = 'Please specify which Sales Allocation or Item you would like line details for.';
            resp.totalRecords = 0;
            resp.hasMoreRecords = false;
            resp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'INVALID_INPUT' });
            return resp;
        }

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        // 1. Parent Sales Allocation Filter
        if (String.isNotBlank(req.documentNumber)) {
            String doc = req.documentNumber.trim();
            binds.put('docExact', doc);
            binds.put('docLike', '%' + doc + '%');
            whereClauses.add('(Order_Allocation__r.Name = :docExact OR Order_Allocation__r.Name LIKE :docLike)');
        }

        // 2. Item Filter
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                binds.put('itemId', scoredItems[0].item.Id);
                whereClauses.add('Item__c = :itemId');
            }
        }

        // 3. Status Filter
        if (String.isNotBlank(req.status)) {
            binds.put('statusVal', req.status.trim());
            whereClauses.add('Status__c = :statusVal');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Order_Allocation_Line_Item__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Order_Allocation__c, Order_Allocation__r.Name, ' +
                                  'Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Ordered_Qty__c, Reserved_Qty_Planned__c, Reserved_Quantity__c, Secured_Qty__c, ' +
                                  'Transfer_Qty_Planned__c, Transfer_Qty_Received__c, ' +
                                  'Procurement_Qty_Planned__c, Procurement_Qty_Received__c, Remaining_Qty__c, ' +
                                  'Status__c, Unit_Price__c, Discount_Percent__c, Discount_Amount__c, ' +
                                  'Tax__c, Tax_Amount__c, Taxable_Amount__c, Gross_Amount__c, Item_Total__c, ' +
                                  'Purchase_Order_Line_Item__c, Purchase_Order_Line_Item__r.Name, ' +
                                  'Sales_Order_Line_Item__c, Sales_Order_Line_Item__r.OrderItemNumber, ' +
                                  'Supply_Request__c, Supply_Request__r.Name ' +
                           'FROM Order_Allocation_Line_Item__c ' +
                           whereStr +
                           'ORDER BY Order_Allocation__r.Name ASC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Order_Allocation_Line_Item__c> lines = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + lines.size() < totalCount);

        if (lines.isEmpty()) {
            resp.message = 'No matching Sales Allocation Line Items were found.';
            resp.summary = 'No Sales Allocation Line Item records were found matching your criteria.';
            resp.jsonResponse = buildSalesAllocationLineJson(lines, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Sales Allocation Line Item(s).';
        resp.summary = buildSalesAllocationLineSummary(lines, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildSalesAllocationLineJson(lines, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 3: GET PURCHASE ORDER STATUS (HEADER LEVEL)
    // -------------------------------------------------------------------------
    /**
     * @description Retrieves header-level Purchase Order records (Purchase_Order__c).
     */
    private static Response handlePurchaseOrderStatus(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_PURCHASE_ORDER_STATUS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        // 1. Document Number / Name
        if (String.isNotBlank(req.documentNumber)) {
            String doc = req.documentNumber.trim();
            binds.put('docExact', doc);
            binds.put('docLike', '%' + doc + '%');
            whereClauses.add('(Name = :docExact OR Name LIKE :docLike)');
        }

        // 2. Account Filter (Requesting, Supplying, or Reference)
        if (String.isNotBlank(req.accountName)) {
            List<Account> accs = resolveAccountCandidates(req.accountName.trim());
            if (!accs.isEmpty()) {
                binds.put('accId', accs[0].Id);
                whereClauses.add('(Requesting_Account__c = :accId OR Supplying_Account__c = :accId OR Reference_Account__c = :accId)');
            }
        }

        // 3. Location Filter (Source or Target)
        if (String.isNotBlank(req.inventoryLocationName)) {
            List<Inventory_Location__c> locs = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locs.isEmpty()) {
                binds.put('locId', locs[0].Id);
                whereClauses.add('(Source_Location__c = :locId OR Target_Location__c = :locId)');
            }
        }

        // 4. Item Filter (via child POLI)
        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                binds.put('itemId', scoredItems[0].item.Id);
                whereClauses.add('Id IN (SELECT Purchase_Order__c FROM Purchase_Order_Line_Item__c WHERE Item__c = :itemId)');
            }
        }

        // 5. Status Filter
        if (String.isNotBlank(req.status)) {
            binds.put('statusVal', req.status.trim());
            whereClauses.add('Status__c = :statusVal');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Purchase_Order__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Status__c, Requesting_Account__c, Requesting_Account__r.Name, ' +
                                  'Supplying_Account__c, Supplying_Account__r.Name, Reference_Account__c, Reference_Account__r.Name, ' +
                                  'Source_Location__c, Source_Location__r.Name, Target_Location__c, Target_Location__r.Name, ' +
                                  'PO_Date__c, Expected_Date__c, Purchase_Requisition__c, Purchase_Requisition__r.Name, ' +
                                  'Sales_Allocation__c, Sales_Allocation__r.Name, ' +
                                  'Sub_Total__c, Discount_Amount__c, Tax_Amount__c, Gross_Amount__c, Total_Amount__c ' +
                           'FROM Purchase_Order__c ' +
                           whereStr +
                           'ORDER BY CreatedDate DESC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Purchase_Order__c> records = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + records.size() < totalCount);

        if (records.isEmpty()) {
            resp.message = 'No matching Purchase Orders were found.';
            resp.summary = 'No Purchase Order records were found matching your criteria.';
            resp.jsonResponse = buildPurchaseOrderJson(records, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Purchase Order(s).';
        resp.summary = buildPurchaseOrderSummary(records, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildPurchaseOrderJson(records, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 4: GET PURCHASE ORDER LINE DETAILS
    // -------------------------------------------------------------------------
    /**
     * @description Retrieves line-item level details for Purchase Order(s) (Purchase_Order_Line_Item__c).
     */
    private static Response handlePurchaseOrderLineDetails(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_PURCHASE_ORDER_LINE_DETAILS;
        resp.currentPage = req.pageNumber;

        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));

        // Validation: Must provide documentNumber or Item filter to prevent uncontrolled full-database line dump
        if (String.isBlank(req.documentNumber) && String.isBlank(itemSearch)) {
            resp.isSuccess = false;
            resp.message = 'Please provide a Purchase Order Document Number (e.g., PO-0001) or an Item filter to retrieve line item details.';
            resp.summary = 'Please specify which Purchase Order or Item you would like line details for.';
            resp.totalRecords = 0;
            resp.hasMoreRecords = false;
            resp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'INVALID_INPUT' });
            return resp;
        }

        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        // 1. Parent PO Filter
        if (String.isNotBlank(req.documentNumber)) {
            String doc = req.documentNumber.trim();
            binds.put('docExact', doc);
            binds.put('docLike', '%' + doc + '%');
            whereClauses.add('(Purchase_Order__r.Name = :docExact OR Purchase_Order__r.Name LIKE :docLike)');
        }

        // 2. Item Filter
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (!scoredItems.isEmpty()) {
                binds.put('itemId', scoredItems[0].item.Id);
                whereClauses.add('Item__c = :itemId');
            }
        }

        // 3. Status Filter
        if (String.isNotBlank(req.status)) {
            binds.put('statusVal', req.status.trim());
            whereClauses.add('Status__c = :statusVal');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Purchase_Order_Line_Item__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Purchase_Order__c, Purchase_Order__r.Name, ' +
                                  'Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Ordered_Qty__c, Received_Qty__c, Previously_Received_Quantity__c, Remaining_Quantity__c, ' +
                                  'Status__c, Unit_Price__c, Discount__c, Discount_Amount__c, ' +
                                  'Tax__c, Tax_Amount__c, Taxable_Amount__c, Gross_Amount__c, Additional_Fee__c, POLI_Total__c, ' +
                                  'Sales_Allocation_Line_Item__c, Sales_Allocation_Line_Item__r.Name, ' +
                                  'Purchase_Requisition_Line__c, Purchase_Requisition_Line__r.Name ' +
                           'FROM Purchase_Order_Line_Item__c ' +
                           whereStr +
                           'ORDER BY Purchase_Order__r.Name ASC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Purchase_Order_Line_Item__c> lines = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = ((req.pageNumber - 1) * queryLim + lines.size() < totalCount);

        if (lines.isEmpty()) {
            resp.message = 'No matching Purchase Order Line Items were found.';
            resp.summary = 'No Purchase Order Line Item records were found matching your criteria.';
            resp.jsonResponse = buildPurchaseOrderLineJson(lines, totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Purchase Order Line Item(s).';
        resp.summary = buildPurchaseOrderLineSummary(lines, totalCount, req.pageNumber, resp.hasMoreRecords);
        resp.jsonResponse = buildPurchaseOrderLineJson(lines, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // STAGED SEARCH & FUZZY MATCHING HELPERS
    // -------------------------------------------------------------------------
    private static List<Item__c> queryItemCandidates(String term) {
        String clean = normalizeText(term);
        if (String.isBlank(clean)) return new List<Item__c>();

        Map<String, Object> binds = new Map<String, Object>{
            'exactCode' => term.trim(),
            'likeTerm' => '%' + term.trim() + '%'
        };

        String soql = 'SELECT Id, Name, Item_Code__c FROM Item__c ' +
                      'WHERE (Item_Code__c = :exactCode OR Name LIKE :likeTerm OR Item_Code__c LIKE :likeTerm) ' +
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
                String fallbackSoql = 'SELECT Id, Name, Item_Code__c FROM Item__c ' +
                                      'WHERE (' + String.join(orClauses, ' OR ') + ') ' +
                                      'ORDER BY Name ASC, Id ASC LIMIT 50';
                results = Database.queryWithBinds(fallbackSoql, tokenBinds, AccessLevel.USER_MODE);
            }
        }

        return results;
    }

    private static List<ScoredItem> scoreAndRankItems(List<Item__c> items, String queryTerm) {
        List<ScoredItem> scored = new List<ScoredItem>();
        String normQuery = normalizeText(queryTerm);

        for (Item__c item : items) {
            Integer score = calculateMatchScore(item, queryTerm, normQuery);
            scored.add(new ScoredItem(item, score));
        }

        scored.sort();
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
            'SELECT Id, Name, Inventory_Location_Code__c FROM Inventory_Location__c ' +
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
                String soql = 'SELECT Id, Name, Inventory_Location_Code__c FROM Inventory_Location__c WHERE ' + String.join(orClauses, ' OR ') + ' ORDER BY Name ASC LIMIT 5';
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
            'the', 'and', 'for', 'with', 'order', 'allocation', 'purchase', 'status', 'line', 'details', 'show', 'list'
        };
        for (String word : raw.split('[\\s,.-]+')) {
            String clean = word.trim().toLowerCase();
            if (clean.length() >= 3 && !stopWords.contains(clean)) {
                tokens.add(clean);
            }
        }
        return tokens;
    }

    // -------------------------------------------------------------------------
    // SUMMARY & JSON BUILDERS (STRICTLY PRIMITIVES & COMPACT JSON)
    // -------------------------------------------------------------------------
    private static String buildSalesAllocationSummary(List<Order_Allocation__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Sales Allocations (' + records.size() + ' of ' + totalCount + ' records)');
        lines.add('');
        for (Order_Allocation__c sa : records) {
            String reqAcc = (sa.Requesting_Account__r != null) ? sa.Requesting_Account__r.Name : (sa.Customer__r != null ? sa.Customer__r.Name : 'N/A');
            String supAcc = (sa.Supplying_Account__r != null) ? sa.Supplying_Account__r.Name : 'N/A';
            String srcLoc = (sa.Source_Location__r != null) ? sa.Source_Location__r.Name : 'N/A';
            String dstLoc = (sa.Target_Location__r != null) ? sa.Target_Location__r.Name : 'N/A';
            lines.add('- **' + sa.Name + '** (' + sa.Status__c + ') - Requesting: ' + reqAcc + ' | Supplying: ' + supAcc);
            lines.add('  - Route: ' + srcLoc + ' → ' + dstLoc + ' | Method: ' + sa.Order_Allocation_Method__c + ' | Grand Total: ' + sa.Grand_Total__c);
            lines.add('  - Dates: Allocation: ' + sa.Order_Allocation_Date__c + ' | Ready to Ship: ' + sa.Ready_to_Ship_Date__c + ' | Shipped: ' + sa.Shipped_Date__c);
        }
        lines.add('');
        if (hasMore) lines.add('*(More Sales Allocations available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildSalesAllocationLineSummary(List<Order_Allocation_Line_Item__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Sales Allocation Line Items (' + records.size() + ' of ' + totalCount + ' lines)');
        lines.add('');
        for (Order_Allocation_Line_Item__c li : records) {
            String itmName = (li.Item__r != null) ? li.Item__r.Name : 'N/A';
            String saName = (li.Order_Allocation__r != null) ? li.Order_Allocation__r.Name : 'N/A';
            lines.add('- **' + itmName + '** on ' + saName + ' (' + li.Status__c + ')');
            lines.add('  - Quantities: Ordered: ' + li.Ordered_Qty__c + ' | Reserved: ' + li.Reserved_Quantity__c + ' | Remaining: ' + li.Remaining_Qty__c + ' | Secured: ' + li.Secured_Qty__c);
            lines.add('  - Transfer (Planned/Recv): ' + li.Transfer_Qty_Planned__c + '/' + li.Transfer_Qty_Received__c + ' | Procurement (Planned/Recv): ' + li.Procurement_Qty_Planned__c + '/' + li.Procurement_Qty_Received__c);
            lines.add('  - Financials: Unit Price: ' + li.Unit_Price__c + ' | Tax %: ' + li.Tax__c + ' | Item Total: ' + li.Item_Total__c);
        }
        lines.add('');
        if (hasMore) lines.add('*(More Line Items available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildPurchaseOrderSummary(List<Purchase_Order__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Purchase Orders (' + records.size() + ' of ' + totalCount + ' records)');
        lines.add('');
        for (Purchase_Order__c po : records) {
            String reqAcc = (po.Requesting_Account__r != null) ? po.Requesting_Account__r.Name : 'N/A';
            String supAcc = (po.Supplying_Account__r != null) ? po.Supplying_Account__r.Name : 'N/A';
            String srcLoc = (po.Source_Location__r != null) ? po.Source_Location__r.Name : 'N/A';
            String dstLoc = (po.Target_Location__r != null) ? po.Target_Location__r.Name : 'N/A';
            lines.add('- **' + po.Name + '** (' + po.Status__c + ') - Requesting: ' + reqAcc + ' | Supplying: ' + supAcc);
            lines.add('  - Route: ' + srcLoc + ' → ' + dstLoc + ' | PO Date: ' + po.PO_Date__c + ' | Expected Date: ' + po.Expected_Date__c);
            lines.add('  - Financials: Subtotal: ' + po.Sub_Total__c + ' | Tax: ' + po.Tax_Amount__c + ' | Total Amount: ' + po.Total_Amount__c);
        }
        lines.add('');
        if (hasMore) lines.add('*(More Purchase Orders available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildPurchaseOrderLineSummary(List<Purchase_Order_Line_Item__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Purchase Order Line Items (' + records.size() + ' of ' + totalCount + ' lines)');
        lines.add('');
        for (Purchase_Order_Line_Item__c poli : records) {
            String itmName = (poli.Item__r != null) ? poli.Item__r.Name : 'N/A';
            String poName = (poli.Purchase_Order__r != null) ? poli.Purchase_Order__r.Name : 'N/A';
            lines.add('- **' + itmName + '** on ' + poName + ' (' + poli.Status__c + ')');
            lines.add('  - Quantities: Ordered: ' + poli.Ordered_Qty__c + ' | Received: ' + poli.Received_Qty__c + ' | Prev Received: ' + poli.Previously_Received_Quantity__c + ' | Remaining: ' + poli.Remaining_Quantity__c);
            lines.add('  - Pricing: Unit Price: ' + poli.Unit_Price__c + ' | Discount: ' + poli.Discount__c + '% | Tax: ' + poli.Tax__c + '% | POLI Total: ' + poli.POLI_Total__c);
        }
        lines.add('');
        if (hasMore) lines.add('*(More Line Items available. Ask for "page ' + (pageNum + 1) + '".)*');
        return String.join(lines, '\n');
    }

    private static String buildSalesAllocationJson(List<Order_Allocation__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Order_Allocation__c sa : records) {
            listMap.add(new Map<String, Object>{
                'name' => sa.Name,
                'status' => sa.Status__c,
                'requestingAccount' => (sa.Requesting_Account__r != null) ? sa.Requesting_Account__r.Name : null,
                'supplyingAccount' => (sa.Supplying_Account__r != null) ? sa.Supplying_Account__r.Name : null,
                'customer' => (sa.Customer__r != null) ? sa.Customer__r.Name : null,
                'sourceLocation' => (sa.Source_Location__r != null) ? sa.Source_Location__r.Name : null,
                'targetLocation' => (sa.Target_Location__r != null) ? sa.Target_Location__r.Name : null,
                'allocationMethod' => sa.Order_Allocation_Method__c,
                'type' => sa.Type__c,
                'dates' => new Map<String, Object>{
                    'allocationDate' => sa.Order_Allocation_Date__c,
                    'confirmedDate' => sa.Confirmed_Date__c,
                    'confirmedPlanDate' => sa.Confirmed_Plan_Date__c,
                    'readyToShipDate' => sa.Ready_to_Ship_Date__c,
                    'shippedDate' => sa.Shipped_Date__c,
                    'orderActivatedDate' => sa.Order_Activated_Date__c
                },
                'totals' => new Map<String, Object>{
                    'subtotal' => sa.Subtotal__c,
                    'discountAmount' => sa.Discount_Amount__c,
                    'taxAmount' => sa.Tax_Amount__c,
                    'additionalCost' => sa.Total_Additional_Cost__c,
                    'loadingUnloadingCharges' => sa.Total_Loading_and_Unloading_Charges__c,
                    'transferCost' => sa.Total_Transfer_Cost__c,
                    'grandTotal' => sa.Grand_Total__c
                },
                'saleOrderReference' => sa.Sale_Order_Reference__c,
                'orderReference' => sa.Order_Reference__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'salesAllocations',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
    }

    private static String buildSalesAllocationLineJson(List<Order_Allocation_Line_Item__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Order_Allocation_Line_Item__c li : records) {
            listMap.add(new Map<String, Object>{
                'name' => li.Name,
                'salesAllocationName' => (li.Order_Allocation__r != null) ? li.Order_Allocation__r.Name : null,
                'itemName' => (li.Item__r != null) ? li.Item__r.Name : null,
                'itemCode' => (li.Item__r != null) ? li.Item__r.Item_Code__c : null,
                'status' => li.Status__c,
                'quantities' => new Map<String, Object>{
                    'orderedQty' => li.Ordered_Qty__c,
                    'reservedQtyPlanned' => li.Reserved_Qty_Planned__c,
                    'reservedQuantity' => li.Reserved_Quantity__c,
                    'securedQty' => li.Secured_Qty__c,
                    'transferQtyPlanned' => li.Transfer_Qty_Planned__c,
                    'transferQtyReceived' => li.Transfer_Qty_Received__c,
                    'procurementQtyPlanned' => li.Procurement_Qty_Planned__c,
                    'procurementQtyReceived' => li.Procurement_Qty_Received__c,
                    'remainingQty' => li.Remaining_Qty__c
                },
                'pricing' => new Map<String, Object>{
                    'unitPrice' => li.Unit_Price__c,
                    'discountPercent' => li.Discount_Percent__c,
                    'discountAmount' => li.Discount_Amount__c,
                    'taxPercent' => li.Tax__c,
                    'taxAmount' => li.Tax_Amount__c,
                    'taxableAmount' => li.Taxable_Amount__c,
                    'grossAmount' => li.Gross_Amount__c,
                    'itemTotal' => li.Item_Total__c
                },
                'references' => new Map<String, Object>{
                    'purchaseOrderLineItem' => (li.Purchase_Order_Line_Item__r != null) ? li.Purchase_Order_Line_Item__r.Name : null,
                    'salesOrderLineItem' => (li.Sales_Order_Line_Item__r != null) ? li.Sales_Order_Line_Item__r.OrderItemNumber : null,
                    'supplyRequest' => (li.Supply_Request__r != null) ? li.Supply_Request__r.Name : null
                }
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'salesAllocationLines',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
    }

    private static String buildPurchaseOrderJson(List<Purchase_Order__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Purchase_Order__c po : records) {
            listMap.add(new Map<String, Object>{
                'name' => po.Name,
                'status' => po.Status__c,
                'requestingAccount' => (po.Requesting_Account__r != null) ? po.Requesting_Account__r.Name : null,
                'supplyingAccount' => (po.Supplying_Account__r != null) ? po.Supplying_Account__r.Name : null,
                'referenceAccount' => (po.Reference_Account__r != null) ? po.Reference_Account__r.Name : null,
                'sourceLocation' => (po.Source_Location__r != null) ? po.Source_Location__r.Name : null,
                'targetLocation' => (po.Target_Location__r != null) ? po.Target_Location__r.Name : null,
                'poDate' => po.PO_Date__c,
                'expectedDate' => po.Expected_Date__c,
                'purchaseRequisition' => (po.Purchase_Requisition__r != null) ? po.Purchase_Requisition__r.Name : null,
                'salesAllocation' => (po.Sales_Allocation__r != null) ? po.Sales_Allocation__r.Name : null,
                'totals' => new Map<String, Object>{
                    'subTotal' => po.Sub_Total__c,
                    'discountAmount' => po.Discount_Amount__c,
                    'taxAmount' => po.Tax_Amount__c,
                    'grossAmount' => po.Gross_Amount__c,
                    'totalAmount' => po.Total_Amount__c
                }
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'purchaseOrders',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
    }

    private static String buildPurchaseOrderLineJson(List<Purchase_Order_Line_Item__c> records, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> listMap = new List<Map<String, Object>>();
        for (Purchase_Order_Line_Item__c poli : records) {
            listMap.add(new Map<String, Object>{
                'name' => poli.Name,
                'purchaseOrderName' => (poli.Purchase_Order__r != null) ? poli.Purchase_Order__r.Name : null,
                'itemName' => (poli.Item__r != null) ? poli.Item__r.Name : null,
                'itemCode' => (poli.Item__r != null) ? poli.Item__r.Item_Code__c : null,
                'status' => poli.Status__c,
                'quantities' => new Map<String, Object>{
                    'orderedQty' => poli.Ordered_Qty__c,
                    'receivedQty' => poli.Received_Qty__c,
                    'previouslyReceivedQuantity' => poli.Previously_Received_Quantity__c,
                    'remainingQuantity' => poli.Remaining_Quantity__c
                },
                'pricing' => new Map<String, Object>{
                    'unitPrice' => poli.Unit_Price__c,
                    'discountPercent' => poli.Discount__c,
                    'discountAmount' => poli.Discount_Amount__c,
                    'taxPercent' => poli.Tax__c,
                    'taxAmount' => poli.Tax_Amount__c,
                    'taxableAmount' => poli.Taxable_Amount__c,
                    'grossAmount' => poli.Gross_Amount__c,
                    'additionalFee' => poli.Additional_Fee__c,
                    'poliTotal' => poli.POLI_Total__c
                },
                'references' => new Map<String, Object>{
                    'salesAllocationLineItem' => (poli.Sales_Allocation_Line_Item__r != null) ? poli.Sales_Allocation_Line_Item__r.Name : null,
                    'purchaseRequisitionLine' => (poli.Purchase_Requisition_Line__r != null) ? poli.Purchase_Requisition_Line__r.Name : null
                }
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'purchaseOrderLines',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => listMap
        });
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
            description='Action to perform: GET_SALES_ALLOCATION_STATUS, GET_SALES_ALLOCATION_LINE_DETAILS, GET_PURCHASE_ORDER_STATUS, or GET_PURCHASE_ORDER_LINE_DETAILS.'
            required=true
        )
        public String actionType;

        @InvocableVariable(label='Document Number' description='Sales Allocation or Purchase Order auto-number (e.g., SA-0001, PO-0001)')
        public String documentNumber;

        @InvocableVariable(label='Item Name' description='Item Name or search phrase (supports fuzzy/partial matching)')
        public String itemName;

        @InvocableVariable(label='Item Code' description='Exact or partial Item Code (e.g., ITEM-ENG-500)')
        public String itemCode;

        @InvocableVariable(label='SKU' description='Stock Keeping Unit or Item Code')
        public String sku;

        @InvocableVariable(label='Account Name' description='Customer, Requesting, Supplying, or Reference Account name')
        public String accountName;

        @InvocableVariable(label='Inventory Location Name' description='Source or Target Warehouse/Location Name or Code (e.g., Hyderabad, LOC-HYD)')
        public String inventoryLocationName;

        @InvocableVariable(label='Status' description='Status filter (e.g., Draft, Confirmed Planning, Shipped, Delivered, Closed, Partially Received)')
        public String status;

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