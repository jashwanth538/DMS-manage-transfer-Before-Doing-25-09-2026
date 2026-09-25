public without sharing class SupplyOrderPlanner {

    private static AuraHandledException createAuraException(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public static Map<String, Object> resolveProcurementAccount(Id supplyingAccId) {
        return SupplyOrderGenService.resolveProcurementAccount(supplyingAccId);
    }

    public static Inventory_Location__c resolveReserveLocation(Order_Allocation__c plan, Id supplyingAccId) {
        return SupplyOrderGenService.resolveReserveLocation(plan, supplyingAccId);
    }

    public class PlanWrapper {
        @AuraEnabled public Id planId {get; set;}
        @AuraEnabled public String planName {get; set;}
        @AuraEnabled public Id destinationLocationId {get; set;}
        @AuraEnabled public String destinationLocationName {get; set;}
        @AuraEnabled public String procurementAccountName {get; set;}
        @AuraEnabled public List<LocationInfo> transferLocations {get; set;}
        @AuraEnabled public List<LineItemWrapper> lineItems {get; set;}
        @AuraEnabled public Boolean isDestinationLocationActive {get; set;}
        @AuraEnabled public String status {get; set;}
    }

    public class LocationInfo {
        @AuraEnabled public Id locationId {get; set;}
        @AuraEnabled public String locationName {get; set;}
        
        public LocationInfo(Id locId, String name) {
            this.locationId = locId;
            this.locationName = name;
        }
    }

    public class LineItemWrapper {
        @AuraEnabled public Id lineItemId {get; set;}
        @AuraEnabled public String lineItemName {get; set;}
        @AuraEnabled public Id itemId {get; set;}
        @AuraEnabled public String itemName {get; set;}
        @AuraEnabled public String itemCode {get; set;}
        @AuraEnabled public Decimal requiredQty {get; set;}
        @AuraEnabled public Decimal destinationStock {get; set;}
        // Map of locationId -> available qty
        @AuraEnabled public Map<Id, Decimal> transferStocks {get; set;}
        @AuraEnabled public Boolean isReviewed {get; set;}
        @AuraEnabled public Decimal reserveQtyPlanned {get; set;}
        @AuraEnabled public Decimal transferQtyPlanned {get; set;}
        @AuraEnabled public Map<Id, Decimal> transferQtyPlannedMap {get; set;}
        @AuraEnabled public Decimal procureQtyPlanned {get; set;}
        @AuraEnabled public String status {get; set;}
    }

    @AuraEnabled
    public static PlanWrapper getSupplyPlanData(String planNumber) {
        System.debug('*** getSupplyPlanData start. planNumber: ' + planNumber);
        if (String.isBlank(planNumber)) {
            throw createAuraException('Order Allocation Identifier is required.');
        }

        List<Order_Allocation__c> plans = new List<Order_Allocation__c>();

        // Check if planNumber is a valid Salesforce ID
        Boolean isId = false;
        try {
            Id tempId = (Id)planNumber.trim();
            isId = true;
        } catch (Exception e) {
            isId = false;
        }
        System.debug('*** planNumber evaluated: isId=' + isId);

        if (isId) {
            plans = [
                SELECT Id, Name, Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Name, Target_Location__r.Is_Active__c, Target_Location__r.Account__c, Source_Location__c, Source_Location__r.Name, Status__c
                FROM Order_Allocation__c 
                WHERE Id = :planNumber.trim() 
                LIMIT 1
            ];
            System.debug('*** Queried plans by ID. Found: ' + plans.size());
        }

        if (plans.isEmpty()) {
            // Sanitize search term (allow space-insensitive matches, e.g. "SP-0001" or "SP - 0001")
            String searchTerm = '%' + planNumber.replaceAll('\\s+', '%') + '%';
            plans = [
                SELECT Id, Name, Requesting_Account__c, Supplying_Account__c, Target_Location__c, Target_Location__r.Name, Target_Location__r.Is_Active__c, Target_Location__r.Account__c, Source_Location__c, Source_Location__r.Name, Status__c
                FROM Order_Allocation__c 
                WHERE Name LIKE :searchTerm 
                LIMIT 1
            ];
            System.debug('*** Queried plans by Name LIKE "' + searchTerm + '". Found: ' + plans.size());
        }

        if (plans.isEmpty()) {
            System.debug('*** No Order Allocation found matching planNumber: ' + planNumber);
            throw createAuraException('No Order Allocation found matching "' + planNumber + '".');
        }

        Order_Allocation__c plan = plans[0];
        Id supplyingAccId = plan.Supplying_Account__c != null ? plan.Supplying_Account__c : (plan.Target_Location__r != null ? plan.Target_Location__r.Account__c : null);

        // Resolve Reserve Location (Supplying Account's inventory location, not Requesting Account's location)
        Inventory_Location__c reserveLoc = resolveReserveLocation(plan, supplyingAccId);

        Id destLocId = reserveLoc != null ? reserveLoc.Id : plan.Target_Location__c;
        String destLocName = reserveLoc != null ? reserveLoc.Name : (plan.Target_Location__r != null ? plan.Target_Location__r.Name : 'Unknown');
        Boolean isDestLocActive = reserveLoc != null ? reserveLoc.Is_Active__c : (plan.Target_Location__r != null ? plan.Target_Location__r.Is_Active__c : false);
        System.debug('*** Found Order Allocation: ID=' + plan.Id + ', Name=' + plan.Name + ', SupplyingAccount=' + supplyingAccId + ', ReserveLocation=' + destLocName + ', Status=' + plan.Status__c);

        // Resolve Procurement Account (Immediate Parent of Supplying Account)
        Map<String, Object> procAccInfo = resolveProcurementAccount(supplyingAccId);
        String procAccName = (String)procAccInfo.get('name');

        // Determine DMS Eligible Child Accounts — strict one-level children only.
        // Delegates to SupplyOrderGenService for single source of truth:
        //   OEM -> Distributor ONLY, Distributor -> Dealer ONLY, Dealer -> Retailer ONLY
        Set<Id> eligibleAccountIds = SupplyOrderGenService.getEligibleChildAccounts(supplyingAccId);
        // Remove Requesting Account — its locations must not appear as transfer options
        if (plan.Requesting_Account__c != null) {
            eligibleAccountIds.remove(plan.Requesting_Account__c);
        }

        // Query child line items
        List<Order_Allocation_Line_Item__c> lineItems = [
            SELECT Id, Name, Item__c, Item__r.Name, Item__r.Item_Code__c, Ordered_Qty__c, Is_Reviewed__c, Status__c,
                   Reserved_Qty_Planned__c, Transfer_Qty_Planned__c, Procurement_Qty_Planned__c, Reserved_Quantity__c
            FROM Order_Allocation_Line_Item__c 
            WHERE Order_Allocation__c = :plan.Id
        ];
        System.debug('*** Queried child line items. Count: ' + lineItems.size());

        // Gather all Item IDs and Line Item IDs
        Set<Id> itemIds = new Set<Id>();
        Set<Id> lineItemIds = new Set<Id>();
        for (Order_Allocation_Line_Item__c li : lineItems) {
            if (li.Item__c != null) {
                itemIds.add(li.Item__c);
            }
            lineItemIds.add(li.Id);
        }

        // Query existing Transfer Supply Requests (and any existing Inventory Transfers) for these line items
        List<Supply_Request__c> existingTransferSRs = [
            SELECT Source_Location__c, Source_Location__r.Name, Requested_Qty__c, Order_Allocation_Line_Item__c
            FROM Supply_Request__c
            WHERE Order_Allocation_Line_Item__c IN :lineItemIds 
              AND (Request_Type__c = 'Transfer SR' OR RecordType.DeveloperName = 'Transfer_Supply_Request')
              AND Status__c != 'Cancelled'
        ];
        System.debug('*** Queried existing Transfer SRs. Count: ' + existingTransferSRs.size());

        List<Inventory_Transfer__c> existingTransfers = [
            SELECT Source_Inventory_Location__c, Source_Inventory_Location__r.Name, Transfer_Qty__c, Order_Allocation_Line_Item__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c IN :lineItemIds AND Status__c != 'Cancelled'
        ];
        System.debug('*** Queried existing active transfers. Count: ' + existingTransfers.size());

        // Map: LineItemId -> SourceLocationId -> Quantity
        Map<Id, Map<Id, Decimal>> lineItemLocTransferMap = new Map<Id, Map<Id, Decimal>>();
        for (Supply_Request__c sr : existingTransferSRs) {
            if (sr.Order_Allocation_Line_Item__c != null && sr.Source_Location__c != null) {
                if (!lineItemLocTransferMap.containsKey(sr.Order_Allocation_Line_Item__c)) {
                    lineItemLocTransferMap.put(sr.Order_Allocation_Line_Item__c, new Map<Id, Decimal>());
                }
                Map<Id, Decimal> transfersForLi = lineItemLocTransferMap.get(sr.Order_Allocation_Line_Item__c);
                Decimal currentVal = transfersForLi.containsKey(sr.Source_Location__c) ? transfersForLi.get(sr.Source_Location__c) : 0;
                transfersForLi.put(sr.Source_Location__c, currentVal + (sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0));
            }
        }
        for (Inventory_Transfer__c it : existingTransfers) {
            if (it.Order_Allocation_Line_Item__c != null && it.Source_Inventory_Location__c != null) {
                if (!lineItemLocTransferMap.containsKey(it.Order_Allocation_Line_Item__c)) {
                    lineItemLocTransferMap.put(it.Order_Allocation_Line_Item__c, new Map<Id, Decimal>());
                }
                Map<Id, Decimal> transfersForLi = lineItemLocTransferMap.get(it.Order_Allocation_Line_Item__c);
                if (!transfersForLi.containsKey(it.Source_Inventory_Location__c)) {
                    Decimal currentVal = transfersForLi.containsKey(it.Source_Inventory_Location__c) ? transfersForLi.get(it.Source_Inventory_Location__c) : 0;
                    transfersForLi.put(it.Source_Inventory_Location__c, currentVal + (it.Transfer_Qty__c != null ? it.Transfer_Qty__c : 0));
                }
            }
        }

        // Query Inventory levels for these items (Filter by Supplying Account + Eligible Child Accounts)
        Set<Id> targetAccountIds = new Set<Id>();
        if (supplyingAccId != null) targetAccountIds.add(supplyingAccId);
        targetAccountIds.addAll(eligibleAccountIds);

        List<Inventory__c> stocks;
        if (!targetAccountIds.isEmpty()) {
            stocks = [
                SELECT Item__c, Account__c, Inventory_Location__c, Inventory_Location__r.Name, Available__c 
                FROM Inventory__c 
                WHERE Item__c IN :itemIds AND Account__c IN :targetAccountIds
            ];
        } else {
            // Fallback for environment setup where Account__c may not be populated on Inventory__c
            stocks = [
                SELECT Item__c, Account__c, Inventory_Location__c, Inventory_Location__r.Name, Available__c 
                FROM Inventory__c 
                WHERE Item__c IN :itemIds
            ];
        }
        System.debug('*** [INVENTORY QUERY] Count: ' + stocks.size() + ', targetAccountIds: ' + targetAccountIds + ', itemIds: ' + itemIds);
        for (Inventory__c s : stocks) {
            System.debug('*** [INVENTORY STOCK RECORD] Item: ' + s.Item__c + ', LocId: ' + s.Inventory_Location__c + ', LocName: ' + (s.Inventory_Location__r != null ? s.Inventory_Location__r.Name : '') + ', Account: ' + s.Account__c + ', Available: ' + s.Available__c);
        }

        // Collect locations that have inventory records or existing transfers/SRs
        Set<Id> locationsWithInventory = new Set<Id>();
        for (Inventory__c stock : stocks) {
            if (stock.Inventory_Location__c != null) {
                locationsWithInventory.add(stock.Inventory_Location__c);
            }
        }
        for (Supply_Request__c sr : existingTransferSRs) {
            if (sr.Source_Location__c != null) {
                locationsWithInventory.add(sr.Source_Location__c);
            }
        }
        for (Inventory_Transfer__c it : existingTransfers) {
            if (it.Source_Inventory_Location__c != null) {
                locationsWithInventory.add(it.Source_Inventory_Location__c);
            }
        }

        // Exclude Reserve Location (destLocId), Requesting Location, and Requesting Account's locations from Transfer columns
        Id requestingAccId = plan.Requesting_Account__c;
        Id requestingLocId = plan.Target_Location__c;

        Set<Id> excludedLocIds = new Set<Id>();
        if (destLocId != null) excludedLocIds.add(destLocId);
        if (requestingLocId != null) excludedLocIds.add(requestingLocId);

        List<Inventory_Location__c> allOtherLocations;
        if (requestingAccId != null) {
            allOtherLocations = [
                SELECT Id, Name, Account__c, Account__r.Name 
                FROM Inventory_Location__c 
                WHERE Id NOT IN :excludedLocIds 
                  AND Account__c != :requestingAccId 
                  AND Account__c IN :eligibleAccountIds
                  AND Is_Active__c = true 
                  AND Id IN :locationsWithInventory
                ORDER BY Name ASC
            ];
        } else {
            allOtherLocations = [
                SELECT Id, Name, Account__c, Account__r.Name 
                FROM Inventory_Location__c 
                WHERE Id NOT IN :excludedLocIds 
                  AND Account__c IN :eligibleAccountIds
                  AND Is_Active__c = true 
                  AND Id IN :locationsWithInventory
                ORDER BY Name ASC
            ];
        }
        System.debug('*** Queried other active transfer locations. Count: ' + allOtherLocations.size());

        List<LocationInfo> transferLocs = new List<LocationInfo>();
        for (Inventory_Location__c loc : allOtherLocations) {
            String displayName = (loc.Account__r != null && String.isNotBlank(loc.Account__r.Name))
                ? loc.Account__r.Name + ' (' + loc.Name + ')'
                : loc.Name;
            transferLocs.add(new LocationInfo(loc.Id, displayName));
        }

        // Map: ItemId -> LocationId -> Available Qty
        Map<Id, Map<Id, Decimal>> itemLocStockMap = new Map<Id, Map<Id, Decimal>>();
        for (Inventory__c stock : stocks) {
            if (!itemLocStockMap.containsKey(stock.Item__c)) {
                itemLocStockMap.put(stock.Item__c, new Map<Id, Decimal>());
            }
            itemLocStockMap.get(stock.Item__c).put(stock.Inventory_Location__c, stock.Available__c);
        }

        // Build wrapped line items
        List<LineItemWrapper> wrappedItems = new List<LineItemWrapper>();
        for (Order_Allocation_Line_Item__c li : lineItems) {
            LineItemWrapper wrapper = new LineItemWrapper();
            wrapper.lineItemId = li.Id;
            wrapper.lineItemName = li.Name;
            wrapper.itemId = li.Item__c;
            wrapper.itemName = li.Item__r.Name;
            wrapper.itemCode = li.Item__r.Item_Code__c;
            wrapper.requiredQty = li.Ordered_Qty__c != null ? li.Ordered_Qty__c : 0;
            
            // Destination stock (null means no record exists)
            Decimal destStock = null;
            if (li.Item__c != null && itemLocStockMap.containsKey(li.Item__c) && destLocId != null) {
                if (itemLocStockMap.get(li.Item__c).containsKey(destLocId)) {
                    Decimal val = itemLocStockMap.get(li.Item__c).get(destLocId);
                    destStock = val != null ? val : 0;
                }
            }
            wrapper.destinationStock = destStock;

            // Transfer locations stock (null means no record exists)
            wrapper.transferStocks = new Map<Id, Decimal>();
            for (LocationInfo loc : transferLocs) {
                Decimal transStock = null;
                if (li.Item__c != null && itemLocStockMap.containsKey(li.Item__c)) {
                    if (itemLocStockMap.get(li.Item__c).containsKey(loc.locationId)) {
                        Decimal val = itemLocStockMap.get(li.Item__c).get(loc.locationId);
                        transStock = val != null ? val : 0;
                    }
                }
                wrapper.transferStocks.put(loc.locationId, transStock);
            }
            wrapper.isReviewed = li.Is_Reviewed__c != null ? li.Is_Reviewed__c : false;

            // Populate pre-saved planned values
            wrapper.reserveQtyPlanned = li.Reserved_Qty_Planned__c != null ? li.Reserved_Qty_Planned__c : 0;
            wrapper.transferQtyPlanned = li.Transfer_Qty_Planned__c != null ? li.Transfer_Qty_Planned__c : 0;
            wrapper.procureQtyPlanned = li.Procurement_Qty_Planned__c != null ? li.Procurement_Qty_Planned__c : 0;
            
            wrapper.transferQtyPlannedMap = new Map<Id, Decimal>();
            Map<Id, Decimal> transfersForLi = lineItemLocTransferMap.get(li.Id);
            Decimal totalAssignedTransfers = 0;
            for (LocationInfo loc : transferLocs) {
                Decimal val = 0;
                if (transfersForLi != null && transfersForLi.containsKey(loc.locationId)) {
                    val = transfersForLi.get(loc.locationId);
                }
                totalAssignedTransfers += val;
                wrapper.transferQtyPlannedMap.put(loc.locationId, val);
            }
            // If total assigned from existing DB transfers is less than li.Transfer_Qty_Planned__c, allocate remainder to transfer locations
            if (li.Transfer_Qty_Planned__c != null && li.Transfer_Qty_Planned__c > totalAssignedTransfers && !transferLocs.isEmpty()) {
                Decimal unassignedTransfer = li.Transfer_Qty_Planned__c - totalAssignedTransfers;
                Id targetLocId = transferLocs[0].locationId;
                for (LocationInfo loc : transferLocs) {
                    Decimal stock = (itemLocStockMap.containsKey(li.Item__c) && itemLocStockMap.get(li.Item__c).containsKey(loc.locationId)) 
                        ? itemLocStockMap.get(li.Item__c).get(loc.locationId) : 0;
                    if (stock > 0) {
                        targetLocId = loc.locationId;
                        break;
                    }
                }
                Decimal curVal = wrapper.transferQtyPlannedMap.get(targetLocId);
                wrapper.transferQtyPlannedMap.put(targetLocId, (curVal != null ? curVal : 0) + unassignedTransfer);
            }
            wrapper.status = li.Status__c;

            wrappedItems.add(wrapper);
        }

        PlanWrapper result = new PlanWrapper();
        result.planId = plan.Id;
        result.planName = plan.Name;
        result.destinationLocationId = destLocId;
        result.destinationLocationName = destLocName;
        result.procurementAccountName = procAccName;
        result.isDestinationLocationActive = isDestLocActive;
        result.status = plan.Status__c;
        result.transferLocations = transferLocs;
        result.lineItems = wrappedItems;

        System.debug('*** getSupplyPlanData completed successfully.');
        return result;
    }

    @AuraEnabled
    public static void updateLineItemReviewStatus(Id lineItemId, Boolean isReviewed) {
        if (lineItemId == null) {
            throw createAuraException('Line Item ID is required.');
        }
        Order_Allocation_Line_Item__c li = new Order_Allocation_Line_Item__c(
            Id = lineItemId,
            Is_Reviewed__c = isReviewed
        );
        update li;
    }

    @AuraEnabled
    public static void updateBulkLineItemReviewStatus(List<Id> lineItemIds, Boolean isReviewed) {
        if (lineItemIds == null || lineItemIds.isEmpty()) {
            return;
        }
        List<Order_Allocation_Line_Item__c> itemsToUpdate = new List<Order_Allocation_Line_Item__c>();
        for (Id lineItemId : lineItemIds) {
            if (lineItemId != null) {
                itemsToUpdate.add(new Order_Allocation_Line_Item__c(
                    Id = lineItemId,
                    Is_Reviewed__c = isReviewed
                ));
            }
        }
        if (!itemsToUpdate.isEmpty()) {
            update itemsToUpdate;
        }
    }

    public class AllocationWrapper {
        @AuraEnabled public Id lineItemId {get; set;}
        @AuraEnabled public Decimal reserveQty {get; set;}
        @AuraEnabled public List<TransferWrapper> transfers {get; set;}
        @AuraEnabled public Decimal procureQty {get; set;}
    }

    public class TransferWrapper {
        @AuraEnabled public Id locationId {get; set;}
        @AuraEnabled public Decimal qty {get; set;}
    }

    /**
     * Submit planned allocations to create reservations, transfers, Transfer SRs/POs/POLIs, and procurement SRs/POs/POLIs.
     * Delegates to SupplyOrderGenService.
     */
    @AuraEnabled
    public static void submitPlanning(List<AllocationWrapper> allocations) {
        SupplyOrderGenService.submitPlanning(allocations);
    }
}