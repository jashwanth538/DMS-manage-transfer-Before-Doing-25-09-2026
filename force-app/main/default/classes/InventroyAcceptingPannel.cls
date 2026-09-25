public without sharing class InventroyAcceptingPannel {
    @AuraEnabled(cacheable=true)
    public static List<Inventory_Transfer__c> getApprovedTransfers() {
        try {
            Boolean isAdmin = InventoryTransferPending.isSystemAdministrator();
            Set<Id> userAccountIds = isAdmin ? new Set<Id>() : InventoryTransferPending.getUserAccountIds();

            if (!isAdmin && userAccountIds.isEmpty()) {
                return new List<Inventory_Transfer__c>();
            }

            if (isAdmin) {
                return [
                    SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c,
                           Source_Inventory_Location__c, Source_Inventory_Location__r.Name, 
                           Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name, 
                           From_Account__c, From_Account__r.Name,
                           To_Account__c, To_Account__r.Name,
                           Transfer_Qty__c, Requested_Date__c, Status__c, Request_Type__c,
                           In_Transit_Qty__c, Received_Qty__c,
                           Order_Allocation_Line_Item__c,
                           Order_Allocation_Line_Item__r.Order_Allocation__r.Name,
                           Order_Allocation_Line_Item__r.Name
                    FROM Inventory_Transfer__c 
                    WHERE Status__c = 'In Transit' 
                    ORDER BY Requested_Date__c DESC
                ];
            } else {
                return [
                    SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c,
                           Source_Inventory_Location__c, Source_Inventory_Location__r.Name, 
                           Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name, 
                           From_Account__c, From_Account__r.Name,
                           To_Account__c, To_Account__r.Name,
                           Transfer_Qty__c, Requested_Date__c, Status__c, Request_Type__c,
                           In_Transit_Qty__c, Received_Qty__c,
                           Order_Allocation_Line_Item__c,
                           Order_Allocation_Line_Item__r.Order_Allocation__r.Name,
                           Order_Allocation_Line_Item__r.Name
                    FROM Inventory_Transfer__c 
                    WHERE Status__c = 'In Transit' 
                    AND To_Account__c IN :userAccountIds
                    ORDER BY Requested_Date__c DESC
                ];
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in getApprovedTransfers: ' + e.getMessage() + '\n' + e.getStackTraceString());
            AuraHandledException aex = new AuraHandledException('Error loading in-transit transfers: ' + e.getMessage());
            aex.setMessage('Error loading in-transit transfers: ' + e.getMessage());
            throw aex;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Inventory_Location__c> getLocations() {
        try {
            List<Inventory_Location__c> locs = [
                SELECT Id, Name, Inventory_Location_Code__c 
                FROM Inventory_Location__c 
                WHERE Is_Active__c = true
                ORDER BY Name
            ];
            return locs;
        } catch (Exception e) {
            AuraHandledException aex = new AuraHandledException('Error loading locations: ' + e.getMessage());
            aex.setMessage('Error loading locations: ' + e.getMessage());
            throw aex;
        }
    }

    @AuraEnabled
    public static Map<String, Object> validateAcceptStatus(Id transferId) {
        List<Inventory_Transfer__c> transfers = [
            SELECT Id, Name, Status__c
            FROM Inventory_Transfer__c
            WHERE Id = :transferId
            LIMIT 1
        ];
        Map<String, Object> result = new Map<String, Object>();
        if (transfers.isEmpty()) {
            result.put('valid', false);
            result.put('message', 'Inventory Transfer record not found.');
            return result;
        }
        Inventory_Transfer__c t = transfers[0];
        if (t.Status__c != 'In Transit') {
            result.put('valid', false);
            result.put('message', 'Seems like someone already accepted transfer "' + t.Name + '". The current status is "' + t.Status__c + '".');
            return result;
        }
        result.put('valid', true);
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> validateAcceptStatuses(List<Id> transferIds) {
        if (transferIds == null || transferIds.isEmpty()) {
            Map<String, Object> result = new Map<String, Object>();
            result.put('valid', false);
            result.put('message', 'No transfer records selected.');
            return result;
        }
        List<Inventory_Transfer__c> transfers = [
            SELECT Id, Name, Status__c
            FROM Inventory_Transfer__c
            WHERE Id IN :transferIds
        ];
        List<String> alreadyActioned = new List<String>();
        for (Inventory_Transfer__c t : transfers) {
            if (t.Status__c != 'In Transit') {
                alreadyActioned.add(t.Name + ' (' + t.Status__c + ')');
            }
        }
        Map<String, Object> result = new Map<String, Object>();
        if (!alreadyActioned.isEmpty()) {
            result.put('valid', false);
            result.put('message', 'Seems like someone already accepted the following transfers: ' + String.join(alreadyActioned, ', ') + '.');
            return result;
        }
        result.put('valid', true);
        return result;
    }

    /**
     * Accepts a single Inventory Transfer with full backtracking support.
     */
    @AuraEnabled
    public static void acceptQuantity(Id transferId) {
        acceptQuantities(new List<Id>{ transferId });
    }

    /**
     * Accepts multiple Inventory Transfers in bulk atomically with recursive backtracking.
     */
    @AuraEnabled
    public static void acceptQuantities(List<Id> transferIds) {
        if (transferIds == null || transferIds.isEmpty()) {
            AuraHandledException aex = new AuraHandledException('No transfer records selected.');
            aex.setMessage('No transfer records selected.');
            throw aex;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // 1. Query transfers to accept in System Mode
            List<Inventory_Transfer__c> transfers = Database.query(
                'SELECT Id, Name, Source_Inventory_Location__c, Destination_Inventory_Location__c, ' +
                '       Item__c, Transfer_Qty__c, Status__c, In_Transit_Qty__c, Received_Qty__c, ' +
                '       Received_Date_Time__c, Request_Type__c, Order_Allocation_Line_Item__c, ' +
                '       Order_Allocation_Line_Item__r.Supply_Request__r.Request_Type__c, ' +
                '       From_Account__c, To_Account__c ' +
                'FROM Inventory_Transfer__c ' +
                'WHERE Id IN :transferIds',
                AccessLevel.SYSTEM_MODE
            );

            if (transfers.isEmpty()) {
                AuraHandledException aex = new AuraHandledException('No Inventory Transfer records found.');
                aex.setMessage('No Inventory Transfer records found.');
                throw aex;
            }

            Set<Id> itemIds = new Set<Id>();
            Set<Id> locIds = new Set<Id>();
            Set<Id> oaliIds = new Set<Id>();

            for (Inventory_Transfer__c t : transfers) {
                if (t.Status__c != 'In Transit') {
                    throw new AuraHandledException('ALREADY_ACTIONED:Seems like someone already accepted transfer "' + t.Name + '". The current status is "' + t.Status__c + '".');
                }
                Decimal qty = t.Transfer_Qty__c != null ? t.Transfer_Qty__c : (t.In_Transit_Qty__c != null ? t.In_Transit_Qty__c : 0);
                if (qty <= 0) {
                    throw new AuraHandledException('Transfer "' + t.Name + '" has invalid quantity: ' + qty);
                }
                if (t.Item__c != null) itemIds.add(t.Item__c);
                if (t.Source_Inventory_Location__c != null) locIds.add(t.Source_Inventory_Location__c);
                if (t.Destination_Inventory_Location__c != null) locIds.add(t.Destination_Inventory_Location__c);
                if (t.Order_Allocation_Line_Item__c != null) oaliIds.add(t.Order_Allocation_Line_Item__c);
            }

            // 2. Preload Direct OALIs and multi-tier upstream Supply Requests and parent OALIs in System Mode
            Map<Id, Order_Allocation_Line_Item__c> allKnownOalis = new Map<Id, Order_Allocation_Line_Item__c>();
            Map<Id, Order_Allocation_Line_Item__c> directOaliMap = new Map<Id, Order_Allocation_Line_Item__c>();
            Map<Id, Supply_Request__c> srsById = new Map<Id, Supply_Request__c>();
            Map<String, Supply_Request__c> srsByName = new Map<String, Supply_Request__c>();
            Map<Id, List<Supply_Request__c>> srsByOaliId = new Map<Id, List<Supply_Request__c>>();

            if (!oaliIds.isEmpty()) {
                List<Order_Allocation_Line_Item__c> qDirectOalis = Database.query(
                    'SELECT Id, Name, Status__c, Ordered_Qty__c, Transfer_Qty_Planned__c, Transfer_Qty_Received__c, ' +
                    '       Reserved_Quantity__c, Reserved_Qty_Planned__c, Procurement_Qty_Planned__c, ' +
                    '       Procurement_Qty_Received__c, Remaining_Qty__c, Secured_Qty__c, Supply_Request__c, ' +
                    '       Source_SR_References__c, Source_SR_Allocation__c, Source_SR_Sub_Type_References__c, ' +
                    '       Purchase_Order_Line_Item__c, Item__c, Order_Allocation__c ' +
                    'FROM Order_Allocation_Line_Item__c ' +
                    'WHERE Id IN :oaliIds',
                    AccessLevel.SYSTEM_MODE
                );
                for (Order_Allocation_Line_Item__c dOali : qDirectOalis) {
                    directOaliMap.put(dOali.Id, dOali);
                    allKnownOalis.put(dOali.Id, dOali);
                }

                // Multi-tier discovery loop across all tiers up to 10 hops
                for (Integer iter = 0; iter < 10; iter++) {
                    Boolean newRecordsFound = false;

                    Set<Id> srIdsToQuery = new Set<Id>();
                    Set<String> srNamesToQuery = new Set<String>();

                    for (Order_Allocation_Line_Item__c oali : allKnownOalis.values()) {
                        if (oali.Supply_Request__c != null && !srsById.containsKey(oali.Supply_Request__c)) {
                            srIdsToQuery.add(oali.Supply_Request__c);
                        }
                        if (String.isNotBlank(oali.Source_SR_References__c)) {
                            for (String ref : InventoryTransferBacktrackingService.parseDelimitedString(oali.Source_SR_References__c)) {
                                if (InventoryTransferBacktrackingService.findSrByName(ref, srsByName) == null) {
                                    InventoryTransferBacktrackingService.addNameVariants(ref, srNamesToQuery);
                                }
                            }
                        }
                        Map<String, Decimal> aMap = InventoryTransferBacktrackingService.parseAllocations(oali.Source_SR_Allocation__c);
                        for (String sName : aMap.keySet()) {
                            if (InventoryTransferBacktrackingService.findSrByName(sName, srsByName) == null) {
                                InventoryTransferBacktrackingService.addNameVariants(sName, srNamesToQuery);
                            }
                        }
                        Map<String, String> subMap = InventoryTransferBacktrackingService.parseSubtypeReferences(oali.Source_SR_Sub_Type_References__c);
                        for (String sName : subMap.keySet()) {
                            if (InventoryTransferBacktrackingService.findSrByName(sName, srsByName) == null) {
                                InventoryTransferBacktrackingService.addNameVariants(sName, srNamesToQuery);
                            }
                        }
                    }

                    for (Supply_Request__c sr : srsById.values()) {
                        if (sr.Supply_Request__c != null && !srsById.containsKey(sr.Supply_Request__c)) {
                            srIdsToQuery.add(sr.Supply_Request__c);
                        }
                    }

                    if (!srIdsToQuery.isEmpty() || !srNamesToQuery.isEmpty()) {
                        List<Supply_Request__c> newSrs = Database.query(
                            'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                            '       Requested_Qty__c, Received_Qty__c, Status__c, Request_Type__c, ' +
                            '       Sub_Request_Type__c, Item__c, Supply_Request__c, Order_Allocation_Line_Item__c, ' +
                            '       Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Account__c ' +
                            'FROM Supply_Request__c ' +
                            'WHERE Id IN :srIdsToQuery OR Name IN :srNamesToQuery',
                            AccessLevel.SYSTEM_MODE
                        );
                        if (!newSrs.isEmpty()) {
                            newRecordsFound = true;
                            for (Supply_Request__c sr : newSrs) {
                                srsById.put(sr.Id, sr);
                                InventoryTransferBacktrackingService.indexSrByName(sr, srsByName);
                                if (sr.Order_Allocation_Line_Item__c != null) {
                                    if (!srsByOaliId.containsKey(sr.Order_Allocation_Line_Item__c)) {
                                        srsByOaliId.put(sr.Order_Allocation_Line_Item__c, new List<Supply_Request__c>());
                                    }
                                    srsByOaliId.get(sr.Order_Allocation_Line_Item__c).add(sr);
                                }
                            }
                        }
                    }

                    Set<Id> oaliIdsToQuery = new Set<Id>();
                    for (Supply_Request__c sr : srsById.values()) {
                        if (sr.Order_Allocation_Line_Item__c != null && !allKnownOalis.containsKey(sr.Order_Allocation_Line_Item__c)) {
                            oaliIdsToQuery.add(sr.Order_Allocation_Line_Item__c);
                        }
                    }

                    Set<Id> knownSrIds = srsById.keySet();
                    if (!oaliIdsToQuery.isEmpty() || !knownSrIds.isEmpty()) {
                        List<Order_Allocation_Line_Item__c> newOalis = Database.query(
                            'SELECT Id, Name, Status__c, Ordered_Qty__c, Transfer_Qty_Planned__c, Transfer_Qty_Received__c, ' +
                            '       Reserved_Quantity__c, Reserved_Qty_Planned__c, Procurement_Qty_Planned__c, ' +
                            '       Procurement_Qty_Received__c, Remaining_Qty__c, Secured_Qty__c, Supply_Request__c, ' +
                            '       Source_SR_References__c, Source_SR_Allocation__c, Source_SR_Sub_Type_References__c, ' +
                            '       Purchase_Order_Line_Item__c, Item__c, Order_Allocation__c ' +
                            'FROM Order_Allocation_Line_Item__c ' +
                            'WHERE Id IN :oaliIdsToQuery OR Supply_Request__c IN :knownSrIds',
                            AccessLevel.SYSTEM_MODE
                        );
                        if (!newOalis.isEmpty()) {
                            for (Order_Allocation_Line_Item__c oali : newOalis) {
                                if (!allKnownOalis.containsKey(oali.Id)) {
                                    allKnownOalis.put(oali.Id, oali);
                                    newRecordsFound = true;
                                }
                            }
                        }
                    }

                    if (!newRecordsFound) {
                        break;
                    }
                }
            }

            // 3. Query Inventory records for all involved locations and items in System Mode
            List<Inventory__c> existingInvs = Database.query(
                'SELECT Id, Item__c, Inventory_Location__c, Transit_Out_Quantity__c, ' +
                '       Transit_In_Quantity__c, Reserved_Sale_Order__c, Available__c, Reserved__c ' +
                'FROM Inventory__c ' +
                'WHERE Item__c IN :itemIds AND Inventory_Location__c IN :locIds',
                AccessLevel.SYSTEM_MODE
            );

            Map<String, Inventory__c> invMap = new Map<String, Inventory__c>();
            for (Inventory__c inv : existingInvs) {
                invMap.put(inv.Item__c + '_' + inv.Inventory_Location__c, inv);
            }

            // 4. Process inventory physical stock movements and transfer updates
            for (Inventory_Transfer__c t : transfers) {
                Decimal qty = t.Transfer_Qty__c != null ? t.Transfer_Qty__c : (t.In_Transit_Qty__c != null ? t.In_Transit_Qty__c : 0);
                System.debug(LoggingLevel.INFO, '[BACKTRACK] Inventory Transfer = ' + t.Id + ' Qty = ' + qty);

                // Step A: Source Location - Remove Transfer Out
                if (t.Source_Inventory_Location__c != null && t.Item__c != null) {
                    String sourceKey = t.Item__c + '_' + t.Source_Inventory_Location__c;
                    Inventory__c sourceInv = invMap.get(sourceKey);
                    if (sourceInv != null) {
                        Decimal currentTransitOut = sourceInv.Transit_Out_Quantity__c != null ? sourceInv.Transit_Out_Quantity__c : 0;
                        sourceInv.Transit_Out_Quantity__c = Math.max(0, currentTransitOut - qty);
                    }
                }

                // Step B: Target Location - Remove Transfer In & Add to Physical Stock
                if (t.Destination_Inventory_Location__c != null && t.Item__c != null) {
                    String destKey = t.Item__c + '_' + t.Destination_Inventory_Location__c;
                    Inventory__c destInv = invMap.get(destKey);
                    if (destInv != null) {
                        Decimal currentTransitIn = destInv.Transit_In_Quantity__c != null ? destInv.Transit_In_Quantity__c : 0;
                        destInv.Transit_In_Quantity__c = Math.max(0, currentTransitIn - qty);
                    } else {
                        destInv = new Inventory__c(
                            Item__c = t.Item__c,
                            Inventory_Location__c = t.Destination_Inventory_Location__c,
                            Transit_In_Quantity__c = 0,
                            Reserved_Sale_Order__c = 0,
                            Available__c = 0
                        );
                        invMap.put(destKey, destInv);
                    }

                    // Resolve effective Supply Request Type from the ROOT/ORIGINAL demand SR in the backtracking chain
                    String effectiveReqType = null;
                    if (t.Order_Allocation_Line_Item__c != null && allKnownOalis.containsKey(t.Order_Allocation_Line_Item__c)) {
                        Order_Allocation_Line_Item__c dOali = allKnownOalis.get(t.Order_Allocation_Line_Item__c);
                        Supply_Request__c rootSr = null;

                        // 1. Direct parent SR
                        if (dOali.Supply_Request__c != null && srsById.containsKey(dOali.Supply_Request__c)) {
                            rootSr = srsById.get(dOali.Supply_Request__c);
                        }
                        // 2. Source SR references
                        if (rootSr == null && String.isNotBlank(dOali.Source_SR_References__c)) {
                            for (String ref : InventoryTransferBacktrackingService.parseDelimitedString(dOali.Source_SR_References__c)) {
                                rootSr = InventoryTransferBacktrackingService.findSrByName(ref, srsByName);
                                if (rootSr != null) break;
                            }
                        }
                        // 3. Source SR allocation
                        if (rootSr == null && String.isNotBlank(dOali.Source_SR_Allocation__c)) {
                            Map<String, Decimal> aMap = InventoryTransferBacktrackingService.parseAllocations(dOali.Source_SR_Allocation__c);
                            for (String sName : aMap.keySet()) {
                                rootSr = InventoryTransferBacktrackingService.findSrByName(sName, srsByName);
                                if (rootSr != null) break;
                            }
                        }
                        // 4. Linked SRs
                        if (rootSr == null && srsByOaliId.containsKey(dOali.Id) && !srsByOaliId.get(dOali.Id).isEmpty()) {
                            rootSr = srsByOaliId.get(dOali.Id)[0];
                        }

                        // Trace rootSr all the way up to the Original/Root Demand SR
                        if (rootSr != null) {
                            Supply_Request__c currSr = rootSr;
                            Set<Id> visitedSrs = new Set<Id>{ currSr.Id };
                            Integer depth = 0;
                            while (depth < 25) {
                                depth++;
                                Supply_Request__c parentSr = null;
                                if (currSr.Supply_Request__c != null && srsById.containsKey(currSr.Supply_Request__c)) {
                                    Id nextId = currSr.Supply_Request__c;
                                    if (!visitedSrs.contains(nextId)) {
                                        parentSr = srsById.get(nextId);
                                    }
                                }
                                if (parentSr == null && currSr.Order_Allocation_Line_Item__c != null) {
                                    Order_Allocation_Line_Item__c recOali = allKnownOalis.get(currSr.Order_Allocation_Line_Item__c);
                                    if (recOali != null) {
                                        if (recOali.Supply_Request__c != null && srsById.containsKey(recOali.Supply_Request__c) && !visitedSrs.contains(recOali.Supply_Request__c)) {
                                            parentSr = srsById.get(recOali.Supply_Request__c);
                                        }
                                        if (parentSr == null && String.isNotBlank(recOali.Source_SR_References__c)) {
                                            for (String rName : InventoryTransferBacktrackingService.parseDelimitedString(recOali.Source_SR_References__c)) {
                                                Supply_Request__c cand = InventoryTransferBacktrackingService.findSrByName(rName, srsByName);
                                                if (cand != null && !visitedSrs.contains(cand.Id)) {
                                                    parentSr = cand;
                                                    break;
                                                }
                                            }
                                        }
                                        if (parentSr == null && String.isNotBlank(recOali.Source_SR_Allocation__c)) {
                                            Map<String, Decimal> aMap = InventoryTransferBacktrackingService.parseAllocations(recOali.Source_SR_Allocation__c);
                                            for (String sName : aMap.keySet()) {
                                                Supply_Request__c cand = InventoryTransferBacktrackingService.findSrByName(sName, srsByName);
                                                if (cand != null && !visitedSrs.contains(cand.Id)) {
                                                    parentSr = cand;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }

                                if (parentSr != null) {
                                    visitedSrs.add(parentSr.Id);
                                    currSr = parentSr;
                                } else {
                                    break;
                                }
                            }
                            rootSr = currSr;
                        }

                        if (rootSr != null && String.isNotBlank(rootSr.Request_Type__c)) {
                            effectiveReqType = rootSr.Request_Type__c;
                            System.debug(LoggingLevel.INFO, '[BACKTRACK-INV] Resolved Root Demand SR ' + rootSr.Name + ' with Request_Type__c = ' + effectiveReqType + ' for Transfer ' + t.Id);
                        }
                    }
                    if (String.isBlank(effectiveReqType)) {
                        effectiveReqType = (t.Order_Allocation_Line_Item__r != null && t.Order_Allocation_Line_Item__r.Supply_Request__r != null && String.isNotBlank(t.Order_Allocation_Line_Item__r.Supply_Request__r.Request_Type__c))
                            ? t.Order_Allocation_Line_Item__r.Supply_Request__r.Request_Type__c
                            : t.Request_Type__c;
                    }

                    Boolean isReservedForSaleOrder = isReservedForSaleOrderRequestType(effectiveReqType);
                    if (isReservedForSaleOrder) {
                        destInv.Reserved_Sale_Order__c = (destInv.Reserved_Sale_Order__c != null ? destInv.Reserved_Sale_Order__c : 0) + qty;
                    } else {
                        destInv.Available__c = (destInv.Available__c != null ? destInv.Available__c : 0) + qty;
                    }
                }

                // Step C: Update Transfer Record
                t.Received_Qty__c = qty;
                t.In_Transit_Qty__c = 0;
                t.Status__c = 'Received';
                t.Received_Date__c = Date.today();
                t.Received_Date_Time__c = System.now();
            }

            // 5. Preload all known OALIs and delegate multi-tier backtracking to service
            InventoryTransferBacktrackingService.processTransferAcceptance(transfers, allKnownOalis, srsById.values());

            // 7. Commit Inventory and Transfer updates atomically under System Mode
            if (!invMap.isEmpty()) {
                Database.upsert(invMap.values(), false, AccessLevel.SYSTEM_MODE);
            }
            Database.update(transfers, false, AccessLevel.SYSTEM_MODE);

            System.debug(LoggingLevel.INFO, '[InventroyAcceptingPannel] acceptQuantities with backtracking completed successfully for ' + transfers.size() + ' records');
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, 'Error in acceptQuantities: ' + e.getMessage() + '\n' + e.getStackTraceString());
            String errorMsg = e.getMessage();
            if (errorMsg != null && errorMsg.startsWith('ALREADY_ACTIONED:')) {
                AuraHandledException aex = new AuraHandledException(errorMsg);
                aex.setMessage(errorMsg);
                throw aex;
            }
            AuraHandledException aex = new AuraHandledException(errorMsg);
            aex.setMessage(errorMsg);
            throw aex;
        }
    }

    /**
     * Helper to check if a request type qualifies for 'Reserved for Sales Order' bin vs 'Available' bin.
     * Rules:
     * - Customer Demand, Transfer SR, Purchase SR -> Reserved_Sale_Order__c
     * - Forecast Demand, Manual Request, Stock Replenishment -> Available__c
     */
    public static Boolean isReservedForSaleOrderRequestType(String reqType) {
        if (String.isBlank(reqType)) {
            return false;
        }
        String normalized = reqType.trim();
        return 'Customer Demand'.equalsIgnoreCase(normalized) ||
               'Customer'.equalsIgnoreCase(normalized) ||
               'Purchase SR'.equalsIgnoreCase(normalized) ||
               'Purchase Supply Request'.equalsIgnoreCase(normalized) ||
               'Purchase'.equalsIgnoreCase(normalized) ||
               'Transfer SR'.equalsIgnoreCase(normalized) ||
               'Transfer Supply Request'.equalsIgnoreCase(normalized) ||
               'Transfer'.equalsIgnoreCase(normalized);
    }
}