public without sharing class SupplyOrderGenService {

    private static AuraHandledException createAuraException(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public static Map<String, Object> resolveProcurementAccount(Id supplyingAccId) {
        Map<String, Object> res = new Map<String, Object>();
        res.put('id', null);
        res.put('name', null);

        if (supplyingAccId == null) {
            return res;
        }

        List<Account> suppAccList = [
            SELECT Id, Name, Type, ParentId, Parent.Name, Dealer__c, Dealer__r.Name, Distributor__c, Distributor__r.Name, OEM__c, OEM__r.Name 
            FROM Account 
            WHERE Id = :supplyingAccId 
            LIMIT 1
        ];

        if (suppAccList.isEmpty()) {
            return res;
        }

        Account suppAcc = suppAccList[0];

        // Check immediate parent relationships in hierarchy order: Parent Account -> Dealer -> Distributor -> OEM
        if (suppAcc.ParentId != null) {
            res.put('id', suppAcc.ParentId);
            res.put('name', suppAcc.Parent != null ? suppAcc.Parent.Name : null);
            return res;
        } else if (suppAcc.Dealer__c != null) {
            res.put('id', suppAcc.Dealer__c);
            res.put('name', suppAcc.Dealer__r != null ? suppAcc.Dealer__r.Name : null);
            return res;
        } else if (suppAcc.Distributor__c != null) {
            res.put('id', suppAcc.Distributor__c);
            res.put('name', suppAcc.Distributor__r != null ? suppAcc.Distributor__r.Name : null);
            return res;
        } else if (suppAcc.OEM__c != null) {
            res.put('id', suppAcc.OEM__c);
            res.put('name', suppAcc.OEM__r != null ? suppAcc.OEM__r.Name : null);
            return res;
        }

        // Fallback: Check for OEM account in the system
        if (suppAcc.Type != 'OEM') {
            List<Account> oems = [SELECT Id, Name FROM Account WHERE Type = 'OEM' LIMIT 1];
            if (!oems.isEmpty()) {
                res.put('id', oems[0].Id);
                res.put('name', oems[0].Name);
                return res;
            }
        }

        return res;
    }

    public static Inventory_Location__c resolveReserveLocation(Order_Allocation__c plan, Id supplyingAccId) {
        if (plan == null) return null;
        if (plan.Target_Location__r != null && plan.Target_Location__r.Account__c == supplyingAccId) {
            return plan.Target_Location__r;
        }
        if (supplyingAccId != null) {
            List<Inventory_Location__c> suppLocs = [
                SELECT Id, Name, Is_Active__c, Account__c
                FROM Inventory_Location__c
                WHERE Account__c = :supplyingAccId AND Is_Active__c = true
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];
            if (!suppLocs.isEmpty()) {
                return suppLocs[0];
            }
            suppLocs = [
                SELECT Id, Name, Is_Active__c, Account__c
                FROM Inventory_Location__c
                WHERE Account__c = :supplyingAccId
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];
            if (!suppLocs.isEmpty()) {
                return suppLocs[0];
            }
        }
        return plan.Target_Location__r;
    }

    /**
     * Determines DMS Eligible Child Accounts (strictly ONE level of children of Supplying Account).
     * Hierarchy: OEM -> Distributor -> Dealer -> Retailer.
     * - OEM: Direct 1-level children are Distributors only.
     * - Distributor: Direct 1-level children are Dealers only (Retailers excluded).
     * - Dealer: Direct 1-level children are Retailers only.
     * - Generic / Fallback: Immediate children via ParentId.
     */
    public static Set<Id> getEligibleChildAccounts(Id supplyingAccId) {
        Set<Id> eligibleAccountIds = new Set<Id>();
        if (supplyingAccId == null) {
            return eligibleAccountIds;
        }

        List<Account> suppAccList = [
            SELECT Id, Name, Type, ParentId, Dealer__c, Distributor__c, OEM__c 
            FROM Account 
            WHERE Id = :supplyingAccId 
            LIMIT 1
        ];

        if (suppAccList.isEmpty()) {
            return eligibleAccountIds;
        }

        Account supplyingAcc = suppAccList[0];
        if (supplyingAcc.Type == 'OEM') {
            // OEM -> Strict 1-level children: Distributors ONLY (no Dealers, no Retailers)
            for (Account acc : [
                SELECT Id 
                FROM Account 
                WHERE (OEM__c = :supplyingAccId OR ParentId = :supplyingAccId)
                  AND Type = 'Distributor'
            ]) {
                eligibleAccountIds.add(acc.Id);
            }
        } else if (supplyingAcc.Type == 'Distributor') {
            // Distributor -> Strict 1-level children: Dealers ONLY (no Retailers)
            for (Account acc : [
                SELECT Id 
                FROM Account 
                WHERE (Distributor__c = :supplyingAccId OR ParentId = :supplyingAccId)
                  AND Type = 'Dealer'
            ]) {
                eligibleAccountIds.add(acc.Id);
            }
        } else if (supplyingAcc.Type == 'Dealer') {
            // Dealer -> Strict 1-level children: Retailers ONLY
            for (Account acc : [
                SELECT Id 
                FROM Account 
                WHERE (Dealer__c = :supplyingAccId OR ParentId = :supplyingAccId)
                  AND Type = 'Retailer'
            ]) {
                eligibleAccountIds.add(acc.Id);
            }
        } else {
            // Fallback for generic hierarchy: immediate 1-level children via ParentId
            for (Account acc : [
                SELECT Id 
                FROM Account 
                WHERE ParentId = :supplyingAccId
            ]) {
                eligibleAccountIds.add(acc.Id);
            }
        }

        // Supplying account itself must never be in child accounts
        eligibleAccountIds.remove(supplyingAccId);

        return eligibleAccountIds;
    }

    private class PoBundle {
        public Purchase_Order__c po;
        public List<Purchase_Order_Line_Item__c> lines;
        public PoBundle(Purchase_Order__c po) {
            this.po = po;
            this.lines = new List<Purchase_Order_Line_Item__c>();
        }
    }

    /**
     * Submit planned allocations to create reservations, transfers, Transfer SRs/POs/POLIs, and procurement SRs/POs/POLIs.
     * Records are created strictly for their respective partial quantities and never for the full ordered quantity.
     */
    public static void submitPlanning(List<SupplyOrderPlanner.AllocationWrapper> allocations) {
        System.debug('*** SupplyOrderGenService.submitPlanning start. Allocations input: ' + JSON.serialize(allocations));
        if (allocations == null || allocations.isEmpty()) {
            throw createAuraException('No allocations provided.');
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // 1. Gather all Line Item IDs to query details
            Set<Id> lineItemIds = new Set<Id>();
            for (SupplyOrderPlanner.AllocationWrapper alloc : allocations) {
                if (alloc.lineItemId != null) {
                    lineItemIds.add(alloc.lineItemId);
                }
            }

            if (lineItemIds.isEmpty()) {
                throw createAuraException('Invalid allocation line item IDs.');
            }

            // Query Order Allocation Line Items and the parent Order Allocation header
            Map<Id, Order_Allocation_Line_Item__c> lineItemsMap = new Map<Id, Order_Allocation_Line_Item__c>([
                SELECT Id, Name, Status__c, Item__c, Item__r.Name, Item__r.Default_Supply_Method__c, Item__r.Target_Days__c,
                       Ordered_Qty__c, Reserved_Qty_Planned__c, Transfer_Qty_Planned__c, Procurement_Qty_Planned__c,
                       Unit_Price__c, Discount_Percent__c, Discount_Amount__c, Tax__c, Tax_Amount__c, Taxable_Amount__c,
                       Gross_Amount__c, Additional_Cost__c, Loading_and_Unloading_Charges__c, Transfer_Cost__c,
                       Supply_Request__c, Ready_to_Ship_Date__c,
                       Order_Allocation__c, Order_Allocation__r.Source_Location__c, Order_Allocation__r.Source_Location__r.Name,
                       Order_Allocation__r.Source_Location__r.Account__c, Order_Allocation__r.Source_Location__r.Is_Active__c,
                       Order_Allocation__r.Target_Location__c, Order_Allocation__r.Target_Location__r.Name,
                       Order_Allocation__r.Target_Location__r.Account__c, Order_Allocation__r.Target_Location__r.Is_Active__c,
                       Order_Allocation__r.Requesting_Account__c, Order_Allocation__r.Supplying_Account__c,
                       Order_Allocation__r.Discount_Amount__c,
                       Order_Allocation__r.Grand_Total__c, Order_Allocation__r.Subtotal__c, Order_Allocation__r.Tax_Amount__c,
                       Order_Allocation__r.Order_Allocation_Date__c, Order_Allocation__r.Customer_Name__c,
                       Order_Allocation__r.Customer__c, Order_Allocation__r.Customer__r.Name,
                       Order_Allocation__r.Status__c
                FROM Order_Allocation_Line_Item__c 
                WHERE Id IN :lineItemIds
            ]);
            System.debug('*** Queried Order Allocation Line Items. Count: ' + lineItemsMap.size());

            // Check for duplicate execution / already confirmed plans
            for (Order_Allocation_Line_Item__c li : lineItemsMap.values()) {
                if (li.Order_Allocation__r != null && (li.Order_Allocation__r.Status__c == 'Confirmed Planning' || li.Order_Allocation__r.Status__c == 'Confirmed Planned')) {
                    throw createAuraException('Order Allocation plan is already confirmed.');
                }
            }

            // Update parent Order_Allocation__c status to Confirmed Planning FIRST
            Set<String> nonOverwritableStatuses = new Set<String>{
                'Ready to Ship', 'Shipped', 'Delivered', 'Closed', 'Cancelled'
            };
            Map<Id, Order_Allocation__c> parentPlansToUpdate = new Map<Id, Order_Allocation__c>();
            for (Order_Allocation_Line_Item__c li : lineItemsMap.values()) {
                if (li.Order_Allocation__c != null && !parentPlansToUpdate.containsKey(li.Order_Allocation__c)) {
                    String currentOaStatus = (li.Order_Allocation__r != null) ? li.Order_Allocation__r.Status__c : null;
                    if (currentOaStatus == null || !nonOverwritableStatuses.contains(currentOaStatus)) {
                        Order_Allocation__c parentPlan = new Order_Allocation__c(
                            Id = li.Order_Allocation__c,
                            Status__c = 'Confirmed Planning',
                            Confirmed_Plan_Date__c = System.now()
                        );
                        parentPlansToUpdate.put(li.Order_Allocation__c, parentPlan);
                    }
                }
            }
            if (!parentPlansToUpdate.isEmpty()) {
                update parentPlansToUpdate.values();
                System.debug('*** Updated parent Order Allocation status to Confirmed Planning first.');
            }

            Map<Id, Id> suppAccToReserveLocIdMap = new Map<Id, Id>();
            Map<String, Id> accountNameToLocIdMap = new Map<String, Id>();
            for (Inventory_Location__c loc : [
                SELECT Id, Name, Account__c, Account__r.Name, Is_Active__c
                FROM Inventory_Location__c
                ORDER BY Is_Active__c DESC, CreatedDate ASC
            ]) {
                if (loc.Account__c != null && !suppAccToReserveLocIdMap.containsKey(loc.Account__c)) {
                    suppAccToReserveLocIdMap.put(loc.Account__c, loc.Id);
                }
                if (loc.Account__r != null && String.isNotBlank(loc.Account__r.Name)) {
                    String cleanAccName = loc.Account__r.Name.toLowerCase().trim();
                    if (!accountNameToLocIdMap.containsKey(cleanAccName)) {
                        accountNameToLocIdMap.put(cleanAccName, loc.Id);
                    }
                }
            }

            // Gather all location IDs (transfers and plan reserve locations) to query their Accounts
            Set<Id> allRelevantLocIds = new Set<Id>();
            for (SupplyOrderPlanner.AllocationWrapper alloc : allocations) {
                if (alloc.transfers != null) {
                    for (SupplyOrderPlanner.TransferWrapper trans : alloc.transfers) {
                        if (trans.locationId != null && trans.qty != null && trans.qty > 0) {
                            allRelevantLocIds.add(trans.locationId);
                        }
                    }
                }
            }
            for (Order_Allocation_Line_Item__c li : lineItemsMap.values()) {
                if (li.Order_Allocation__r != null) {
                    Id suppId = li.Order_Allocation__r.Supplying_Account__c != null ? li.Order_Allocation__r.Supplying_Account__c : (li.Order_Allocation__r.Target_Location__r != null ? li.Order_Allocation__r.Target_Location__r.Account__c : null);
                    Inventory_Location__c resLoc = resolveReserveLocation(li.Order_Allocation__r, suppId);
                    if (resLoc != null && resLoc.Id != null) {
                        allRelevantLocIds.add(resLoc.Id);
                    }
                    if (li.Order_Allocation__r.Target_Location__c != null) {
                        allRelevantLocIds.add(li.Order_Allocation__r.Target_Location__c);
                    }
                }
            }

            Map<Id, Inventory_Location__c> sourceLocationMap = new Map<Id, Inventory_Location__c>();
            Map<String, Id> invLocItemToAccountMap = new Map<String, Id>();
            if (!allRelevantLocIds.isEmpty()) {
                sourceLocationMap = new Map<Id, Inventory_Location__c>([
                    SELECT Id, Name, Account__c FROM Inventory_Location__c WHERE Id IN :allRelevantLocIds
                ]);
                for (Inventory__c inv : [
                    SELECT Id, Inventory_Location__c, Item__c, Account__c 
                    FROM Inventory__c 
                    WHERE Inventory_Location__c IN :allRelevantLocIds AND Account__c != null
                ]) {
                    invLocItemToAccountMap.put(inv.Inventory_Location__c + '_' + inv.Item__c, inv.Account__c);
                    if (!invLocItemToAccountMap.containsKey(String.valueOf(inv.Inventory_Location__c))) {
                        invLocItemToAccountMap.put(String.valueOf(inv.Inventory_Location__c), inv.Account__c);
                    }
                }
            }

            // Map each parent Order Allocation plan ID to its list of line items and allocation wrappers
            Map<Id, List<Order_Allocation_Line_Item__c>> planToLineItemsMap = new Map<Id, List<Order_Allocation_Line_Item__c>>();
            Map<Id, List<SupplyOrderPlanner.AllocationWrapper>> planToAllocationsMap = new Map<Id, List<SupplyOrderPlanner.AllocationWrapper>>();

            for (SupplyOrderPlanner.AllocationWrapper alloc : allocations) {
                if (!lineItemsMap.containsKey(alloc.lineItemId)) {
                    continue;
                }
                Order_Allocation_Line_Item__c li = lineItemsMap.get(alloc.lineItemId);
                Id parentPlanId = li.Order_Allocation__c;
                if (!planToLineItemsMap.containsKey(parentPlanId)) {
                    planToLineItemsMap.put(parentPlanId, new List<Order_Allocation_Line_Item__c>());
                    planToAllocationsMap.put(parentPlanId, new List<SupplyOrderPlanner.AllocationWrapper>());
                }
                planToLineItemsMap.get(parentPlanId).add(li);
                planToAllocationsMap.get(parentPlanId).add(alloc);
            }

            List<PoBundle> poBundles = new List<PoBundle>();
            Map<String, PoBundle> transferPoBundleMap = new Map<String, PoBundle>();
            List<Purchase_Order_Line_Item__c> allPOLIsToInsert = new List<Purchase_Order_Line_Item__c>();

            List<Supply_Request__c> allSRsToInsert = new List<Supply_Request__c>();
            Map<Id, Supply_Request__c> liIdToProcSRMap = new Map<Id, Supply_Request__c>();
            Map<Id, Supply_Request__c> liIdToTransferSRMap = new Map<Id, Supply_Request__c>();
            Map<Id, Purchase_Order_Line_Item__c> liIdToProcPoliMap = new Map<Id, Purchase_Order_Line_Item__c>();

            Map<String, Schema.RecordTypeInfo> srRtMap = Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName();
            Id transferSrRtId = srRtMap.containsKey('Transfer_Supply_Request') ? srRtMap.get('Transfer_Supply_Request').getRecordTypeId() : null;
            Id purchaseSrRtId = srRtMap.containsKey('Purchase_Supply_Request') ? srRtMap.get('Purchase_Supply_Request').getRecordTypeId() : null;

            List<Inventory_Reservation__c> reservationsToInsert = new List<Inventory_Reservation__c>();
            List<Order_Allocation_Line_Item__c> lineItemsToUpdate = new List<Order_Allocation_Line_Item__c>();

            // Collect inventory keys (ItemId + '_' + LocationId) to query and update Inventory__c records
            Map<String, Decimal> reserveDeductionMap = new Map<String, Decimal>();
            Map<String, Decimal> reserveSaleOrderMap = new Map<String, Decimal>();

            // Iterate over each unique Order Allocation plan
            for (Id parentPlanId : planToLineItemsMap.keySet()) {
                List<Order_Allocation_Line_Item__c> planLines = planToLineItemsMap.get(parentPlanId);
                List<SupplyOrderPlanner.AllocationWrapper> planAllocs = planToAllocationsMap.get(parentPlanId);

                Order_Allocation_Line_Item__c firstLi = planLines[0];
                Id requestingAccId = firstLi.Order_Allocation__r.Requesting_Account__c;
                Id supplyingAccId = firstLi.Order_Allocation__r.Supplying_Account__c != null ? firstLi.Order_Allocation__r.Supplying_Account__c : (firstLi.Order_Allocation__r.Target_Location__r != null ? firstLi.Order_Allocation__r.Target_Location__r.Account__c : null);

                // Resolve Reserve Location
                Inventory_Location__c planResLoc = resolveReserveLocation(firstLi.Order_Allocation__r, supplyingAccId);
                Id reserveLocId = planResLoc != null ? planResLoc.Id : firstLi.Order_Allocation__r.Target_Location__c;

                // Resolve 1-level eligible child accounts for transfer validation
                Set<Id> eligibleChildAccs = (supplyingAccId != null)
                    ? getEligibleChildAccounts(supplyingAccId)
                    : new Set<Id>();

                // Resolve Procurement Account (Immediate Parent of Supplying Account)
                Map<String, Object> procAccInfo = resolveProcurementAccount(supplyingAccId);
                Id immediateParentAccountId = (Id)procAccInfo.get('id');

                // If immediate parent account could not be resolved from hierarchy, check Order Allocation's source location account
                if (immediateParentAccountId == null && firstLi.Order_Allocation__r.Source_Location__r != null && firstLi.Order_Allocation__r.Source_Location__r.Account__c != null) {
                    immediateParentAccountId = firstLi.Order_Allocation__r.Source_Location__r.Account__c;
                }

                // Resolve procuring parent account's inventory location as the Source Location for procurement SR
                Id parentProcLocId = null;
                String parentAccName = (String)procAccInfo.get('name');

                if (immediateParentAccountId != null) {
                    if (suppAccToReserveLocIdMap.containsKey(immediateParentAccountId)) {
                        parentProcLocId = suppAccToReserveLocIdMap.get(immediateParentAccountId);
                    } else if (String.isNotBlank(parentAccName) && accountNameToLocIdMap.containsKey(parentAccName.toLowerCase().trim())) {
                        parentProcLocId = accountNameToLocIdMap.get(parentAccName.toLowerCase().trim());
                    }

                    // Fallback: Check grandparent in hierarchy (e.g. Distributor / OEM)
                    if (parentProcLocId == null) {
                        Map<String, Object> grandParentInfo = resolveProcurementAccount(immediateParentAccountId);
                        Id grandParentId = (Id)grandParentInfo.get('id');
                        String grandParentName = (String)grandParentInfo.get('name');
                        if (grandParentId != null && grandParentId != immediateParentAccountId) {
                            if (suppAccToReserveLocIdMap.containsKey(grandParentId)) {
                                parentProcLocId = suppAccToReserveLocIdMap.get(grandParentId);
                            } else if (String.isNotBlank(grandParentName) && accountNameToLocIdMap.containsKey(grandParentName.toLowerCase().trim())) {
                                parentProcLocId = accountNameToLocIdMap.get(grandParentName.toLowerCase().trim());
                            }
                        }
                    }
                }

                Integer maxTargetDays = 0;
                for (Order_Allocation_Line_Item__c li : planLines) {
                    if (li.Item__r != null && li.Item__r.Target_Days__c != null) {
                        Integer td = li.Item__r.Target_Days__c.intValue();
                        if (td > maxTargetDays) {
                            maxTargetDays = td;
                        }
                    }
                }

                Id oaSourceLocId = firstLi.Order_Allocation__r.Source_Location__c;
                Id oaTargetLocId = (firstLi.Order_Allocation__r.Target_Location__c != null) ? firstLi.Order_Allocation__r.Target_Location__c : reserveLocId;

                Boolean hasPositiveProcurement = false;
                for (SupplyOrderPlanner.AllocationWrapper alloc : planAllocs) {
                    if (alloc.procureQty != null && alloc.procureQty > 0) {
                        hasPositiveProcurement = true;
                        break;
                    }
                }

                // Create Procurement Purchase Order (PO) if has at least one positive procurement line item
                Purchase_Order__c procurementPo = null;
                PoBundle procPoBundle = null;
                if (hasPositiveProcurement) {
                    Id poSourceLocId = (parentProcLocId != null) ? parentProcLocId : oaSourceLocId;
                    Id poTargetLocId = (reserveLocId != null) ? reserveLocId : oaTargetLocId;

                    procurementPo = new Purchase_Order__c(
                        Requesting_Account__c = supplyingAccId,
                        Supplying_Account__c = immediateParentAccountId,
                        Sales_Allocation__c = parentPlanId,
                        Source_Location__c = poSourceLocId,
                        Target_Location__c = poTargetLocId,
                        PO_Date__c = firstLi.Order_Allocation__r.Order_Allocation_Date__c != null ? firstLi.Order_Allocation__r.Order_Allocation_Date__c : System.today(),
                        Expected_Date__c = System.today().addDays(maxTargetDays),
                        Status__c = 'Draft'
                    );
                    procPoBundle = new PoBundle(procurementPo);
                    poBundles.add(procPoBundle);
                }

                // Process line items for this Order Allocation Plan
                for (Integer i = 0; i < planLines.size(); i++) {
                    Order_Allocation_Line_Item__c li = planLines[i];
                    SupplyOrderPlanner.AllocationWrapper alloc = planAllocs[i];

                    Id itemId = li.Item__c;
                    Decimal resQty = alloc.reserveQty != null ? alloc.reserveQty : 0;
                    Decimal procQty = alloc.procureQty != null ? alloc.procureQty : 0;

                    // Validate negative quantities
                    if (resQty < 0) {
                        throw createAuraException('Reserved quantity cannot be negative.');
                    }
                    if (procQty < 0) {
                        throw createAuraException('Procurement quantity cannot be negative.');
                    }

                    // Process Inventory Transfers and Transfer SRs/POs
                    Decimal totalTransQty = 0;
                    if (alloc.transfers != null) {
                        for (SupplyOrderPlanner.TransferWrapper trans : alloc.transfers) {
                            if (trans.qty != null) {
                                if (trans.qty < 0) {
                                    throw createAuraException('Transfer quantity cannot be negative.');
                                }
                                if (trans.qty > 0 && trans.locationId != null) {
                                    totalTransQty += trans.qty;
                                    Integer itemTargetDays = (li.Item__r != null && li.Item__r.Target_Days__c != null) ? li.Item__r.Target_Days__c.intValue() : 0;
                                    Id fromAccId = sourceLocationMap.containsKey(trans.locationId) ? sourceLocationMap.get(trans.locationId).Account__c : null;
                                    if (fromAccId == null) {
                                        String invKey = trans.locationId + '_' + itemId;
                                        if (invLocItemToAccountMap.containsKey(invKey)) {
                                            fromAccId = invLocItemToAccountMap.get(invKey);
                                        } else if (invLocItemToAccountMap.containsKey(String.valueOf(trans.locationId))) {
                                            fromAccId = invLocItemToAccountMap.get(String.valueOf(trans.locationId));
                                        }
                                    }

                                    // A transfer must always be between two different accounts.
                                    if (fromAccId != null && fromAccId == supplyingAccId) {
                                        throw createAuraException(
                                            'Transfer source account cannot be the same as the supplying account of the Order Allocation.'
                                        );
                                    }

                                    // Enforce one-level child account restriction for transfers
                                    if (fromAccId != null && !eligibleChildAccs.isEmpty() && !eligibleChildAccs.contains(fromAccId)) {
                                        throw createAuraException(
                                            'Transfer source location must belong to a direct (one-level) child account of the supplying account.'
                                        );
                                    }

                                    if (fromAccId == null) {
                                        throw createAuraException(
                                            'Unable to determine supplying account for transfer location: ' +
                                            trans.locationId
                                        );
                                    }

                                    Id srTargetLocId = (firstLi.Order_Allocation__r.Target_Location__c != null)
                                        ? firstLi.Order_Allocation__r.Target_Location__c
                                        : reserveLocId;

                                    Supply_Request__c transferSR = new Supply_Request__c(
                                        Item__c = itemId,
                                        Requested_Qty__c = trans.qty,
                                        Reference_Account__c = supplyingAccId,
                                        Requesting_Account__c = requestingAccId,
                                        Supplying_Account__c = fromAccId,
                                        Source_Location__c = trans.locationId,
                                        Target_Location__c = srTargetLocId,
                                        Required_Date__c = System.today().addDays(itemTargetDays),
                                        Request_Type__c = 'Transfer SR',
                                        Status__c = 'Open',
                                        Supply_Method__c = 'Purchase',
                                        Supply_Request__c = li.Supply_Request__c,
                                        Order_Allocation_Line_Item__c = li.Id,
                                        Automated_Supply_Request__c = true
                                    );
                                    if (transferSrRtId != null) {
                                        transferSR.RecordTypeId = transferSrRtId;
                                    }
                                    allSRsToInsert.add(transferSR);
                                    if (!liIdToTransferSRMap.containsKey(li.Id)) {
                                        liIdToTransferSRMap.put(li.Id, transferSR);
                                    }

                                    // 3. Transfer Purchase Order & POLI
                                    Id poSourceLocId = trans.locationId;
                                    String transferPoKey = parentPlanId + '_' + requestingAccId + '_' + fromAccId + '_' + supplyingAccId + '_' + poSourceLocId + '_' + srTargetLocId;

                                    PoBundle transferPoBundle;
                                    if (transferPoBundleMap.containsKey(transferPoKey)) {
                                        transferPoBundle = transferPoBundleMap.get(transferPoKey);
                                    } else {
                                        Purchase_Order__c transferPo = new Purchase_Order__c(
                                            Requesting_Account__c = requestingAccId,
                                            Supplying_Account__c = fromAccId,
                                            Reference_Account__c = supplyingAccId,
                                            Sales_Allocation__c = parentPlanId,
                                            Source_Location__c = poSourceLocId,
                                            Target_Location__c = srTargetLocId,
                                            PO_Date__c = firstLi.Order_Allocation__r.Order_Allocation_Date__c != null ? firstLi.Order_Allocation__r.Order_Allocation_Date__c : System.today(),
                                            Expected_Date__c = System.today().addDays(itemTargetDays),
                                            Status__c = 'Draft'
                                        );
                                        transferPoBundle = new PoBundle(transferPo);
                                        transferPoBundleMap.put(transferPoKey, transferPoBundle);
                                        poBundles.add(transferPoBundle);
                                    }

                                    Purchase_Order_Line_Item__c transferPoli = new Purchase_Order_Line_Item__c(
                                        Sales_Allocation_Line_Item__c = li.Id,
                                        Item__c = itemId,
                                        Ordered_Qty__c = trans.qty,
                                        Unit_Price__c = li.Unit_Price__c,
                                        Discount__c = li.Discount_Percent__c,
                                        Tax__c = li.Tax__c,
                                        Additional_Fee__c = li.Additional_Cost__c,
                                        Status__c = 'Open'
                                    );

                                    transferPoBundle.lines.add(transferPoli);
                                    allPOLIsToInsert.add(transferPoli);
                                }
                            }
                        }
                    }

                    // Validate fulfillment quantities against ordered quantity
                    Decimal totalAllocated = resQty + totalTransQty + procQty;
                    Decimal maxOrdered = li.Ordered_Qty__c != null ? li.Ordered_Qty__c : 0;
                    if (totalAllocated > maxOrdered) {
                        String prodName = (li.Item__r != null && String.isNotBlank(li.Item__r.Name)) ? li.Item__r.Name : 'Item';
                        throw createAuraException('Total allocated quantity (' + totalAllocated + ') cannot exceed ordered quantity (' + maxOrdered + ') for ' + prodName + '.');
                    }

                    // Process Inventory Reservations if any
                    if (resQty > 0) {
                        String reservationStatus = (resQty >= maxOrdered) 
                            ? 'Fully Reserved' 
                            : 'Partially Reserved';

                        Inventory_Reservation__c ir = new Inventory_Reservation__c(
                            Requesting_Account__c = requestingAccId,
                            Supplying_Account__c = supplyingAccId,
                            Inventory_Location__c = reserveLocId,
                            Item__c = itemId,
                            Order_Allocation_Line_Item__c = li.Id,
                            Requested_Qty__c = resQty,
                            Reserved_Qty__c = resQty,
                            Reservation_Date__c = System.today(),
                            Status__c = reservationStatus
                        );
                        reservationsToInsert.add(ir);
                        System.debug('*** [INVENTORY RESERVATION CREATING] LineItem: ' + li.Id + ', Item: ' + itemId + ', ReserveLoc: ' + reserveLocId + ', ResQty: ' + resQty + ', Status: ' + reservationStatus);

                        if (reserveLocId != null && itemId != null) {
                            String invKey = itemId + '_' + reserveLocId;
                            
                            // Track available stock deduction
                            Decimal curDeduction = reserveDeductionMap.containsKey(invKey) ? reserveDeductionMap.get(invKey) : 0;
                            reserveDeductionMap.put(invKey, curDeduction + resQty);

                            // Add to Reserved_Sale_Order__c
                            Decimal currentQty = reserveSaleOrderMap.containsKey(invKey) ? reserveSaleOrderMap.get(invKey) : 0;
                            reserveSaleOrderMap.put(invKey, currentQty + resQty);

                            System.debug('*** [INVENTORY MAP ACCUMULATION] Key: ' + invKey + ', CurDeduction: ' + curDeduction + ' -> NewTotalDeduction: ' + (curDeduction + resQty) + ', CurSaleOrder: ' + currentQty + ' -> NewTotalSaleOrder: ' + (currentQty + resQty));
                        }
                    }

                    // Create Supply Request (Procurement) ONLY if procurement quantity > 0
                    if (procQty > 0) {
                        Integer itemTargetDays = (li.Item__r != null && li.Item__r.Target_Days__c != null) ? li.Item__r.Target_Days__c.intValue() : 0;

                        String supplyMethod = 'Purchase';
                        if (li.Item__r != null && String.isNotBlank(li.Item__r.Default_Supply_Method__c)) {
                            String dsm = li.Item__r.Default_Supply_Method__c;
                            if (dsm == 'Purchase' || dsm == 'Manufacture') {
                                supplyMethod = dsm;
                            } else if (dsm == 'Both') {
                                supplyMethod = 'Undecided';
                            }
                        }
                        String reqTypeVal = (supplyMethod == 'Manufacture') ? 'Manufacture' : 'Purchase';

                        Id srTargetLocId = (firstLi.Order_Allocation__r.Source_Location__c != null) 
                            ? firstLi.Order_Allocation__r.Source_Location__c 
                            : (reserveLocId != null ? reserveLocId : firstLi.Order_Allocation__r.Target_Location__c);

                        Supply_Request__c procSR = new Supply_Request__c(
                            Item__c = itemId,
                            Requested_Qty__c = procQty,
                            Requesting_Account__c = supplyingAccId,
                            Supplying_Account__c = immediateParentAccountId,
                            Source_Location__c = parentProcLocId,
                            Target_Location__c = srTargetLocId,
                            Required_Date__c = System.today().addDays(itemTargetDays),
                            Request_Type__c = 'Purchase SR',
                            Status__c = 'Open',
                            Supply_Method__c = supplyMethod,
                            Type__c = reqTypeVal,
                            Supply_Request__c = li.Supply_Request__c,
                            Order_Allocation_Line_Item__c = li.Id,
                            Automated_Supply_Request__c = true
                        );
                        if (purchaseSrRtId != null) {
                            procSR.RecordTypeId = purchaseSrRtId;
                        }
                        allSRsToInsert.add(procSR);
                        liIdToProcSRMap.put(li.Id, procSR);

                        // Procurement POLI
                        Purchase_Order_Line_Item__c procPoli = new Purchase_Order_Line_Item__c(
                            Sales_Allocation_Line_Item__c = li.Id,
                            Item__c = itemId,
                            Ordered_Qty__c = procQty,
                            Unit_Price__c = li.Unit_Price__c,
                            Discount__c = li.Discount_Percent__c,
                            Tax__c = li.Tax__c,
                            Additional_Fee__c = li.Additional_Cost__c,
                            Status__c = 'Open'
                        );
                        if (procPoBundle != null) {
                            procPoBundle.lines.add(procPoli);
                        }
                        allPOLIsToInsert.add(procPoli);
                        liIdToProcPoliMap.put(li.Id, procPoli);
                    }

                    // Update planned fields on line item
                    li.Reserved_Qty_Planned__c = resQty;
                    li.Reserved_Quantity__c = resQty;
                    li.Transfer_Qty_Planned__c = totalTransQty;
                    li.Procurement_Qty_Planned__c = procQty;
                    
                    // Do not revert if already 'Ready to Ship', 'Shipped', 'Delivered', etc.
                    if (li.Status__c == null || !nonOverwritableStatuses.contains(li.Status__c)) {
                        li.Status__c = 'Planned';
                    }
                    lineItemsToUpdate.add(li);
                }
            }

            // Update line items status and planned quantities FIRST
            if (!lineItemsToUpdate.isEmpty()) {
                update lineItemsToUpdate;
                System.debug('*** Updated Order Allocation Line Items status to Planned first.');
            }

            // Query and update Inventory__c records for RESERVATIONS ONLY
            if (!reserveDeductionMap.isEmpty()) {
                Set<Id> itemIds = new Set<Id>();
                Set<Id> locIds = new Set<Id>();

                for (String key : reserveDeductionMap.keySet()) {
                    String[] parts = key.split('_');
                    itemIds.add((Id)parts[0]);
                    locIds.add((Id)parts[1]);
                }

                System.debug('*** [INVENTORY UPDATE BATCH] Reserve keys: ' + reserveDeductionMap.keySet() + ', itemIds: ' + itemIds + ', locIds: ' + locIds);

                List<Inventory__c> existingInventories = [
                    SELECT Id, Item__c, Inventory_Location__c, Inventory_Location__r.Name, Inventory_Location__r.Account__c, Account__c, Available__c, Reserved_Sale_Order__c, Reserved_Transfer__c 
                    FROM Inventory__c 
                    WHERE Item__c IN :itemIds AND Inventory_Location__c IN :locIds
                ];

                Map<String, Inventory__c> inventoryMap = new Map<String, Inventory__c>();
                for (Inventory__c inv : existingInventories) {
                    inventoryMap.put(inv.Item__c + '_' + inv.Inventory_Location__c, inv);
                    System.debug('*** [INVENTORY EXISTING RECORD FOUND] Id: ' + inv.Id + ', Key: ' + inv.Item__c + '_' + inv.Inventory_Location__c + ', Available: ' + inv.Available__c + ', Reserved_Sale_Order: ' + inv.Reserved_Sale_Order__c);
                }

                List<Inventory__c> inventoriesToUpdate = new List<Inventory__c>();
                for (String key : reserveDeductionMap.keySet()) {
                    Decimal totalDeductAmt = reserveDeductionMap.get(key);
                    Decimal saleOrderAddAmt = reserveSaleOrderMap.containsKey(key) ? reserveSaleOrderMap.get(key) : 0;

                    Inventory__c inv = inventoryMap.get(key);
                    Decimal currentAvailable = (inv != null && inv.Available__c != null) ? inv.Available__c : 0;
                    
                    if (currentAvailable < totalDeductAmt) {
                        String productName = 'Unknown Product';
                        String[] parts = key.split('_');
                        Id targetItemId = (Id)parts[0];
                        for (Order_Allocation_Line_Item__c li : lineItemsMap.values()) {
                            if (li.Item__c == targetItemId && li.Item__r != null && String.isNotBlank(li.Item__r.Name)) {
                                productName = li.Item__r.Name;
                                break;
                            }
                        }
                        System.debug(LoggingLevel.ERROR, '*** [INVENTORY STOCK INSUFFICIENT] Product: ' + productName + ', CurrentAvailable: ' + currentAvailable + ', TotalDeductAmt: ' + totalDeductAmt);
                        throw createAuraException('INSUFFICIENT_STOCK: ' + productName + ' (Available: ' + currentAvailable + ', Requested: ' + totalDeductAmt + ')');
                    }
                    
                    if (inv == null) {
                        String[] parts = key.split('_');
                        Id itemPart = (Id)parts[0];
                        Id locPart = (Id)parts[1];

                        Id locAccId = sourceLocationMap.containsKey(locPart) ? sourceLocationMap.get(locPart).Account__c : null;

                        inv = new Inventory__c(
                            Item__c = itemPart,
                            Inventory_Location__c = locPart,
                            Account__c = locAccId,
                            Available__c = 0,
                            Reserved_Sale_Order__c = 0,
                            Reserved_Transfer__c = 0
                        );
                        System.debug('*** [INVENTORY NEW RECORD CREATING] Key: ' + key + ', Account: ' + locAccId);
                    }
                    
                    Decimal oldSaleOrderReserved = inv.Reserved_Sale_Order__c != null ? inv.Reserved_Sale_Order__c : 0;
                    Decimal newAvailable = currentAvailable - totalDeductAmt;
                    Decimal newSaleOrderReserved = oldSaleOrderReserved + saleOrderAddAmt;

                    System.debug('*** [INVENTORY TRANSACTION UPDATE] Id: ' + inv.Id + ', Key: ' + key + ' | Available: ' + currentAvailable + ' - ' + totalDeductAmt + ' = ' + newAvailable + ' | Reserved_Sale_Order: ' + oldSaleOrderReserved + ' + ' + saleOrderAddAmt + ' = ' + newSaleOrderReserved);

                    // Reduce Available__c
                    inv.Available__c = newAvailable;
                    // Increase Reserved_Sale_Order__c
                    inv.Reserved_Sale_Order__c = newSaleOrderReserved;
                    inventoriesToUpdate.add(inv);
                }

                if (!inventoriesToUpdate.isEmpty()) {
                    System.debug('*** [INVENTORY UPSERT EXECUTING] Records to upsert count: ' + inventoriesToUpdate.size());
                    upsert inventoriesToUpdate;
                    System.debug('*** [INVENTORY UPSERT COMPLETE] Records upserted successfully: ' + inventoriesToUpdate);
                }
            }

            // 1. Bulk Insert Purchase Orders and POLIs
            if (!poBundles.isEmpty()) {
                List<Purchase_Order__c> allPOsToInsert = new List<Purchase_Order__c>();
                for (PoBundle bundle : poBundles) {
                    if (bundle.po != null) {
                        allPOsToInsert.add(bundle.po);
                    }
                }
                if (!allPOsToInsert.isEmpty()) {
                    insert allPOsToInsert;
                }

                for (PoBundle bundle : poBundles) {
                    if (bundle.po != null && bundle.po.Id != null && bundle.lines != null) {
                        for (Purchase_Order_Line_Item__c poli : bundle.lines) {
                            if (poli != null) {
                                poli.Purchase_Order__c = bundle.po.Id;
                            }
                        }
                    }
                }

                if (!allPOLIsToInsert.isEmpty()) {
                    insert allPOLIsToInsert;
                }

                // Generate financial records (Payable, Invoice, Invoice Line Items, Receivable)
                Set<Id> createdPoIds = new Set<Id>();
                for (Purchase_Order__c po : allPOsToInsert) {
                    if (po.Id != null) {
                        createdPoIds.add(po.Id);
                    }
                }
                if (!createdPoIds.isEmpty()) {
                    FinancialRecordService.generateFinancialRecordsForPOs(createdPoIds);
                }
            }

            // 2. Bulk Insert Supply Requests (Procurement + Transfer SRs)
            if (!allSRsToInsert.isEmpty()) {
                insert allSRsToInsert;
            }

            // Link created POLI and Supply Request IDs back to Order Allocation Line Items
            Boolean hasLineItemReferencesToUpdate = false;
            for (Order_Allocation_Line_Item__c li : lineItemsToUpdate) {
                if (liIdToProcPoliMap.containsKey(li.Id) && liIdToProcPoliMap.get(li.Id) != null) {
                    li.Purchase_Order_Line_Item__c = liIdToProcPoliMap.get(li.Id).Id;
                    hasLineItemReferencesToUpdate = true;
                }
                if (liIdToProcSRMap.containsKey(li.Id) && liIdToProcSRMap.get(li.Id) != null) {
                    li.Supply_Request__c = liIdToProcSRMap.get(li.Id).Id;
                    hasLineItemReferencesToUpdate = true;
                } else if (liIdToTransferSRMap.containsKey(li.Id) && liIdToTransferSRMap.get(li.Id) != null) {
                    li.Supply_Request__c = liIdToTransferSRMap.get(li.Id).Id;
                    hasLineItemReferencesToUpdate = true;
                }
            }

            // Perform remaining insertions and updates in bulk
            if (!reservationsToInsert.isEmpty()) {
                insert reservationsToInsert;
            }
            if (hasLineItemReferencesToUpdate && !lineItemsToUpdate.isEmpty()) {
                update lineItemsToUpdate;
            }
        } catch (AuraHandledException aex) {
            Database.rollback(sp);
            throw aex;
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, '*** Exception in SupplyOrderGenService.submitPlanning: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw createAuraException('Submission Failed: ' + e.getMessage());
        }
    }
}