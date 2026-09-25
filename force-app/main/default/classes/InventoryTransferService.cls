public without sharing class InventoryTransferService {
    /**
     * Creates Inventory_Transfer__c records for eligible Order Allocation Line Items.
     * Enforces bulk safety and duplicate prevention.
     *
     * @param oaliIds Set of Order_Allocation_Line_Item__c record IDs
     */
    public static void createInventoryTransfersForOALIs(Set<Id> oaliIds) {
        if (oaliIds == null || oaliIds.isEmpty()) {
            return;
        }

        // 1. Bulk query OALI records and parent Order Allocation details
        List<Order_Allocation_Line_Item__c> oaliList = [
            SELECT Id,
                   Item__c,
                   Ordered_Qty__c,
                   Transfer_Qty_Planned__c,
                   Transfer_Qty_Received__c,
                   Procurement_Qty_Planned__c,
                   Procurement_Qty_Received__c,
                   Reserved_Quantity__c,
                   Reserved_Qty_Planned__c,
                   Remaining_Qty__c,
                   Secured_Qty__c,
                   Supply_Request__c,
                   Source_SR_References__c,
                   Source_SR_Allocation__c,
                   Status__c,
                   Order_Allocation__c,
                   Order_Allocation__r.Supplying_Account__c,
                   Order_Allocation__r.Supplying_Account__r.RecordType.DeveloperName,
                   Order_Allocation__r.Supplying_Account__r.RecordType.Name,
                   Order_Allocation__r.Requesting_Account__c,
                   Order_Allocation__r.Requesting_Account__r.RecordType.DeveloperName,
                   Order_Allocation__r.Requesting_Account__r.RecordType.Name,
                   Order_Allocation__r.Customer__c,
                   Order_Allocation__r.Source_Location__c,
                   Order_Allocation__r.Target_Location__c
            FROM Order_Allocation_Line_Item__c
            WHERE Id IN :oaliIds
        ];

        if (oaliList.isEmpty()) {
            return;
        }

        // Process all OALIs (retailer exclusion commented out so transfers are created for all accounts)
        processNonRetailerOALIs(oaliList, oaliIds);
        /*
        // Filter out OALIs where OA Supplying Account or Requesting Account record type is Retailer
        List<Order_Allocation_Line_Item__c> nonRetailerOalis = new List<Order_Allocation_Line_Item__c>();
        for (Order_Allocation_Line_Item__c oali : oaliList) {
            if (!isRetailerAccount(oali)) {
                nonRetailerOalis.add(oali);
            }
        }

        if (!nonRetailerOalis.isEmpty()) {
            processNonRetailerOALIs(nonRetailerOalis, oaliIds);
        }
        */
    }

    /**
     * Checks whether the parent Order Allocation has a Retailer Supplying Account.
     * If Supplying Account is Retailer, no Inventory Transfer should be created.
     * If Supplying Account is Dealer/Distributor and Requesting Account is Retailer, transfer is created.
     *
     * @param oali Order_Allocation_Line_Item__c record
     * @return Boolean true only if Supplying Account is Retailer
     */
    @TestVisible
    private static Boolean isRetailerAccount(Order_Allocation_Line_Item__c oali) {
        if (oali == null || oali.Order_Allocation__r == null) {
            return false;
        }

        // Only check Supplying Account RecordType (e.g. Kumar Traders(Retailer))
        if (oali.Order_Allocation__r.Supplying_Account__r != null && 
            oali.Order_Allocation__r.Supplying_Account__r.RecordType != null) {
            String supDevName = oali.Order_Allocation__r.Supplying_Account__r.RecordType.DeveloperName;
            String supName = oali.Order_Allocation__r.Supplying_Account__r.RecordType.Name;
            if ('Retailer'.equalsIgnoreCase(supDevName) || 'Retailer'.equalsIgnoreCase(supName)) {
                return true;
            }
        }

        return false;
    }

    @TestVisible
    private static Boolean isRetailerRequestingAccount(Order_Allocation_Line_Item__c oali) {
        if (oali == null || oali.Order_Allocation__r == null) {
            return false;
        }

        if (oali.Order_Allocation__r.Requesting_Account__r != null && 
            oali.Order_Allocation__r.Requesting_Account__r.RecordType != null) {
            String reqDevName = oali.Order_Allocation__r.Requesting_Account__r.RecordType.DeveloperName;
            String reqName = oali.Order_Allocation__r.Requesting_Account__r.RecordType.Name;
            if ('Retailer'.equalsIgnoreCase(reqDevName) || 'Retailer'.equalsIgnoreCase(reqName)) {
                return true;
            }
        }

        return false;
    }

    /*
    // =========================================================================
    // [COMMENTED OUT] RETAILER SPECIFIC PROCESSING METHODS
    // =========================================================================
    / **
     * Handles Retailer OALIs:
     * - Deducts quantity directly from the Retailer's Available bin.
     * - Sets OALI Status__c to 'Shipped'.
     * /
    private static void processRetailerOALIs(List<Order_Allocation_Line_Item__c> retailerOalis) {
        Set<Id> itemIds = new Set<Id>();
        Set<Id> locationIds = new Set<Id>();

        for (Order_Allocation_Line_Item__c oali : retailerOalis) {
            if (oali.Item__c != null) {
                itemIds.add(oali.Item__c);
            }
            if (oali.Order_Allocation__r != null) {
                Id locId = oali.Order_Allocation__r.Source_Location__c != null 
                    ? oali.Order_Allocation__r.Source_Location__c 
                    : oali.Order_Allocation__r.Target_Location__c;
                if (locId != null) {
                    locationIds.add(locId);
                }
            }
        }

        List<Inventory__c> existingInvs = [
            SELECT Id, Item__c, Inventory_Location__c, Available__c
            FROM Inventory__c
            WHERE Item__c IN :itemIds AND Inventory_Location__c IN :locationIds
        ];

        Map<String, Inventory__c> invMap = new Map<String, Inventory__c>();
        for (Inventory__c inv : existingInvs) {
            invMap.put(inv.Item__c + '_' + inv.Inventory_Location__c, inv);
        }

        List<Inventory__c> invsToUpsert = new List<Inventory__c>();
        List<Order_Allocation_Line_Item__c> oalisToUpdate = new List<Order_Allocation_Line_Item__c>();

        for (Order_Allocation_Line_Item__c oali : retailerOalis) {
            Decimal qty = deriveTransferQuantity(oali);
            Id locId = oali.Order_Allocation__r != null 
                ? (oali.Order_Allocation__r.Source_Location__c != null 
                    ? oali.Order_Allocation__r.Source_Location__c 
                    : oali.Order_Allocation__r.Target_Location__c)
                : null;

            if (oali.Item__c != null && locId != null) {
                String key = oali.Item__c + '_' + locId;
                Inventory__c inv = invMap.get(key);
                if (inv != null) {
                    inv.Available__c = Math.max(0, (inv.Available__c != null ? inv.Available__c : 0) - qty);
                    invsToUpsert.add(inv);
                } else {
                    inv = new Inventory__c(
                        Item__c = oali.Item__c,
                        Inventory_Location__c = locId,
                        Available__c = 0
                    );
                    invMap.put(key, inv);
                    invsToUpsert.add(inv);
                }
            }

            // Update OALI status directly to 'Shipped'
            oalisToUpdate.add(new Order_Allocation_Line_Item__c(
                Id = oali.Id,
                Status__c = 'Shipped'
            ));
        }

        if (!invsToUpsert.isEmpty()) {
            upsert invsToUpsert;
        }

        if (!oalisToUpdate.isEmpty()) {
            update oalisToUpdate;
        }
    }

    private static Boolean isRetailerAccount(Order_Allocation_Line_Item__c oali) {
        if (oali.Order_Allocation__r != null && oali.Order_Allocation__r.Supplying_Account__r != null) {
            String recordTypeDevName = oali.Order_Allocation__r.Supplying_Account__r.RecordType != null 
                ? oali.Order_Allocation__r.Supplying_Account__r.RecordType.DeveloperName 
                : null;
            String recordTypeName = oali.Order_Allocation__r.Supplying_Account__r.RecordType != null 
                ? oali.Order_Allocation__r.Supplying_Account__r.RecordType.Name 
                : null;

            if ('Retailer'.equalsIgnoreCase(recordTypeDevName) || 'Retailer'.equalsIgnoreCase(recordTypeName)) {
                return true;
            }
        }
        return false;
    }
    */

    /**
     * Generates Inventory_Transfer__c in 'Requested' status for eligible OALIs.
     * Supports multiple partial fulfillment transfers for the same OALI.
     * Calculates remaining eligible quantity by subtracting already planned/transferred customer quantities.
     * Backtracks to the Original/Main Supply Request to resolve final destination (To Account / Target Location).
     */
    private static void processNonRetailerOALIs(
        List<Order_Allocation_Line_Item__c> oaliList,
        Set<Id> oaliIds
    ) {
        // Query existing non-cancelled Inventory_Transfer__c records to track already created customer transfers
        Map<Id, List<Inventory_Transfer__c>> existingTransfersByOaliId = new Map<Id, List<Inventory_Transfer__c>>();
        for (Inventory_Transfer__c existingTransfer : [
            SELECT Id,
                   Order_Allocation_Line_Item__c,
                   Transfer_Qty__c,
                   Status__c,
                   From_Account__c,
                   To_Account__c,
                   Request_Type__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c IN :oaliIds
              AND Status__c != 'Cancelled'
        ]) {
            if (existingTransfer.Order_Allocation_Line_Item__c != null) {
                if (!existingTransfersByOaliId.containsKey(existingTransfer.Order_Allocation_Line_Item__c)) {
                    existingTransfersByOaliId.put(existingTransfer.Order_Allocation_Line_Item__c, new List<Inventory_Transfer__c>());
                }
                existingTransfersByOaliId.get(existingTransfer.Order_Allocation_Line_Item__c).add(existingTransfer);
            }
        }

        // Trace and resolve Original Supply Request for all OALIs in this batch
        Map<Id, Supply_Request__c> originalSrByOaliId = resolveOriginalSupplyRequestsForOALIs(oaliList);

        List<Inventory_Transfer__c> transfersToInsert = new List<Inventory_Transfer__c>();

        for (Order_Allocation_Line_Item__c oali : oaliList) {
            Id supplyingAccId = (oali.Order_Allocation__r != null) ? oali.Order_Allocation__r.Supplying_Account__c : null;
            
            // Resolve final destination account and location from the Original SR if available
            Supply_Request__c origSr = originalSrByOaliId.get(oali.Id);
            Id toAccountId = null;
            Id destLocationId = null;

            if (origSr != null) {
                toAccountId = origSr.Requesting_Account__c;
                destLocationId = origSr.Target_Location__c;
            }

            // Fallback to immediate Order Allocation destination if no Original SR exists
            if (toAccountId == null && oali.Order_Allocation__r != null) {
                toAccountId = (oali.Order_Allocation__r.Requesting_Account__c != null 
                    ? oali.Order_Allocation__r.Requesting_Account__c 
                    : oali.Order_Allocation__r.Customer__c);
            }
            if (destLocationId == null && oali.Order_Allocation__r != null) {
                destLocationId = oali.Order_Allocation__r.Target_Location__c;
            }

            // Calculate customer fulfillment transfer quantity already created for this OALI
            Decimal alreadyCreatedTransferQty = 0;
            if (existingTransfersByOaliId.containsKey(oali.Id)) {
                for (Inventory_Transfer__c existingXfer : existingTransfersByOaliId.get(oali.Id)) {
                    // Match customer fulfillment transfers (outbound from supplying account or to destination account)
                    Boolean isOutbound = (supplyingAccId != null && existingXfer.From_Account__c == supplyingAccId);
                    Boolean isToCustomer = (toAccountId != null && existingXfer.To_Account__c == toAccountId);
                    if (isOutbound || isToCustomer || (supplyingAccId == null && toAccountId == null)) {
                        alreadyCreatedTransferQty += (existingXfer.Transfer_Qty__c != null ? existingXfer.Transfer_Qty__c : 0);
                    }
                }
            }

            // Derive applicable remaining transfer quantity
            Decimal transferQty = deriveTransferQuantity(oali, alreadyCreatedTransferQty);

            // Skip creation if no newly eligible quantity exists (duplicate prevention)
            if (transferQty <= 0) {
                continue;
            }

            Inventory_Transfer__c transfer = new Inventory_Transfer__c();
            transfer.Order_Allocation_Line_Item__c = oali.Id;
            transfer.Item__c = oali.Item__c;

            // Map supplying/source account (Actual stock/source account)
            transfer.From_Account__c = supplyingAccId;
            // Map destination account (Original SR requesting account)
            transfer.To_Account__c = toAccountId;
            transfer.Account__c = toAccountId != null ? toAccountId : supplyingAccId;

            // Inventory Locations
            if (oali.Order_Allocation__r != null) {
                transfer.Source_Inventory_Location__c = oali.Order_Allocation__r.Source_Location__c;
            }
            transfer.Destination_Inventory_Location__c = destLocationId;

            transfer.Transfer_Qty__c = transferQty;

            // Default Status, Request Type, and Requested Date
            transfer.Status__c = 'Requested';
            transfer.Request_Type__c = 'Customer Demand';
            transfer.Requested_Date__c = Date.today();

            transfersToInsert.add(transfer);
        }

        if (!transfersToInsert.isEmpty()) {
            insert transfersToInsert;
        }
    }

    /**
     * Resolves the root Original/Main Supply Request for a collection of OALIs by traversing upstream SR relationships.
     * Backtracks: OALI -> Direct Supply_Request__c / Source_SR_References__c -> Parent Supply_Request__c ... -> Root SR
     * If multiple source references exist, uses Source_SR_Allocation__c to pick the matching branch.
     * Stops when an SR has no upstream/source SR.
     * Guards against circular loops using visited sets and a maximum depth limit.
     */
    private static Map<Id, Supply_Request__c> resolveOriginalSupplyRequestsForOALIs(List<Order_Allocation_Line_Item__c> oaliList) {
        Map<Id, Supply_Request__c> originalSrByOaliId = new Map<Id, Supply_Request__c>();

        // Cache for all Supply Request records keyed by Id and Name
        Map<Id, Supply_Request__c> srByIdMap = new Map<Id, Supply_Request__c>();
        Map<String, Supply_Request__c> srByNameMap = new Map<String, Supply_Request__c>();

        // 1. Collect initial direct Supply Request IDs and all Name variants from OALIs
        Set<Id> srIdsToQuery = new Set<Id>();
        Set<String> srNamesToQuery = new Set<String>();

        for (Order_Allocation_Line_Item__c oali : oaliList) {
            if (oali.Supply_Request__c != null) {
                srIdsToQuery.add(oali.Supply_Request__c);
            }
            if (String.isNotBlank(oali.Source_SR_References__c)) {
                for (String ref : oali.Source_SR_References__c.split(',')) {
                    addNameVariants(ref, srNamesToQuery);
                }
            }
            if (String.isNotBlank(oali.Source_SR_Allocation__c)) {
                for (String entry : oali.Source_SR_Allocation__c.split(',')) {
                    String[] parts = entry.split(':');
                    if (!parts.isEmpty()) {
                        addNameVariants(parts[0], srNamesToQuery);
                    }
                }
            }
        }

        // Query initial SRs by Id or Name variants
        if (!srIdsToQuery.isEmpty() || !srNamesToQuery.isEmpty()) {
            for (Supply_Request__c sr : [
                SELECT Id, Name, Requesting_Account__c, Supplying_Account__c, Target_Location__c, Source_Location__c, Supply_Request__c, Order_Allocation_Line_Item__c
                FROM Supply_Request__c
                WHERE Id IN :srIdsToQuery OR Name IN :srNamesToQuery
            ]) {
                srByIdMap.put(sr.Id, sr);
                indexSrByName(sr, srByNameMap);
            }
        }

        // Cache for all OALIs discovered in upstream chain
        Map<Id, Order_Allocation_Line_Item__c> allKnownOalis = new Map<Id, Order_Allocation_Line_Item__c>();
        for (Order_Allocation_Line_Item__c o : oaliList) {
            allKnownOalis.put(o.Id, o);
        }

        // Map linking SR Id -> Fulfilling OALI (where OALI.Supply_Request__c = SR.Id)
        Map<Id, Order_Allocation_Line_Item__c> fulfillingOaliBySrId = new Map<Id, Order_Allocation_Line_Item__c>();

        // 2. Iteratively trace upstream SRs and OALIs across all tiers (loop protected)
        Integer maxDepth = 25;
        Integer currentDepth = 0;
        Set<Id> srIdsNeedingUpstream = new Set<Id>(srByIdMap.keySet());

        while (!srIdsNeedingUpstream.isEmpty() && currentDepth < maxDepth) {
            currentDepth++;
            Set<Id> nextSrIdsToQuery = new Set<Id>();
            Set<String> nextSrNamesToQuery = new Set<String>();
            Set<Id> nextOaliIdsToQuery = new Set<Id>();

            // Collect direct parent SR lookups & linked receiving OALIs on SRs
            for (Id srId : srIdsNeedingUpstream) {
                Supply_Request__c sr = srByIdMap.get(srId);
                if (sr == null) continue;

                if (sr.Supply_Request__c != null && !srByIdMap.containsKey(sr.Supply_Request__c)) {
                    nextSrIdsToQuery.add(sr.Supply_Request__c);
                }
                if (sr.Order_Allocation_Line_Item__c != null && !allKnownOalis.containsKey(sr.Order_Allocation_Line_Item__c)) {
                    nextOaliIdsToQuery.add(sr.Order_Allocation_Line_Item__c);
                }
            }

            // Query OALIs fulfilling these SRs (e.g. Speed Motors SALI-00739 linked to SR-00931)
            List<Order_Allocation_Line_Item__c> fulfillingOalis = [
                SELECT Id, Name, Supply_Request__c, Source_SR_References__c, Source_SR_Allocation__c
                FROM Order_Allocation_Line_Item__c
                WHERE Supply_Request__c IN :srIdsNeedingUpstream
            ];
            for (Order_Allocation_Line_Item__c fOali : fulfillingOalis) {
                allKnownOalis.put(fOali.Id, fOali);
                if (fOali.Supply_Request__c != null) {
                    fulfillingOaliBySrId.put(fOali.Supply_Request__c, fOali);
                }
                if (String.isNotBlank(fOali.Source_SR_References__c)) {
                    for (String ref : fOali.Source_SR_References__c.split(',')) {
                        addNameVariants(ref, nextSrNamesToQuery);
                    }
                }
                if (String.isNotBlank(fOali.Source_SR_Allocation__c)) {
                    for (String entry : fOali.Source_SR_Allocation__c.split(',')) {
                        String[] parts = entry.split(':');
                        if (!parts.isEmpty()) {
                            addNameVariants(parts[0], nextSrNamesToQuery);
                        }
                    }
                }
            }

            // Query extra receiving OALIs (Order_Allocation_Line_Item__c on SR)
            if (!nextOaliIdsToQuery.isEmpty()) {
                List<Order_Allocation_Line_Item__c> extraOalis = [
                    SELECT Id, Name, Supply_Request__c, Source_SR_References__c, Source_SR_Allocation__c
                    FROM Order_Allocation_Line_Item__c
                    WHERE Id IN :nextOaliIdsToQuery
                ];
                for (Order_Allocation_Line_Item__c eOali : extraOalis) {
                    allKnownOalis.put(eOali.Id, eOali);
                    if (eOali.Supply_Request__c != null && !srByIdMap.containsKey(eOali.Supply_Request__c)) {
                        nextSrIdsToQuery.add(eOali.Supply_Request__c);
                    }
                    if (String.isNotBlank(eOali.Source_SR_References__c)) {
                        for (String ref : eOali.Source_SR_References__c.split(',')) {
                            addNameVariants(ref, nextSrNamesToQuery);
                        }
                    }
                    if (String.isNotBlank(eOali.Source_SR_Allocation__c)) {
                        for (String entry : eOali.Source_SR_Allocation__c.split(',')) {
                            String[] parts = entry.split(':');
                            if (!parts.isEmpty()) {
                                addNameVariants(parts[0], nextSrNamesToQuery);
                            }
                        }
                    }
                }
            }

            srIdsNeedingUpstream.clear();

            // Query next level upstream SRs
            if (!nextSrIdsToQuery.isEmpty() || !nextSrNamesToQuery.isEmpty()) {
                List<Supply_Request__c> nextSrs = [
                    SELECT Id, Name, Requesting_Account__c, Supplying_Account__c, Target_Location__c, Source_Location__c, Supply_Request__c, Order_Allocation_Line_Item__c
                    FROM Supply_Request__c
                    WHERE Id IN :nextSrIdsToQuery OR Name IN :nextSrNamesToQuery
                ];

                for (Supply_Request__c nSr : nextSrs) {
                    if (!srByIdMap.containsKey(nSr.Id)) {
                        srByIdMap.put(nSr.Id, nSr);
                        indexSrByName(nSr, srByNameMap);
                        srIdsNeedingUpstream.add(nSr.Id);
                    }
                }
            }
        }

        // 3. For each OALI, traverse upstream to find the Original/Main SR (top of the entire chain)
        for (Order_Allocation_Line_Item__c oali : oaliList) {
            Supply_Request__c startingSr = null;

            // Priority a: Direct Supply_Request__c lookup
            if (oali.Supply_Request__c != null && srByIdMap.containsKey(oali.Supply_Request__c)) {
                startingSr = srByIdMap.get(oali.Supply_Request__c);
            }

            // Priority b: Check Source_SR_Allocation__c
            if (startingSr == null && String.isNotBlank(oali.Source_SR_Allocation__c)) {
                for (String entry : oali.Source_SR_Allocation__c.split(',')) {
                    String[] parts = entry.split(':');
                    if (!parts.isEmpty()) {
                        startingSr = findSrByName(parts[0], srByNameMap);
                        if (startingSr != null) {
                            break;
                        }
                    }
                }
            }

            // Priority c: Direct Source_SR_References__c comma separated list
            if (startingSr == null && String.isNotBlank(oali.Source_SR_References__c)) {
                for (String candName : oali.Source_SR_References__c.split(',')) {
                    startingSr = findSrByName(candName, srByNameMap);
                    if (startingSr != null) {
                        break;
                    }
                }
            }

            if (startingSr != null) {
                Supply_Request__c currentSr = startingSr;
                Set<Id> visitedSrIds = new Set<Id>();
                visitedSrIds.add(currentSr.Id);

                // Traverse upstream across SR parent lookups and intermediate OALI relationships
                Integer traversalDepth = 0;
                while (traversalDepth < 25) {
                    traversalDepth++;
                    Supply_Request__c nextSr = null;

                    // 1. Direct parent lookup: currentSr.Supply_Request__c
                    if (currentSr.Supply_Request__c != null && srByIdMap.containsKey(currentSr.Supply_Request__c)) {
                        Id nextSrId = currentSr.Supply_Request__c;
                        if (!visitedSrIds.contains(nextSrId)) {
                            nextSr = srByIdMap.get(nextSrId);
                        }
                    }

                    // 2. Fulfilling OALI for current SR (where OALI.Supply_Request__c == currentSr.Id)
                    if (nextSr == null && fulfillingOaliBySrId.containsKey(currentSr.Id)) {
                        Order_Allocation_Line_Item__c fulOali = fulfillingOaliBySrId.get(currentSr.Id);
                        nextSr = resolveUpstreamSrFromOali(fulOali, srByIdMap, srByNameMap, visitedSrIds);
                    }

                    // 3. Receiving OALI on current SR (currentSr.Order_Allocation_Line_Item__c)
                    if (nextSr == null && currentSr.Order_Allocation_Line_Item__c != null && allKnownOalis.containsKey(currentSr.Order_Allocation_Line_Item__c)) {
                        Order_Allocation_Line_Item__c recOali = allKnownOalis.get(currentSr.Order_Allocation_Line_Item__c);
                        nextSr = resolveUpstreamSrFromOali(recOali, srByIdMap, srByNameMap, visitedSrIds);
                    }

                    if (nextSr != null) {
                        visitedSrIds.add(nextSr.Id);
                        currentSr = nextSr;
                    } else {
                        // Reached top/root SR (no further upstream parent exists)
                        break;
                    }
                }

                originalSrByOaliId.put(oali.Id, currentSr);
            }
        }

        return originalSrByOaliId;
    }

    /**
     * Resolves the next upstream SR from an intermediate OALI's Source_SR_References__c or direct Supply_Request__c.
     */
    private static Supply_Request__c resolveUpstreamSrFromOali(
        Order_Allocation_Line_Item__c intermediateOali,
        Map<Id, Supply_Request__c> srByIdMap,
        Map<String, Supply_Request__c> srByNameMap,
        Set<Id> visitedSrIds
    ) {
        if (intermediateOali == null) {
            return null;
        }

        // Check Source_SR_Allocation__c
        if (String.isNotBlank(intermediateOali.Source_SR_Allocation__c)) {
            for (String entry : intermediateOali.Source_SR_Allocation__c.split(',')) {
                String[] parts = entry.split(':');
                if (!parts.isEmpty()) {
                    Supply_Request__c found = findSrByName(parts[0], srByNameMap);
                    if (found != null && !visitedSrIds.contains(found.Id)) {
                        return found;
                    }
                }
            }
        }

        // Check Source_SR_References__c
        if (String.isNotBlank(intermediateOali.Source_SR_References__c)) {
            for (String candName : intermediateOali.Source_SR_References__c.split(',')) {
                Supply_Request__c found = findSrByName(candName, srByNameMap);
                if (found != null && !visitedSrIds.contains(found.Id)) {
                    return found;
                }
            }
        }

        // Check direct lookup
        if (intermediateOali.Supply_Request__c != null && srByIdMap.containsKey(intermediateOali.Supply_Request__c)) {
            Id nextId = intermediateOali.Supply_Request__c;
            if (!visitedSrIds.contains(nextId)) {
                return srByIdMap.get(nextId);
            }
        }

        return null;
    }

    /**
     * Derives the applicable transfer quantity based strictly on:
     * 1. Reserved eligibility: Reserved_Qty_Planned__c == Reserved_Quantity__c (when planned > 0, or direct reservation)
     * 2. Procurement eligibility: Procurement_Qty_Planned__c == Procurement_Qty_Received__c (when planned > 0, or direct procurement)
     * Transfer quantities (Transfer_Qty_Planned__c / Transfer_Qty_Received__c) are NEVER included.
     * Subtracts already fulfilled/planned customer transfer quantity to produce the exact remaining eligible amount.
     * Does NOT depend on OALI Status__c.
     */
    private static Decimal deriveTransferQuantity(Order_Allocation_Line_Item__c oali, Decimal alreadyCreatedTransferQty) {
        Decimal totalEligibleQty = 0;

        Decimal reservedPlanned = oali.Reserved_Qty_Planned__c != null ? oali.Reserved_Qty_Planned__c : 0;
        Decimal reservedActual = oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : 0;
        Decimal procurePlanned = oali.Procurement_Qty_Planned__c != null ? oali.Procurement_Qty_Planned__c : 0;
        Decimal procureReceived = oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0;
        Decimal transferPlanned = oali.Transfer_Qty_Planned__c != null ? oali.Transfer_Qty_Planned__c : 0;
        Decimal orderedQty = oali.Ordered_Qty__c != null ? oali.Ordered_Qty__c : 0;
        Decimal priorCreated = alreadyCreatedTransferQty != null ? alreadyCreatedTransferQty : 0;

        // 1. Reserved quantity is eligible when planned equals actual (or when directly reserved without a plan)
        if (reservedPlanned > 0 && reservedActual == reservedPlanned) {
            totalEligibleQty += reservedActual;
        } else if (reservedPlanned == 0 && reservedActual > 0) {
            totalEligibleQty += reservedActual;
        }

        /*
        // 2. Procurement quantity is eligible when planned equals received (or when directly received without a plan)
        if (procurePlanned > 0 && procureReceived == procurePlanned) {
            totalEligibleQty += procureReceived;
        } else if (procurePlanned == 0 && procureReceived > 0) {
            totalEligibleQty += procureReceived;
        }

        // 3. Fallback for direct allocations with no planned channels
        if (totalEligibleQty == 0 && reservedPlanned == 0 && procurePlanned == 0 && transferPlanned == 0) {
            if (oali.Secured_Qty__c != null && oali.Secured_Qty__c > 0) {
                totalEligibleQty = oali.Secured_Qty__c;
            } else if (orderedQty > 0) {
                totalEligibleQty = orderedQty;
            }
        }
        */

        // Cap at total ordered quantity
        if (orderedQty > 0 && totalEligibleQty > orderedQty) {
            totalEligibleQty = orderedQty;
        }

        // Calculate only the remaining unfulfilled eligible quantity
        Decimal remainingEligibleQty = totalEligibleQty - priorCreated;
        return remainingEligibleQty > 0 ? remainingEligibleQty : 0;
    }

    // =========================================================================
    // SR NAME NORMALIZATION & RESILIENT LOOKUP HELPERS
    // =========================================================================

    /**
     * Normalizes an SR Name to a canonical comparison key.
     * E.g. "SR - 00931" and "SR-00931" both become "SR-00931".
     */
    public static String normalizeSrKey(String name) {
        if (String.isBlank(name)) {
            return '';
        }
        String norm = name.trim().toUpperCase();
        norm = norm.replaceAll('\\s*-\\s*', '-');
        norm = norm.replaceAll('\\s+', ' ');
        return norm;
    }

    /**
     * Adds name variants to a Set for querying.
     * Generates both with-space ("SR - 00931") and without-space ("SR-00931") formats.
     */
    public static void addNameVariants(String rawName, Set<String> nameSet) {
        if (String.isBlank(rawName) || nameSet == null) {
            return;
        }
        String trimmed = rawName.trim();
        nameSet.add(trimmed);
        nameSet.add(trimmed.replaceAll('\\s*-\\s*', ' - '));
        nameSet.add(trimmed.replaceAll('\\s*-\\s*', '-'));
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
}