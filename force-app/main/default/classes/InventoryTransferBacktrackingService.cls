/**
 * @description Centralized, bulkified backtracking service for Inventory Transfer acceptance.
 *              Executes a controlled, OALI-first graph traversal with deterministic decision-making:
 *              - Exact Subtype Matching: compares Current SR Subtype vs Source Referenced Subtype.
 *              - OALI-First Evaluation: validates Source OALI eligibility BEFORE updating Source SR.
 *              - Multi-Tier Exhaustive Pre-loading: iteratively discovers and preloads all ancestor SRs, OALIs, POs, and POLIs.
 *              - Resilient On-Demand Fallback: guarantees no branch is skipped due to map misses.
 *              - Multi-Path POLI Synchronization: updates POLIs and PO headers across all fulfilled legs.
 *              - Cycle Protection: tracks visited SR and OALI IDs to prevent infinite loops.
 *              - Standardized Logging: provides auditable logs for all UPDATE / CONTINUE / STOP / SKIP decisions.
 */
public without sharing class InventoryTransferBacktrackingService {

    public enum DecisionType {
        DECISION_UPDATE,
        DECISION_CONTINUE,
        DECISION_STOP,
        DECISION_SKIP
    }

    public enum PropagationScope {
        ONE_LEVEL,
        FULL_CHAIN
    }

    /**
     * DTO representing an evaluation decision on an entity.
     */
    public class Decision {
        public DecisionType decisionType;
        public String reason;
        public Decimal allocatedQty;

        public Decision(DecisionType decisionType, String reason, Decimal allocatedQty) {
            this.decisionType = decisionType;
            this.reason = reason;
            this.allocatedQty = allocatedQty;
        }

        public Decision(DecisionType decisionType, String reason) {
            this(decisionType, reason, 0);
        }
    }

    /**
     * State container for an active backtracking node in the graph traversal.
     */
    private class TraversalNode {
        public Order_Allocation_Line_Item__c currentOali;
        public Supply_Request__c currentSr;
        public Decimal availableQty;
        public Integer level;

        public TraversalNode(
            Order_Allocation_Line_Item__c currentOali,
            Supply_Request__c currentSr,
            Decimal availableQty,
            Integer level
        ) {
            this.currentOali = currentOali;
            this.currentSr = currentSr;
            this.availableQty = availableQty;
            this.level = level;
        }
    }

    /**
     * Overload: Main entry point called when Inventory Transfers are accepted with preloaded data.
     */
    public static void processTransferAcceptance(
        List<Inventory_Transfer__c> acceptedTransfers,
        Map<Id, Order_Allocation_Line_Item__c> preloadedOalis,
        List<Supply_Request__c> preloadedSrs
    ) {
        processTransferAcceptanceInternal(acceptedTransfers, preloadedOalis, preloadedSrs);
    }

    /**
     * Main entry point called when Inventory Transfers are accepted.
     * Evaluates direct OALIs and current SRs, then propagates fulfillment backwards
     * through source SRs and source OALIs across arbitrary levels.
     *
     * @param acceptedTransfers List of Inventory_Transfer__c records being accepted
     */
    public static void processTransferAcceptance(List<Inventory_Transfer__c> acceptedTransfers) {
        processTransferAcceptanceInternal(acceptedTransfers, null, null);
    }

    private static void processTransferAcceptanceInternal(
        List<Inventory_Transfer__c> acceptedTransfers,
        Map<Id, Order_Allocation_Line_Item__c> preloadedOalis,
        List<Supply_Request__c> preloadedSrs
    ) {
        if (acceptedTransfers == null || acceptedTransfers.isEmpty()) {
            return;
        }

        System.debug(LoggingLevel.INFO, '[BACKTRACK] Starting acceptance backtracking for ' + acceptedTransfers.size() + ' transfer(s)');

        // 1. Collect direct OALI IDs and transfer IDs from transfers
        Set<Id> directOaliIds = new Set<Id>();
        Set<Id> transferIds = new Set<Id>();
        for (Inventory_Transfer__c t : acceptedTransfers) {
            if (t.Id != null) {
                transferIds.add(t.Id);
            }
            if (t.Order_Allocation_Line_Item__c != null) {
                directOaliIds.add(t.Order_Allocation_Line_Item__c);
            }
        }

        if (directOaliIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[BACKTRACK-STOP] No direct OALIs linked to accepted transfers');
            return;
        }

        // Re-query transfer details if necessary to ensure account and location information is present
        Map<Id, Inventory_Transfer__c> detailedTransferMap = new Map<Id, Inventory_Transfer__c>();
        if (!transferIds.isEmpty()) {
            List<Inventory_Transfer__c> qTransfers = Database.query(
                'SELECT Id, Name, Order_Allocation_Line_Item__c, Transfer_Qty__c, In_Transit_Qty__c, ' +
                '       Request_Type__c, To_Account__c, From_Account__c, Destination_Inventory_Location__c, ' +
                '       Destination_Inventory_Location__r.Account__c ' +
                'FROM Inventory_Transfer__c ' +
                'WHERE Id IN :transferIds',
                AccessLevel.SYSTEM_MODE
            );
            detailedTransferMap = new Map<Id, Inventory_Transfer__c>(qTransfers);
        }

        // 2. Pre-fetch direct OALIs and initialize caches
        Map<Id, Order_Allocation_Line_Item__c> allKnownOalis = new Map<Id, Order_Allocation_Line_Item__c>();
        if (!directOaliIds.isEmpty()) {
            List<Order_Allocation_Line_Item__c> qOalis = Database.query(
                'SELECT Id, Name, Ordered_Qty__c, Transfer_Qty_Planned__c, Transfer_Qty_Received__c, ' +
                '       Reserved_Quantity__c, Reserved_Qty_Planned__c, Procurement_Qty_Planned__c, ' +
                '       Procurement_Qty_Received__c, Remaining_Qty__c, Secured_Qty__c, Status__c, ' +
                '       Supply_Request__c, Source_SR_References__c, Source_SR_Allocation__c, ' +
                '       Source_SR_Sub_Type_References__c, Purchase_Order_Line_Item__c, Item__c, ' +
                '       Order_Allocation__c ' +
                'FROM Order_Allocation_Line_Item__c ' +
                'WHERE Id IN :directOaliIds',
                AccessLevel.SYSTEM_MODE
            );
            allKnownOalis = new Map<Id, Order_Allocation_Line_Item__c>(qOalis);
        }

        if (preloadedOalis != null && !preloadedOalis.isEmpty()) {
            for (Id oaliId : preloadedOalis.keySet()) {
                if (!allKnownOalis.containsKey(oaliId)) {
                    allKnownOalis.put(oaliId, preloadedOalis.get(oaliId));
                }
            }
        }

        Map<Id, Supply_Request__c> allKnownSrsById = new Map<Id, Supply_Request__c>();
        Map<String, Supply_Request__c> allKnownSrsByName = new Map<String, Supply_Request__c>();

        if (preloadedSrs != null && !preloadedSrs.isEmpty()) {
            for (Supply_Request__c sr : preloadedSrs) {
                if (sr.Id != null) {
                    allKnownSrsById.put(sr.Id, sr);
                }
                indexSrByName(sr, allKnownSrsByName);
            }
        }

        // =========================================================================
        // EXHAUSTIVE MULTI-TIER ANCESTOR PRE-FETCH LOOP
        // Iteratively resolves all unqueried SR Names, SR IDs, and OALI IDs across all hops.
        // =========================================================================
        Integer prefetchHop = 0;
        Boolean newRecordsFound = true;
        while (newRecordsFound && prefetchHop < 10) {
            prefetchHop++;
            newRecordsFound = false;

            Set<Id> srIdsToQuery = new Set<Id>();
            Set<String> srNamesToQuery = new Set<String>();

            // Collect referenced SR IDs and Names from all known OALIs
            for (Order_Allocation_Line_Item__c oali : allKnownOalis.values()) {
                if (oali.Supply_Request__c != null && !allKnownSrsById.containsKey(oali.Supply_Request__c)) {
                    srIdsToQuery.add(oali.Supply_Request__c);
                }
                if (String.isNotBlank(oali.Source_SR_References__c)) {
                    for (String ref : parseDelimitedString(oali.Source_SR_References__c)) {
                        if (findSrByName(ref, allKnownSrsByName) == null) {
                            addNameVariants(ref, srNamesToQuery);
                        }
                    }
                }
                Map<String, Decimal> allocMap = parseAllocations(oali.Source_SR_Allocation__c);
                for (String srName : allocMap.keySet()) {
                    if (findSrByName(srName, allKnownSrsByName) == null) {
                        addNameVariants(srName, srNamesToQuery);
                    }
                }
                Map<String, String> subMap = parseSubtypeReferences(oali.Source_SR_Sub_Type_References__c);
                for (String srName : subMap.keySet()) {
                    if (findSrByName(srName, allKnownSrsByName) == null) {
                        addNameVariants(srName, srNamesToQuery);
                    }
                }
            }

            // Collect unqueried parent SR IDs from known SRs
            for (Supply_Request__c sr : allKnownSrsById.values()) {
                if (sr.Supply_Request__c != null && !allKnownSrsById.containsKey(sr.Supply_Request__c)) {
                    srIdsToQuery.add(sr.Supply_Request__c);
                }
            }

            // Bulk Query missing SRs in System Mode
            if (!srIdsToQuery.isEmpty() || !srNamesToQuery.isEmpty()) {
                List<Supply_Request__c> newSrs = new List<Supply_Request__c>();
                if (!srIdsToQuery.isEmpty() && !srNamesToQuery.isEmpty()) {
                    newSrs = Database.query(
                        'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                        '       Requested_Qty__c, Received_Qty__c, Status__c, Request_Type__c, ' +
                        '       Sub_Request_Type__c, Item__c, Supply_Request__c, Order_Allocation_Line_Item__c, ' +
                        '       Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Account__c ' +
                        'FROM Supply_Request__c ' +
                        'WHERE Id IN :srIdsToQuery OR Name IN :srNamesToQuery',
                        AccessLevel.SYSTEM_MODE
                    );
                } else if (!srIdsToQuery.isEmpty()) {
                    newSrs = Database.query(
                        'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                        '       Requested_Qty__c, Received_Qty__c, Status__c, Request_Type__c, ' +
                        '       Sub_Request_Type__c, Item__c, Supply_Request__c, Order_Allocation_Line_Item__c, ' +
                        '       Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Account__c ' +
                        'FROM Supply_Request__c ' +
                        'WHERE Id IN :srIdsToQuery',
                        AccessLevel.SYSTEM_MODE
                    );
                } else if (!srNamesToQuery.isEmpty()) {
                    newSrs = Database.query(
                        'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                        '       Requested_Qty__c, Received_Qty__c, Status__c, Request_Type__c, ' +
                        '       Sub_Request_Type__c, Item__c, Supply_Request__c, Order_Allocation_Line_Item__c, ' +
                        '       Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Account__c ' +
                        'FROM Supply_Request__c ' +
                        'WHERE Name IN :srNamesToQuery',
                        AccessLevel.SYSTEM_MODE
                    );
                }

                if (!newSrs.isEmpty()) {
                    newRecordsFound = true;
                    for (Supply_Request__c sr : newSrs) {
                        allKnownSrsById.put(sr.Id, sr);
                        indexSrByName(sr, allKnownSrsByName);
                    }
                }
            }

            // Collect unqueried OALI IDs from newly known SRs
            Set<Id> oaliIdsToQuery = new Set<Id>();
            for (Supply_Request__c sr : allKnownSrsById.values()) {
                if (sr.Order_Allocation_Line_Item__c != null && !allKnownOalis.containsKey(sr.Order_Allocation_Line_Item__c)) {
                    oaliIdsToQuery.add(sr.Order_Allocation_Line_Item__c);
                }
            }

            // Bulk Query missing OALIs in System Mode
            if (!oaliIdsToQuery.isEmpty()) {
                List<Order_Allocation_Line_Item__c> newOalis = Database.query(
                    'SELECT Id, Name, Ordered_Qty__c, Transfer_Qty_Planned__c, Transfer_Qty_Received__c, ' +
                    '       Reserved_Quantity__c, Reserved_Qty_Planned__c, Procurement_Qty_Planned__c, ' +
                    '       Procurement_Qty_Received__c, Remaining_Qty__c, Secured_Qty__c, Status__c, ' +
                    '       Supply_Request__c, Source_SR_References__c, Source_SR_Allocation__c, ' +
                    '       Source_SR_Sub_Type_References__c, Purchase_Order_Line_Item__c, Item__c, ' +
                    '       Order_Allocation__c ' +
                    'FROM Order_Allocation_Line_Item__c ' +
                    'WHERE Id IN :oaliIdsToQuery',
                    AccessLevel.SYSTEM_MODE
                );
                if (!newOalis.isEmpty()) {
                    newRecordsFound = true;
                    for (Order_Allocation_Line_Item__c oali : newOalis) {
                        allKnownOalis.put(oali.Id, oali);
                    }
                }
            }
        }

        // Map linking SR Id -> Source OALI
        Map<Id, Order_Allocation_Line_Item__c> sourceOaliBySrId = new Map<Id, Order_Allocation_Line_Item__c>();

        // Pre-query OALIs that fulfill the known SRs in System Mode
        Set<Id> srIdsNeedingOalis = allKnownSrsById.keySet();
        if (!srIdsNeedingOalis.isEmpty()) {
            List<Order_Allocation_Line_Item__c> oalisFulfillingSrs = Database.query(
                'SELECT Id, Name, Ordered_Qty__c, Transfer_Qty_Planned__c, Transfer_Qty_Received__c, ' +
                '       Reserved_Quantity__c, Reserved_Qty_Planned__c, Procurement_Qty_Planned__c, ' +
                '       Procurement_Qty_Received__c, Remaining_Qty__c, Secured_Qty__c, Status__c, ' +
                '       Supply_Request__c, Source_SR_References__c, Source_SR_Allocation__c, ' +
                '       Source_SR_Sub_Type_References__c, Purchase_Order_Line_Item__c, Item__c, ' +
                '       Order_Allocation__c ' +
                'FROM Order_Allocation_Line_Item__c ' +
                'WHERE Supply_Request__c IN :srIdsNeedingOalis',
                AccessLevel.SYSTEM_MODE
            );
            for (Order_Allocation_Line_Item__c sOali : oalisFulfillingSrs) {
                allKnownOalis.put(sOali.Id, sOali);
                if (sOali.Supply_Request__c != null) {
                    sourceOaliBySrId.put(sOali.Supply_Request__c, sOali);
                }
            }
        }

        // Map direct OALI lookup on SR
        for (Supply_Request__c sr : allKnownSrsById.values()) {
            if (sr.Order_Allocation_Line_Item__c != null && allKnownOalis.containsKey(sr.Order_Allocation_Line_Item__c)) {
                sourceOaliBySrId.put(sr.Id, allKnownOalis.get(sr.Order_Allocation_Line_Item__c));
            }
        }

        // 3. Pre-fetch Purchase Order Line Items via PurchaseOrderBacktrackingService
        PurchaseOrderBacktrackingService poService = new PurchaseOrderBacktrackingService();
        Set<Id> poliIds = new Set<Id>();
        Set<Id> oaIds = new Set<Id>();
        for (Order_Allocation_Line_Item__c oali : allKnownOalis.values()) {
            if (oali.Purchase_Order_Line_Item__c != null) {
                poliIds.add(oali.Purchase_Order_Line_Item__c);
            }
            if (oali.Order_Allocation__c != null) {
                oaIds.add(oali.Order_Allocation__c);
            }
        }
        if (!poliIds.isEmpty()) {
            poService.loadPolis(poliIds);
        }
        poService.loadPolisByOaliIds(allKnownOalis.keySet());
        if (!oaIds.isEmpty()) {
            poService.loadPolisByOrderAllocationIds(oaIds);
        }

        // Collections for Bulk DML
        Map<Id, Order_Allocation_Line_Item__c> oalisToUpdate = new Map<Id, Order_Allocation_Line_Item__c>();
        Map<Id, Supply_Request__c> srsToUpdate = new Map<Id, Supply_Request__c>();

        // 4. Execute graph traversal per accepted transfer
        for (Inventory_Transfer__c rawTransfer : acceptedTransfers) {
            Inventory_Transfer__c transfer = (rawTransfer.Id != null && detailedTransferMap.containsKey(rawTransfer.Id))
                ? detailedTransferMap.get(rawTransfer.Id)
                : rawTransfer;
            Decimal acceptedQty = transfer.Transfer_Qty__c != null ? transfer.Transfer_Qty__c : (transfer.In_Transit_Qty__c != null ? transfer.In_Transit_Qty__c : 0);
            if (acceptedQty <= 0 || transfer.Order_Allocation_Line_Item__c == null) {
                continue;
            }

            Order_Allocation_Line_Item__c directOali = allKnownOalis.get(transfer.Order_Allocation_Line_Item__c);
            if (directOali == null) {
                System.debug(LoggingLevel.WARN, '[BACKTRACK-SKIP] Direct OALI not found for transfer ' + transfer.Id);
                continue;
            }

            // Cycle protection sets per transfer path
            Set<Id> visitedSrIds = new Set<Id>();
            Set<Id> visitedOaliIds = new Set<Id>();

            // --- LEVEL 0: RESOLVE CURRENT SR(S) & PARTY MATCHING ---
            Map<Id, Supply_Request__c> allDirectSrs = new Map<Id, Supply_Request__c>();
            if (directOali.Supply_Request__c != null && allKnownSrsById.containsKey(directOali.Supply_Request__c)) {
                allDirectSrs.put(directOali.Supply_Request__c, allKnownSrsById.get(directOali.Supply_Request__c));
            }
            if (String.isNotBlank(directOali.Source_SR_References__c)) {
                for (String ref : parseDelimitedString(directOali.Source_SR_References__c)) {
                    Supply_Request__c found = findSrByNameWithFallback(ref, allKnownSrsByName, allKnownSrsById, allKnownOalis, poService);
                    if (found != null) {
                        allDirectSrs.put(found.Id, found);
                    }
                }
            }
            if (String.isNotBlank(directOali.Source_SR_Allocation__c)) {
                Map<String, Decimal> allocMap = parseAllocations(directOali.Source_SR_Allocation__c);
                for (String ref : allocMap.keySet()) {
                    Supply_Request__c found = findSrByNameWithFallback(ref, allKnownSrsByName, allKnownSrsById, allKnownOalis, poService);
                    if (found != null) {
                        allDirectSrs.put(found.Id, found);
                    }
                }
            }

            // Party-match candidate SRs against the accepted transfer
            Map<Id, Supply_Request__c> matchedSrs = new Map<Id, Supply_Request__c>();
            for (Supply_Request__c sr : allDirectSrs.values()) {
                if (isTransferFulfillingSr(transfer, sr)) {
                    matchedSrs.put(sr.Id, sr);
                }
            }
            // If no SR matched parties explicitly, fallback to all candidate direct SRs
            if (matchedSrs.isEmpty() && !allDirectSrs.isEmpty()) {
                matchedSrs.putAll(allDirectSrs);
            }

            // Check if any matched SR is an external Transfer SR or Procurement SR
            Boolean isActuallyFulfillingTransferSr = false;
            Boolean isActuallyFulfillingPurchaseSr = false;
            for (Supply_Request__c mSr : matchedSrs.values()) {
                if (isTransferSupplyRequest(mSr)) {
                    isActuallyFulfillingTransferSr = true;
                    break;
                } else if (isProcurementSupplyRequest(mSr)) {
                    isActuallyFulfillingPurchaseSr = true;
                    break;
                }
            }

            // Determine if this transfer is delivering already-reserved local stock
            Decimal reservedQty = directOali.Reserved_Quantity__c != null ? directOali.Reserved_Quantity__c : 0;
            Decimal reservedPlanned = directOali.Reserved_Qty_Planned__c != null ? directOali.Reserved_Qty_Planned__c : 0;
            Boolean isReservedStockDelivery = !isActuallyFulfillingTransferSr && !isActuallyFulfillingPurchaseSr && (reservedQty > 0 || reservedPlanned > 0);

            // --- LEVEL 0: DIRECT OALI EVALUATION & UPDATE ---
            visitedOaliIds.add(directOali.Id);
            Decimal orderedCap = directOali.Ordered_Qty__c != null && directOali.Ordered_Qty__c > 0 ? directOali.Ordered_Qty__c : acceptedQty;
            Decimal directAllocQty = Math.min(acceptedQty, orderedCap);

            applyOaliQuantityUpdate(directOali, directAllocQty, isActuallyFulfillingTransferSr, true, isReservedStockDelivery);
            oalisToUpdate.put(directOali.Id, directOali);
            System.debug(LoggingLevel.INFO, '[BACKTRACK-OALI] Direct OALI ' + directOali.Id + ' updated with Qty = ' + directAllocQty + 
                ' (isTransfer=' + isActuallyFulfillingTransferSr + ', isReservedDelivery=' + isReservedStockDelivery + ')');

            // --- LEVEL 0: DIRECT SR(S) EVALUATION & UPDATE ---
            Map<String, Decimal> directSrAllocCaps = parseAllocations(directOali.Source_SR_Allocation__c);
            List<TraversalNode> parentNodesToQueue = new List<TraversalNode>();

            for (Supply_Request__c dSr : matchedSrs.values()) {
                visitedSrIds.add(dSr.Id);
                Decimal srCap = directAllocQty;
                for (String aKey : directSrAllocCaps.keySet()) {
                    if (isSrNameMatch(aKey, dSr.Name) && directSrAllocCaps.get(aKey) != null) {
                        srCap = Math.min(srCap, directSrAllocCaps.get(aKey));
                        break;
                    }
                }
                Decision dSrDecision = evaluateSrEligibility(dSr, srCap);
                if (dSrDecision.decisionType == DecisionType.DECISION_UPDATE) {
                    applySrQuantityUpdate(dSr, dSrDecision.allocatedQty);
                    srsToUpdate.put(dSr.Id, dSr);
                    System.debug(LoggingLevel.INFO, '[BACKTRACK-SR] Direct SR ' + dSr.Name + ' updated with Qty = ' + dSrDecision.allocatedQty + '. Decision = UPDATE');
                }

                // If dSr is created for a parent customer/receiving OALI, roll up fulfilled quantity
                Order_Allocation_Line_Item__c parentCustomerOali = null;
                if (dSr.Order_Allocation_Line_Item__c != null) {
                    parentCustomerOali = allKnownOalis.get(dSr.Order_Allocation_Line_Item__c);
                }
                if (parentCustomerOali == null) {
                    parentCustomerOali = sourceOaliBySrId.get(dSr.Id);
                }
                if (parentCustomerOali == null && dSr.Supply_Request__c != null) {
                    parentCustomerOali = sourceOaliBySrId.get(dSr.Supply_Request__c);
                }
                if (parentCustomerOali != null) {
                    Decimal qtyToRollup = (dSrDecision.decisionType == DecisionType.DECISION_UPDATE)
                        ? dSrDecision.allocatedQty
                        : directAllocQty;
                    Boolean srIsTransfer = isTransferSupplyRequest(dSr);
                    applyRollupToParentOali(parentCustomerOali, qtyToRollup, srIsTransfer);
                    oalisToUpdate.put(parentCustomerOali.Id, parentCustomerOali);

                    // Synchronize linked POLI on Parent Customer OALI
                    poService.recordPoliReceiptForOali(
                        parentCustomerOali,
                        qtyToRollup,
                        transfer.From_Account__c
                    );

                    System.debug(LoggingLevel.INFO, '[BACKTRACK-ROLLUP] Level 0: Rolled up Qty = ' + qtyToRollup + 
                        ' (isTransfer=' + srIsTransfer + ') into Parent OALI ' + parentCustomerOali.Id + ' from Direct SR ' + dSr.Name);

                    // Allow parent OALI to enter the traversal queue so its Source_SR_References__c can be processed
                    if (parentCustomerOali.Id != directOali.Id) {
                        parentNodesToQueue.add(new TraversalNode(parentCustomerOali, dSr, qtyToRollup, 1));
                    }
                }
            }

            // --- LEVEL 0: DIRECT POLI UPDATE ---
            poService.recordPoliReceiptForOali(
                directOali,
                directAllocQty,
                transfer.From_Account__c
            );

            // --- BACKTRACKING TRAVERSAL: PROCESS SOURCE CHAIN ---
            List<TraversalNode> queue = new List<TraversalNode>();
            if (!matchedSrs.isEmpty()) {
                for (Supply_Request__c dSr : matchedSrs.values()) {
                    queue.add(new TraversalNode(directOali, dSr, directAllocQty, 1));
                }
            } else {
                queue.add(new TraversalNode(directOali, null, directAllocQty, 1));
            }
            if (!parentNodesToQueue.isEmpty()) {
                queue.addAll(parentNodesToQueue);
            }

            while (!queue.isEmpty()) {
                TraversalNode node = queue.remove(0);
                Order_Allocation_Line_Item__c parentOali = node.currentOali;
                Supply_Request__c parentSr = node.currentSr;
                Decimal availableQty = node.availableQty;

                if (String.isBlank(parentOali.Source_SR_References__c) && 
                    String.isBlank(parentOali.Source_SR_Allocation__c) && 
                    String.isBlank(parentOali.Source_SR_Sub_Type_References__c)) {
                    System.debug(LoggingLevel.INFO, '[BACKTRACK-STOP] OALI ' + parentOali.Id + ' has no source SR references. Reached legitimate chain root.');
                    continue;
                }

                Map<String, Decimal> srAllocMap = parseAllocations(parentOali.Source_SR_Allocation__c);

                // Collect referenced SR names from all reference fields
                Set<String> referencedSrNames = new Set<String>();
                if (String.isNotBlank(parentOali.Source_SR_References__c)) {
                    referencedSrNames.addAll(parseDelimitedString(parentOali.Source_SR_References__c));
                }
                referencedSrNames.addAll(srAllocMap.keySet());
                Map<String, String> subMap = parseSubtypeReferences(parentOali.Source_SR_Sub_Type_References__c);
                referencedSrNames.addAll(subMap.keySet());

                for (String sourceSrName : referencedSrNames) {
                    Supply_Request__c candidateSourceSr = findSrByNameWithFallback(
                        sourceSrName,
                        allKnownSrsByName,
                        allKnownSrsById,
                        allKnownOalis,
                        poService
                    );
                    if (candidateSourceSr == null) {
                        System.debug(LoggingLevel.WARN, '[BACKTRACK-SKIP] Source SR ' + sourceSrName + ' not found in database. Decision = SKIP');
                        continue;
                    }

                    if (visitedSrIds.contains(candidateSourceSr.Id)) {
                        System.debug(LoggingLevel.INFO, '[BACKTRACK-SKIP] Source SR ' + candidateSourceSr.Name + ' already visited in traversal path. Decision = SKIP');
                        continue;
                    }

                    // Scope determination based on Account custody / Intermediate sourcing
                    PropagationScope scope = determinePropagationScope(transfer, directOali, parentSr, candidateSourceSr);
                    if (scope == PropagationScope.ONE_LEVEL) {
                        System.debug(LoggingLevel.INFO, '[BACKTRACK-STOP] Transfer ' + transfer.Id + 
                            ' is an intermediate sourcing/procurement transfer for candidate Source SR ' + candidateSourceSr.Name +
                            '. Propagation Scope = ONE_LEVEL.');

                        Decimal cap = availableQty;
                        for (String aKey : srAllocMap.keySet()) {
                            if (isSrNameMatch(aKey, candidateSourceSr.Name) && srAllocMap.get(aKey) != null) {
                                cap = Math.min(cap, srAllocMap.get(aKey));
                                break;
                            }
                        }
                        Decimal maxPropagatableQty = Math.min(availableQty, cap);

                        Order_Allocation_Line_Item__c intermediateParentOali = sourceOaliBySrId.get(candidateSourceSr.Id);
                        if (intermediateParentOali == null && candidateSourceSr.Order_Allocation_Line_Item__c != null) {
                            intermediateParentOali = allKnownOalis.get(candidateSourceSr.Order_Allocation_Line_Item__c);
                        }
                        if (intermediateParentOali == null && parentSr != null && parentSr.Order_Allocation_Line_Item__c != null) {
                            intermediateParentOali = allKnownOalis.get(parentSr.Order_Allocation_Line_Item__c);
                        }

                        if (intermediateParentOali != null) {
                            Boolean isTransferBranch = isTransferSupplyRequest(candidateSourceSr) || (parentSr != null && isTransferSupplyRequest(parentSr));
                            applyRollupToParentOali(intermediateParentOali, maxPropagatableQty, isTransferBranch);
                            oalisToUpdate.put(intermediateParentOali.Id, intermediateParentOali);

                            // Synchronize linked POLI on Intermediate Parent OALI
                            poService.recordPoliReceiptForOali(
                                intermediateParentOali,
                                maxPropagatableQty,
                                candidateSourceSr.Supplying_Account__c
                            );

                            System.debug(LoggingLevel.INFO, '[BACKTRACK-ROLLUP] Traversal: Rolled up Qty = ' + maxPropagatableQty + 
                                ' (isTransfer=' + isTransferBranch + ') into Parent OALI ' + intermediateParentOali.Id);
                        }
                        // Stop traversal down this branch - intermediate sourcing stops here
                        continue;
                    }

                    // Scope == PropagationScope.FULL_CHAIN
                    Decimal cap = availableQty;
                    for (String aKey : srAllocMap.keySet()) {
                        if (isSrNameMatch(aKey, candidateSourceSr.Name) && srAllocMap.get(aKey) != null) {
                            cap = Math.min(cap, srAllocMap.get(aKey));
                            break;
                        }
                    }
                    Decimal maxPropagatableQty = Math.min(availableQty, cap);

                    // Multi-path resolution for Source OALI (must be an unvisited downstream OALI)
                    Order_Allocation_Line_Item__c sourceOali = sourceOaliBySrId.get(candidateSourceSr.Id);
                    if (sourceOali != null && (sourceOali.Id == parentOali.Id || visitedOaliIds.contains(sourceOali.Id))) {
                        sourceOali = null;
                    }
                    if (sourceOali == null && candidateSourceSr.Order_Allocation_Line_Item__c != null) {
                        Order_Allocation_Line_Item__c cand = allKnownOalis.get(candidateSourceSr.Order_Allocation_Line_Item__c);
                        if (cand != null && cand.Id != parentOali.Id && !visitedOaliIds.contains(cand.Id)) {
                            sourceOali = cand;
                        }
                    }
                    if (sourceOali == null && candidateSourceSr.Supply_Request__c != null) {
                        Order_Allocation_Line_Item__c cand = sourceOaliBySrId.get(candidateSourceSr.Supply_Request__c);
                        if (cand != null && cand.Id != parentOali.Id && !visitedOaliIds.contains(cand.Id)) {
                            sourceOali = cand;
                        }
                        if (sourceOali == null && allKnownSrsById.containsKey(candidateSourceSr.Supply_Request__c)) {
                            Supply_Request__c pSr = allKnownSrsById.get(candidateSourceSr.Supply_Request__c);
                            if (pSr.Order_Allocation_Line_Item__c != null) {
                                Order_Allocation_Line_Item__c po = allKnownOalis.get(pSr.Order_Allocation_Line_Item__c);
                                if (po != null && po.Id != parentOali.Id && !visitedOaliIds.contains(po.Id)) {
                                    sourceOali = po;
                                }
                            }
                        }
                    }
                    if (sourceOali == null) {
                        for (Order_Allocation_Line_Item__c candOali : allKnownOalis.values()) {
                            if (candOali.Id == parentOali.Id || visitedOaliIds.contains(candOali.Id)) {
                                continue;
                            }
                            if (candOali.Supply_Request__c == candidateSourceSr.Id || isSrReferencedInOali(candOali, candidateSourceSr.Name)) {
                                sourceOali = candOali;
                                break;
                            }
                        }
                    }

                    if (sourceOali == null) {
                        // Candidate SR is a standalone or root SR without a downstream OALI: update SR directly
                        Decision sourceSrDecision = evaluateSrEligibility(candidateSourceSr, maxPropagatableQty);
                        if (sourceSrDecision.decisionType == DecisionType.DECISION_UPDATE) {
                            visitedSrIds.add(candidateSourceSr.Id);
                            applySrQuantityUpdate(candidateSourceSr, sourceSrDecision.allocatedQty);
                            srsToUpdate.put(candidateSourceSr.Id, candidateSourceSr);
                            System.debug(LoggingLevel.INFO, '[BACKTRACK-SR] Standalone Source SR ' + candidateSourceSr.Name + ' updated with Qty = ' + sourceSrDecision.allocatedQty);

                            // Synchronize any linked POLI on parentOali for this root SR
                            poService.recordPoliReceiptForOali(
                                parentOali,
                                sourceSrDecision.allocatedQty,
                                candidateSourceSr.Supplying_Account__c
                            );
                        }
                        continue;
                    }

                    // Cycle Protection on OALI
                    if (visitedOaliIds.contains(sourceOali.Id)) {
                        System.debug(LoggingLevel.INFO, '[BACKTRACK-SKIP] Source OALI ' + sourceOali.Id + ' already visited in traversal path. Decision = SKIP');
                        continue;
                    }

                    // Evaluate Source OALI Eligibility & Capacity
                    Decision sourceOaliDecision = evaluateOaliEligibility(sourceOali, maxPropagatableQty);
                    if (sourceOaliDecision.decisionType == DecisionType.DECISION_SKIP) {
                        System.debug(LoggingLevel.INFO, '[BACKTRACK-SKIP] Source OALI ' + sourceOali.Id + ' skipped: ' + sourceOaliDecision.reason + '. Decision = SKIP');
                        continue;
                    }

                    // Evaluate Source SR Eligibility & Capacity
                    Decision sourceSrDecision = evaluateSrEligibility(candidateSourceSr, sourceOaliDecision.allocatedQty);
                    if (sourceSrDecision.decisionType == DecisionType.DECISION_SKIP) {
                        System.debug(LoggingLevel.INFO, '[BACKTRACK-SKIP] Source SR ' + candidateSourceSr.Name + ' skipped: ' + sourceSrDecision.reason + '. Decision = SKIP');
                        continue;
                    }

                    Decimal finalPropagatedQty = Math.min(sourceOaliDecision.allocatedQty, sourceSrDecision.allocatedQty);
                    if (finalPropagatedQty <= 0) {
                        System.debug(LoggingLevel.INFO, '[BACKTRACK-SKIP] Zero propagatable quantity for OALI ' + sourceOali.Id + ' and SR ' + candidateSourceSr.Name);
                        continue;
                    }

                    // Update Source OALI
                    visitedOaliIds.add(sourceOali.Id);
                    Boolean isFullChainTransfer = isTransferSupplyRequest(candidateSourceSr);
                    applyOaliQuantityUpdate(sourceOali, finalPropagatedQty, isFullChainTransfer, false);
                    oalisToUpdate.put(sourceOali.Id, sourceOali);
                    System.debug(LoggingLevel.INFO, '[BACKTRACK-OALI] Source OALI ' + sourceOali.Id + 
                        ' Ordered = ' + sourceOali.Ordered_Qty__c + 
                        ' Propagated = ' + finalPropagatedQty + 
                        ' isTransfer = ' + isFullChainTransfer +
                        '. Decision = UPDATE');

                    // Update Source SR
                    visitedSrIds.add(candidateSourceSr.Id);
                    applySrQuantityUpdate(candidateSourceSr, finalPropagatedQty);
                    srsToUpdate.put(candidateSourceSr.Id, candidateSourceSr);
                    System.debug(LoggingLevel.INFO, '[BACKTRACK-SR] Source SR ' + candidateSourceSr.Name + 
                        ' Requested = ' + candidateSourceSr.Requested_Qty__c + 
                        ' Received = ' + candidateSourceSr.Received_Qty__c + 
                        ' Propagated = ' + finalPropagatedQty + 
                        '. Decision = UPDATE');

                    // Update Linked POLI on Source OALI
                    poService.recordPoliReceiptForOali(
                        sourceOali,
                        finalPropagatedQty,
                        candidateSourceSr.Supplying_Account__c
                    );

                    // Queue for Next Level Traversal (if further source references exist)
                    queue.add(new TraversalNode(sourceOali, candidateSourceSr, finalPropagatedQty, node.level + 1));
                    System.debug(LoggingLevel.INFO, '[BACKTRACK-CONTINUE] Queued next level from OALI ' + sourceOali.Id + ' with Qty = ' + finalPropagatedQty);
                }
            }
        }

        // 5. Commit all updates atomically in bulk
        if (!oalisToUpdate.isEmpty()) {
            ensureParentOaAccess(oalisToUpdate.values());
            List<Order_Allocation_Line_Item__c> cleanOaliUpdates = new List<Order_Allocation_Line_Item__c>();
            for (Order_Allocation_Line_Item__c oali : oalisToUpdate.values()) {
                cleanOaliUpdates.add(new Order_Allocation_Line_Item__c(
                    Id = oali.Id,
                    Status__c = oali.Status__c,
                    Transfer_Qty_Received__c = oali.Transfer_Qty_Received__c,
                    Procurement_Qty_Received__c = oali.Procurement_Qty_Received__c,
                    Secured_Qty__c = oali.Secured_Qty__c
                ));
            }
            List<Database.SaveResult> oaliResults = Database.update(cleanOaliUpdates, false, AccessLevel.SYSTEM_MODE);
            for (Database.SaveResult sr : oaliResults) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        System.debug(LoggingLevel.WARN, '[BACKTRACK] OALI ' + sr.getId() + ' update warning: ' + err.getStatusCode() + ' - ' + err.getMessage());
                    }
                }
            }
            System.debug(LoggingLevel.INFO, '[BACKTRACK] Committed ' + cleanOaliUpdates.size() + ' OALI update(s)');
        }
        if (!srsToUpdate.isEmpty()) {
            List<Supply_Request__c> cleanSrUpdates = new List<Supply_Request__c>();
            for (Supply_Request__c sr : srsToUpdate.values()) {
                cleanSrUpdates.add(new Supply_Request__c(
                    Id = sr.Id,
                    Received_Qty__c = sr.Received_Qty__c,
                    Status__c = sr.Status__c
                ));
            }
            List<Database.SaveResult> srResults = Database.update(cleanSrUpdates, false, AccessLevel.SYSTEM_MODE);
            for (Database.SaveResult sr : srResults) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        System.debug(LoggingLevel.WARN, '[BACKTRACK] SR ' + sr.getId() + ' update warning: ' + err.getStatusCode() + ' - ' + err.getMessage());
                    }
                }
            }
            System.debug(LoggingLevel.INFO, '[BACKTRACK] Committed ' + cleanSrUpdates.size() + ' SR update(s)');
        }
        poService.commitPoliUpdates();
    }

    // =========================================================================
    // DECISION ENGINES
    // =========================================================================

    /**
     * Determines whether an Inventory Transfer should propagate beyond Level 0 (FULL_CHAIN)
     * or stop at Level 0 (ONE_LEVEL).
     */
    public static PropagationScope determinePropagationScope(
        Inventory_Transfer__c transfer,
        Order_Allocation_Line_Item__c directOali,
        Supply_Request__c currentSr,
        Supply_Request__c candidateSourceSr
    ) {
        if (transfer == null || candidateSourceSr == null) {
            return PropagationScope.FULL_CHAIN;
        }

        System.debug(LoggingLevel.INFO, '[BACKTRACK-SCOPE] Full chain backtracking active for Source SR ' + 
            candidateSourceSr.Name + '. Scope = FULL_CHAIN. Decision = CONTINUE');
        return PropagationScope.FULL_CHAIN;
    }

    /**
     * Evaluates candidate OALI eligibility and available remaining capacity.
     */
    public static Decision evaluateOaliEligibility(Order_Allocation_Line_Item__c oali, Decimal requestedQty) {
        if (oali == null) {
            return new Decision(DecisionType.DECISION_SKIP, 'OALI record is null');
        }
        if (requestedQty == null || requestedQty <= 0) {
            return new Decision(DecisionType.DECISION_SKIP, 'Requested quantity is zero or negative');
        }

        Decimal orderedQty = oali.Ordered_Qty__c != null ? oali.Ordered_Qty__c : 0;
        Decimal reservedQty = oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : 0;
        Decimal transferRec = oali.Transfer_Qty_Received__c != null ? oali.Transfer_Qty_Received__c : 0;
        Decimal procRec = oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0;
        Decimal totalReceived = reservedQty + transferRec + procRec;

        if (orderedQty > 0 && totalReceived >= orderedQty) {
            return new Decision(DecisionType.DECISION_SKIP, 'OALI already fully received (Ordered=' + orderedQty + ', Received=' + totalReceived + ')');
        }

        Decimal remainingCapacity = orderedQty > 0 ? Math.max(0, orderedQty - totalReceived) : requestedQty;
        if (remainingCapacity <= 0) {
            return new Decision(DecisionType.DECISION_SKIP, 'OALI has no remaining capacity');
        }

        Decimal allocQty = Math.min(requestedQty, remainingCapacity);
        return new Decision(DecisionType.DECISION_UPDATE, 'OALI eligible for update', allocQty);
    }

    /**
     * Evaluates candidate SR eligibility and available remaining capacity.
     */
    public static Decision evaluateSrEligibility(Supply_Request__c sr, Decimal requestedQty) {
        if (sr == null) {
            return new Decision(DecisionType.DECISION_SKIP, 'SR record is null');
        }
        if (requestedQty == null || requestedQty <= 0) {
            return new Decision(DecisionType.DECISION_SKIP, 'Requested quantity is zero or negative');
        }

        Decimal reqQty = sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0;
        Decimal recQty = sr.Received_Qty__c != null ? sr.Received_Qty__c : 0;

        if (reqQty > 0 && recQty >= reqQty && (sr.Status__c == 'Completed' || sr.Status__c == 'Received')) {
            return new Decision(DecisionType.DECISION_SKIP, 'SR already fully fulfilled and completed');
        }

        Decimal remainingCapacity = reqQty > 0 ? Math.max(0, reqQty - recQty) : requestedQty;
        if (remainingCapacity <= 0) {
            return new Decision(DecisionType.DECISION_SKIP, 'SR has no remaining unfulfilled capacity');
        }

        Decimal allocQty = Math.min(requestedQty, remainingCapacity);
        return new Decision(DecisionType.DECISION_UPDATE, 'SR eligible for update', allocQty);
    }

    // =========================================================================
    // QUANTITY & STATUS APPLICATION HELPERS
    // =========================================================================

    /**
     * Applies quantity increment and status recalculation to an OALI.
     */
    public static void applyOaliQuantityUpdate(
        Order_Allocation_Line_Item__c oali,
        Decimal qtyToAdd,
        Boolean isTransferSR,
        Boolean isDirectSrTarget,
        Boolean isReservedStockDelivery
    ) {
        if (oali == null) {
            return;
        }

        Decimal orderedQty = oali.Ordered_Qty__c != null ? oali.Ordered_Qty__c : 0;
        Decimal reservedQty = oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : 0;
        Decimal existingTransferRec = oali.Transfer_Qty_Received__c != null ? oali.Transfer_Qty_Received__c : 0;
        Decimal existingProcRec = oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0;
        Decimal existingTotalRec = reservedQty + existingTransferRec + existingProcRec;

        if (!isReservedStockDelivery && qtyToAdd != null && qtyToAdd > 0) {
            Decimal remainingCapacity = (orderedQty > 0) ? Math.max(0, orderedQty - existingTotalRec) : qtyToAdd;
            Decimal allocToOali = (orderedQty > 0) ? Math.min(qtyToAdd, remainingCapacity) : qtyToAdd;

            if (isTransferSR) {
                oali.Transfer_Qty_Received__c = existingTransferRec + allocToOali;
            } else {
                oali.Procurement_Qty_Received__c = existingProcRec + allocToOali;
            }
        }

        Decimal finalTransferRec = oali.Transfer_Qty_Received__c != null ? oali.Transfer_Qty_Received__c : 0;
        Decimal finalProcRec = oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0;
        Decimal finalTotalRec = reservedQty + finalTransferRec + finalProcRec;
        oali.Secured_Qty__c = finalTotalRec;

        if (orderedQty > 0 && finalTotalRec >= orderedQty) {
            oali.Status__c = 'Delivered';
        } else if (finalTotalRec > 0) {
            oali.Status__c = 'Partially Delivered';
        }
    }

    public static void applyOaliQuantityUpdate(
        Order_Allocation_Line_Item__c oali,
        Decimal qtyToAdd,
        Boolean isTransferSR,
        Boolean isDirectSrTarget
    ) {
        applyOaliQuantityUpdate(oali, qtyToAdd, isTransferSR, isDirectSrTarget, false);
    }

    public static void applyOaliQuantityUpdate(
        Order_Allocation_Line_Item__c oali,
        Decimal qtyToAdd,
        String requestType,
        Boolean isDirectSrTarget
    ) {
        Boolean isTransferSR = String.isNotBlank(requestType) && 
            ('Transfer SR'.equalsIgnoreCase(requestType.trim()) || 'Transfer'.equalsIgnoreCase(requestType.trim()));
        applyOaliQuantityUpdate(oali, qtyToAdd, isTransferSR, isDirectSrTarget, false);
    }

    /**
     * Rolls up fulfilled quantity into a parent/source OALI.
     */
    public static void applyRollupToParentOali(Order_Allocation_Line_Item__c parentOali, Decimal qtyToAdd, Boolean isTransferSR) {
        if (parentOali == null || qtyToAdd == null || qtyToAdd <= 0) {
            return;
        }

        Decimal orderedQty = parentOali.Ordered_Qty__c != null ? parentOali.Ordered_Qty__c : 0;
        Decimal reservedQty = parentOali.Reserved_Quantity__c != null ? parentOali.Reserved_Quantity__c : 0;
        Decimal existingTransferRec = parentOali.Transfer_Qty_Received__c != null ? parentOali.Transfer_Qty_Received__c : 0;
        Decimal existingProcRec = parentOali.Procurement_Qty_Received__c != null ? parentOali.Procurement_Qty_Received__c : 0;
        Decimal currentTotal = reservedQty + existingTransferRec + existingProcRec;

        Decimal remainingCap = orderedQty > 0 ? Math.max(0, orderedQty - currentTotal) : qtyToAdd;
        Decimal alloc = orderedQty > 0 ? Math.min(qtyToAdd, remainingCap) : qtyToAdd;

        if (isTransferSR) {
            parentOali.Transfer_Qty_Received__c = existingTransferRec + alloc;
        } else {
            parentOali.Procurement_Qty_Received__c = existingProcRec + alloc;
        }

        Decimal finalTransferRec = parentOali.Transfer_Qty_Received__c != null ? parentOali.Transfer_Qty_Received__c : 0;
        Decimal finalProcRec = parentOali.Procurement_Qty_Received__c != null ? parentOali.Procurement_Qty_Received__c : 0;
        Decimal finalTotal = reservedQty + finalTransferRec + finalProcRec;
        parentOali.Secured_Qty__c = finalTotal;

        if (orderedQty > 0 && finalTotal >= orderedQty) {
            parentOali.Status__c = 'Delivered';
        } else if (finalTotal > 0) {
            parentOali.Status__c = 'Partially Delivered';
        }
    }

    public static void applyProcurementRollupToParentOali(Order_Allocation_Line_Item__c parentOali, Decimal qtyToAdd) {
        applyRollupToParentOali(parentOali, qtyToAdd, false);
    }

    /**
     * Applies received quantity increment and status recalculation to a Supply Request.
     */
    public static void applySrQuantityUpdate(Supply_Request__c sr, Decimal qtyToAdd) {
        if (sr == null || qtyToAdd == null || qtyToAdd <= 0) {
            return;
        }

        Decimal currentRec = sr.Received_Qty__c != null ? sr.Received_Qty__c : 0;
        Decimal req = sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0;

        sr.Received_Qty__c = currentRec + qtyToAdd;
        if (req > 0 && sr.Received_Qty__c > req) {
            sr.Received_Qty__c = req;
        }

        if ((req > 0 && sr.Received_Qty__c >= req) || (req <= 0 && sr.Received_Qty__c > 0)) {
            sr.Status__c = 'Completed';
        } else if (sr.Received_Qty__c > 0) {
            sr.Status__c = 'Partially Received';
        }
    }

    // =========================================================================
    // PARSING & SUBTYPE NORMALIZATION
    // =========================================================================

    /**
     * Parses Source_SR_Sub_Type_References__c into a deterministic map of SR Name -> Subtype.
     */
    public static Map<String, String> parseSubtypeReferences(String rawText) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(rawText)) {
            return result;
        }

        List<String> entries = rawText.contains('\n') ? rawText.split('\n') : rawText.split(',');
        for (String entry : entries) {
            String trimmed = entry.trim();
            if (String.isNotBlank(trimmed) && trimmed.contains(':')) {
                List<String> parts = trimmed.split(':');
                if (parts.size() >= 2) {
                    String srName = parts[0].trim();
                    String subtype = parts[1].trim();
                    if (String.isNotBlank(srName) && String.isNotBlank(subtype)) {
                        result.put(srName, subtype);
                    }
                }
            }
        }
        return result;
    }

    /**
     * Parses Source_SR_Allocation__c into a map of SR Name -> Allocated Quantity Cap.
     */
    public static Map<String, Decimal> parseAllocations(String rawText) {
        Map<String, Decimal> result = new Map<String, Decimal>();
        if (String.isBlank(rawText)) {
            return result;
        }

        List<String> entries = rawText.contains('\n') ? rawText.split('\n') : rawText.split(',');
        for (String entry : entries) {
            String trimmed = entry.trim();
            if (String.isNotBlank(trimmed) && trimmed.contains(':')) {
                List<String> parts = trimmed.split(':');
                if (parts.size() >= 2) {
                    String srName = parts[0].trim();
                    try {
                        Decimal cap = Decimal.valueOf(parts[1].trim());
                        if (String.isNotBlank(srName)) {
                            result.put(srName, cap);
                        }
                    } catch (Exception e) {
                        // Ignore non-numeric allocation caps
                    }
                }
            }
        }
        return result;
    }

    /**
     * Normalizes subtype strings for deterministic comparison.
     */
    public static String normalizeSubtype(String subtype) {
        if (String.isBlank(subtype)) {
            return '';
        }
        String normalized = subtype.trim();
        normalized = normalized.replace('→', ' to ')
                               .replace('->', ' to ')
                               .replace('—>', ' to ');
        normalized = normalized.replaceAll('\\s+', ' ').trim().toLowerCase();
        return normalized;
    }

    /**
     * Compares Current SR Subtype against Referenced Source Subtype using exact matching.
     */
    public static Boolean isExactSubtypeMatch(String currentSubtype, String referencedSubtype) {
        if (String.isBlank(currentSubtype) || String.isBlank(referencedSubtype)) {
            return false;
        }
        String normCurrent = normalizeSubtype(currentSubtype);
        String normReferenced = normalizeSubtype(referencedSubtype);
        return normCurrent.equals(normReferenced);
    }

    /**
     * Splits comma, newline, or semicolon delimited text into a trimmed list of non-blank tokens.
     */
    public static List<String> parseDelimitedString(String rawText) {
        List<String> result = new List<String>();
        if (String.isBlank(rawText)) {
            return result;
        }
        String unified = rawText.replace('\n', ',').replace('\r', ',').replace(';', ',');
        for (String part : unified.split(',')) {
            String trimmed = part.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed);
            }
        }
        return result;
    }

    /**
     * Normalizes an SR Name to a canonical comparison key.
     */
    public static String normalizeSrKey(String name) {
        if (String.isBlank(name)) {
            return '';
        }
        String norm = name.replaceAll('[\u00A0\u2000-\u200B\u202F\u205F\u3000]', ' ')
                          .replaceAll('[\u2010-\u2015\u2212\uFE63\uFF0D]', '-')
                          .trim()
                          .toUpperCase();
        norm = norm.replaceAll('\\s*-\\s*', '-');
        norm = norm.replaceAll('\\s+', ' ');
        return norm;
    }

    /**
     * Adds name variants to a Set for querying.
     */
    public static void addNameVariants(String rawName, Set<String> nameSet) {
        if (String.isBlank(rawName) || nameSet == null) {
            return;
        }
        String cleaned = rawName.replaceAll('[\u00A0\u2000-\u200B\u202F\u205F\u3000]', ' ')
                                .replaceAll('[\u2010-\u2015\u2212\uFE63\uFF0D]', '-')
                                .trim();
        nameSet.add(rawName.trim());
        nameSet.add(cleaned);
        nameSet.add(cleaned.replaceAll('\\s*-\\s*', ' - '));
        nameSet.add(cleaned.replaceAll('\\s*-\\s*', '-'));
        nameSet.add(cleaned.replaceAll('\\s+', ''));

        Pattern p = Pattern.compile('(\\d+)');
        Matcher m = p.matcher(cleaned);
        if (m.find()) {
            String numStr = m.group(1);
            nameSet.add('SR-' + numStr);
            nameSet.add('SR - ' + numStr);
            try {
                Integer numVal = Integer.valueOf(numStr);
                nameSet.add('SR-' + numVal);
                nameSet.add('SR - ' + numVal);
            } catch (Exception ignored) {}
        }
    }

    /**
     * Checks if two SR names match, ignoring spacing around hyphens and case.
     */
    public static Boolean isSrNameMatch(String name1, String name2) {
        if (String.isBlank(name1) || String.isBlank(name2)) {
            return false;
        }
        return normalizeSrKey(name1).equals(normalizeSrKey(name2));
    }

    /**
     * Checks if a Supply Request name is referenced anywhere in an OALI's reference fields.
     */
    public static Boolean isSrReferencedInOali(Order_Allocation_Line_Item__c oali, String srName) {
        if (oali == null || String.isBlank(srName)) {
            return false;
        }
        if (String.isNotBlank(oali.Source_SR_References__c)) {
            for (String ref : parseDelimitedString(oali.Source_SR_References__c)) {
                if (isSrNameMatch(ref, srName)) return true;
            }
        }
        if (String.isNotBlank(oali.Source_SR_Allocation__c)) {
            Map<String, Decimal> aMap = parseAllocations(oali.Source_SR_Allocation__c);
            for (String ref : aMap.keySet()) {
                if (isSrNameMatch(ref, srName)) return true;
            }
        }
        if (String.isNotBlank(oali.Source_SR_Sub_Type_References__c)) {
            Map<String, String> sMap = parseSubtypeReferences(oali.Source_SR_Sub_Type_References__c);
            for (String ref : sMap.keySet()) {
                if (isSrNameMatch(ref, srName)) return true;
            }
        }
        return false;
    }

    /**
     * Indexes a Supply_Request__c into a name map under multiple keys for resilient lookup.
     */
    public static void indexSrByName(Supply_Request__c sr, Map<String, Supply_Request__c> srMap) {
        if (sr == null || String.isBlank(sr.Name) || srMap == null) {
            return;
        }
        srMap.put(sr.Name.toUpperCase(), sr);
        srMap.put(normalizeSrKey(sr.Name), sr);
    }

    /**
     * Resolves a Supply_Request__c from a name map using case-insensitive and normalized keys.
     */
    public static Supply_Request__c findSrByName(String srName, Map<String, Supply_Request__c> srMap) {
        if (String.isBlank(srName) || srMap == null) {
            return null;
        }
        String rawUpper = srName.trim().toUpperCase();
        if (srMap.containsKey(rawUpper)) {
            return srMap.get(rawUpper);
        }
        String normKey = normalizeSrKey(srName);
        if (srMap.containsKey(normKey)) {
            return srMap.get(normKey);
        }
        return null;
    }

    /**
     * Resilient fallback resolver for Supply_Request__c by name.
     * Checks in-memory cache first; if not found, performs an on-demand SOQL fallback
     * and automatically preloads any linked OALIs/POLIs so traversal does not halt.
     */
    public static Supply_Request__c findSrByNameWithFallback(
        String srName,
        Map<String, Supply_Request__c> srMap,
        Map<Id, Supply_Request__c> srByIdMap,
        Map<Id, Order_Allocation_Line_Item__c> knownOalis,
        PurchaseOrderBacktrackingService poService
    ) {
        if (String.isBlank(srName)) {
            return null;
        }

        Supply_Request__c found = findSrByName(srName, srMap);
        if (found != null) {
            return found;
        }

        // On-Demand SOQL Fallback in System Mode
        Set<String> nameVariants = new Set<String>();
        addNameVariants(srName, nameVariants);
        List<Supply_Request__c> fallbackList = Database.query(
            'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
            '       Requested_Qty__c, Received_Qty__c, Status__c, Request_Type__c, ' +
            '       Sub_Request_Type__c, Item__c, Supply_Request__c, Order_Allocation_Line_Item__c, ' +
            '       Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Account__c ' +
            'FROM Supply_Request__c ' +
            'WHERE Name IN :nameVariants ' +
            'LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );

        // If exact variants missed, fallback to numeric LIKE matching in System Mode
        if (fallbackList.isEmpty()) {
            Pattern p = Pattern.compile('(\\d+)');
            Matcher m = p.matcher(srName);
            if (m.find()) {
                String numStr = m.group(1);
                String likePattern = '%SR%' + numStr + '%';
                fallbackList = Database.query(
                    'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                    '       Requested_Qty__c, Received_Qty__c, Status__c, Request_Type__c, ' +
                    '       Sub_Request_Type__c, Item__c, Supply_Request__c, Order_Allocation_Line_Item__c, ' +
                    '       Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Account__c ' +
                    'FROM Supply_Request__c ' +
                    'WHERE Name LIKE :likePattern ' +
                    'LIMIT 5',
                    AccessLevel.SYSTEM_MODE
                );
            }
        }

        if (!fallbackList.isEmpty()) {
            found = fallbackList[0];
            if (srByIdMap != null) {
                srByIdMap.put(found.Id, found);
            }
            if (srMap != null) {
                indexSrByName(found, srMap);
            }
            System.debug(LoggingLevel.INFO, '[BACKTRACK-FALLBACK] Successfully recovered SR ' + found.Name + ' via SOQL fallback');

            // Preload linked OALI if missing from cache in System Mode
            if (knownOalis != null && found.Order_Allocation_Line_Item__c != null && !knownOalis.containsKey(found.Order_Allocation_Line_Item__c)) {
                Id oaliIdToFetch = found.Order_Allocation_Line_Item__c;
                List<Order_Allocation_Line_Item__c> newlyFoundOalis = Database.query(
                    'SELECT Id, Name, Ordered_Qty__c, Transfer_Qty_Planned__c, Transfer_Qty_Received__c, ' +
                    '       Reserved_Quantity__c, Reserved_Qty_Planned__c, Procurement_Qty_Planned__c, ' +
                    '       Procurement_Qty_Received__c, Remaining_Qty__c, Secured_Qty__c, Status__c, ' +
                    '       Supply_Request__c, Source_SR_References__c, Source_SR_Allocation__c, ' +
                    '       Source_SR_Sub_Type_References__c, Purchase_Order_Line_Item__c, Item__c, ' +
                    '       Order_Allocation__c ' +
                    'FROM Order_Allocation_Line_Item__c ' +
                    'WHERE Id = :oaliIdToFetch',
                    AccessLevel.SYSTEM_MODE
                );
                if (!newlyFoundOalis.isEmpty()) {
                    Order_Allocation_Line_Item__c nOali = newlyFoundOalis[0];
                    knownOalis.put(nOali.Id, nOali);
                    if (poService != null) {
                        poService.loadPolisByOaliIds(new Set<Id>{ nOali.Id });
                        if (nOali.Order_Allocation__c != null) {
                            poService.loadPolisByOrderAllocationIds(new Set<Id>{ nOali.Order_Allocation__c });
                        }
                    }
                }
            }
        }

        return found;
    }

    /**
     * Determines whether a Supply Request is a Transfer SR based on its Record Type.
     */
    public static Boolean isTransferSupplyRequest(Supply_Request__c sr) {
        if (sr == null) {
            return false;
        }
        if (sr.RecordType != null) {
            String devName = sr.RecordType.DeveloperName;
            String rtName = sr.RecordType.Name;
            if ('Transfer_Supply_Request'.equalsIgnoreCase(devName) ||
                'Transfer Supply Request'.equalsIgnoreCase(rtName) ||
                'Transfer SR'.equalsIgnoreCase(rtName)) {
                return true;
            }
        }
        Map<String, Schema.RecordTypeInfo> rtMap = Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName();
        if (rtMap != null && rtMap.containsKey('Transfer_Supply_Request')) {
            Id transferRtId = rtMap.get('Transfer_Supply_Request').getRecordTypeId();
            if (transferRtId != null && sr.RecordTypeId == transferRtId) {
                return true;
            }
        }
        if (String.isNotBlank(sr.Request_Type__c) && 
            ('Transfer SR'.equalsIgnoreCase(sr.Request_Type__c.trim()) || 'Transfer'.equalsIgnoreCase(sr.Request_Type__c.trim()))) {
            return true;
        }
        return false;
    }

    /**
     * Determines whether a Supply Request is a Procurement SR based on its Record Type.
     */
    public static Boolean isProcurementSupplyRequest(Supply_Request__c sr) {
        if (sr == null) {
            return false;
        }
        if (sr.RecordType != null) {
            String devName = sr.RecordType.DeveloperName;
            String rtName = sr.RecordType.Name;
            if ('Purchase_Supply_Request'.equalsIgnoreCase(devName) ||
                'Purchase Supply Request'.equalsIgnoreCase(rtName) ||
                'Purchase SR'.equalsIgnoreCase(rtName)) {
                return true;
            }
        }
        Map<String, Schema.RecordTypeInfo> rtMap = Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName();
        if (rtMap != null && rtMap.containsKey('Purchase_Supply_Request')) {
            Id purchaseRtId = rtMap.get('Purchase_Supply_Request').getRecordTypeId();
            if (purchaseRtId != null && sr.RecordTypeId == purchaseRtId) {
                return true;
            }
        }
        if (String.isNotBlank(sr.Request_Type__c) && 
            ('Purchase SR'.equalsIgnoreCase(sr.Request_Type__c.trim()) || 'Purchase'.equalsIgnoreCase(sr.Request_Type__c.trim()))) {
            return true;
        }
        return false;
    }

    /**
     * Determines OALI Delivery Status based on ordered quantity and total secured/received quantity.
     */
    public static String determineDeliveryStatus(Decimal orderedQty, Decimal totalReceived, String currentStatus) {
        if (orderedQty == null || orderedQty <= 0) {
            return currentStatus;
        }
        Decimal rec = (totalReceived != null && totalReceived > 0) ? totalReceived : 0;
        if (rec >= orderedQty) {
            return 'Delivered';
        } else if (rec > 0) {
            return 'Partially Delivered';
        }
        return currentStatus;
    }

    /**
     * Determines OALI Shipment Status based on ordered quantity and cumulative shipped quantity.
     */
    public static String determineShipmentStatus(Decimal orderedQty, Decimal cumulativeShipped, String currentStatus) {
        if (orderedQty == null || orderedQty <= 0) {
            return currentStatus;
        }
        Decimal shipped = (cumulativeShipped != null && cumulativeShipped > 0) ? cumulativeShipped : 0;
        if (shipped >= orderedQty) {
            return 'Shipped';
        } else if (shipped > 0) {
            return 'Partially Shipped';
        }
        return currentStatus;
    }

    /**
     * Ensures community users have Edit access to parent Order_Allocation__c records
     * by inserting Order_Allocation__Share records when needed.
     */
    public static void ensureParentOaAccess(List<Order_Allocation_Line_Item__c> oalis) {
        if (oalis == null || oalis.isEmpty()) {
            return;
        }
        Set<Id> oaIds = new Set<Id>();
        for (Order_Allocation_Line_Item__c oali : oalis) {
            try {
                if (oali.isSet('Order_Allocation__c') && oali.Order_Allocation__c != null) {
                    oaIds.add(oali.Order_Allocation__c);
                }
            } catch (Exception ex) {
                // If field was not queried on this SObject instance, ignore
            }
        }
        if (oaIds.isEmpty()) {
            return;
        }

        Id currentUserId = UserInfo.getUserId();
        List<SObject> sharesToInsert = new List<SObject>();
        try {
            Schema.SObjectType shareType = Schema.getGlobalDescribe().get('Order_Allocation__Share');
            if (shareType != null) {
                for (Id oaId : oaIds) {
                    SObject share = shareType.newSObject();
                    share.put('ParentId', oaId);
                    share.put('UserOrGroupId', currentUserId);
                    share.put('AccessLevel', 'Edit');
                    share.put('RowCause', 'Manual');
                    sharesToInsert.add(share);
                }
                if (!sharesToInsert.isEmpty()) {
                    Database.insert(sharesToInsert, false);
                }
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.FINE, '[InventoryTransferBacktrackingService] Non-critical share error: ' + ex.getMessage());
        }
    }

    /**
     * Checks if an Inventory Transfer is fulfilling a specific Supply Request by matching parties.
     */
    public static Boolean isTransferFulfillingSr(Inventory_Transfer__c transfer, Supply_Request__c sr) {
        if (transfer == null || sr == null) {
            return false;
        }
        Boolean partiesMatch = (transfer.From_Account__c != null && sr.Supplying_Account__c != null && transfer.From_Account__c == sr.Supplying_Account__c)
            && (transfer.To_Account__c != null && sr.Requesting_Account__c != null && transfer.To_Account__c == sr.Requesting_Account__c);
        return partiesMatch;
    }
}