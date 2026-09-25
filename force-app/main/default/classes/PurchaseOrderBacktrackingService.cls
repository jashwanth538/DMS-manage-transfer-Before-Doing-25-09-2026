/**
 * @description Centralized, bulk-safe backtracking service for Purchase Order Line Items (POLI) and Purchase Orders (PO).
 *              Encapsulates all POLI and PO header queries, calculations, receipt accumulations, and system-mode bulk DML.
 *              Guarantees that:
 *              - Supports multi-path POLI discovery:
 *                1. Forward lookup: OALI.Purchase_Order_Line_Item__c (root demand PO/POLI)
 *                2. Reverse lookup: POLI.Sales_Allocation_Line_Item__c (sub-sourcing leg PO/POLI created under intermediate suppliers)
 *                3. Header correlation: POLI.Purchase_Order__r.Sales_Allocation__c matched with OALI.Order_Allocation__c and Item__c
 *              - Multiple receipt rollups in the same transaction accumulate cleanly without overwriting.
 *              - Status transitions ('Open', 'Partially Received', 'Fully Received') are accurately calculated on both POLI and parent PO headers.
 *              - Thin payload updates are performed under AccessLevel.SYSTEM_MODE to prevent FLS/CRUD issues.
 *              - Graceful recovery when an OALI has a stale/deleted POLI ID by falling back to reverse/header correlations.
 *              - All updates are logged with the standardized '[BACKTRACK-POLI]' and '[BACKTRACK-PO]' prefixes for auditability.
 */
