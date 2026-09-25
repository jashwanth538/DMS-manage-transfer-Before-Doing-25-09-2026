public without sharing class InventoryTransferPending {
    @TestVisible
    public static Set<Id> testAccountIdsOverride;
    @TestVisible
    public static Boolean testIsAdminOverride;

    public static Boolean isSystemAdministrator() {
        if (testIsAdminOverride != null) {
            return testIsAdminOverride;
        }
        Profile p = [SELECT Id, Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1];
        return (p.Name == 'System Administrator');
    }

    public static Set<Id> getUserAccountIds() {
        if (testAccountIdsOverride != null) {
            return testAccountIdsOverride;
        }
        Set<Id> userAccountIds = new Set<Id>();
        Set<Id> groupIds = new Set<Id>();
        for (GroupMember gm : [
            SELECT GroupId 
            FROM GroupMember 
            WHERE UserOrGroupId = :UserInfo.getUserId()
        ]) {
            groupIds.add(gm.GroupId);
        }
        if (groupIds.isEmpty()) {
            return userAccountIds;
        }

        Set<String> groupIdStrings = new Set<String>();
        for (Id gId : groupIds) {
            groupIdStrings.add(String.valueOf(gId));
            if (String.valueOf(gId).length() >= 15) {
                groupIdStrings.add(String.valueOf(gId).substring(0, 15));
            }
        }

        Map<Id, Group> userGroups = new Map<Id, Group>([
            SELECT Id, Name, DeveloperName 
            FROM Group 
            WHERE Id IN :groupIds
        ]);
        Set<String> groupNames = new Set<String>();
        for (Group g : userGroups.values()) {
            if (String.isNotBlank(g.Name)) {
                groupNames.add(g.Name);
            }
            if (String.isNotBlank(g.DeveloperName)) {
                groupNames.add(g.DeveloperName);
            }
        }

        for (Account_Public_Group_Mapping__c mapping : [
            SELECT Account__c 
            FROM Account_Public_Group_Mapping__c 
            WHERE Active__c = true 
            AND Account__c != null 
            AND (Public_Group_Id__c IN :groupIdStrings OR Public_Group_Name__c IN :groupNames)
        ]) {
            userAccountIds.add(mapping.Account__c);
        }

        return userAccountIds;
    }

    @AuraEnabled(cacheable=true)
    public static List<Inventory_Transfer__c> getPendingTransfers() {
        try {
            Boolean isAdmin = isSystemAdministrator();
            Set<Id> userAccountIds = isAdmin ? new Set<Id>() : getUserAccountIds();

            if (!isAdmin && userAccountIds.isEmpty()) {
                return new List<Inventory_Transfer__c>();
            }

            if (isAdmin) {
                return [
                    SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c,
                           Source_Inventory_Location__c, Source_Inventory_Location__r.Name, 
                           Source_Inventory_Location__r.Account__c, Source_Inventory_Location__r.Account__r.Name,
                           Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name, 
                           Destination_Inventory_Location__r.Account__c, Destination_Inventory_Location__r.Account__r.Name,
                           From_Account__c, From_Account__r.Name,
                           To_Account__c, To_Account__r.Name,
                           Transfer_Qty__c, Requested_Date__c, Status__c, Request_Type__c,
                           In_Transit_Qty__c, Received_Qty__c,
                           Order_Allocation_Line_Item__c,
                           Order_Allocation_Line_Item__r.Order_Allocation__r.Name,
                           Order_Allocation_Line_Item__r.Name
                    FROM Inventory_Transfer__c 
                    WHERE Status__c = 'Requested'
                    ORDER BY Requested_Date__c DESC
                ];
            } else {
                return [
                    SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c,
                           Source_Inventory_Location__c, Source_Inventory_Location__r.Name, 
                           Source_Inventory_Location__r.Account__c, Source_Inventory_Location__r.Account__r.Name,
                           Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name, 
                           Destination_Inventory_Location__r.Account__c, Destination_Inventory_Location__r.Account__r.Name,
                           From_Account__c, From_Account__r.Name,
                           To_Account__c, To_Account__r.Name,
                           Transfer_Qty__c, Requested_Date__c, Status__c, Request_Type__c,
                           In_Transit_Qty__c, Received_Qty__c,
                           Order_Allocation_Line_Item__c,
                           Order_Allocation_Line_Item__r.Order_Allocation__r.Name,
                           Order_Allocation_Line_Item__r.Name
                    FROM Inventory_Transfer__c 
                    WHERE Status__c = 'Requested'
                    AND From_Account__c IN :userAccountIds
                    ORDER BY Requested_Date__c DESC
                ];
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in getPendingTransfers: ' + e.getMessage() + '\n' + e.getStackTraceString());
            AuraHandledException ahe = new AuraHandledException('Error loading pending transfers: ' + e.getMessage());
            ahe.setMessage('Error loading pending transfers: ' + e.getMessage());
            throw ahe;
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
            AuraHandledException ahe = new AuraHandledException(e.getMessage());
            ahe.setMessage(e.getMessage());
            throw ahe;
        }
    }

    @AuraEnabled
    public static Map<String, Object> validateTransferStatus(Id transferId) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            List<Inventory_Transfer__c> transfers = Database.query(
                'SELECT Id, Name, Status__c ' +
                'FROM Inventory_Transfer__c ' +
                'WHERE Id = :transferId ' +
                'LIMIT 1',
                AccessLevel.SYSTEM_MODE
            );
            if (transfers.isEmpty()) {
                result.put('valid', false);
                result.put('message', 'Inventory Transfer record not found.');
                return result;
            }
            Inventory_Transfer__c t = transfers[0];
            if (t.Status__c != 'Requested') {
                result.put('valid', false);
                result.put('message', 'Seems like someone already initiated transfer "' + t.Name + '". The current status is "' + t.Status__c + '".');
                return result;
            }
            result.put('valid', true);
            return result;
        } catch (Exception e) {
            result.put('valid', false);
            result.put('message', e.getMessage());
            return result;
        }
    }

    @AuraEnabled
    public static Map<String, Object> validateTransferStatuses(List<Id> transferIds) {
        Map<String, Object> result = new Map<String, Object>();
        if (transferIds == null || transferIds.isEmpty()) {
            result.put('valid', false);
            result.put('message', 'No transfer records selected.');
            return result;
        }
        try {
            List<Inventory_Transfer__c> transfers = Database.query(
                'SELECT Id, Name, Status__c ' +
                'FROM Inventory_Transfer__c ' +
                'WHERE Id IN :transferIds',
                AccessLevel.SYSTEM_MODE
            );
            List<String> alreadyActioned = new List<String>();
            for (Inventory_Transfer__c t : transfers) {
                if (t.Status__c != 'Requested') {
                    alreadyActioned.add(t.Name + ' (' + t.Status__c + ')');
                }
            }
            if (!alreadyActioned.isEmpty()) {
                result.put('valid', false);
                result.put('message', 'Seems like someone already initiated the following transfers: ' + String.join(alreadyActioned, ', ') + '.');
                return result;
            }
            result.put('valid', true);
            return result;
        } catch (Exception e) {
            result.put('valid', false);
            result.put('message', e.getMessage());
            return result;
        }
    }

    /**
     * Initiates a single Inventory Transfer:
     * 1. Validates transfer exists, status is 'Requested', quantity > 0, accounts & locations exist.
     * 2. Checks Source Inventory 'Reserved for Sales Order' has sufficient stock (Reserved_Sale_Order__c >= qty).
     * 3. Moves quantity:
     *    Source Location:
     *      Reserved_Sale_Order__c -= qty
     *      Transit_Out_Quantity__c += qty
     *    Target Location:
     *      Transit_In_Quantity__c += qty
     * 4. Updates transfer Status to 'In Transit', In_Transit_Qty__c = qty, Shipped_Date__c = today.
     * 5. Updates linked Order_Allocation_Line_Item__c Status__c to 'Shipped' (unless already 'Delivered').
     * 6. Atomicity guaranteed via rollback on any error.
     */
    @AuraEnabled
    public static Map<String, String> initiateTransfer(Id transferId) {
        if (transferId == null) {
            throw new AuraHandledException('Transfer ID cannot be null.');
        }
        List<Map<String, String>> results = initiateTransfers(new List<Id>{ transferId });
        if (results == null || results.isEmpty()) {
            throw new AuraHandledException('Initiate transfer failed.');
        }
        Map<String, String> res = results[0];
        res.put('message', 'Transfer ' + res.get('transferName') + ' initiated successfully.');
        return res;
    }

    /**
     * Initiates multiple Inventory Transfers in a single atomic transaction.
     */
    @AuraEnabled
    public static List<Map<String, String>> initiateTransfers(List<Id> transferIds) {
        if (transferIds == null || transferIds.isEmpty()) {
            AuraHandledException ahe = new AuraHandledException('No transfer records selected.');
            ahe.setMessage('No transfer records selected.');
            throw ahe;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            List<Inventory_Transfer__c> transfers = Database.query(
                'SELECT Id, Name, Source_Inventory_Location__c, Source_Inventory_Location__r.Account__c, ' +
                '       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Account__c, ' +
                '       From_Account__c, To_Account__c, Item__c, Transfer_Qty__c, Status__c, ' +
                '       In_Transit_Qty__c, Shipped_Date__c, Request_Type__c, ' +
                '       Order_Allocation_Line_Item__c, ' +
                '       Order_Allocation_Line_Item__r.Supply_Request__c, ' +
                '       Order_Allocation_Line_Item__r.Source_SR_References__c, ' +
                '       Order_Allocation_Line_Item__r.Source_SR_Allocation__c ' +
                'FROM Inventory_Transfer__c ' +
                'WHERE Id IN :transferIds',
                AccessLevel.SYSTEM_MODE
            );

            Set<Id> itemIds = new Set<Id>();
            Set<Id> locIds = new Set<Id>();
            Set<Id> directOaliIds = new Set<Id>();

            for (Inventory_Transfer__c t : transfers) {
                if (t.Status__c != 'Requested') {
                    throw new AuraHandledException('ALREADY_ACTIONED:Transfer "' + t.Name + '" is already in "' + t.Status__c + '" status.');
                }
                Decimal qty = t.Transfer_Qty__c != null ? t.Transfer_Qty__c : 0;
                if (qty <= 0) {
                    throw new AuraHandledException('Transfer "' + t.Name + '" has invalid quantity: ' + qty);
                }
                if (t.Source_Inventory_Location__c == null || t.Destination_Inventory_Location__c == null) {
                    throw new AuraHandledException('Transfer "' + t.Name + '" is missing source or destination location.');
                }
                if (t.Item__c == null) {
                    throw new AuraHandledException('Transfer "' + t.Name + '" is missing an Item reference.');
                }
                itemIds.add(t.Item__c);
                locIds.add(t.Source_Inventory_Location__c);
                locIds.add(t.Destination_Inventory_Location__c);

                if (t.Order_Allocation_Line_Item__c != null) {
                    directOaliIds.add(t.Order_Allocation_Line_Item__c);
                }
            }

            // Query existing inventory records for all items and locations in System Mode
            List<Inventory__c> existingInvs = Database.query(
                'SELECT Id, Item__c, Inventory_Location__c, Available__c, Transit_Out_Quantity__c, ' +
                '       Transit_In_Quantity__c, Reserved_Sale_Order__c, Reserved__c ' +
                'FROM Inventory__c ' +
                'WHERE Item__c IN :itemIds AND Inventory_Location__c IN :locIds',
                AccessLevel.SYSTEM_MODE
            );

            Map<String, Inventory__c> invMap = new Map<String, Inventory__c>();
            for (Inventory__c inv : existingInvs) {
                invMap.put(inv.Item__c + '_' + inv.Inventory_Location__c, inv);
            }

            // Shipment Backtracking: recursively find direct OALIs and all upstream parent/ancestor OALIs in System Mode
            Map<Id, Order_Allocation_Line_Item__c> oalisToUpdateMap = new Map<Id, Order_Allocation_Line_Item__c>();
            Set<Id> allOaliIdsForReservation = new Set<Id>();

            if (!directOaliIds.isEmpty()) {
                Map<Id, Order_Allocation_Line_Item__c> allKnownOalis = new Map<Id, Order_Allocation_Line_Item__c>();
                List<Order_Allocation_Line_Item__c> qDirectOalis = Database.query(
                    'SELECT Id, Status__c, Ordered_Qty__c, Supply_Request__c, Source_SR_References__c, ' +
                    '       Source_SR_Allocation__c, Order_Allocation__c ' +
                    'FROM Order_Allocation_Line_Item__c ' +
                    'WHERE Id IN :directOaliIds',
                    AccessLevel.SYSTEM_MODE
                );
                for (Order_Allocation_Line_Item__c dOali : qDirectOalis) {
                    allKnownOalis.put(dOali.Id, dOali);
                    allOaliIdsForReservation.add(dOali.Id);
                }

                Map<Id, Supply_Request__c> allKnownSrsById = new Map<Id, Supply_Request__c>();
                Map<String, Supply_Request__c> allKnownSrsByName = new Map<String, Supply_Request__c>();
                Map<Id, Set<Id>> parentOaliToFulfillingOaliIds = new Map<Id, Set<Id>>();

                // Multi-tier traversal loop to discover all ancestor SRs and OALIs up to 10 hops
                for (Integer iter = 0; iter < 10; iter++) {
                    Boolean newRecordsFound = false;

                    // Collect SR references from known OALIs
                    Set<Id> srIdsToQuery = new Set<Id>();
                    Set<String> srNamesToQuery = new Set<String>();

                    for (Order_Allocation_Line_Item__c oali : allKnownOalis.values()) {
                        if (oali.Supply_Request__c != null && !allKnownSrsById.containsKey(oali.Supply_Request__c)) {
                            srIdsToQuery.add(oali.Supply_Request__c);
                        }
                        if (String.isNotBlank(oali.Source_SR_References__c)) {
                            for (String ref : InventoryTransferBacktrackingService.parseDelimitedString(oali.Source_SR_References__c)) {
                                if (InventoryTransferBacktrackingService.findSrByName(ref, allKnownSrsByName) == null) {
                                    InventoryTransferBacktrackingService.addNameVariants(ref, srNamesToQuery);
                                }
                            }
                        }
                        if (String.isNotBlank(oali.Source_SR_Allocation__c)) {
                            Map<String, Decimal> aMap = InventoryTransferBacktrackingService.parseAllocations(oali.Source_SR_Allocation__c);
                            for (String sName : aMap.keySet()) {
                                if (InventoryTransferBacktrackingService.findSrByName(sName, allKnownSrsByName) == null) {
                                    InventoryTransferBacktrackingService.addNameVariants(sName, srNamesToQuery);
                                }
                            }
                        }
                    }

                    // Collect parent SR references from known SRs
                    for (Supply_Request__c sr : allKnownSrsById.values()) {
                        if (sr.Supply_Request__c != null && !allKnownSrsById.containsKey(sr.Supply_Request__c)) {
                            srIdsToQuery.add(sr.Supply_Request__c);
                        }
                    }

                    // Query missing SRs in System Mode
                    if (!srIdsToQuery.isEmpty() || !srNamesToQuery.isEmpty()) {
                        List<Supply_Request__c> newSrs = new List<Supply_Request__c>();
                        if (!srIdsToQuery.isEmpty() && !srNamesToQuery.isEmpty()) {
                            newSrs = Database.query(
                                'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                                '       Request_Type__c, Supply_Request__c, Order_Allocation_Line_Item__c ' +
                                'FROM Supply_Request__c ' +
                                'WHERE Id IN :srIdsToQuery OR Name IN :srNamesToQuery',
                                AccessLevel.SYSTEM_MODE
                            );
                        } else if (!srIdsToQuery.isEmpty()) {
                            newSrs = Database.query(
                                'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                                '       Request_Type__c, Supply_Request__c, Order_Allocation_Line_Item__c ' +
                                'FROM Supply_Request__c ' +
                                'WHERE Id IN :srIdsToQuery',
                                AccessLevel.SYSTEM_MODE
                            );
                        } else if (!srNamesToQuery.isEmpty()) {
                            newSrs = Database.query(
                                'SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, RecordType.Name, ' +
                                '       Request_Type__c, Supply_Request__c, Order_Allocation_Line_Item__c ' +
                                'FROM Supply_Request__c ' +
                                'WHERE Name IN :srNamesToQuery',
                                AccessLevel.SYSTEM_MODE
                            );
                        }

                        if (!newSrs.isEmpty()) {
                            newRecordsFound = true;
                            for (Supply_Request__c sr : newSrs) {
                                allKnownSrsById.put(sr.Id, sr);
                                InventoryTransferBacktrackingService.indexSrByName(sr, allKnownSrsByName);
                            }
                        }
                    }

                    // Collect missing OALIs from known SRs
                    Set<Id> oaliIdsToQuery = new Set<Id>();
                    for (Supply_Request__c sr : allKnownSrsById.values()) {
                        if (sr.Order_Allocation_Line_Item__c != null && !allKnownOalis.containsKey(sr.Order_Allocation_Line_Item__c)) {
                            oaliIdsToQuery.add(sr.Order_Allocation_Line_Item__c);
                        }
                    }

                    if (!oaliIdsToQuery.isEmpty()) {
                        List<Order_Allocation_Line_Item__c> newOalis = Database.query(
                            'SELECT Id, Status__c, Ordered_Qty__c, Supply_Request__c, Source_SR_References__c, ' +
                            '       Source_SR_Allocation__c, Order_Allocation__c ' +
                            'FROM Order_Allocation_Line_Item__c ' +
                            'WHERE Id IN :oaliIdsToQuery',
                            AccessLevel.SYSTEM_MODE
                        );
                        if (!newOalis.isEmpty()) {
                            newRecordsFound = true;
                            for (Order_Allocation_Line_Item__c no : newOalis) {
                                allKnownOalis.put(no.Id, no);
                                allOaliIdsForReservation.add(no.Id);
                            }
                        }
                    }

                    if (!newRecordsFound) {
                        break;
                    }
                }

                // Also check for OALIs that fulfill known SRs via Supply_Request__c lookup in System Mode
                Set<Id> allKnownSrIds = allKnownSrsById.keySet();
                if (!allKnownSrIds.isEmpty()) {
                    List<Order_Allocation_Line_Item__c> fulfillingOalis = Database.query(
                        'SELECT Id, Status__c, Ordered_Qty__c, Supply_Request__c, Source_SR_References__c, ' +
                        '       Source_SR_Allocation__c, Order_Allocation__c ' +
                        'FROM Order_Allocation_Line_Item__c ' +
                        'WHERE Supply_Request__c IN :allKnownSrIds',
                        AccessLevel.SYSTEM_MODE
                    );
                    for (Order_Allocation_Line_Item__c fo : fulfillingOalis) {
                        allKnownOalis.put(fo.Id, fo);
                        allOaliIdsForReservation.add(fo.Id);
                    }
                }

                // Map each parent OALI to the direct child OALIs that fulfill it
                Map<Id, Set<Id>> directParentToChildOaliIds = new Map<Id, Set<Id>>();
                for (Order_Allocation_Line_Item__c oali : allKnownOalis.values()) {
                    directParentToChildOaliIds.put(oali.Id, new Set<Id>());
                }

                for (Order_Allocation_Line_Item__c fulfillingOali : allKnownOalis.values()) {
                    // Collect all SRs referenced/fulfilled by fulfillingOali
                    Set<Supply_Request__c> fulfilledSrs = new Set<Supply_Request__c>();
                    if (fulfillingOali.Supply_Request__c != null && allKnownSrsById.containsKey(fulfillingOali.Supply_Request__c)) {
                        fulfilledSrs.add(allKnownSrsById.get(fulfillingOali.Supply_Request__c));
                    }
                    if (String.isNotBlank(fulfillingOali.Source_SR_References__c)) {
                        for (String ref : InventoryTransferBacktrackingService.parseDelimitedString(fulfillingOali.Source_SR_References__c)) {
                            Supply_Request__c s = InventoryTransferBacktrackingService.findSrByName(ref, allKnownSrsByName);
                            if (s != null) {
                                fulfilledSrs.add(s);
                            }
                        }
                    }
                    if (String.isNotBlank(fulfillingOali.Source_SR_Allocation__c)) {
                        Map<String, Decimal> aMap = InventoryTransferBacktrackingService.parseAllocations(fulfillingOali.Source_SR_Allocation__c);
                        for (String sName : aMap.keySet()) {
                            Supply_Request__c s = InventoryTransferBacktrackingService.findSrByName(sName, allKnownSrsByName);
                            if (s != null) {
                                fulfilledSrs.add(s);
                            }
                        }
                    }

                    // For each fulfilled SR, find the parent OALI that requested this SR
                    for (Supply_Request__c s : fulfilledSrs) {
                        Supply_Request__c currS = s;
                        Set<Id> visitedHop = new Set<Id>{ currS.Id };
                        while (currS != null && currS.Order_Allocation_Line_Item__c == null && currS.Supply_Request__c != null) {
                            if (visitedHop.contains(currS.Supply_Request__c)) break;
                            visitedHop.add(currS.Supply_Request__c);
                            currS = allKnownSrsById.get(currS.Supply_Request__c);
                        }
                        if (currS != null && currS.Order_Allocation_Line_Item__c != null && allKnownOalis.containsKey(currS.Order_Allocation_Line_Item__c)) {
                            Id parentOaliId = currS.Order_Allocation_Line_Item__c;
                            if (parentOaliId != fulfillingOali.Id) {
                                directParentToChildOaliIds.get(parentOaliId).add(fulfillingOali.Id);
                            }
                        }
                    }
                }

                // Compute transitive closure: parentOaliToFulfillingOaliIds
                // Each OALI's shipped quantity is contributed to by itself and all descendant fulfilling OALIs
                for (Order_Allocation_Line_Item__c oali : allKnownOalis.values()) {
                    Set<Id> allFulfilling = new Set<Id>{ oali.Id };
                    List<Id> toProcess = new List<Id>(directParentToChildOaliIds.get(oali.Id));
                    Set<Id> visited = new Set<Id>(toProcess);
                    while (!toProcess.isEmpty()) {
                        Id childId = toProcess.remove(0);
                        allFulfilling.add(childId);
                        if (directParentToChildOaliIds.containsKey(childId)) {
                            for (Id grandChildId : directParentToChildOaliIds.get(childId)) {
                                if (!visited.contains(grandChildId)) {
                                    visited.add(grandChildId);
                                    toProcess.add(grandChildId);
                                }
                            }
                        }
                    }
                    parentOaliToFulfillingOaliIds.put(oali.Id, allFulfilling);
                }

                // Query all non-cancelled Inventory Transfers related to any discovered OALIs in System Mode
                Set<Id> allRelevantOaliIds = allKnownOalis.keySet();
                Map<Id, List<Inventory_Transfer__c>> transfersByOaliId = new Map<Id, List<Inventory_Transfer__c>>();
                List<Inventory_Transfer__c> relatedTransfers = Database.query(
                    'SELECT Id, Name, Order_Allocation_Line_Item__c, Transfer_Qty__c, ' +
                    '       In_Transit_Qty__c, Received_Qty__c, Status__c ' +
                    'FROM Inventory_Transfer__c ' +
                    'WHERE Order_Allocation_Line_Item__c IN :allRelevantOaliIds ' +
                    'AND Status__c != \'Cancelled\'',
                    AccessLevel.SYSTEM_MODE
                );
                for (Inventory_Transfer__c tRel : relatedTransfers) {
                    if (!transfersByOaliId.containsKey(tRel.Order_Allocation_Line_Item__c)) {
                        transfersByOaliId.put(tRel.Order_Allocation_Line_Item__c, new List<Inventory_Transfer__c>());
                    }
                    transfersByOaliId.get(tRel.Order_Allocation_Line_Item__c).add(tRel);
                }

                // Calculate cumulative shipped quantity and update status for ALL levels of OALIs
                for (Order_Allocation_Line_Item__c oali : allKnownOalis.values()) {
                    Set<Id> contributingOaliIds = parentOaliToFulfillingOaliIds.containsKey(oali.Id)
                        ? parentOaliToFulfillingOaliIds.get(oali.Id)
                        : new Set<Id>{ oali.Id };

                    Decimal cumulativeShipped = 0;
                    Set<Id> countedTransferIds = new Set<Id>();

                    // 1. Transfers currently being initiated
                    for (Inventory_Transfer__c tCurrent : transfers) {
                        if (contributingOaliIds.contains(tCurrent.Order_Allocation_Line_Item__c)) {
                            cumulativeShipped += (tCurrent.Transfer_Qty__c != null ? tCurrent.Transfer_Qty__c : 0);
                            if (tCurrent.Id != null) {
                                countedTransferIds.add(tCurrent.Id);
                            }
                        }
                    }

                    // 2. Existing transfers in DB
                    for (Id cId : contributingOaliIds) {
                        if (transfersByOaliId.containsKey(cId)) {
                            for (Inventory_Transfer__c tDb : transfersByOaliId.get(cId)) {
                                if (countedTransferIds.contains(tDb.Id)) {
                                    continue;
                                }
                                if (tDb.Status__c == 'In Transit') {
                                    cumulativeShipped += (tDb.In_Transit_Qty__c != null && tDb.In_Transit_Qty__c > 0 ? tDb.In_Transit_Qty__c : (tDb.Transfer_Qty__c != null ? tDb.Transfer_Qty__c : 0));
                                } else if (tDb.Status__c == 'Received') {
                                    cumulativeShipped += (tDb.Received_Qty__c != null && tDb.Received_Qty__c > 0 ? tDb.Received_Qty__c : (tDb.Transfer_Qty__c != null ? tDb.Transfer_Qty__c : 0));
                                }
                            }
                        }
                    }

                    String newStatus = InventoryTransferBacktrackingService.determineShipmentStatus(oali.Ordered_Qty__c, cumulativeShipped, oali.Status__c);
                    if (newStatus != oali.Status__c) {
                        oali.Status__c = newStatus;
                        oalisToUpdateMap.put(oali.Id, oali);
                        System.debug(LoggingLevel.INFO, '[InventoryTransferPending] OALI ' + oali.Id + ' Status updated to ' + newStatus + ' (Ordered=' + oali.Ordered_Qty__c + ', Shipped=' + cumulativeShipped + ')');
                    }
                }
            }

            // Update reservations on direct and upstream OALIs to 'Consumed' in System Mode
            if (!allOaliIdsForReservation.isEmpty()) {
                List<Inventory_Reservation__c> resList = Database.query(
                    'SELECT Id, Status__c ' +
                    'FROM Inventory_Reservation__c ' +
                    'WHERE Order_Allocation_Line_Item__c IN :allOaliIdsForReservation ' +
                    'AND Status__c != \'Consumed\'',
                    AccessLevel.SYSTEM_MODE
                );
                for (Inventory_Reservation__c r : resList) {
                    r.Status__c = 'Consumed';
                }
                if (!resList.isEmpty()) {
                    Database.update(resList, false, AccessLevel.SYSTEM_MODE);
                }
            }

            // Process each transfer
            List<Map<String, String>> results = new List<Map<String, String>>();
            for (Inventory_Transfer__c t : transfers) {
                Decimal qty = t.Transfer_Qty__c != null ? t.Transfer_Qty__c : 0;

                // Source inventory
                String sourceKey = t.Item__c + '_' + t.Source_Inventory_Location__c;
                Inventory__c sourceInv = invMap.get(sourceKey);
                Decimal sourceReserved = (sourceInv != null && sourceInv.Reserved_Sale_Order__c != null) 
                    ? sourceInv.Reserved_Sale_Order__c : 0;

                if (sourceReserved < qty) {
                    throw new AuraHandledException(
                        'Initiate failed: Insufficient Reserved for Sales Order quantity for transfer ' + 
                        t.Name + '. Required: ' + qty + ', Available: ' + sourceReserved
                    );
                }

                sourceInv.Reserved_Sale_Order__c = sourceReserved - qty;
                sourceInv.Transit_Out_Quantity__c = (sourceInv.Transit_Out_Quantity__c != null ? sourceInv.Transit_Out_Quantity__c : 0) + qty;

                // Destination inventory
                String destKey = t.Item__c + '_' + t.Destination_Inventory_Location__c;
                Inventory__c destInv = invMap.get(destKey);
                if (destInv != null) {
                    destInv.Transit_In_Quantity__c = (destInv.Transit_In_Quantity__c != null ? destInv.Transit_In_Quantity__c : 0) + qty;
                } else {
                    destInv = new Inventory__c(
                        Item__c = t.Item__c,
                        Inventory_Location__c = t.Destination_Inventory_Location__c,
                        Transit_In_Quantity__c = qty,
                        Available__c = 0,
                        Reserved_Sale_Order__c = 0
                    );
                    invMap.put(destKey, destInv);
                }

                t.Status__c = 'In Transit';
                t.In_Transit_Qty__c = qty;
                t.Shipped_Date__c = Date.today();
                t.Shipped_Date_Time__c = System.now();

                Map<String, String> res = new Map<String, String>();
                res.put('transferName', t.Name);
                res.put('status', 'In Transit');
                results.add(res);
            }

            Database.upsert(invMap.values(), false, AccessLevel.SYSTEM_MODE);
            if (!oalisToUpdateMap.isEmpty()) {
                InventoryTransferBacktrackingService.ensureParentOaAccess(oalisToUpdateMap.values());
                List<Order_Allocation_Line_Item__c> cleanOaliUpdates = new List<Order_Allocation_Line_Item__c>();
                for (Order_Allocation_Line_Item__c oali : oalisToUpdateMap.values()) {
                    cleanOaliUpdates.add(new Order_Allocation_Line_Item__c(
                        Id = oali.Id,
                        Status__c = oali.Status__c
                    ));
                }
                List<Database.SaveResult> oaliResults = Database.update(cleanOaliUpdates, false, AccessLevel.SYSTEM_MODE);
                for (Database.SaveResult sr : oaliResults) {
                    if (!sr.isSuccess()) {
                        for (Database.Error err : sr.getErrors()) {
                            System.debug(LoggingLevel.WARN, '[InventoryTransferPending] OALI ' + sr.getId() + ' update warning: ' + err.getStatusCode() + ' - ' + err.getMessage());
                        }
                    }
                }
            }
            Database.update(transfers, false, AccessLevel.SYSTEM_MODE);

            return results;
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, 'Error in initiateTransfers: ' + e.getMessage() + '\n' + e.getStackTraceString());
            String errorMsg = e.getMessage();
            AuraHandledException ahe = new AuraHandledException(errorMsg);
            ahe.setMessage(errorMsg);
            throw ahe;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Inventory_Transfer__c> getDashboardTransfers() {
        try {
            Boolean isAdmin = isSystemAdministrator();
            Set<Id> userAccountIds = isAdmin ? new Set<Id>() : getUserAccountIds();

            if (!isAdmin && userAccountIds.isEmpty()) {
                return new List<Inventory_Transfer__c>();
            }

            if (isAdmin) {
                return [
                    SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c,
                           Source_Inventory_Location__c, Source_Inventory_Location__r.Name, 
                           Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name, 
                           Transfer_Qty__c, Requested_Date__c, Shipped_Date__c, Received_Date__c, Status__c, Request_Type__c,
                           In_Transit_Qty__c, Received_Qty__c,
                           From_Account__c, To_Account__c,
                           Order_Allocation_Line_Item__r.Order_Allocation__r.Name,
                           Order_Allocation_Line_Item__r.Name
                    FROM Inventory_Transfer__c 
                    WHERE Status__c IN ('Requested', 'Approved', 'In Transit', 'Received')
                    ORDER BY Requested_Date__c DESC
                ];
            } else {
                return [
                    SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c,
                           Source_Inventory_Location__c, Source_Inventory_Location__r.Name, 
                           Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name, 
                           Transfer_Qty__c, Requested_Date__c, Shipped_Date__c, Received_Date__c, Status__c, Request_Type__c,
                           In_Transit_Qty__c, Received_Qty__c,
                           From_Account__c, To_Account__c,
                           Order_Allocation_Line_Item__r.Order_Allocation__r.Name,
                           Order_Allocation_Line_Item__r.Name
                    FROM Inventory_Transfer__c 
                    WHERE Status__c IN ('Requested', 'Approved', 'In Transit', 'Received')
                    AND (From_Account__c IN :userAccountIds OR To_Account__c IN :userAccountIds)
                    ORDER BY Requested_Date__c DESC
                ];
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in getDashboardTransfers: ' + e.getMessage());
            AuraHandledException ahe = new AuraHandledException('Error loading dashboard transfers: ' + e.getMessage());
            ahe.setMessage('Error loading dashboard transfers: ' + e.getMessage());
            throw ahe;
        }
    }
}