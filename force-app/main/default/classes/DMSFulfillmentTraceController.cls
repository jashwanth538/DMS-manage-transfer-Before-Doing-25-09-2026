/**
 * @description Controller for the dmsFulfillmentTrace LWC.
 *              Provides a generic, read-only, end-to-end trace of a DMS fulfillment requirement:
 *              - Upstream discovery to find the root requirement (SR or OA/OALI)
 *              - Bulkified downstream multi-branch traversal (Reserved, Procurement SR/PO/POLI, Transfer SR/OALI/IT)
 *              - Physical movement tracking (Source Location -> Destination Location)
 *              - Quantity reconciliation and mismatch detection
 *              - Visited-set cycle protection and depth limit safety
 */
public with sharing class DMSFulfillmentTraceController {

    private static final Integer MAX_TRAVERSAL_DEPTH = 10;

    /**
     * Data transfer object returning the complete trace graph.
     */
    public class TraceResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public String startingRecordId { get; set; }
        @AuraEnabled public TraceSummary summary { get; set; }
        @AuraEnabled public TraceNode rootNode { get; set; }
        @AuraEnabled public List<ReconciliationItem> reconciliations { get; set; }
        @AuraEnabled public Map<String, TraceNode> allNodesMap { get; set; }

        public TraceResult() {
            this.success = true;
            this.reconciliations = new List<ReconciliationItem>();
            this.allNodesMap = new Map<String, TraceNode>();
        }
    }

    /**
     * High-level summary metrics for the header ribbon.
     */
    public class TraceSummary {
        @AuraEnabled public String rootRecordName { get; set; }
        @AuraEnabled public String rootRecordType { get; set; }
        @AuraEnabled public String rootRecordId { get; set; }
        @AuraEnabled public String itemName { get; set; }
        @AuraEnabled public String itemCode { get; set; }
        @AuraEnabled public String overallStatus { get; set; }
        @AuraEnabled public Decimal totalRequiredQty { get; set; }
        @AuraEnabled public Decimal totalReservedQty { get; set; }
        @AuraEnabled public Decimal totalTransferQty { get; set; }
        @AuraEnabled public Decimal totalProcurementQty { get; set; }
        @AuraEnabled public Decimal totalReceivedQty { get; set; }
        @AuraEnabled public Decimal totalRemainingQty { get; set; }
        @AuraEnabled public Boolean hasMismatch { get; set; }
        @AuraEnabled public String mismatchMessage { get; set; }

        public TraceSummary() {
            this.totalRequiredQty = 0;
            this.totalReservedQty = 0;
            this.totalTransferQty = 0;
            this.totalProcurementQty = 0;
            this.totalReceivedQty = 0;
            this.totalRemainingQty = 0;
            this.hasMismatch = false;
        }
    }

    /**
     * Represents an individual node in the trace tree/timeline.
     */
    public class TraceNode {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String sObjectType { get; set; }
        @AuraEnabled public String nodeType { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String requestType { get; set; }
        @AuraEnabled public String supplyMethod { get; set; }
        @AuraEnabled public String itemName { get; set; }
        @AuraEnabled public String itemCode { get; set; }
        @AuraEnabled public Decimal requestedQty { get; set; }
        @AuraEnabled public Decimal reservedQty { get; set; }
        @AuraEnabled public Decimal reservedPlannedQty { get; set; }
        @AuraEnabled public Decimal transferPlannedQty { get; set; }
        @AuraEnabled public Decimal transferReceivedQty { get; set; }
        @AuraEnabled public Decimal procurementPlannedQty { get; set; }
        @AuraEnabled public Decimal procurementReceivedQty { get; set; }
        @AuraEnabled public Decimal receivedQty { get; set; }
        @AuraEnabled public Decimal remainingQty { get; set; }
        @AuraEnabled public String requestingAccount { get; set; }
        @AuraEnabled public String requestingAccountId { get; set; }
        @AuraEnabled public String supplyingAccount { get; set; }
        @AuraEnabled public String supplyingAccountId { get; set; }
        @AuraEnabled public String sourceLocation { get; set; }
        @AuraEnabled public String sourceLocationId { get; set; }
        @AuraEnabled public String targetLocation { get; set; }
        @AuraEnabled public String targetLocationId { get; set; }
        @AuraEnabled public String physicalMovement { get; set; }
        @AuraEnabled public String relationshipReason { get; set; }
        @AuraEnabled public Boolean isCurrentRecord { get; set; }
        @AuraEnabled public Boolean isRoot { get; set; }
        @AuraEnabled public List<TraceNode> children { get; set; }
        @AuraEnabled public Map<String, String> keyAttributes { get; set; }

        public TraceNode() {
            this.children = new List<TraceNode>();
            this.keyAttributes = new Map<String, String>();
            this.isCurrentRecord = false;
            this.isRoot = false;
            this.requestedQty = 0;
            this.reservedQty = 0;
            this.reservedPlannedQty = 0;
            this.transferPlannedQty = 0;
            this.transferReceivedQty = 0;
            this.procurementPlannedQty = 0;
            this.procurementReceivedQty = 0;
            this.receivedQty = 0;
            this.remainingQty = 0;
        }
    }

    /**
     * Quantity reconciliation item per allocation line.
     */
    public class ReconciliationItem {
        @AuraEnabled public String lineItemId { get; set; }
        @AuraEnabled public String lineItemName { get; set; }
        @AuraEnabled public String itemName { get; set; }
        @AuraEnabled public Decimal requiredQty { get; set; }
        @AuraEnabled public Decimal reservedQty { get; set; }
        @AuraEnabled public Decimal transferQty { get; set; }
        @AuraEnabled public Decimal procurementQty { get; set; }
        @AuraEnabled public Decimal allocatedTotal { get; set; }
        @AuraEnabled public Decimal receivedTotal { get; set; }
        @AuraEnabled public Decimal remainingQty { get; set; }
        @AuraEnabled public Boolean isBalanced { get; set; }
        @AuraEnabled public String statusMessage { get; set; }
    }

    /**
     * Main AuraEnabled entry point for tracing a record by ID.
     */
    @AuraEnabled(cacheable=true)
    public static TraceResult getTrace(Id recordId) {
        TraceResult result = new TraceResult();
        result.startingRecordId = String.valueOf(recordId);

        if (recordId == null) {
            result.success = false;
            result.errorMessage = 'Record ID cannot be null.';
            return result;
        }

        try {
            String sObjName = recordId.getSObjectType().getDescribe().getName();
            Set<Id> upstreamVisited = new Set<Id>{ recordId };

            // Step 1: Upstream Discovery - Find the topmost Root Record
            Id rootRecordId = resolveRootRecordId(recordId, sObjName, upstreamVisited);

            // Step 2: Downstream Traversal - Build full graph from Root
            buildTraceGraph(rootRecordId, recordId, result);

        } catch (Exception ex) {
            result.success = false;
            result.errorMessage = 'Error building fulfillment trace: ' + ex.getMessage();
            System.debug(LoggingLevel.ERROR, 'DMSFulfillmentTraceController error: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
        }

        return result;
    }

    /**
     * Search entry point for finding records by Name (e.g. 'SR-00001', 'OA-00001', 'OALI-00001').
     */
    @AuraEnabled(cacheable=true)
    public static TraceResult getTraceBySearch(String searchTerm) {
        TraceResult result = new TraceResult();
        if (String.isBlank(searchTerm)) {
            result.success = false;
            result.errorMessage = 'Please provide a search term (Record Name or ID).';
            return result;
        }

        String term = searchTerm.trim();
        Id targetId = null;

        // Check if user provided a 15/18 char Salesforce ID directly
        if ((term.length() == 15 || term.length() == 18) && Pattern.matches('^[a-zA-Z0-9]+$', term)) {
            try {
                targetId = (Id)term;
            } catch (Exception e) {
                targetId = null;
            }
        }

        if (targetId == null) {
            Set<String> searchTerms = new Set<String>{ term };
            String noSpace = term.replace(' ', '');
            searchTerms.add(noSpace);
            if (term.contains('-') && !term.contains(' - ')) {
                searchTerms.add(term.replace('-', ' - '));
            }
            if (term.contains(' - ')) {
                searchTerms.add(term.replace(' - ', '-'));
            }

            // Search Order_Allocation__c
            List<Order_Allocation__c> oas = [
                SELECT Id FROM Order_Allocation__c 
                WHERE Name IN :searchTerms 
                WITH USER_MODE 
                LIMIT 1
            ];
            if (!oas.isEmpty()) {
                targetId = oas[0].Id;
            }

            // Search Supply_Request__c
            if (targetId == null) {
                List<Supply_Request__c> srs = [
                    SELECT Id FROM Supply_Request__c 
                    WHERE Name IN :searchTerms 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!srs.isEmpty()) {
                    targetId = srs[0].Id;
                }
            }

            // Search Order_Allocation_Line_Item__c
            if (targetId == null) {
                List<Order_Allocation_Line_Item__c> oalis = [
                    SELECT Id FROM Order_Allocation_Line_Item__c 
                    WHERE Name IN :searchTerms 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!oalis.isEmpty()) {
                    targetId = oalis[0].Id;
                }
            }

            // Search Purchase_Order__c
            if (targetId == null) {
                List<Purchase_Order__c> pos = [
                    SELECT Id FROM Purchase_Order__c 
                    WHERE Name IN :searchTerms 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!pos.isEmpty()) {
                    targetId = pos[0].Id;
                }
            }

            // Search Purchase_Order_Line_Item__c
            if (targetId == null) {
                List<Purchase_Order_Line_Item__c> polis = [
                    SELECT Id FROM Purchase_Order_Line_Item__c 
                    WHERE Name IN :searchTerms 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!polis.isEmpty()) {
                    targetId = polis[0].Id;
                }
            }

            // Search Inventory_Transfer__c
            if (targetId == null) {
                List<Inventory_Transfer__c> its = [
                    SELECT Id FROM Inventory_Transfer__c 
                    WHERE Name IN :searchTerms 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!its.isEmpty()) {
                    targetId = its[0].Id;
                }
            }

            // Search Inventory_Reservation__c
            if (targetId == null) {
                List<Inventory_Reservation__c> irs = [
                    SELECT Id FROM Inventory_Reservation__c 
                    WHERE Name IN :searchTerms 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!irs.isEmpty()) {
                    targetId = irs[0].Id;
                }
            }

            // Fallback: LIKE query on OA, SR, PO
            if (targetId == null && noSpace.length() >= 3) {
                String likeTerm = '%' + noSpace + '%';
                List<Order_Allocation__c> oaLikes = [SELECT Id FROM Order_Allocation__c WHERE Name LIKE :likeTerm WITH USER_MODE LIMIT 1];
                if (!oaLikes.isEmpty()) {
                    targetId = oaLikes[0].Id;
                } else {
                    List<Supply_Request__c> srLikes = [SELECT Id FROM Supply_Request__c WHERE Name LIKE :likeTerm WITH USER_MODE LIMIT 1];
                    if (!srLikes.isEmpty()) {
                        targetId = srLikes[0].Id;
                    } else {
                        List<Purchase_Order__c> poLikes = [SELECT Id FROM Purchase_Order__c WHERE Name LIKE :likeTerm WITH USER_MODE LIMIT 1];
                        if (!poLikes.isEmpty()) {
                            targetId = poLikes[0].Id;
                        }
                    }
                }
            }
        }

        if (targetId == null) {
            result.success = false;
            result.errorMessage = 'No DMS record found matching: ' + term;
            return result;
        }

        return getTrace(targetId);
    }

    // =========================================================================
    // STEP 1: UPSTREAM RESOLUTION (FIND ROOT RECORD)
    // =========================================================================

    private static Id resolveRootRecordId(Id currentId, String sObjName, Set<Id> visited) {
        Id resolvedRootId = currentId;
        Integer hops = 0;

        while (hops < MAX_TRAVERSAL_DEPTH) {
            hops++;
            Id nextParentId = null;

            if (sObjName == 'Inventory_Reservation__c') {
                List<Inventory_Reservation__c> irs = [
                    SELECT Id, Order_Allocation_Line_Item__c 
                    FROM Inventory_Reservation__c 
                    WHERE Id = :resolvedRootId 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!irs.isEmpty() && irs[0].Order_Allocation_Line_Item__c != null) {
                    nextParentId = irs[0].Order_Allocation_Line_Item__c;
                    sObjName = 'Order_Allocation_Line_Item__c';
                }
            } else if (sObjName == 'Inventory_Transfer__c') {
                List<Inventory_Transfer__c> its = [
                    SELECT Id, Order_Allocation_Line_Item__c 
                    FROM Inventory_Transfer__c 
                    WHERE Id = :resolvedRootId 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!its.isEmpty() && its[0].Order_Allocation_Line_Item__c != null) {
                    nextParentId = its[0].Order_Allocation_Line_Item__c;
                    sObjName = 'Order_Allocation_Line_Item__c';
                }
            } else if (sObjName == 'Purchase_Order_Line_Item__c') {
                List<Purchase_Order_Line_Item__c> polis = [
                    SELECT Id, Sales_Allocation_Line_Item__c, Purchase_Order__c, Purchase_Order__r.Sales_Allocation__c 
                    FROM Purchase_Order_Line_Item__c 
                    WHERE Id = :resolvedRootId 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!polis.isEmpty()) {
                    if (polis[0].Sales_Allocation_Line_Item__c != null) {
                        nextParentId = polis[0].Sales_Allocation_Line_Item__c;
                        sObjName = 'Order_Allocation_Line_Item__c';
                    } else if (polis[0].Purchase_Order__r != null && polis[0].Purchase_Order__r.Sales_Allocation__c != null) {
                        nextParentId = polis[0].Purchase_Order__r.Sales_Allocation__c;
                        sObjName = 'Order_Allocation__c';
                    } else if (polis[0].Purchase_Order__c != null) {
                        nextParentId = polis[0].Purchase_Order__c;
                        sObjName = 'Purchase_Order__c';
                    }
                }
            } else if (sObjName == 'Purchase_Order__c') {
                List<Purchase_Order__c> pos = [
                    SELECT Id, Sales_Allocation__c 
                    FROM Purchase_Order__c 
                    WHERE Id = :resolvedRootId 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!pos.isEmpty() && pos[0].Sales_Allocation__c != null) {
                    nextParentId = pos[0].Sales_Allocation__c;
                    sObjName = 'Order_Allocation__c';
                }
            } else if (sObjName == 'Order_Allocation__c') {
                // If OA has an initiating SR on one of its OALIs, follow it upstream
                List<Order_Allocation_Line_Item__c> oalis = [
                    SELECT Id, Supply_Request__c, Source_SR_References__c 
                    FROM Order_Allocation_Line_Item__c 
                    WHERE Order_Allocation__c = :resolvedRootId 
                    WITH USER_MODE
                    LIMIT 20
                ];
                for (Order_Allocation_Line_Item__c oali : oalis) {
                    if (oali.Supply_Request__c != null) {
                        nextParentId = oali.Supply_Request__c;
                        sObjName = 'Supply_Request__c';
                        break;
                    } else if (String.isNotBlank(oali.Source_SR_References__c)) {
                        String refName = oali.Source_SR_References__c.trim();
                        List<Supply_Request__c> matchedSRs = [
                            SELECT Id FROM Supply_Request__c 
                            WHERE Name = :refName 
                            WITH USER_MODE 
                            LIMIT 1
                        ];
                        if (!matchedSRs.isEmpty()) {
                            nextParentId = matchedSRs[0].Id;
                            sObjName = 'Supply_Request__c';
                            break;
                        }
                    }
                }
            } else if (sObjName == 'Order_Allocation_Line_Item__c') {
                List<Order_Allocation_Line_Item__c> oalis = [
                    SELECT Id, Supply_Request__c, Source_SR_References__c, Order_Allocation__c 
                    FROM Order_Allocation_Line_Item__c 
                    WHERE Id = :resolvedRootId 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!oalis.isEmpty()) {
                    if (oalis[0].Supply_Request__c != null) {
                        nextParentId = oalis[0].Supply_Request__c;
                        sObjName = 'Supply_Request__c';
                    } else if (String.isNotBlank(oalis[0].Source_SR_References__c)) {
                        String refName = oalis[0].Source_SR_References__c.trim();
                        List<Supply_Request__c> matchedSRs = [
                            SELECT Id FROM Supply_Request__c 
                            WHERE Name = :refName 
                            WITH USER_MODE 
                            LIMIT 1
                        ];
                        if (!matchedSRs.isEmpty()) {
                            nextParentId = matchedSRs[0].Id;
                            sObjName = 'Supply_Request__c';
                        }
                    }
                }
            } else if (sObjName == 'Supply_Request__c') {
                List<Supply_Request__c> srs = [
                    SELECT Id, Supply_Request__c, Order_Allocation_Line_Item__c 
                    FROM Supply_Request__c 
                    WHERE Id = :resolvedRootId 
                    WITH USER_MODE 
                    LIMIT 1
                ];
                if (!srs.isEmpty()) {
                    if (srs[0].Supply_Request__c != null) {
                        nextParentId = srs[0].Supply_Request__c;
                        sObjName = 'Supply_Request__c';
                    } else if (srs[0].Order_Allocation_Line_Item__c != null) {
                        nextParentId = srs[0].Order_Allocation_Line_Item__c;
                        sObjName = 'Order_Allocation_Line_Item__c';
                    }
                }
            }

            if (nextParentId != null && !visited.contains(nextParentId)) {
                visited.add(nextParentId);
                resolvedRootId = nextParentId;
            } else {
                break;
            }
        }

        return resolvedRootId;
    }

    // =========================================================================
    // STEP 2: DOWNSTREAM MULTI-BRANCH TRAVERSAL
    // =========================================================================

    private static void buildTraceGraph(Id rootRecordId, Id currentRecordId, TraceResult result) {
        String rootSObjName = rootRecordId.getSObjectType().getDescribe().getName();
        Set<Id> visitedIds = new Set<Id>{ rootRecordId };

        TraceSummary summary = new TraceSummary();
        summary.rootRecordId = String.valueOf(rootRecordId);

        Set<Id> rootOaliIds = new Set<Id>();
        Supply_Request__c rootSR = null;
        Order_Allocation__c rootOA = null;
        List<Purchase_Order__c> directPOs = new List<Purchase_Order__c>();

        if (rootSObjName == 'Supply_Request__c') {
            rootSR = querySupplyRequestById(rootRecordId);
            summary.rootRecordName = rootSR.Name;
            summary.rootRecordType = 'Supply Request';
            summary.itemName = rootSR.Item__r != null ? rootSR.Item__r.Name : '';
            summary.itemCode = rootSR.Item__r != null ? rootSR.Item__r.Item_Code__c : '';
            summary.overallStatus = rootSR.Status__c;
            summary.totalRequiredQty = rootSR.Requested_Qty__c != null ? rootSR.Requested_Qty__c : 0;
            summary.totalReceivedQty = rootSR.Received_Qty__c != null ? rootSR.Received_Qty__c : 0;
            summary.totalRemainingQty = rootSR.Remaining_Quantity__c != null ? rootSR.Remaining_Quantity__c : 0;

            // Find immediate OALIs fulfilling this Root SR
            if (rootSR.Order_Allocation_Line_Item__c != null) {
                rootOaliIds.add(rootSR.Order_Allocation_Line_Item__c);
            }
            List<Order_Allocation_Line_Item__c> directOalis = [
                SELECT Id FROM Order_Allocation_Line_Item__c 
                WHERE Supply_Request__c = :rootRecordId 
                WITH USER_MODE
            ];
            for (Order_Allocation_Line_Item__c dOali : directOalis) {
                rootOaliIds.add(dOali.Id);
            }

            // Fallback: Check in memory for Source_SR_References__c / Source_SR_Allocation__c matching root SR name
            if (rootOaliIds.isEmpty() && String.isNotBlank(rootSR.Name)) {
                String cleanSrName = rootSR.Name.replace(' ', '').toUpperCase();
                String srIdStr = String.valueOf(rootSR.Id);
                List<Order_Allocation_Line_Item__c> candOalis;
                if (rootSR.Item__c != null) {
                    candOalis = [
                        SELECT Id, Source_SR_References__c, Source_SR_Allocation__c 
                        FROM Order_Allocation_Line_Item__c 
                        WHERE Item__c = :rootSR.Item__c 
                        WITH USER_MODE 
                        ORDER BY CreatedDate DESC 
                        LIMIT 100
                    ];
                } else {
                    candOalis = [
                        SELECT Id, Source_SR_References__c, Source_SR_Allocation__c 
                        FROM Order_Allocation_Line_Item__c 
                        WITH USER_MODE 
                        ORDER BY CreatedDate DESC 
                        LIMIT 100
                    ];
                }
                for (Order_Allocation_Line_Item__c candOali : candOalis) {
                    Boolean matches = false;
                    if (String.isNotBlank(candOali.Source_SR_References__c)) {
                        String cleanRef = candOali.Source_SR_References__c.replace(' ', '').toUpperCase();
                        if (cleanRef.contains(cleanSrName) || candOali.Source_SR_References__c.contains(srIdStr)) {
                            matches = true;
                        }
                    }
                    if (!matches && String.isNotBlank(candOali.Source_SR_Allocation__c)) {
                        String cleanAlloc = candOali.Source_SR_Allocation__c.replace(' ', '').toUpperCase();
                        if (cleanAlloc.contains(cleanSrName) || candOali.Source_SR_Allocation__c.contains(srIdStr)) {
                            matches = true;
                        }
                    }
                    if (matches) {
                        rootOaliIds.add(candOali.Id);
                    }
                }
            }
        } else if (rootSObjName == 'Order_Allocation__c') {
            rootOA = queryOrderAllocationById(rootRecordId);
            summary.rootRecordName = rootOA.Name;
            summary.rootRecordType = 'Order Allocation';
            summary.overallStatus = rootOA.Status__c;

            List<Order_Allocation_Line_Item__c> childOalis = [
                SELECT Id FROM Order_Allocation_Line_Item__c 
                WHERE Order_Allocation__c = :rootRecordId 
                WITH USER_MODE
            ];
            for (Order_Allocation_Line_Item__c cOali : childOalis) {
                rootOaliIds.add(cOali.Id);
            }

            // Also query Purchase Orders directly linked to this Order Allocation
            Set<Id> directPoIds = new Set<Id>();
            if (rootOA.Purchase_Order__c != null) {
                directPoIds.add(rootOA.Purchase_Order__c);
            }

            directPOs = [
                SELECT Id, Name, Status__c, PO_Date__c,
                       Supplying_Account__c, Supplying_Account__r.Name,
                       Requesting_Account__c, Requesting_Account__r.Name,
                       Source_Location__c, Source_Location__r.Name,
                       Target_Location__c, Target_Location__r.Name,
                       (SELECT Id, Name, Status__c, Ordered_Qty__c, Received_Qty__c, Previously_Received_Quantity__c, Remaining_Quantity__c,
                               Sales_Allocation_Line_Item__c,
                               Item__c, Item__r.Name, Item__r.Item_Code__c,
                               Purchase_Order__c, Purchase_Order__r.Name,
                               Purchase_Order__r.Supplying_Account__c, Purchase_Order__r.Supplying_Account__r.Name,
                               Purchase_Order__r.Requesting_Account__c, Purchase_Order__r.Requesting_Account__r.Name,
                               Purchase_Order__r.Source_Location__c, Purchase_Order__r.Source_Location__r.Name,
                               Purchase_Order__r.Target_Location__c, Purchase_Order__r.Target_Location__r.Name,
                               Purchase_Order__r.PO_Date__c, Purchase_Order__r.Status__c
                        FROM Purchase_Order_Line_Item__r)
                FROM Purchase_Order__c
                WHERE Sales_Allocation__c = :rootRecordId
                   OR Id IN :directPoIds
                WITH USER_MODE
            ];

            // If OA is linked to a Sale Order, query Order Items to populate required quantity & product
            if (rootOA.Sale_Order__c != null) {
                List<OrderItem> soItems = [
                    SELECT Id, Quantity, Product2.Name, Product2.ProductCode 
                    FROM OrderItem 
                    WHERE OrderId = :rootOA.Sale_Order__c 
                    WITH USER_MODE
                ];
                if (!soItems.isEmpty()) {
                    Decimal soQtySum = 0;
                    for (OrderItem oi : soItems) {
                        soQtySum += (oi.Quantity != null ? oi.Quantity : 0);
                        if (String.isBlank(summary.itemName) && oi.Product2 != null) {
                            summary.itemName = oi.Product2.Name;
                            summary.itemCode = oi.Product2.ProductCode;
                        }
                    }
                    summary.totalRequiredQty = soQtySum;
                }
            }
        } else if (rootSObjName == 'Order_Allocation_Line_Item__c') {
            rootOaliIds.add(rootRecordId);
        }

        // Initialize root node
        TraceNode rootNode = new TraceNode();
        rootNode.id = String.valueOf(rootRecordId);
        rootNode.sObjectType = rootSObjName;
        rootNode.isRoot = true;
        rootNode.isCurrentRecord = (rootRecordId == currentRecordId);

        if (rootSR != null) {
            populateSRNode(rootNode, rootSR, 'Root Supply Request', 'Starting point of fulfillment requirement');
        } else if (rootOA != null) {
            populateOANode(rootNode, rootOA, 'Root Order Allocation', 'Starting point of allocation planning');
        }

        result.rootNode = rootNode;
        result.allNodesMap.put(rootNode.id, rootNode);

        // Bulk Traverse all downstream branches from rootOaliIds
        if (!rootOaliIds.isEmpty()) {
            traverseDownstreamBranches(rootOaliIds, rootNode, currentRecordId, visitedIds, result, summary);
        }

        // Attach direct POs and POLIs (for Order Allocation root, or when OALIs do not cover direct PO lines)
        if (!directPOs.isEmpty()) {
            for (Purchase_Order__c po : directPOs) {
                visitedIds.add(po.Id);
                Boolean hasPolis = (po.Purchase_Order_Line_Item__r != null && !po.Purchase_Order_Line_Item__r.isEmpty());

                if (hasPolis) {
                    for (Purchase_Order_Line_Item__c poli : po.Purchase_Order_Line_Item__r) {
                        // Only attach if this POLI was not already visited via an OALI
                        if (!visitedIds.contains(poli.Id)) {
                            visitedIds.add(poli.Id);

                            TraceNode poliNode = new TraceNode();
                            poliNode.id = String.valueOf(poli.Id);
                            poliNode.sObjectType = 'Purchase_Order_Line_Item__c';
                            poliNode.isCurrentRecord = (poli.Id == currentRecordId);
                            populatePOLINode(poliNode, poli, 'Purchase Order Line', 'Direct PO procurement planned on ' + (rootOA != null ? rootOA.Name : 'Allocation'));
                            rootNode.children.add(poliNode);
                            result.allNodesMap.put(poliNode.id, poliNode);

                            Decimal pOrdered = poli.Ordered_Qty__c != null ? poli.Ordered_Qty__c : 0;
                            Decimal pRecv = (poli.Received_Qty__c != null ? poli.Received_Qty__c : (poli.Previously_Received_Quantity__c != null ? poli.Previously_Received_Quantity__c : 0));
                            Decimal pRem = poli.Remaining_Quantity__c != null ? poli.Remaining_Quantity__c : Math.max(0, pOrdered - pRecv);

                            summary.totalProcurementQty += pOrdered;
                            summary.totalReceivedQty += pRecv;

                            if (String.isBlank(summary.itemName) && poli.Item__r != null) {
                                summary.itemName = poli.Item__r.Name;
                                summary.itemCode = poli.Item__r.Item_Code__c;
                            }

                            // Generate reconciliation line item for this direct POLI
                            ReconciliationItem rItem = new ReconciliationItem();
                            rItem.lineItemId = poli.Id;
                            rItem.lineItemName = poli.Name + ' (' + po.Name + ')';
                            rItem.itemName = (poli.Item__r != null) ? poli.Item__r.Name : 'Item';
                            rItem.requiredQty = (summary.totalRequiredQty > 0 ? summary.totalRequiredQty : pOrdered);
                            rItem.procurementQty = pOrdered;
                            rItem.allocatedTotal = pOrdered;
                            rItem.receivedTotal = pRecv;
                            rItem.remainingQty = pRem;
                            rItem.isBalanced = true;
                            rItem.statusMessage = 'Direct PO Procurement (' + pOrdered + ' of ' + rItem.requiredQty + ')';
                            result.reconciliations.add(rItem);
                        }
                    }
                } else if (!visitedIds.contains(po.Id)) {
                    TraceNode poNode = new TraceNode();
                    poNode.id = String.valueOf(po.Id);
                    poNode.sObjectType = 'Purchase_Order__c';
                    poNode.nodeType = 'Purchase Order';
                    poNode.name = po.Name;
                    poNode.status = po.Status__c;
                    poNode.relationshipReason = 'Direct PO for ' + (rootOA != null ? rootOA.Name : 'Allocation');
                    poNode.supplyingAccount = (po.Supplying_Account__r != null) ? po.Supplying_Account__r.Name : '';
                    poNode.requestingAccount = (po.Requesting_Account__r != null) ? po.Requesting_Account__r.Name : '';
                    poNode.sourceLocation = (po.Source_Location__r != null) ? po.Source_Location__r.Name : '';
                    poNode.targetLocation = (po.Target_Location__r != null) ? po.Target_Location__r.Name : '';
                    poNode.physicalMovement = (String.isNotBlank(poNode.sourceLocation) ? poNode.sourceLocation : 'N/A') + ' ➔ ' + (String.isNotBlank(poNode.targetLocation) ? poNode.targetLocation : 'N/A');
                    poNode.keyAttributes.put('PO Date', po.PO_Date__c != null ? String.valueOf(po.PO_Date__c) : 'N/A');
                    poNode.keyAttributes.put('PO Status', po.Status__c != null ? po.Status__c : 'Draft');
                    rootNode.children.add(poNode);
                    result.allNodesMap.put(poNode.id, poNode);
                }
            }
        }

        // If root is OA and required qty was not derived from OALIs or Sale Order, default to procurement qty
        if (rootOA != null && summary.totalRequiredQty == 0 && summary.totalProcurementQty > 0) {
            summary.totalRequiredQty = summary.totalProcurementQty;
        }

        // Finalize Summary Status & Reconciliation
        summary.hasMismatch = false;
        for (ReconciliationItem rItem : result.reconciliations) {
            if (!rItem.isBalanced) {
                summary.hasMismatch = true;
                summary.mismatchMessage = 'Quantity mismatch detected on ' + rItem.lineItemName + ': ' + rItem.statusMessage;
                break;
            }
        }
        if (!summary.hasMismatch && summary.totalRequiredQty > 0) {
            summary.totalRemainingQty = Math.max(0, summary.totalRequiredQty - summary.totalReceivedQty);
        }

        result.summary = summary;
    }

    /**
     * Traverses downstream fulfillment records in governed stages.
     */
    private static void traverseDownstreamBranches(
        Set<Id> oaliIdsToProcess,
        TraceNode parentNode,
        Id currentRecordId,
        Set<Id> visitedIds,
        TraceResult result,
        TraceSummary summary
    ) {
        Set<Id> currentOaliIds = new Set<Id>(oaliIdsToProcess);
        Integer depth = 0;

        while (!currentOaliIds.isEmpty() && depth < MAX_TRAVERSAL_DEPTH) {
            depth++;

            // 1. Bulk Query OALIs with item and parent OA details
            List<Order_Allocation_Line_Item__c> oaliRecords = [
                SELECT Id, Name, Status__c, Ordered_Qty__c,
                       Reserved_Qty_Planned__c, Reserved_Quantity__c,
                       Transfer_Qty_Planned__c, Transfer_Qty_Received__c,
                       Procurement_Qty_Planned__c, Procurement_Qty_Received__c,
                       Remaining_Qty__c, Secured_Qty__c,
                       Supply_Request__c, Supply_Request__r.Name,
                       Purchase_Order_Line_Item__c, Purchase_Order_Line_Item__r.Name,
                       Source_SR_References__c, Source_SR_Allocation__c,
                       Item__c, Item__r.Name, Item__r.Item_Code__c,
                       Order_Allocation__c, Order_Allocation__r.Name,
                       Order_Allocation__r.Supplying_Account__c, Order_Allocation__r.Supplying_Account__r.Name,
                       Order_Allocation__r.Requesting_Account__c, Order_Allocation__r.Requesting_Account__r.Name,
                       Order_Allocation__r.Source_Location__c, Order_Allocation__r.Source_Location__r.Name,
                       Order_Allocation__r.Target_Location__c, Order_Allocation__r.Target_Location__r.Name
                FROM Order_Allocation_Line_Item__c
                WHERE Id IN :currentOaliIds
                WITH USER_MODE
            ];

            // 2. Bulk Query Child SRs (Procurement SRs and Transfer SRs)
            List<Supply_Request__c> childSRs = [
                SELECT Id, Name, Status__c, Request_Type__c, Supply_Method__c, Type__c,
                       Requested_Qty__c, Received_Qty__c, Remaining_Quantity__c, Required_Date__c,
                       Item__c, Item__r.Name, Item__r.Item_Code__c,
                       Requesting_Account__c, Requesting_Account__r.Name,
                       Supplying_Account__c, Supplying_Account__r.Name,
                       Reference_Account__c, Reference_Account__r.Name,
                       Source_Location__c, Source_Location__r.Name,
                       Target_Location__c, Target_Location__r.Name,
                       Order_Allocation_Line_Item__c, Supply_Request__c
                FROM Supply_Request__c
                WHERE Order_Allocation_Line_Item__c IN :currentOaliIds
                WITH USER_MODE
            ];

            // 3. Bulk Query Child Purchase Order Line Items
            List<Purchase_Order_Line_Item__c> childPOLIs = [
                SELECT Id, Name, Status__c, Ordered_Qty__c, Received_Qty__c, Previously_Received_Quantity__c, Remaining_Quantity__c,
                       Sales_Allocation_Line_Item__c,
                       Item__c, Item__r.Name, Item__r.Item_Code__c,
                       Purchase_Order__c, Purchase_Order__r.Name,
                       Purchase_Order__r.Supplying_Account__c, Purchase_Order__r.Supplying_Account__r.Name,
                       Purchase_Order__r.Requesting_Account__c, Purchase_Order__r.Requesting_Account__r.Name,
                       Purchase_Order__r.Source_Location__c, Purchase_Order__r.Source_Location__r.Name,
                       Purchase_Order__r.Target_Location__c, Purchase_Order__r.Target_Location__r.Name,
                       Purchase_Order__r.PO_Date__c, Purchase_Order__r.Status__c
                FROM Purchase_Order_Line_Item__c
                WHERE Sales_Allocation_Line_Item__c IN :currentOaliIds
                WITH USER_MODE
            ];

            // 4. Bulk Query Child Inventory Transfers
            List<Inventory_Transfer__c> childTransfers = [
                SELECT Id, Name, Status__c, Request_Type__c, Supply_Method__c,
                       Transfer_Qty__c, In_Transit_Qty__c, Received_Qty__c,
                       Requested_Date__c, Shipped_Date__c, Received_Date__c,
                       Order_Allocation_Line_Item__c,
                       Item__c, Item__r.Name, Item__r.Item_Code__c,
                       From_Account__c, From_Account__r.Name,
                       To_Account__c, To_Account__r.Name,
                       Source_Inventory_Location__c, Source_Inventory_Location__r.Name,
                       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name
                FROM Inventory_Transfer__c
                WHERE Order_Allocation_Line_Item__c IN :currentOaliIds
                WITH USER_MODE
            ];

            // 5. Bulk Query Child Inventory Reservations
            List<Inventory_Reservation__c> childReservations = [
                SELECT Id, Name, Status__c, Requested_Qty__c, Reserved_Qty__c, Reservation_Date__c, Expiry_Date__c,
                       Order_Allocation_Line_Item__c,
                       Item__c, Item__r.Name, Item__r.Item_Code__c,
                       Supplying_Account__c, Supplying_Account__r.Name,
                       Requesting_Account__c, Requesting_Account__r.Name,
                       Inventory_Location__c, Inventory_Location__r.Name
                FROM Inventory_Reservation__c
                WHERE Order_Allocation_Line_Item__c IN :currentOaliIds
                WITH USER_MODE
            ];

            // Map children by parent OALI ID
            Map<Id, List<Supply_Request__c>> srsByOali = new Map<Id, List<Supply_Request__c>>();
            Map<Id, List<Purchase_Order_Line_Item__c>> polisByOali = new Map<Id, List<Purchase_Order_Line_Item__c>>();
            Map<Id, List<Inventory_Transfer__c>> transfersByOali = new Map<Id, List<Inventory_Transfer__c>>();
            Map<Id, List<Inventory_Reservation__c>> reservationsByOali = new Map<Id, List<Inventory_Reservation__c>>();

            for (Supply_Request__c sr : childSRs) {
                if (!srsByOali.containsKey(sr.Order_Allocation_Line_Item__c)) {
                    srsByOali.put(sr.Order_Allocation_Line_Item__c, new List<Supply_Request__c>());
                }
                srsByOali.get(sr.Order_Allocation_Line_Item__c).add(sr);
            }
            for (Purchase_Order_Line_Item__c poli : childPOLIs) {
                if (!polisByOali.containsKey(poli.Sales_Allocation_Line_Item__c)) {
                    polisByOali.put(poli.Sales_Allocation_Line_Item__c, new List<Purchase_Order_Line_Item__c>());
                }
                polisByOali.get(poli.Sales_Allocation_Line_Item__c).add(poli);
            }
            for (Inventory_Transfer__c it : childTransfers) {
                if (!transfersByOali.containsKey(it.Order_Allocation_Line_Item__c)) {
                    transfersByOali.put(it.Order_Allocation_Line_Item__c, new List<Inventory_Transfer__c>());
                }
                transfersByOali.get(it.Order_Allocation_Line_Item__c).add(it);
            }
            for (Inventory_Reservation__c ir : childReservations) {
                if (!reservationsByOali.containsKey(ir.Order_Allocation_Line_Item__c)) {
                    reservationsByOali.put(ir.Order_Allocation_Line_Item__c, new List<Inventory_Reservation__c>());
                }
                reservationsByOali.get(ir.Order_Allocation_Line_Item__c).add(ir);
            }

            Set<Id> nextChildSRIds = new Set<Id>();
            Map<Id, TraceNode> oaliNodeMap = new Map<Id, TraceNode>();

            for (Order_Allocation_Line_Item__c oali : oaliRecords) {
                visitedIds.add(oali.Id);

                TraceNode oaliNode = new TraceNode();
                oaliNode.id = String.valueOf(oali.Id);
                oaliNode.sObjectType = 'Order_Allocation_Line_Item__c';
                oaliNode.isCurrentRecord = (oali.Id == currentRecordId);
                populateOALINode(oaliNode, oali, 'Order Allocation Line', 'Line item requirement on ' + (oali.Order_Allocation__r != null ? oali.Order_Allocation__r.Name : 'Allocation'));

                result.allNodesMap.put(oaliNode.id, oaliNode);
                oaliNodeMap.put(oali.Id, oaliNode);

                // Add to parent node
                parentNode.children.add(oaliNode);

                // Track reconciliation metrics
                ReconciliationItem rItem = buildReconciliation(oali);
                result.reconciliations.add(rItem);

                // Accumulate summary totals from root level OALIs
                if (depth == 1) {
                    summary.totalReservedQty += (oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : (oali.Reserved_Qty_Planned__c != null ? oali.Reserved_Qty_Planned__c : 0));
                    summary.totalTransferQty += (oali.Transfer_Qty_Planned__c != null ? oali.Transfer_Qty_Planned__c : 0);
                    summary.totalProcurementQty += (oali.Procurement_Qty_Planned__c != null ? oali.Procurement_Qty_Planned__c : 0);
                    if (summary.rootRecordType != 'Supply Request') {
                        summary.totalRequiredQty += (oali.Ordered_Qty__c != null ? oali.Ordered_Qty__c : 0);
                        summary.totalReceivedQty += ((oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : 0) +
                                                    (oali.Transfer_Qty_Received__c != null ? oali.Transfer_Qty_Received__c : 0) +
                                                    (oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0));
                        summary.totalRemainingQty += (oali.Remaining_Qty__c != null ? oali.Remaining_Qty__c : 0);
                    }
                }

                // Attach Reservations (Reserved Branch)
                if (reservationsByOali.containsKey(oali.Id)) {
                    for (Inventory_Reservation__c ir : reservationsByOali.get(oali.Id)) {
                        visitedIds.add(ir.Id);
                        TraceNode resNode = new TraceNode();
                        resNode.id = String.valueOf(ir.Id);
                        resNode.sObjectType = 'Inventory_Reservation__c';
                        resNode.isCurrentRecord = (ir.Id == currentRecordId);
                        populateReservationNode(resNode, ir, 'Inventory Reservation', 'Stock reserved at local location for ' + oali.Name);
                        oaliNode.children.add(resNode);
                        result.allNodesMap.put(resNode.id, resNode);
                    }
                }

                // Attach Child Supply Requests (Procurement SR / Transfer SR)
                if (srsByOali.containsKey(oali.Id)) {
                    for (Supply_Request__c cSr : srsByOali.get(oali.Id)) {
                        visitedIds.add(cSr.Id);
                        nextChildSRIds.add(cSr.Id);

                        TraceNode srNode = new TraceNode();
                        srNode.id = String.valueOf(cSr.Id);
                        srNode.sObjectType = 'Supply_Request__c';
                        srNode.isCurrentRecord = (cSr.Id == currentRecordId);
                        String branchRole = ('Transfer SR'.equalsIgnoreCase(cSr.Request_Type__c)) ? 'Transfer Supply Request' : 'Procurement Supply Request';
                        populateSRNode(srNode, cSr, branchRole, 'Child demand created from ' + oali.Name + ' via ' + cSr.Request_Type__c);
                        oaliNode.children.add(srNode);
                        result.allNodesMap.put(srNode.id, srNode);
                    }
                }

                // Attach Purchase Order Line Items
                if (polisByOali.containsKey(oali.Id)) {
                    for (Purchase_Order_Line_Item__c poli : polisByOali.get(oali.Id)) {
                        visitedIds.add(poli.Id);
                        TraceNode poliNode = new TraceNode();
                        poliNode.id = String.valueOf(poli.Id);
                        poliNode.sObjectType = 'Purchase_Order_Line_Item__c';
                        poliNode.isCurrentRecord = (poli.Id == currentRecordId);
                        populatePOLINode(poliNode, poli, 'Purchase Order Line', 'PO procurement created for ' + oali.Name);
                        oaliNode.children.add(poliNode);
                        result.allNodesMap.put(poliNode.id, poliNode);
                    }
                }

                // Attach Inventory Transfers
                if (transfersByOali.containsKey(oali.Id)) {
                    for (Inventory_Transfer__c it : transfersByOali.get(oali.Id)) {
                        visitedIds.add(it.Id);
                        TraceNode itNode = new TraceNode();
                        itNode.id = String.valueOf(it.Id);
                        itNode.sObjectType = 'Inventory_Transfer__c';
                        itNode.isCurrentRecord = (it.Id == currentRecordId);
                        populateTransferNode(itNode, it, 'Inventory Transfer', 'Physical inventory movement for ' + oali.Name);
                        oaliNode.children.add(itNode);
                        result.allNodesMap.put(itNode.id, itNode);
                    }
                }
            }

            // 6. Check if child SRs have downstream OALIs (next level down)
            currentOaliIds.clear();
            if (!nextChildSRIds.isEmpty()) {
                List<Order_Allocation_Line_Item__c> nextLevelOalis = [
                    SELECT Id FROM Order_Allocation_Line_Item__c 
                    WHERE Supply_Request__c IN :nextChildSRIds 
                      AND Id NOT IN :visitedIds
                    WITH USER_MODE
                ];
                for (Order_Allocation_Line_Item__c nOali : nextLevelOalis) {
                    currentOaliIds.add(nOali.Id);
                }
            }
        }
    }

    // =========================================================================
    // NODE POPULATION HELPERS
    // =========================================================================

    private static void populateSRNode(TraceNode node, Supply_Request__c sr, String nodeType, String reason) {
        node.name = sr.Name;
        node.nodeType = nodeType;
        node.status = sr.Status__c;
        node.requestType = sr.Request_Type__c;
        node.supplyMethod = sr.Supply_Method__c;
        node.itemName = (sr.Item__r != null) ? sr.Item__r.Name : '';
        node.itemCode = (sr.Item__r != null) ? sr.Item__r.Item_Code__c : '';
        node.requestedQty = sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0;
        node.receivedQty = sr.Received_Qty__c != null ? sr.Received_Qty__c : 0;
        node.remainingQty = sr.Remaining_Quantity__c != null ? sr.Remaining_Quantity__c : 0;
        node.requestingAccount = (sr.Requesting_Account__r != null) ? sr.Requesting_Account__r.Name : '';
        node.requestingAccountId = sr.Requesting_Account__c;
        node.supplyingAccount = (sr.Supplying_Account__r != null) ? sr.Supplying_Account__r.Name : '';
        node.supplyingAccountId = sr.Supplying_Account__c;
        node.sourceLocation = (sr.Source_Location__r != null) ? sr.Source_Location__r.Name : '';
        node.sourceLocationId = sr.Source_Location__c;
        node.targetLocation = (sr.Target_Location__r != null) ? sr.Target_Location__r.Name : '';
        node.targetLocationId = sr.Target_Location__c;
        node.relationshipReason = reason;

        if (String.isNotBlank(node.sourceLocation) || String.isNotBlank(node.targetLocation)) {
            node.physicalMovement = (String.isNotBlank(node.sourceLocation) ? node.sourceLocation : 'N/A') +
                                    ' ➔ ' +
                                    (String.isNotBlank(node.targetLocation) ? node.targetLocation : 'N/A');
        }

        node.keyAttributes.put('Request Type', String.isNotBlank(sr.Request_Type__c) ? sr.Request_Type__c : 'Standard');
        node.keyAttributes.put('Supply Method', String.isNotBlank(sr.Supply_Method__c) ? sr.Supply_Method__c : 'N/A');
        node.keyAttributes.put('Required Date', sr.Required_Date__c != null ? String.valueOf(sr.Required_Date__c) : 'N/A');
    }

    private static void populateOANode(TraceNode node, Order_Allocation__c oa, String nodeType, String reason) {
        node.name = oa.Name;
        node.nodeType = nodeType;
        node.status = oa.Status__c;
        node.requestType = oa.Type__c;
        node.requestingAccount = (oa.Requesting_Account__r != null) ? oa.Requesting_Account__r.Name : (oa.Customer__r != null ? oa.Customer__r.Name : (String.isNotBlank(oa.Customer_Name__c) ? oa.Customer_Name__c : ''));
        node.requestingAccountId = oa.Requesting_Account__c != null ? oa.Requesting_Account__c : oa.Customer__c;
        node.supplyingAccount = (oa.Supplying_Account__r != null) ? oa.Supplying_Account__r.Name : '';
        node.supplyingAccountId = oa.Supplying_Account__c;
        node.sourceLocation = (oa.Source_Location__r != null) ? oa.Source_Location__r.Name : '';
        node.sourceLocationId = oa.Source_Location__c;
        node.targetLocation = (oa.Target_Location__r != null) ? oa.Target_Location__r.Name : '';
        node.targetLocationId = oa.Target_Location__c;
        node.relationshipReason = reason;

        if (String.isNotBlank(node.sourceLocation) || String.isNotBlank(node.targetLocation)) {
            node.physicalMovement = (String.isNotBlank(node.sourceLocation) ? node.sourceLocation : 'N/A') +
                                    ' ➔ ' +
                                    (String.isNotBlank(node.targetLocation) ? node.targetLocation : 'N/A');
        }

        node.keyAttributes.put('Allocation Status', oa.Status__c != null ? oa.Status__c : 'Draft');
        node.keyAttributes.put('Type', oa.Type__c != null ? oa.Type__c : 'Standard');
        node.keyAttributes.put('Order Allocation Date', oa.Order_Allocation_Date__c != null ? String.valueOf(oa.Order_Allocation_Date__c) : 'N/A');
        if (String.isNotBlank(oa.Sale_Order_Reference__c)) {
            node.keyAttributes.put('Sale Order Ref', oa.Sale_Order_Reference__c);
        }
        if (String.isNotBlank(oa.Customer_Name__c)) {
            node.keyAttributes.put('Customer Name', oa.Customer_Name__c);
        }
    }

    private static void populateOALINode(TraceNode node, Order_Allocation_Line_Item__c oali, String nodeType, String reason) {
        node.name = oali.Name;
        node.nodeType = nodeType;
        node.status = oali.Status__c;
        node.itemName = (oali.Item__r != null) ? oali.Item__r.Name : '';
        node.itemCode = (oali.Item__r != null) ? oali.Item__r.Item_Code__c : '';
        node.requestedQty = oali.Ordered_Qty__c != null ? oali.Ordered_Qty__c : 0;
        node.reservedQty = oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : 0;
        node.reservedPlannedQty = oali.Reserved_Qty_Planned__c != null ? oali.Reserved_Qty_Planned__c : 0;
        node.transferPlannedQty = oali.Transfer_Qty_Planned__c != null ? oali.Transfer_Qty_Planned__c : 0;
        node.transferReceivedQty = oali.Transfer_Qty_Received__c != null ? oali.Transfer_Qty_Received__c : 0;
        node.procurementPlannedQty = oali.Procurement_Qty_Planned__c != null ? oali.Procurement_Qty_Planned__c : 0;
        node.procurementReceivedQty = oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0;
        node.remainingQty = oali.Remaining_Qty__c != null ? oali.Remaining_Qty__c : 0;

        Decimal totalReceived = node.reservedQty + node.transferReceivedQty + node.procurementReceivedQty;
        node.receivedQty = totalReceived;

        if (oali.Order_Allocation__r != null) {
            node.requestingAccount = (oali.Order_Allocation__r.Requesting_Account__r != null) ? oali.Order_Allocation__r.Requesting_Account__r.Name : '';
            node.requestingAccountId = oali.Order_Allocation__r.Requesting_Account__c;
            node.supplyingAccount = (oali.Order_Allocation__r.Supplying_Account__r != null) ? oali.Order_Allocation__r.Supplying_Account__r.Name : '';
            node.supplyingAccountId = oali.Order_Allocation__r.Supplying_Account__c;
            node.sourceLocation = (oali.Order_Allocation__r.Source_Location__r != null) ? oali.Order_Allocation__r.Source_Location__r.Name : '';
            node.sourceLocationId = oali.Order_Allocation__r.Source_Location__c;
            node.targetLocation = (oali.Order_Allocation__r.Target_Location__r != null) ? oali.Order_Allocation__r.Target_Location__r.Name : '';
            node.targetLocationId = oali.Order_Allocation__r.Target_Location__c;

            if (String.isNotBlank(node.sourceLocation) || String.isNotBlank(node.targetLocation)) {
                node.physicalMovement = (String.isNotBlank(node.sourceLocation) ? node.sourceLocation : 'N/A') +
                                        ' ➔ ' +
                                        (String.isNotBlank(node.targetLocation) ? node.targetLocation : 'N/A');
            }
        }

        node.relationshipReason = reason;
        node.keyAttributes.put('Parent Allocation', oali.Order_Allocation__r != null ? oali.Order_Allocation__r.Name : 'N/A');
        node.keyAttributes.put('Initiating SR', oali.Supply_Request__r != null ? oali.Supply_Request__r.Name : (String.isNotBlank(oali.Source_SR_References__c) ? oali.Source_SR_References__c : 'Direct'));
        node.keyAttributes.put('Planned Breakdown', 'Res: ' + node.reservedPlannedQty + ' | Trans: ' + node.transferPlannedQty + ' | Proc: ' + node.procurementPlannedQty);
        node.keyAttributes.put('Received Breakdown', 'Res: ' + node.reservedQty + ' | Trans: ' + node.transferReceivedQty + ' | Proc: ' + node.procurementReceivedQty);
    }

    private static void populatePOLINode(TraceNode node, Purchase_Order_Line_Item__c poli, String nodeType, String reason) {
        node.name = poli.Name;
        node.nodeType = nodeType;
        node.status = poli.Status__c;
        node.itemName = (poli.Item__r != null) ? poli.Item__r.Name : '';
        node.itemCode = (poli.Item__r != null) ? poli.Item__r.Item_Code__c : '';
        node.requestedQty = poli.Ordered_Qty__c != null ? poli.Ordered_Qty__c : 0;
        node.receivedQty = poli.Received_Qty__c != null ? poli.Received_Qty__c : (poli.Previously_Received_Quantity__c != null ? poli.Previously_Received_Quantity__c : 0);
        node.remainingQty = poli.Remaining_Quantity__c != null ? poli.Remaining_Quantity__c : 0;

        if (poli.Purchase_Order__r != null) {
            node.supplyingAccount = (poli.Purchase_Order__r.Supplying_Account__r != null) ? poli.Purchase_Order__r.Supplying_Account__r.Name : '';
            node.supplyingAccountId = poli.Purchase_Order__r.Supplying_Account__c;
            node.requestingAccount = (poli.Purchase_Order__r.Requesting_Account__r != null) ? poli.Purchase_Order__r.Requesting_Account__r.Name : '';
            node.requestingAccountId = poli.Purchase_Order__r.Requesting_Account__c;
            node.sourceLocation = (poli.Purchase_Order__r.Source_Location__r != null) ? poli.Purchase_Order__r.Source_Location__r.Name : '';
            node.sourceLocationId = poli.Purchase_Order__r.Source_Location__c;
            node.targetLocation = (poli.Purchase_Order__r.Target_Location__r != null) ? poli.Purchase_Order__r.Target_Location__r.Name : '';
            node.targetLocationId = poli.Purchase_Order__r.Target_Location__c;

            if (String.isNotBlank(node.sourceLocation) || String.isNotBlank(node.targetLocation)) {
                node.physicalMovement = (String.isNotBlank(node.sourceLocation) ? node.sourceLocation : 'N/A') +
                                        ' ➔ ' +
                                        (String.isNotBlank(node.targetLocation) ? node.targetLocation : 'N/A');
            }
        }

        node.relationshipReason = reason;
        node.keyAttributes.put('Purchase Order', poli.Purchase_Order__r != null ? poli.Purchase_Order__r.Name : 'N/A');
        node.keyAttributes.put('PO Status', poli.Purchase_Order__r != null ? poli.Purchase_Order__r.Status__c : 'N/A');
        node.keyAttributes.put('PO Date', poli.Purchase_Order__r != null && poli.Purchase_Order__r.PO_Date__c != null ? String.valueOf(poli.Purchase_Order__r.PO_Date__c) : 'N/A');
    }

    private static void populateTransferNode(TraceNode node, Inventory_Transfer__c it, String nodeType, String reason) {
        node.name = it.Name;
        node.nodeType = nodeType;
        node.status = it.Status__c;
        node.requestType = it.Request_Type__c;
        node.supplyMethod = it.Supply_Method__c;
        node.itemName = (it.Item__r != null) ? it.Item__r.Name : '';
        node.itemCode = (it.Item__r != null) ? it.Item__r.Item_Code__c : '';
        node.requestedQty = it.Transfer_Qty__c != null ? it.Transfer_Qty__c : 0;
        node.receivedQty = it.Received_Qty__c != null ? it.Received_Qty__c : 0;
        node.remainingQty = Math.max(0, node.requestedQty - node.receivedQty);

        node.supplyingAccount = (it.From_Account__r != null) ? it.From_Account__r.Name : '';
        node.supplyingAccountId = it.From_Account__c;
        node.requestingAccount = (it.To_Account__r != null) ? it.To_Account__r.Name : '';
        node.requestingAccountId = it.To_Account__c;

        // Actual Physical Movement between warehouse locations
        node.sourceLocation = (it.Source_Inventory_Location__r != null) ? it.Source_Inventory_Location__r.Name : '';
        node.sourceLocationId = it.Source_Inventory_Location__c;
        node.targetLocation = (it.Destination_Inventory_Location__r != null) ? it.Destination_Inventory_Location__r.Name : '';
        node.targetLocationId = it.Destination_Inventory_Location__c;

        node.physicalMovement = (String.isNotBlank(node.sourceLocation) ? node.sourceLocation : 'Source Loc') +
                                ' ➔ ' +
                                (String.isNotBlank(node.targetLocation) ? node.targetLocation : 'Dest Loc');

        node.relationshipReason = reason;
        node.keyAttributes.put('In-Transit Qty', String.valueOf(it.In_Transit_Qty__c != null ? it.In_Transit_Qty__c : 0));
        node.keyAttributes.put('Shipped Date', it.Shipped_Date__c != null ? String.valueOf(it.Shipped_Date__c) : 'Not Shipped');
        node.keyAttributes.put('Received Date', it.Received_Date__c != null ? String.valueOf(it.Received_Date__c) : 'Pending');
    }

    private static void populateReservationNode(TraceNode node, Inventory_Reservation__c ir, String nodeType, String reason) {
        node.name = ir.Name;
        node.nodeType = nodeType;
        node.status = ir.Status__c;
        node.itemName = (ir.Item__r != null) ? ir.Item__r.Name : '';
        node.itemCode = (ir.Item__r != null) ? ir.Item__r.Item_Code__c : '';
        node.requestedQty = ir.Requested_Qty__c != null ? ir.Requested_Qty__c : 0;
        node.reservedQty = ir.Reserved_Qty__c != null ? ir.Reserved_Qty__c : 0;
        node.receivedQty = node.reservedQty;
        node.remainingQty = Math.max(0, node.requestedQty - node.reservedQty);

        node.supplyingAccount = (ir.Supplying_Account__r != null) ? ir.Supplying_Account__r.Name : '';
        node.supplyingAccountId = ir.Supplying_Account__c;
        node.requestingAccount = (ir.Requesting_Account__r != null) ? ir.Requesting_Account__r.Name : '';
        node.requestingAccountId = ir.Requesting_Account__c;
        node.sourceLocation = (ir.Inventory_Location__r != null) ? ir.Inventory_Location__r.Name : '';
        node.sourceLocationId = ir.Inventory_Location__c;
        node.targetLocation = node.sourceLocation;
        node.physicalMovement = node.sourceLocation + ' (Held in Local Stock)';

        node.relationshipReason = reason;
        node.keyAttributes.put('Reserved Quantity', String.valueOf(node.reservedQty));
        node.keyAttributes.put('Reservation Date', ir.Reservation_Date__c != null ? String.valueOf(ir.Reservation_Date__c) : 'N/A');
    }

    // =========================================================================
    // QUANTITY RECONCILIATION LOGIC
    // =========================================================================

    private static ReconciliationItem buildReconciliation(Order_Allocation_Line_Item__c oali) {
        ReconciliationItem item = new ReconciliationItem();
        item.lineItemId = String.valueOf(oali.Id);
        item.lineItemName = oali.Name;
        item.itemName = (oali.Item__r != null) ? oali.Item__r.Name : 'Item';
        item.requiredQty = oali.Ordered_Qty__c != null ? oali.Ordered_Qty__c : 0;
        item.reservedQty = oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : (oali.Reserved_Qty_Planned__c != null ? oali.Reserved_Qty_Planned__c : 0);
        item.transferQty = oali.Transfer_Qty_Planned__c != null ? oali.Transfer_Qty_Planned__c : 0;
        item.procurementQty = oali.Procurement_Qty_Planned__c != null ? oali.Procurement_Qty_Planned__c : 0;

        item.allocatedTotal = item.reservedQty + item.transferQty + item.procurementQty;
        item.receivedTotal = (oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : 0) +
                             (oali.Transfer_Qty_Received__c != null ? oali.Transfer_Qty_Received__c : 0) +
                             (oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0);
        item.remainingQty = oali.Remaining_Qty__c != null ? oali.Remaining_Qty__c : Math.max(0, item.requiredQty - item.receivedTotal);

        if (item.allocatedTotal > item.requiredQty) {
            item.isBalanced = false;
            item.statusMessage = 'Allocated channels (' + item.allocatedTotal + ') exceed Required (' + item.requiredQty + ')';
        } else if (item.allocatedTotal < item.requiredQty) {
            item.isBalanced = true; // Partially planned requirement is normal in progress
            item.statusMessage = 'Partially planned (' + item.allocatedTotal + ' of ' + item.requiredQty + ' planned)';
        } else {
            item.isBalanced = true;
            item.statusMessage = 'Fully allocated (' + item.allocatedTotal + ' of ' + item.requiredQty + ')';
        }

        return item;
    }

    // =========================================================================
    // QUERY HELPERS
    // =========================================================================

    private static Supply_Request__c querySupplyRequestById(Id srId) {
        return [
            SELECT Id, Name, Status__c, Request_Type__c, Supply_Method__c, Type__c,
                   Requested_Qty__c, Received_Qty__c, Remaining_Quantity__c, Required_Date__c,
                   Item__c, Item__r.Name, Item__r.Item_Code__c,
                   Requesting_Account__c, Requesting_Account__r.Name,
                   Supplying_Account__c, Supplying_Account__r.Name,
                   Reference_Account__c, Reference_Account__r.Name,
                   Source_Location__c, Source_Location__r.Name,
                   Target_Location__c, Target_Location__r.Name,
                   Order_Allocation_Line_Item__c, Supply_Request__c
            FROM Supply_Request__c
            WHERE Id = :srId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static Order_Allocation__c queryOrderAllocationById(Id oaId) {
        return [
            SELECT Id, Name, Status__c, Type__c, Order_Allocation_Date__c, Shipped_Date__c,
                   Supplying_Account__c, Supplying_Account__r.Name,
                   Requesting_Account__c, Requesting_Account__r.Name,
                   Customer__c, Customer__r.Name, Customer_Name__c,
                   Source_Location__c, Source_Location__r.Name,
                   Target_Location__c, Target_Location__r.Name,
                   Purchase_Order__c,
                   Sale_Order__c, Sale_Order_Reference__c
            FROM Order_Allocation__c
            WHERE Id = :oaId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}