public without sharing class PurchaseOrderBacktrackingService {

    // Internal cache of loaded Purchase Order Line Items keyed by Id
    private Map<Id, Purchase_Order_Line_Item__c> poliCache;

    // Mapping from OALI Id to list of reverse-linked POLIs where POLI.Sales_Allocation_Line_Item__c == OALI.Id
    private Map<Id, List<Purchase_Order_Line_Item__c>> polisByOaliId;

    // Mapping from Order_Allocation__c Id to list of POLIs under POs tied to that Order Allocation
    private Map<Id, List<Purchase_Order_Line_Item__c>> polisByOaId;

    // Track dirty POLI records to be committed in bulk
    private Map<Id, Purchase_Order_Line_Item__c> dirtyPolis;

    /**
     * Constructor initializing internal caches.
     */
    public PurchaseOrderBacktrackingService() {
        this.poliCache = new Map<Id, Purchase_Order_Line_Item__c>();
        this.polisByOaliId = new Map<Id, List<Purchase_Order_Line_Item__c>>();
        this.polisByOaId = new Map<Id, List<Purchase_Order_Line_Item__c>>();
        this.dirtyPolis = new Map<Id, Purchase_Order_Line_Item__c>();
    }

    /**
     * Pre-loads Purchase Order Line Items into the internal cache in bulk by POLI IDs.
     * Only queries records not already present in the cache.
     *
     * @param poliIds Set of Purchase_Order_Line_Item__c IDs to fetch
     */
    public void loadPolis(Set<Id> poliIds) {
        if (poliIds == null || poliIds.isEmpty()) {
            return;
        }

        Set<Id> idsToQuery = new Set<Id>();
        for (Id pId : poliIds) {
            if (pId != null && !this.poliCache.containsKey(pId)) {
                idsToQuery.add(pId);
            }
        }

        if (idsToQuery.isEmpty()) {
            return;
        }

        List<Purchase_Order_Line_Item__c> loadedPolis = Database.query(
            'SELECT Id, Purchase_Order__c, Sales_Allocation_Line_Item__c, ' +
            '       Item__c, Ordered_Qty__c, Received_Qty__c, Status__c, ' +
            '       Purchase_Order__r.Sales_Allocation__c, ' +
            '       Purchase_Order__r.Supplying_Account__c, Purchase_Order__r.Requesting_Account__c, ' +
            '       Purchase_Order__r.Source_Location__c, Purchase_Order__r.Target_Location__c ' +
            'FROM Purchase_Order_Line_Item__c ' +
            'WHERE Id IN :idsToQuery',
            AccessLevel.SYSTEM_MODE
        );
        for (Purchase_Order_Line_Item__c poli : loadedPolis) {
            cachePoli(poli);
        }
    }

    /**
     * Pre-loads reverse-lookup Purchase Order Line Items by related Order Allocation Line Item IDs.
     * Finds POLIs where Sales_Allocation_Line_Item__c IN :oaliIds.
     *
     * @param oaliIds Set of Order_Allocation_Line_Item__c IDs
     */
    public void loadPolisByOaliIds(Set<Id> oaliIds) {
        if (oaliIds == null || oaliIds.isEmpty()) {
            return;
        }

        List<Purchase_Order_Line_Item__c> loadedPolis = Database.query(
            'SELECT Id, Purchase_Order__c, Sales_Allocation_Line_Item__c, ' +
            '       Item__c, Ordered_Qty__c, Received_Qty__c, Status__c, ' +
            '       Purchase_Order__r.Sales_Allocation__c, ' +
            '       Purchase_Order__r.Supplying_Account__c, Purchase_Order__r.Requesting_Account__c, ' +
            '       Purchase_Order__r.Source_Location__c, Purchase_Order__r.Target_Location__c ' +
            'FROM Purchase_Order_Line_Item__c ' +
            'WHERE Sales_Allocation_Line_Item__c IN :oaliIds',
            AccessLevel.SYSTEM_MODE
        );
        for (Purchase_Order_Line_Item__c poli : loadedPolis) {
            cachePoli(poli);
        }
    }

    /**
     * Pre-loads Purchase Order Line Items tied to Order Allocation headers.
     * Finds POLIs where Purchase_Order__r.Sales_Allocation__c IN :oaIds or
     * Sales_Allocation_Line_Item__r.Order_Allocation__c IN :oaIds.
     *
     * @param oaIds Set of Order_Allocation__c IDs
     */
    public void loadPolisByOrderAllocationIds(Set<Id> oaIds) {
        if (oaIds == null || oaIds.isEmpty()) {
            return;
        }

        List<Purchase_Order_Line_Item__c> loadedPolis = Database.query(
            'SELECT Id, Purchase_Order__c, Sales_Allocation_Line_Item__c, ' +
            '       Item__c, Ordered_Qty__c, Received_Qty__c, Status__c, ' +
            '       Purchase_Order__r.Sales_Allocation__c, ' +
            '       Purchase_Order__r.Supplying_Account__c, Purchase_Order__r.Requesting_Account__c, ' +
            '       Purchase_Order__r.Source_Location__c, Purchase_Order__r.Target_Location__c ' +
            'FROM Purchase_Order_Line_Item__c ' +
            'WHERE Purchase_Order__r.Sales_Allocation__c IN :oaIds ' +
            '   OR Sales_Allocation_Line_Item__r.Order_Allocation__c IN :oaIds',
            AccessLevel.SYSTEM_MODE
        );
        for (Purchase_Order_Line_Item__c poli : loadedPolis) {
            cachePoli(poli);
        }
    }

    /**
     * Internal helper to index a POLI into all internal lookup caches cleanly.
     */
    private void cachePoli(Purchase_Order_Line_Item__c poli) {
        if (poli == null || poli.Id == null) {
            return;
        }
        this.poliCache.put(poli.Id, poli);

        // Index by OALI Id
        if (poli.Sales_Allocation_Line_Item__c != null) {
            if (!this.polisByOaliId.containsKey(poli.Sales_Allocation_Line_Item__c)) {
                this.polisByOaliId.put(poli.Sales_Allocation_Line_Item__c, new List<Purchase_Order_Line_Item__c>());
            }
            Boolean found = false;
            for (Purchase_Order_Line_Item__c existing : this.polisByOaliId.get(poli.Sales_Allocation_Line_Item__c)) {
                if (existing.Id == poli.Id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                this.polisByOaliId.get(poli.Sales_Allocation_Line_Item__c).add(poli);
            }
        }

        // Index by Order Allocation Id
        if (poli.Purchase_Order__r != null && poli.Purchase_Order__r.Sales_Allocation__c != null) {
            Id oaId = poli.Purchase_Order__r.Sales_Allocation__c;
            if (!this.polisByOaId.containsKey(oaId)) {
                this.polisByOaId.put(oaId, new List<Purchase_Order_Line_Item__c>());
            }
            Boolean found = false;
            for (Purchase_Order_Line_Item__c existing : this.polisByOaId.get(oaId)) {
                if (existing.Id == poli.Id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                this.polisByOaId.get(oaId).add(poli);
            }
        }
    }

    /**
     * Records an incremental received quantity against a Purchase Order Line Item by Id.
     * Automatically handles in-memory accumulation across multiple calls for the same record.
     * If the POLI is not pre-loaded, it loads it on demand.
     *
     * @param poliId Id of the Purchase_Order_Line_Item__c
     * @param qtyReceived Decimal quantity received to accumulate
     * @return Boolean true if receipt was successfully recorded, false otherwise
     */
    public Boolean recordPoliReceipt(Id poliId, Decimal qtyReceived) {
        if (poliId == null || qtyReceived == null || qtyReceived <= 0) {
            return false;
        }

        if (!this.poliCache.containsKey(poliId)) {
            loadPolis(new Set<Id>{ poliId });
        }

        Purchase_Order_Line_Item__c poli = this.poliCache.get(poliId);
        if (poli == null) {
            System.debug(LoggingLevel.WARN, '[BACKTRACK-POLI] Skipping: POLI record not found in database for Id ' + poliId);
            return false;
        }

        Decimal currentRec = poli.Received_Qty__c != null ? poli.Received_Qty__c : 0;
        Decimal ordered = poli.Ordered_Qty__c != null ? poli.Ordered_Qty__c : 0;

        Decimal remaining = ordered > 0 ? Math.max(0, ordered - currentRec) : qtyReceived;
        Decimal alloc = ordered > 0 ? Math.min(qtyReceived, remaining) : qtyReceived;

        Decimal newRec = currentRec + alloc;
        poli.Received_Qty__c = newRec;

        if (newRec <= 0) {
            poli.Status__c = 'Open';
        } else if (ordered > 0 && newRec >= ordered) {
            poli.Status__c = 'Fully Received';
        } else {
            poli.Status__c = 'Partially Received';
        }

        this.dirtyPolis.put(poli.Id, poli);

        System.debug(LoggingLevel.INFO, '[BACKTRACK-POLI] POLI ' + poli.Id + 
            ' | PO ' + poli.Purchase_Order__c +
            ' | Previous Received = ' + currentRec + 
            ' | Added = ' + alloc + 
            ' (Requested = ' + qtyReceived + ')' +
            ' | New Received = ' + poli.Received_Qty__c + 
            ' | Ordered = ' + ordered + 
            ' | Status = ' + poli.Status__c);
        return true;
    }

    /**
     * Overloaded context-aware POLI receipt recorder accepting an Order_Allocation_Line_Item__c record.
     * Evaluates:
     * 1. Direct lookup on OALI.Purchase_Order_Line_Item__c.
     * 2. Reverse lookup on POLIs where POLI.Sales_Allocation_Line_Item__c == oali.Id.
     * 3. Header lookup on POLIs where PO.Sales_Allocation__c == oali.Order_Allocation__c matching Item__c.
     *
     * @param oali Order_Allocation_Line_Item__c record
     * @param qtyReceived Decimal quantity received to accumulate
     * @param supplyingAccountId Supplying account from the transfer or supply request (optional)
     */
    public void recordPoliReceiptForOali(
        Order_Allocation_Line_Item__c oali,
        Decimal qtyReceived,
        Id supplyingAccountId
    ) {
        if (oali == null || qtyReceived == null || qtyReceived <= 0) {
            return;
        }

        Boolean directSuccess = false;
        Set<Id> updatedPoliIds = new Set<Id>();

        // 1. Direct POLI lookup on OALI
        if (oali.Purchase_Order_Line_Item__c != null) {
            directSuccess = recordPoliReceipt(oali.Purchase_Order_Line_Item__c, qtyReceived);
            if (directSuccess) {
                updatedPoliIds.add(oali.Purchase_Order_Line_Item__c);
            }
        }

        // 2. Reverse lookup POLIs where POLI.Sales_Allocation_Line_Item__c == oali.Id
        if (this.polisByOaliId.containsKey(oali.Id)) {
            List<Purchase_Order_Line_Item__c> subPolis = this.polisByOaliId.get(oali.Id);
            for (Purchase_Order_Line_Item__c subPoli : subPolis) {
                if (updatedPoliIds.contains(subPoli.Id)) {
                    continue;
                }

                Boolean isMatch = true;
                if (supplyingAccountId != null && subPoli.Purchase_Order__r != null && subPoli.Purchase_Order__r.Supplying_Account__c != null) {
                    isMatch = (subPoli.Purchase_Order__r.Supplying_Account__c == supplyingAccountId);
                }

                if (isMatch) {
                    if (recordPoliReceipt(subPoli.Id, qtyReceived)) {
                        updatedPoliIds.add(subPoli.Id);
                    }
                }
            }
        }

        // 3. Header correlation lookup via PO.Sales_Allocation__c and Item__c
        if (oali.Order_Allocation__c != null && this.polisByOaId.containsKey(oali.Order_Allocation__c)) {
            List<Purchase_Order_Line_Item__c> oaPolis = this.polisByOaId.get(oali.Order_Allocation__c);
            for (Purchase_Order_Line_Item__c oaPoli : oaPolis) {
                if (updatedPoliIds.contains(oaPoli.Id)) {
                    continue;
                }

                Boolean itemMatches = (oali.Item__c != null && oaPoli.Item__c != null && oali.Item__c == oaPoli.Item__c);
                if (!itemMatches && oali.Item__c != null && oaPoli.Item__c == null) {
                    itemMatches = true;
                }

                if (itemMatches) {
                    Boolean isMatch = true;
                    if (supplyingAccountId != null && oaPoli.Purchase_Order__r != null && oaPoli.Purchase_Order__r.Supplying_Account__c != null) {
                        isMatch = (oaPoli.Purchase_Order__r.Supplying_Account__c == supplyingAccountId);
                    }

                    if (isMatch) {
                        if (recordPoliReceipt(oaPoli.Id, qtyReceived)) {
                            updatedPoliIds.add(oaPoli.Id);
                        }
                    }
                }
            }

            // Fallback for full-chain/drop-shipment delivery if no account-filtered POLI was updated
            if (updatedPoliIds.isEmpty()) {
                for (Purchase_Order_Line_Item__c oaPoli : oaPolis) {
                    if (updatedPoliIds.contains(oaPoli.Id)) {
                        continue;
                    }
                    Boolean itemMatches = (oali.Item__c != null && oaPoli.Item__c != null && oali.Item__c == oaPoli.Item__c);
                    if (itemMatches) {
                        if (recordPoliReceipt(oaPoli.Id, qtyReceived)) {
                            updatedPoliIds.add(oaPoli.Id);
                        }
                    }
                }
            }
        }
    }

    /**
     * Context-aware POLI receipt recorder by IDs (backward compatibility).
     *
     * @param oaliId Id of the Order_Allocation_Line_Item__c
     * @param directPoliId Primary POLI Id from oali.Purchase_Order_Line_Item__c (optional)
     * @param qtyReceived Decimal quantity received to accumulate
     * @param supplyingAccountId Supplying account from the transfer or supply request (optional)
     */
    public void recordPoliReceiptForOali(
        Id oaliId,
        Id directPoliId,
        Decimal qtyReceived,
        Id supplyingAccountId
    ) {
        if (qtyReceived == null || qtyReceived <= 0) {
            return;
        }

        Set<Id> updatedPoliIds = new Set<Id>();

        // 1. Direct POLI lookup
        if (directPoliId != null) {
            if (recordPoliReceipt(directPoliId, qtyReceived)) {
                updatedPoliIds.add(directPoliId);
            }
        }

        // 2. Reverse lookup POLIs where POLI.Sales_Allocation_Line_Item__c == oaliId
        if (oaliId != null && this.polisByOaliId.containsKey(oaliId)) {
            List<Purchase_Order_Line_Item__c> subPolis = this.polisByOaliId.get(oaliId);
            for (Purchase_Order_Line_Item__c subPoli : subPolis) {
                if (updatedPoliIds.contains(subPoli.Id)) {
                    continue;
                }

                Boolean isMatch = true;
                if (supplyingAccountId != null && subPoli.Purchase_Order__r != null && subPoli.Purchase_Order__r.Supplying_Account__c != null) {
                    isMatch = (subPoli.Purchase_Order__r.Supplying_Account__c == supplyingAccountId);
                }

                if (isMatch) {
                    if (recordPoliReceipt(subPoli.Id, qtyReceived)) {
                        updatedPoliIds.add(subPoli.Id);
                    }
                }
            }
        }
    }

    /**
     * Bulk convenience method to record receipts for multiple POLIs at once.
     *
     * @param qtyByPoliId Map of POLI Id to incremental quantity received
     */
    public void recordPoliReceipts(Map<Id, Decimal> qtyByPoliId) {
        if (qtyByPoliId == null || qtyByPoliId.isEmpty()) {
            return;
        }

        loadPolis(qtyByPoliId.keySet());

        for (Id poliId : qtyByPoliId.keySet()) {
            recordPoliReceipt(poliId, qtyByPoliId.get(poliId));
        }
    }

    /**
     * Commits all accumulated POLI updates in bulk using thin-payload DML under System Mode.
     * Also recalculates and updates the parent Purchase_Order__c header status in lockstep.
     *
     * @return Integer number of records updated
     */
    public Integer commitPoliUpdates() {
        if (this.dirtyPolis.isEmpty()) {
            return 0;
        }

        List<Purchase_Order_Line_Item__c> cleanPoliUpdates = new List<Purchase_Order_Line_Item__c>();
        Set<Id> parentPoIds = new Set<Id>();

        for (Purchase_Order_Line_Item__c poli : this.dirtyPolis.values()) {
            cleanPoliUpdates.add(new Purchase_Order_Line_Item__c(
                Id = poli.Id,
                Received_Qty__c = poli.Received_Qty__c,
                Status__c = poli.Status__c
            ));
            if (poli.Purchase_Order__c != null) {
                parentPoIds.add(poli.Purchase_Order__c);
            }
        }

        List<Database.SaveResult> poliResults = Database.update(cleanPoliUpdates, false, AccessLevel.SYSTEM_MODE);
        Integer successCount = 0;
        for (Database.SaveResult sr : poliResults) {
            if (sr.isSuccess()) {
                successCount++;
            } else {
                for (Database.Error err : sr.getErrors()) {
                    System.debug(LoggingLevel.WARN, '[BACKTRACK-POLI] POLI ' + sr.getId() + ' update warning: ' + err.getStatusCode() + ' - ' + err.getMessage());
                }
            }
        }

        System.debug(LoggingLevel.INFO, '[BACKTRACK-POLI] Committed ' + successCount + ' of ' + cleanPoliUpdates.size() + ' POLI update(s)');
        this.dirtyPolis.clear();

        // Roll up status to parent Purchase Order headers
        if (!parentPoIds.isEmpty()) {
            commitPurchaseOrderHeaderUpdates(parentPoIds);
        }

        return successCount;
    }

    /**
     * Recalculates and updates parent Purchase Order headers based on sister line item statuses.
     *
     * @param poIds Set of Purchase_Order__c IDs to evaluate
     */
    private void commitPurchaseOrderHeaderUpdates(Set<Id> poIds) {
        if (poIds == null || poIds.isEmpty()) {
            return;
        }

        // Query all sister line items under these POs in System Mode
        List<Purchase_Order_Line_Item__c> allSisterPolis = Database.query(
            'SELECT Id, Purchase_Order__c, Ordered_Qty__c, Received_Qty__c, Status__c ' +
            'FROM Purchase_Order_Line_Item__c ' +
            'WHERE Purchase_Order__c IN :poIds',
            AccessLevel.SYSTEM_MODE
        );

        Map<Id, List<Purchase_Order_Line_Item__c>> polisByPoId = new Map<Id, List<Purchase_Order_Line_Item__c>>();
        for (Purchase_Order_Line_Item__c poli : allSisterPolis) {
            if (!polisByPoId.containsKey(poli.Purchase_Order__c)) {
                polisByPoId.put(poli.Purchase_Order__c, new List<Purchase_Order_Line_Item__c>());
            }
            // Use in-memory updated version if present in cache
            if (this.poliCache.containsKey(poli.Id)) {
                polisByPoId.get(poli.Purchase_Order__c).add(this.poliCache.get(poli.Id));
            } else {
                polisByPoId.get(poli.Purchase_Order__c).add(poli);
            }
        }

        List<Purchase_Order__c> poUpdates = new List<Purchase_Order__c>();
        for (Id poId : poIds) {
            List<Purchase_Order_Line_Item__c> lines = polisByPoId.get(poId);
            if (lines == null || lines.isEmpty()) {
                continue;
            }

            Boolean allFullyReceived = true;
            Boolean anyReceived = false;

            for (Purchase_Order_Line_Item__c line : lines) {
                Decimal ord = line.Ordered_Qty__c != null ? line.Ordered_Qty__c : 0;
                Decimal rec = line.Received_Qty__c != null ? line.Received_Qty__c : 0;

                if (rec > 0) {
                    anyReceived = true;
                }
                if (ord > 0 && rec < ord) {
                    allFullyReceived = false;
                }
            }

            String calculatedStatus = 'Draft';
            if (allFullyReceived) {
                calculatedStatus = 'Fully Received';
            } else if (anyReceived) {
                calculatedStatus = 'Partially Received';
            }

            poUpdates.add(new Purchase_Order__c(
                Id = poId,
                Status__c = calculatedStatus
            ));

            System.debug(LoggingLevel.INFO, '[BACKTRACK-PO] PO ' + poId + ' status evaluated: ' + calculatedStatus + 
                ' (allFullyReceived=' + allFullyReceived + ', anyReceived=' + anyReceived + ')');
        }

        if (!poUpdates.isEmpty()) {
            List<Database.SaveResult> poResults = Database.update(poUpdates, false, AccessLevel.SYSTEM_MODE);
            for (Database.SaveResult sr : poResults) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        System.debug(LoggingLevel.WARN, '[BACKTRACK-PO] PO ' + sr.getId() + ' update warning: ' + err.getStatusCode() + ' - ' + err.getMessage());
                    }
                }
            }
            System.debug(LoggingLevel.INFO, '[BACKTRACK-PO] Committed ' + poUpdates.size() + ' Purchase Order header update(s)');
        }
    }

    /**
     * Returns whether there are uncommitted POLI updates pending.
     */
    public Boolean hasPendingUpdates() {
        return !this.dirtyPolis.isEmpty();
    }
}