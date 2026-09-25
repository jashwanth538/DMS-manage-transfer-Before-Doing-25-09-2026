/**
 * @description Invocable Apex Action for the Agentforce "Maxi" subagent: Product & Pricing Assistant.
 *              Provides high-performance, strictly read-only Item and Item Price search, retrieval,
 *              pricing resolution, and pagination across Item__c, Item_Price__c, Account, and Inventory_Location__c.
 *
 * Core Architectural Standards Enforced:
 * 1. Read-Only: Strictly zero DML operations (no insert/update/delete/undelete/upsert).
 * 2. Enterprise Security: Declared `with sharing` and executes queries with `AccessLevel.USER_MODE`.
 * 3. Bulkification: Safely handles bulk Invocable requests (`List<Request>`) without governor-limit breaches.
 * 4. Primitive-Only Contract: Request/Response expose ONLY primitive data types (String, Boolean, Integer).
 *    Zero complex sObject lists, Maps, or nested DTO lists exposed to Agentforce.
 * 5. Real Pagination: Deterministic ordering, total record count calculation via SOQL COUNT(),
 *    and exact page calculation (`pageNumber`, `queryLimit`, `hasMoreRecords`, `currentPage`, `totalRecords`).
 * 6. Deterministic & Fuzzy Search Strategy:
 *    - Stage 1: Exact ID / Item Code / SKU lookup.
 *    - Stage 2: Selective case-insensitive SOQL wildcard search (`Name LIKE`, `Item_Code__c LIKE`).
 *    - Stage 3: Normalized string and tokenized multi-word search in SOQL / in-memory.
 *    - Stage 4: Lightweight Levenshtein distance & similarity scoring on bounded candidate sets for typo tolerance.
 * 7. Boundary Enforcement: Clear disclaimer that stock threshold fields (Reorder Level, Target Stock)
 *    represent master planning configurations and live on-hand quantities belong to the Inventory Assistant.
 *
 * @author AM Industries DMS Agentforce Team
 */
public with sharing class DMS_ProductPricingAgentAction {

    // -------------------------------------------------------------------------
    // CONSTANTS: Action Types, Limits & Disclaimers
    // -------------------------------------------------------------------------
    public static final String ACTION_SEARCH_ITEMS              = 'SEARCH_ITEMS';
    public static final String ACTION_GET_ITEM_DETAILS          = 'GET_ITEM_DETAILS';
    public static final String ACTION_GET_PRICING               = 'GET_PRICING';

    // Aliases for Agentforce NLP tolerance
    public static final String ALIAS_SEARCH_PRODUCTS            = 'SEARCH_PRODUCTS';
    public static final String ALIAS_GET_PRODUCT_DETAILS        = 'GET_PRODUCT_DETAILS';
    public static final String ALIAS_LIST_ITEMS                 = 'LIST_ITEMS';
    public static final String ALIAS_LIST_PRICES                = 'LIST_PRICES';
    public static final String ALIAS_RESOLVE_PRICING            = 'RESOLVE_PRICING';

    public static final Integer DEFAULT_PAGE_SIZE               = 25;
    public static final Integer MAX_PAGE_SIZE                   = 100;

    public static final String BOUNDARY_STOCK_NOTICE = 
        'Important Boundary Note: The stock quantities displayed (Reorder Level, Stock Low/Medium/High Level, Target Stock Level) ' +
        'represent master planning configuration thresholds on the Item record. ' +
        'For live on-hand quantities, reserved stock, or real-time warehouse availability, please ask the Inventory Assistant.';

    // -------------------------------------------------------------------------
    // INVOCABLE ENTRY POINT (BULK-SAFE)
    // -------------------------------------------------------------------------
    /**
     * @description Invocable entry point for Agentforce / Flow execution.
     * @param requests List of user request parameters passed by the subagent.
     * @return List<Response> Parallel list of primitive responses.
     */
    @InvocableMethod(
        label='DMS Product & Pricing Assistant Action'
        description='Search Items, retrieve Item details, and get Item pricing with pagination and fuzzy matching for the Product & Pricing Assistant.'
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
                System.debug(LoggingLevel.ERROR, 'DMS_ProductPricingAgentAction error: ' + ex.getTypeName() + ': ' + ex.getMessage() + ' at ' + ex.getStackTraceString());
                Response errResp = new Response();
                errResp.isSuccess = false;
                errResp.actionExecuted = (req != null && String.isNotBlank(req.actionType)) ? req.actionType : 'UNKNOWN';
                errResp.message = 'Sorry, I couldn\'t retrieve the requested Item information right now.';
                errResp.summary = 'An unexpected technical issue occurred while processing your request. Please try again or refine your query.';
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
            valResp.message = 'Missing action type. Please specify SEARCH_ITEMS, GET_ITEM_DETAILS, or GET_PRICING.';
            valResp.summary = 'Please specify what you would like to do: search for items, view item details, or check item pricing.';
            valResp.totalRecords = 0;
            valResp.currentPage = pageNum;
            valResp.hasMoreRecords = false;
            valResp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'INVALID_INPUT' });
            return valResp;
        }

        if (action == ACTION_SEARCH_ITEMS) {
            return handleSearchItems(req);
        } else if (action == ACTION_GET_ITEM_DETAILS) {
            return handleGetItemDetails(req);
        } else if (action == ACTION_GET_PRICING) {
            return handleGetPricing(req);
        } else {
            Response unsupResp = new Response();
            unsupResp.isSuccess = false;
            unsupResp.actionExecuted = action;
            unsupResp.message = 'Unsupported Product & Pricing request: ' + action;
            unsupResp.summary = 'The requested action "' + action + '" is not supported. Supported actions are SEARCH_ITEMS, GET_ITEM_DETAILS, and GET_PRICING.';
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
            if (upper.contains('DETAIL')) {
                return ACTION_GET_ITEM_DETAILS;
            }
            if (upper.contains('PRICE') || upper.contains('PRICING')) {
                return ACTION_GET_PRICING;
            }
            if (upper.contains('SEARCH') || upper.contains('LIST') || upper.contains('ITEM') || upper.contains('PROD')) {
                return ACTION_SEARCH_ITEMS;
            }
            return upper;
        }

        // Automatic inference when actionType is omitted by Agentforce
        if (String.isNotBlank(req.accountName) || String.isNotBlank(req.inventoryLocationName)) {
            return ACTION_GET_PRICING;
        }

        Boolean hasIdentifier = (String.isNotBlank(req.itemName) || String.isNotBlank(req.itemCode) || String.isNotBlank(req.sku));
        if (hasIdentifier) {
            return ACTION_SEARCH_ITEMS;
        }

        // Default to search/list items
        return ACTION_SEARCH_ITEMS;
    }

    // -------------------------------------------------------------------------
    // USE CASE 1 & 8: SEARCH ITEMS / LIST ITEMS (WITH PAGINATION & FUZZY MATCHING)
    // -------------------------------------------------------------------------
    /**
     * @description Searches Item__c records using staged matching and returns paginated results.
     */
    private static Response handleSearchItems(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_SEARCH_ITEMS;
        resp.currentPage = req.pageNumber;

        Boolean includeInactive = (req.includeInactive == true);
        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        String searchTerm = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));

        // 1. Broad / List All Items Query
        if (String.isBlank(searchTerm)) {
            Map<String, Object> binds = new Map<String, Object>{
                'lim' => queryLim,
                'offset' => offsetVal
            };
            String countSoql = 'SELECT COUNT() FROM Item__c' + (includeInactive ? '' : ' WHERE Active__c = true');
            Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

            String querySoql = 'SELECT Id, Name, Item_Code__c, Item_Description__c, Product_Id__c, ' +
                                      'Item_Family__c, Classification__c, Unit_Of_Measure__c, Quantity_Unit_Of_Measure__c, ' +
                                      'Active__c, Is_Sellable__c, Is_Inventory_Item__c, Base_Tax__c, ' +
                                      'Default_Supply_Method__c, Delivery_Preparation_Time__c, ' +
                                      'Reorder_Level__c, Stock_Low_Level_Quantity__c, Stock_Medium_Level_Quantity__c, ' +
                                      'Stock_High_Level_Quantity__c, Target_Stock_Level__c, Target_Days__c ' +
                               'FROM Item__c ' +
                               (includeInactive ? '' : 'WHERE Active__c = true ') +
                               'ORDER BY Name ASC, Id ASC ' +
                               'LIMIT :lim OFFSET :offset';

            List<Item__c> records = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);
            return buildItemSearchResponse(resp, records, totalCount, req.pageNumber, req.queryLimit, searchTerm);
        }

        // 2. Targeted Search using Staged Priority (Exact Code/SKU -> Name LIKE -> Fuzzy Token match)
        List<Item__c> candidates = queryItemCandidates(searchTerm, includeInactive);
        List<ScoredItem> scoredItems = scoreAndRankItems(candidates, searchTerm);

        Integer totalCount = scoredItems.size();
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = (offsetVal + queryLim < totalCount);

        // Paginate scored results in-memory
        List<Item__c> pagedItems = new List<Item__c>();
        for (Integer i = offsetVal; i < Math.min(offsetVal + queryLim, totalCount); i++) {
            pagedItems.add(scoredItems[i].item);
        }

        return buildItemSearchResponse(resp, pagedItems, totalCount, req.pageNumber, req.queryLimit, searchTerm);
    }

    // -------------------------------------------------------------------------
    // USE CASE 2: GET ITEM DETAILS
    // -------------------------------------------------------------------------
    /**
     * @description Retrieves complete Item business details for a single target Item.
     */
    private static Response handleGetItemDetails(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_ITEM_DETAILS;
        resp.currentPage = 1;

        String searchTerm = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));

        if (String.isBlank(searchTerm)) {
            resp.isSuccess = false;
            resp.message = 'Please provide an Item Name, Item Code, or SKU to retrieve item details.';
            resp.summary = 'Please specify the name or code of the item you want details for.';
            resp.totalRecords = 0;
            resp.hasMoreRecords = false;
            resp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'INVALID_INPUT' });
            return resp;
        }

        Boolean includeInactive = (req.includeInactive == true);
        List<Item__c> candidates = queryItemCandidates(searchTerm, includeInactive);
        List<ScoredItem> scoredItems = scoreAndRankItems(candidates, searchTerm);

        if (scoredItems.isEmpty()) {
            resp.isSuccess = true;
            resp.totalRecords = 0;
            resp.hasMoreRecords = false;
            resp.message = 'No matching Item was found for "' + searchTerm + '".';
            resp.summary = 'No matching Item was found for "' + searchTerm + '". Please verify the name or search all items.';
            resp.jsonResponse = JSON.serialize(new Map<String, Object>{
                'type' => 'items',
                'totalRecords' => 0,
                'currentPage' => 1,
                'hasMoreRecords' => false,
                'records' => new List<Object>()
            });
            return resp;
        }

        // Check if there are multiple equally plausible matches and the top match is not an exact match
        if (scoredItems.size() > 1 && scoredItems[0].score < 95 && Math.abs(scoredItems[0].score - scoredItems[1].score) < 5) {
            resp.isSuccess = true;
            resp.totalRecords = scoredItems.size();
            resp.hasMoreRecords = false;
            resp.message = 'Multiple Items matched the request. Please select one.';
            resp.summary = buildMultipleMatchesSummary(scoredItems);
            resp.jsonResponse = buildItemJson(extractItems(scoredItems), scoredItems.size(), 1, false);
            return resp;
        }

        // High-confidence single Item match
        Item__c targetItem = scoredItems[0].item;
        resp.isSuccess = true;
        resp.totalRecords = 1;
        resp.hasMoreRecords = false;
        resp.message = 'Found details for Item ' + targetItem.Name + '.';
        resp.summary = buildItemDetailSummary(targetItem);
        resp.jsonResponse = buildItemJson(new List<Item__c>{ targetItem }, 1, 1, false);

        return resp;
    }

    // -------------------------------------------------------------------------
    // USE CASE 3-7 & 9: GET PRICING / SEARCH ITEM PRICES
    // -------------------------------------------------------------------------
    /**
     * @description Retrieves pricing for Item only, Item + Account, Item + Location, or broad Item Prices.
     */
    private static Response handleGetPricing(Request req) {
        Response resp = new Response();
        resp.actionExecuted = ACTION_GET_PRICING;
        resp.currentPage = req.pageNumber;

        Boolean includeInactive = (req.includeInactive == true);
        Integer offsetVal = (req.pageNumber - 1) * req.queryLimit;
        Integer queryLim = req.queryLimit;

        String itemSearch = String.isNotBlank(req.itemName) ? req.itemName.trim() : (String.isNotBlank(req.itemCode) ? req.itemCode.trim() : (String.isNotBlank(req.sku) ? req.sku.trim() : ''));

        // 1. Resolve Account if accountName was provided
        Account resolvedAccount = null;
        List<Account> accountCandidates = new List<Account>();
        if (String.isNotBlank(req.accountName)) {
            accountCandidates = resolveAccountCandidates(req.accountName.trim());
            if (!accountCandidates.isEmpty()) {
                resolvedAccount = accountCandidates[0];
            }
        }

        // 2. Resolve Inventory Location if locationName was provided
        Inventory_Location__c resolvedLocation = null;
        List<Inventory_Location__c> locationCandidates = new List<Inventory_Location__c>();
        if (String.isNotBlank(req.inventoryLocationName)) {
            locationCandidates = resolveLocationCandidates(req.inventoryLocationName.trim());
            if (!locationCandidates.isEmpty()) {
                resolvedLocation = locationCandidates[0];
            }
        }

        // 3. Ambiguous Account or Location check
        if (String.isNotBlank(req.accountName) && accountCandidates.size() > 1 && !accountCandidates[0].Name.equalsIgnoreCase(req.accountName.trim())) {
            resp.isSuccess = true;
            resp.totalRecords = accountCandidates.size();
            resp.hasMoreRecords = false;
            resp.message = 'Multiple Accounts matched "' + req.accountName + '". Please select one.';
            resp.summary = buildMultipleAccountsSummary(accountCandidates);
            resp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'AMBIGUOUS_ACCOUNT', 'candidates' => accountCandidates });
            return resp;
        }

        if (String.isNotBlank(req.inventoryLocationName) && locationCandidates.size() > 1 && !locationCandidates[0].Name.equalsIgnoreCase(req.inventoryLocationName.trim())) {
            resp.isSuccess = true;
            resp.totalRecords = locationCandidates.size();
            resp.hasMoreRecords = false;
            resp.message = 'Multiple Inventory Locations matched "' + req.inventoryLocationName + '". Please select one.';
            resp.summary = buildMultipleLocationsSummary(locationCandidates);
            resp.jsonResponse = JSON.serialize(new Map<String, Object>{ 'status' => 'AMBIGUOUS_LOCATION', 'candidates' => locationCandidates });
            return resp;
        }

        // 4. Resolve Target Item if an item identifier was given
        Item__c targetItem = null;
        if (String.isNotBlank(itemSearch)) {
            List<Item__c> itemCandidates = queryItemCandidates(itemSearch, includeInactive);
            List<ScoredItem> scoredItems = scoreAndRankItems(itemCandidates, itemSearch);
            if (scoredItems.isEmpty()) {
                resp.isSuccess = true;
                resp.totalRecords = 0;
                resp.hasMoreRecords = false;
                resp.message = 'No matching Item was found for "' + itemSearch + '".';
                resp.summary = 'No matching Item was found for "' + itemSearch + '". Please check the item name.';
                resp.jsonResponse = buildPricingJson(new List<Item_Price__c>(), 0, 1, false);
                return resp;
            }
            targetItem = scoredItems[0].item;
        }

        // 5. Query Item_Price__c with safe binds
        Map<String, Object> binds = new Map<String, Object>{
            'lim' => queryLim,
            'offset' => offsetVal
        };
        List<String> whereClauses = new List<String>();

        if (!includeInactive) {
            whereClauses.add('Active__c = true');
        }
        if (targetItem != null) {
            binds.put('itemId', targetItem.Id);
            whereClauses.add('Item__c = :itemId');
        }
        if (resolvedAccount != null) {
            binds.put('accId', resolvedAccount.Id);
            whereClauses.add('Item_Price_Account__c = :accId');
        }
        if (resolvedLocation != null) {
            binds.put('locId', resolvedLocation.Id);
            whereClauses.add('Inventory_Location__c = :locId');
        }

        String whereStr = whereClauses.isEmpty() ? '' : 'WHERE ' + String.join(whereClauses, ' AND ') + ' ';

        String countSoql = 'SELECT COUNT() FROM Item_Price__c ' + whereStr;
        Integer totalCount = Database.countQueryWithBinds(countSoql, binds, AccessLevel.USER_MODE);

        String querySoql = 'SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c, ' +
                                  'Item_Price_Account__c, Item_Price_Account__r.Name, ' +
                                  'Inventory_Location__c, Inventory_Location__r.Name, Inventory_Location__r.Inventory_Location_Code__c, ' +
                                  'Unit_Price__c, Discount__c, Tax__c, Active__c ' +
                           'FROM Item_Price__c ' +
                           whereStr +
                           'ORDER BY Item__r.Name ASC, Name ASC, Id ASC ' +
                           'LIMIT :lim OFFSET :offset';

        List<Item_Price__c> priceRecords = Database.queryWithBinds(querySoql, binds, AccessLevel.USER_MODE);

        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.hasMoreRecords = (offsetVal + priceRecords.size() < totalCount);

        if (priceRecords.isEmpty()) {
            if (targetItem != null) {
                String filterDesc = '';
                if (resolvedAccount != null) filterDesc += ' for Account "' + resolvedAccount.Name + '"';
                if (resolvedLocation != null) filterDesc += ' at Location "' + resolvedLocation.Name + '"';
                resp.message = 'The Item was found, but no matching Item Price was found' + filterDesc + '.';
                resp.summary = 'The Item "' + targetItem.Name + '" was found, but no matching Item Price record exists' + filterDesc + '.';
            } else {
                resp.message = 'No matching Item Price records were found.';
                resp.summary = 'No Item Price records were found matching your criteria.';
            }
            resp.jsonResponse = buildPricingJson(new List<Item_Price__c>(), totalCount, req.pageNumber, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' Item Price record(s).';
        resp.summary = buildPricingSummary(priceRecords, targetItem, resolvedAccount, resolvedLocation, totalCount, resp.hasMoreRecords);
        resp.jsonResponse = buildPricingJson(priceRecords, totalCount, req.pageNumber, resp.hasMoreRecords);

        return resp;
    }

    // -------------------------------------------------------------------------
    // STAGED SEARCH & FUZZY SCORING HELPERS (BOUNDED & BULK-SAFE)
    // -------------------------------------------------------------------------
    /**
     * @description Stage 1 & 2: Queries bounded Item candidates using selective SOQL filters.
     */
    private static List<Item__c> queryItemCandidates(String term, Boolean includeInactive) {
        String clean = normalizeText(term);
        if (String.isBlank(clean)) {
            return new List<Item__c>();
        }

        Map<String, Object> binds = new Map<String, Object>{
            'exactCode' => term.trim(),
            'likeTerm' => '%' + term.trim() + '%',
            'normLike' => '%' + clean + '%'
        };

        String activeFilter = includeInactive ? '' : 'AND Active__c = true ';

        String soql = 'SELECT Id, Name, Item_Code__c, Item_Description__c, Product_Id__c, ' +
                             'Item_Family__c, Classification__c, Unit_Of_Measure__c, Quantity_Unit_Of_Measure__c, ' +
                             'Active__c, Is_Sellable__c, Is_Inventory_Item__c, Base_Tax__c, ' +
                             'Default_Supply_Method__c, Delivery_Preparation_Time__c, ' +
                             'Reorder_Level__c, Stock_Low_Level_Quantity__c, Stock_Medium_Level_Quantity__c, ' +
                             'Stock_High_Level_Quantity__c, Target_Stock_Level__c, Target_Days__c ' +
                      'FROM Item__c ' +
                      'WHERE (Item_Code__c = :exactCode OR Product_Id__c = :exactCode ' +
                             'OR Name LIKE :likeTerm OR Item_Code__c LIKE :likeTerm) ' +
                      activeFilter +
                      'ORDER BY Name ASC, Id ASC LIMIT 50';

        List<Item__c> results = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);

        // Fallback: If 0 results, do tokenized fallback
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
                String fallbackSoql = 'SELECT Id, Name, Item_Code__c, Item_Description__c, Product_Id__c, ' +
                                             'Item_Family__c, Classification__c, Unit_Of_Measure__c, Quantity_Unit_Of_Measure__c, ' +
                                             'Active__c, Is_Sellable__c, Is_Inventory_Item__c, Base_Tax__c, ' +
                                             'Default_Supply_Method__c, Delivery_Preparation_Time__c, ' +
                                             'Reorder_Level__c, Stock_Low_Level_Quantity__c, Stock_Medium_Level_Quantity__c, ' +
                                             'Stock_High_Level_Quantity__c, Target_Stock_Level__c, Target_Days__c ' +
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
     * @description Stage 3 & 4: Scores candidate Items deterministically based on priority.
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

    /**
     * @description Deterministic match score calculation (0 to 100).
     */
    private static Integer calculateMatchScore(Item__c item, String queryTerm, String normQuery) {
        String itemName = item.Name != null ? item.Name : '';
        String itemCode = item.Item_Code__c != null ? item.Item_Code__c : '';
        String normName = normalizeText(itemName);
        String normCode = normalizeText(itemCode);

        // 1. Exact Item Code / SKU
        if (itemCode.equalsIgnoreCase(queryTerm.trim())) {
            return 100;
        }

        // 2. Exact Item Name (Case-Insensitive)
        if (itemName.equalsIgnoreCase(queryTerm.trim())) {
            return 98;
        }

        // 3. Normalized Match (Ignoring spacing/punctuation/casing)
        if (normName.equals(normQuery) || normCode.equals(normQuery)) {
            return 95;
        }

        // 4. Starts-with or Contains Match
        if (normName.startsWith(normQuery)) {
            return 90;
        }
        if (normName.contains(normQuery) || normQuery.contains(normName)) {
            return 85;
        }

        // 5. Token Overlap Score
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
            if (matchCount == queryTokens.size()) {
                return 80;
            } else if (matchCount > 0) {
                return 50 + (matchCount * 10);
            }
        }

        // 6. Fuzzy Levenshtein Distance (bounded)
        Integer dist = normName.getLevenshteinDistance(normQuery);
        if (dist <= 3) {
            return Math.max(40, 75 - (dist * 10));
        }

        return 30;
    }

    /**
     * @description Normalizes text: trims, lowercases, and replaces multiple spaces/punctuation.
     */
    private static String normalizeText(String raw) {
        if (String.isBlank(raw)) {
            return '';
        }
        // Retain alphanumeric and decimal points; replace special punctuation with single space
        String cleaned = raw.replaceAll('[^a-zA-Z0-9\\.]', ' ');
        return cleaned.replaceAll('\\s+', ' ').trim().toLowerCase();
    }

    /**
     * @description Extracts significant words (>2 chars) excluding conversational stop words.
     */
    private static List<String> extractSignificantTokens(String raw) {
        List<String> tokens = new List<String>();
        if (String.isBlank(raw)) {
            return tokens;
        }
        Set<String> stopWords = new Set<String>{
            'the', 'and', 'for', 'with', 'item', 'product', 'details', 'price', 'pricing', 'show', 'give', 'list', 'about'
        };
        for (String word : raw.split('[\\s,.-]+')) {
            String clean = word.trim().toLowerCase();
            if (clean.length() >= 3 && !stopWords.contains(clean)) {
                tokens.add(clean);
            }
        }
        return tokens;
    }

    /**
     * @description Resolves Account candidates with wildcard and tokenized fallback.
     */
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

    /**
     * @description Resolves Inventory Location candidates by exact code or name.
     */
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

    private static List<Item__c> extractItems(List<ScoredItem> scoredList) {
        List<Item__c> items = new List<Item__c>();
        for (ScoredItem si : scoredList) {
            items.add(si.item);
        }
        return items;
    }

    // -------------------------------------------------------------------------
    // RESPONSE BUILDERS & JSON SERIALIZATION (PRIMITIVES & COMPACT JSON)
    // -------------------------------------------------------------------------
    private static Response buildItemSearchResponse(Response resp, List<Item__c> items, Integer totalCount, Integer pageNum, Integer limitCount, String searchTerm) {
        resp.isSuccess = true;
        resp.totalRecords = totalCount;
        resp.currentPage = pageNum;
        resp.hasMoreRecords = ((pageNum - 1) * limitCount + items.size() < totalCount);

        if (items.isEmpty()) {
            resp.message = 'No matching Item was found.';
            resp.summary = String.isNotBlank(searchTerm) 
                ? 'No matching Item was found for "' + searchTerm + '".' 
                : 'No Item records are currently available.';
            resp.jsonResponse = buildItemJson(items, totalCount, pageNum, false);
            return resp;
        }

        resp.message = 'Found ' + totalCount + ' matching Item(s).';
        resp.summary = buildItemListSummary(items, totalCount, pageNum, resp.hasMoreRecords);
        resp.jsonResponse = buildItemJson(items, totalCount, pageNum, resp.hasMoreRecords);

        return resp;
    }

    private static String buildItemListSummary(List<Item__c> items, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<String> lines = new List<String>();
        lines.add('### Item Catalog Results (Page ' + pageNum + ' - ' + items.size() + ' of ' + totalCount + ' items)');
        lines.add('');
        for (Item__c itm : items) {
            lines.add('- **' + itm.Name + '**' + (itm.Item_Code__c != null ? ' (Code: ' + itm.Item_Code__c + ')' : ''));
            lines.add('  - Family: ' + (itm.Item_Family__c != null ? itm.Item_Family__c : 'N/A') + ' | Classification: ' + (itm.Classification__c != null ? itm.Classification__c : 'N/A'));
            lines.add('  - Status: Active: ' + (itm.Active__c ? 'Yes' : 'No') + ' | Sellable: ' + (itm.Is_Sellable__c ? 'Yes' : 'No') + ' | Inventory Item: ' + (itm.Is_Inventory_Item__c ? 'Yes' : 'No'));
            lines.add('  - Reorder Level: ' + (itm.Reorder_Level__c != null ? String.valueOf(itm.Reorder_Level__c) : 'N/A') + ' | UOM: ' + (itm.Unit_Of_Measure__c != null ? itm.Unit_Of_Measure__c : 'N/A'));
        }
        lines.add('');
        if (hasMore) {
            lines.add('*(More records available. Ask for "page ' + (pageNum + 1) + '" or specify a search term to narrow down.)*');
            lines.add('');
        }
        lines.add('---');
        lines.add(BOUNDARY_STOCK_NOTICE);
        return String.join(lines, '\n');
    }

    private static String buildItemDetailSummary(Item__c itm) {
        List<String> lines = new List<String>();
        lines.add('### Item Details: ' + itm.Name);
        lines.add('- **Item Code**: ' + (itm.Item_Code__c != null ? itm.Item_Code__c : 'N/A'));
        lines.add('- **Family**: ' + (itm.Item_Family__c != null ? itm.Item_Family__c : 'N/A'));
        lines.add('- **Classification**: ' + (itm.Classification__c != null ? itm.Classification__c : 'N/A'));
        lines.add('- **Description**: ' + (itm.Item_Description__c != null ? itm.Item_Description__c : 'N/A'));
        lines.add('- **Status**: Active: ' + (itm.Active__c ? 'Yes' : 'No') + ' | Sellable: ' + (itm.Is_Sellable__c ? 'Yes' : 'No') + ' | Inventory Item: ' + (itm.Is_Inventory_Item__c ? 'Yes' : 'No'));
        lines.add('- **Supply & Tax**: Supply Method: ' + (itm.Default_Supply_Method__c != null ? itm.Default_Supply_Method__c : 'N/A') + ' | Base Tax: ' + (itm.Base_Tax__c != null ? String.valueOf(itm.Base_Tax__c) + '%' : 'N/A') + ' | Prep Time: ' + (itm.Delivery_Preparation_Time__c != null ? String.valueOf(itm.Delivery_Preparation_Time__c) + ' days' : 'N/A'));
        lines.add('- **Planning Thresholds**: Reorder Level: ' + itm.Reorder_Level__c + ' | Target Stock: ' + itm.Target_Stock_Level__c + ' | Target Days: ' + itm.Target_Days__c + ' | UOM: ' + itm.Unit_Of_Measure__c);
        lines.add('');
        lines.add('---');
        lines.add(BOUNDARY_STOCK_NOTICE);
        return String.join(lines, '\n');
    }

    private static String buildPricingSummary(List<Item_Price__c> prices, Item__c item, Account acc, Inventory_Location__c loc, Integer totalCount, Boolean hasMore) {
        List<String> lines = new List<String>();
        String title = (item != null) ? 'Pricing for ' + item.Name : 'Item Pricing Records';
        lines.add('### ' + title + ' (' + prices.size() + ' of ' + totalCount + ' records)');
        if (acc != null) lines.add('**Account Filter**: ' + acc.Name);
        if (loc != null) lines.add('**Location Filter**: ' + loc.Name);
        lines.add('');

        for (Item_Price__c ip : prices) {
            String itemLabel = (ip.Item__r != null) ? ip.Item__r.Name : 'Item';
            String accLabel = (ip.Item_Price_Account__r != null) ? ip.Item_Price_Account__r.Name : 'General Base';
            String locLabel = (ip.Inventory_Location__r != null) ? ip.Inventory_Location__r.Name : 'All Locations';
            Decimal net = ip.Unit_Price__c;
            if (ip.Unit_Price__c != null && ip.Discount__c != null && ip.Discount__c > 0) {
                net = (ip.Unit_Price__c * (1.0 - (ip.Discount__c / 100.0))).setScale(2, System.RoundingMode.HALF_UP);
            }

            lines.add('- **' + itemLabel + '** (' + accLabel + ' @ ' + locLabel + ')');
            lines.add('  - Unit Price: ' + ip.Unit_Price__c + ' | Discount: ' + ip.Discount__c + '% | Net Price: ' + net + ' | Tax: ' + ip.Tax__c + '% | Active: ' + (ip.Active__c ? 'Yes' : 'No'));
        }
        lines.add('');
        if (hasMore) {
            lines.add('*(More price records available. Ask for "page 2" or refine with a specific Account or Location.)*');
            lines.add('');
        }
        return String.join(lines, '\n');
    }

    private static String buildMultipleMatchesSummary(List<ScoredItem> candidates) {
        List<String> lines = new List<String>();
        lines.add('Found multiple matching Items:');
        for (Integer i = 0; i < Math.min(candidates.size(), 5); i++) {
            lines.add((i + 1) + '. ' + candidates[i].item.Name + (candidates[i].item.Item_Code__c != null ? ' (' + candidates[i].item.Item_Code__c + ')' : ''));
        }
        lines.add('');
        lines.add('Which Item would you like?');
        return String.join(lines, '\n');
    }

    private static String buildMultipleAccountsSummary(List<Account> accounts) {
        List<String> lines = new List<String>();
        lines.add('Found multiple matching Accounts:');
        for (Integer i = 0; i < accounts.size(); i++) {
            lines.add((i + 1) + '. ' + accounts[i].Name);
        }
        lines.add('');
        lines.add('Which Account would you like pricing for?');
        return String.join(lines, '\n');
    }

    private static String buildMultipleLocationsSummary(List<Inventory_Location__c> locations) {
        List<String> lines = new List<String>();
        lines.add('Found multiple matching Inventory Locations:');
        for (Integer i = 0; i < locations.size(); i++) {
            lines.add((i + 1) + '. ' + locations[i].Name + (locations[i].Inventory_Location_Code__c != null ? ' (' + locations[i].Inventory_Location_Code__c + ')' : ''));
        }
        lines.add('');
        lines.add('Which Location would you like pricing for?');
        return String.join(lines, '\n');
    }

    private static String buildItemJson(List<Item__c> items, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Item__c itm : items) {
            records.add(new Map<String, Object>{
                'itemName' => itm.Name,
                'itemCode' => itm.Item_Code__c,
                'sku' => itm.Item_Code__c,
                'description' => itm.Item_Description__c,
                'family' => itm.Item_Family__c,
                'classification' => itm.Classification__c,
                'active' => itm.Active__c,
                'sellable' => itm.Is_Sellable__c,
                'inventoryItem' => itm.Is_Inventory_Item__c,
                'unitOfMeasure' => itm.Unit_Of_Measure__c,
                'baseTax' => itm.Base_Tax__c,
                'defaultSupplyMethod' => itm.Default_Supply_Method__c,
                'reorderLevel' => itm.Reorder_Level__c,
                'targetStockLevel' => itm.Target_Stock_Level__c,
                'targetDays' => itm.Target_Days__c,
                'deliveryPreparationTime' => itm.Delivery_Preparation_Time__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'items',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => records
        });
    }

    private static String buildPricingJson(List<Item_Price__c> prices, Integer totalCount, Integer pageNum, Boolean hasMore) {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Item_Price__c ip : prices) {
            Decimal net = ip.Unit_Price__c;
            if (ip.Unit_Price__c != null && ip.Discount__c != null && ip.Discount__c > 0) {
                net = (ip.Unit_Price__c * (1.0 - (ip.Discount__c / 100.0))).setScale(2, System.RoundingMode.HALF_UP);
            }
            records.add(new Map<String, Object>{
                'priceRecordName' => ip.Name,
                'itemName' => (ip.Item__r != null) ? ip.Item__r.Name : null,
                'itemCode' => (ip.Item__r != null) ? ip.Item__r.Item_Code__c : null,
                'accountName' => (ip.Item_Price_Account__r != null) ? ip.Item_Price_Account__r.Name : null,
                'inventoryLocationName' => (ip.Inventory_Location__r != null) ? ip.Inventory_Location__r.Name : null,
                'inventoryLocationCode' => (ip.Inventory_Location__r != null) ? ip.Inventory_Location__r.Inventory_Location_Code__c : null,
                'unitPrice' => ip.Unit_Price__c,
                'discount' => ip.Discount__c,
                'netPrice' => net,
                'tax' => ip.Tax__c,
                'active' => ip.Active__c
            });
        }
        return JSON.serializePretty(new Map<String, Object>{
            'type' => 'itemPrices',
            'totalRecords' => totalCount,
            'currentPage' => pageNum,
            'hasMoreRecords' => hasMore,
            'records' => records
        });
    }

    // -------------------------------------------------------------------------
    // COMPARABLE WRAPPER FOR SCORE RANKING
    // -------------------------------------------------------------------------
    private class ScoredItem implements Comparable {
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
            return (otherScored.score - this.score); // Descending order
        }
    }

    // -------------------------------------------------------------------------
    // REQUEST & RESPONSE WRAPPERS (PRIMITIVE-ONLY INVOCABLE CONTRACT)
    // -------------------------------------------------------------------------
    public class Request {
        @InvocableVariable(
            label='Action Type'
            description='Action to perform: SEARCH_ITEMS, GET_ITEM_DETAILS, or GET_PRICING. Case-insensitive; if omitted, inferred from inputs.'
        )
        public String actionType;

        @InvocableVariable(label='Item Name' description='Item Name or search phrase (supports fuzzy/partial matching)')
        public String itemName;

        @InvocableVariable(label='Item Code' description='Exact or partial Item Code (e.g., ITEM-ENG-500)')
        public String itemCode;

        @InvocableVariable(label='SKU' description='Stock Keeping Unit or Item Code')
        public String sku;

        @InvocableVariable(label='Account Name' description='Customer or Dealer Account name for account-specific pricing')
        public String accountName;

        @InvocableVariable(label='Inventory Location Name' description='Warehouse / Depot Location Name or Code (e.g., Hyderabad, LOC-HYD)')
        public String inventoryLocationName;

        @InvocableVariable(label='Include Inactive' description='Set true to include inactive Items or Item Prices (default false)')
        public Boolean includeInactive;

        @InvocableVariable(label='Is Active' description='Filter for active items (true for active only, false for inactive). Alias for includeInactive.')
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