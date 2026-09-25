public without sharing class SupplyPlanController {
    
    @AuraEnabled(cacheable=true)
    public static LWCServerCalloutWrapper searchSupplyPlans(String searchKey) {
        LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
        try {
            if (String.isBlank(searchKey)) {
                wrapper.resultList = [
                    SELECT Id, Name, Status__c, Target_Location__r.Name
                    FROM Order_Allocation__c
                    WITH USER_MODE
                    ORDER BY LastModifiedDate DESC
                    LIMIT 10
                ];
                wrapper.isSuccess = true;
                return wrapper;
            }
            String key = '%' + searchKey.trim() + '%';
            wrapper.resultList = [
                SELECT Id, Name, Status__c, Target_Location__r.Name
                FROM Order_Allocation__c
                WHERE Name LIKE :key
                WITH USER_MODE
                LIMIT 10
            ];
            wrapper.isSuccess = true;
        } catch (Exception e) {
            wrapper.isSuccess = false;
            wrapper.errorMsg = e.getMessage();
        }
        return wrapper;
    }

    @AuraEnabled
    public static LWCServerCalloutWrapper getSupplyPlanDetails(String planIdentifier) {
        LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
        try {
            if (String.isBlank(planIdentifier)) {
                wrapper.isSuccess = false;
                wrapper.errorMsg = 'Invalid Plan Identifier';
                return wrapper;
            }
            
            List<Order_Allocation__c> plans = new List<Order_Allocation__c>();
            
            Boolean isId = false;
            try {
                Id tempId = (Id)planIdentifier.trim();
                isId = true;
            } catch (Exception e) {
                isId = false;
            }
            
            if (isId) {
                plans = [
                    SELECT Id, Name, Status__c, Target_Location__c, Target_Location__r.Name, Target_Location__r.Account__c, Target_Location__r.Account__r.Name, Target_Location__r.Account__r.Type, Source_Location__c, Source_Location__r.Name,
                           Requesting_Account__c, Requesting_Account__r.Name, Supplying_Account__c, Supplying_Account__r.Name, Supplying_Account__r.Type, Supplying_Account__r.RecordType.Name, Supplying_Account__r.RecordType.DeveloperName,
                           Customer__c, Customer__r.Name, Customer_Name__c, Bill_To_Contact__c, Bill_To_Contact__r.Name,
                           (SELECT Id, Name, Item__c, Item__r.Name, Ordered_Qty__c,
                                   Reserved_Qty_Planned__c, Transfer_Qty_Planned__c, Procurement_Qty_Planned__c
                            FROM Order_Allocation_Line_Items__r
                            ORDER BY Name ASC)
                    FROM Order_Allocation__c
                    WHERE Id = :planIdentifier.trim()
                    WITH USER_MODE
                ];
            } else {
                String searchTerm = '%' + planIdentifier.replaceAll('\\s+', '%') + '%';
                plans = [
                    SELECT Id, Name, Status__c, Target_Location__c, Target_Location__r.Name, Target_Location__r.Account__c, Target_Location__r.Account__r.Name, Target_Location__r.Account__r.Type, Source_Location__c, Source_Location__r.Name,
                           Requesting_Account__c, Requesting_Account__r.Name, Supplying_Account__c, Supplying_Account__r.Name, Supplying_Account__r.Type, Supplying_Account__r.RecordType.Name, Supplying_Account__r.RecordType.DeveloperName,
                           Customer__c, Customer__r.Name, Customer_Name__c, Bill_To_Contact__c, Bill_To_Contact__r.Name,
                           (SELECT Id, Name, Item__c, Item__r.Name, Ordered_Qty__c,
                                   Reserved_Qty_Planned__c, Transfer_Qty_Planned__c, Procurement_Qty_Planned__c
                            FROM Order_Allocation_Line_Items__r
                            ORDER BY Name ASC)
                    FROM Order_Allocation__c
                    WHERE Name LIKE :searchTerm
                    WITH USER_MODE
                    LIMIT 1
                ];
            }
            
            if (plans.isEmpty()) {
                wrapper.isSuccess = false;
                wrapper.errorMsg = 'Plan not found';
                return wrapper;
            }
            
            Order_Allocation__c plan = plans[0];
            wrapper.result = plan;
            
            Set<Id> itemIds = new Set<Id>();
            Set<Id> lineItemIds = new Set<Id>();
            for (Order_Allocation_Line_Item__c item : plan.Order_Allocation_Line_Items__r) {
                if (item.Item__c != null) {
                    itemIds.add(item.Item__c);
                }
                lineItemIds.add(item.Id);
            }
            
            List<Inventory__c> inventories = new List<Inventory__c>();
            if (!itemIds.isEmpty()) {
                inventories = [
                    SELECT Id, Inventory_Location__c, Inventory_Location__r.Name, Item__c, Item__r.Name, Available__c
                    FROM Inventory__c
                    WHERE Item__c IN :itemIds
                    WITH USER_MODE
                ];
            }
            
            Integer transferCount = 0;
            if (!lineItemIds.isEmpty()) {
                transferCount = [
                    SELECT count()
                    FROM Inventory_Transfer__c
                    WHERE Order_Allocation_Line_Item__c IN :lineItemIds 
                      AND Status__c != 'Cancelled' 
                      AND Status__c != 'Received'
                    WITH USER_MODE
                ];
            }
            
            wrapper.referenceCache.put('inventories', inventories);
            wrapper.referenceCache.put('transferCount', transferCount);
            wrapper.isSuccess = true;
        } catch (Exception e) {
            wrapper.isSuccess = false;
            wrapper.errorMsg = e.getMessage();
        }
        return wrapper;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSupplyPlanSummary(String searchTerm) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            if (String.isBlank(searchTerm)) {
                result.put('isFound', false);
                return result;
            }
            SupplyOrderPlanner.PlanWrapper planData = SupplyOrderPlanner.getSupplyPlanData(searchTerm);
            if (planData == null) {
                result.put('isFound', false);
                return result;
            }
            
            Decimal totalRequired = 0;
            Decimal reservedQty = 0;
            Decimal transferQty = 0;
            Decimal procurementQty = 0;
            
            Set<Id> lineItemIds = new Set<Id>();
            for (SupplyOrderPlanner.LineItemWrapper item : planData.lineItems) {
                if (item.lineItemId != null) {
                    lineItemIds.add(item.lineItemId);
                }
            }

            Map<Id, Inventory_Reservation__c> resMap = new Map<Id, Inventory_Reservation__c>();
            Map<Id, Inventory_Transfer__c> transMap = new Map<Id, Inventory_Transfer__c>();
            Map<Id, Supply_Request__c> transSrMap = new Map<Id, Supply_Request__c>();
            Map<Id, Supply_Request__c> procSrMap = new Map<Id, Supply_Request__c>();
            Map<Id, List<Purchase_Order_Line_Item__c>> itemToPolisMap = new Map<Id, List<Purchase_Order_Line_Item__c>>();
            Map<Id, Purchase_Requisition_Line__c> prLineMap = new Map<Id, Purchase_Requisition_Line__c>();

            if (!lineItemIds.isEmpty()) {
                for (Inventory_Reservation__c r : [
                    SELECT Id, Name, Status__c, Order_Allocation_Line_Item__c
                    FROM Inventory_Reservation__c
                    WHERE Order_Allocation_Line_Item__c IN :lineItemIds
                    WITH USER_MODE
                ]) {
                    resMap.put(r.Order_Allocation_Line_Item__c, r);
                }

                for (Supply_Request__c sr : [
                    SELECT Id, Name, Status__c, Request_Type__c, Order_Allocation_Line_Item__c, Item__c,
                           Supplying_Account__r.Name
                    FROM Supply_Request__c
                    WHERE Order_Allocation_Line_Item__c IN :lineItemIds 
                      AND Status__c != 'Cancelled'
                    WITH USER_MODE
                ]) {
                    if (sr.Request_Type__c == 'Transfer SR' || sr.RecordType.DeveloperName == 'Transfer_Supply_Request' || (sr.Name != null && sr.Name.contains('Transfer'))) {
                        transSrMap.put(sr.Order_Allocation_Line_Item__c, sr);
                    } else {
                        procSrMap.put(sr.Order_Allocation_Line_Item__c, sr);
                    }
                }

                for (Inventory_Transfer__c t : [
                    SELECT Id, Name, Status__c, Order_Allocation_Line_Item__c
                    FROM Inventory_Transfer__c
                    WHERE Order_Allocation_Line_Item__c IN :lineItemIds AND Status__c != 'Cancelled'
                    WITH USER_MODE
                ]) {
                    transMap.put(t.Order_Allocation_Line_Item__c, t);
                }

                if (planData.planId != null) {
                    for (Purchase_Order_Line_Item__c poli : [
                        SELECT Id, Name, Ordered_Qty__c, Status__c, Item__c, Item__r.Name,
                               Purchase_Order__c, Purchase_Order__r.Name, Purchase_Order__r.Status__c,
                               Purchase_Order__r.Supplying_Account__r.Name,
                               Purchase_Order__r.Requesting_Account__r.Name
                        FROM Purchase_Order_Line_Item__c
                        WHERE Purchase_Order__r.Sales_Allocation__c = :planData.planId
                        WITH USER_MODE
                        ORDER BY CreatedDate ASC
                    ]) {
                        if (poli.Item__c != null) {
                            if (!itemToPolisMap.containsKey(poli.Item__c)) {
                                itemToPolisMap.put(poli.Item__c, new List<Purchase_Order_Line_Item__c>());
                            }
                            itemToPolisMap.get(poli.Item__c).add(poli);
                        }
                    }
                }

                if (planData.destinationLocationId != null) {
                    for (Purchase_Requisition_Line__c prl : [
                        SELECT Id, Name, Status__c, Item__c, Purchase_Requisition__c, Purchase_Requisition__r.Name, Purchase_Requisition__r.Status__c, Purchase_Requisition__r.Supplying_Account__r.Name
                        FROM Purchase_Requisition_Line__c
                        WHERE Purchase_Requisition__r.Source_Location__c = :planData.destinationLocationId
                        WITH USER_MODE
                        ORDER BY CreatedDate DESC
                    ]) {
                        if (prl.Item__c != null && !prLineMap.containsKey(prl.Item__c)) {
                            prLineMap.put(prl.Item__c, prl);
                        }
                    }
                }
            }

            List<Map<String, Object>> details = new List<Map<String, Object>>();
            
            for (SupplyOrderPlanner.LineItemWrapper item : planData.lineItems) {
                Decimal req = item.requiredQty != null ? item.requiredQty : 0;
                totalRequired += req;
                
                Boolean isExecuted = planData.status != null && planData.status != 'Draft';
                
                Decimal res = 0;
                Decimal remaining = req;
                
                if (isExecuted) {
                    res = item.reserveQtyPlanned != null ? item.reserveQtyPlanned : 0;
                } else {
                    Decimal destStock = item.destinationStock != null ? item.destinationStock : 0;
                    res = planData.isDestinationLocationActive ? Math.min(req, destStock) : 0;
                }
                reservedQty += res;
                remaining -= res;
                
                if (res > 0) {
                    Inventory_Reservation__c rRec = resMap.get(item.lineItemId);
                    Map<String, Object> d = new Map<String, Object>();
                    d.put('sourceType', 'Reservation');
                    d.put('requestType', 'Reservation');
                    d.put('fromWarehouse', planData.destinationLocationName);
                    d.put('productName', item.itemName);
                    d.put('lineItemId', item.lineItemId);
                    d.put('lineItemName', item.lineItemName);
                    d.put('qty', res);
                    d.put('sourceNumber', rRec != null ? rRec.Name : 'Not Generated');
                    d.put('sourceId', rRec != null ? rRec.Id : null);
                    d.put('status', rRec != null && String.isNotBlank(rRec.Status__c) ? rRec.Status__c : (planData.status != null ? planData.status : 'Draft'));
                    if (rRec == null) {
                        d.put('reason', 'Reservation record not generated yet (Plan status: ' + (planData.status != null ? planData.status : 'Draft') + ')');
                    }
                    details.add(d);
                }
                
                if (isExecuted) {
                    Decimal itemTransferAllocated = 0;
                    if (item.transferQtyPlannedMap != null) {
                        for (SupplyOrderPlanner.LocationInfo loc : planData.transferLocations) {
                            Decimal tAlloc = item.transferQtyPlannedMap.get(loc.locationId);
                            if (tAlloc == null) tAlloc = 0;
                            if (tAlloc > 0) {
                                transferQty += tAlloc;
                                itemTransferAllocated += tAlloc;
                                remaining -= tAlloc;
                                Supply_Request__c srRec = transSrMap.get(item.lineItemId);
                                Inventory_Transfer__c tRec = transMap.get(item.lineItemId);
                                String srcNum = srRec != null ? srRec.Name : (tRec != null ? tRec.Name : 'Not Generated');
                                Id srcId = srRec != null ? srRec.Id : (tRec != null ? tRec.Id : null);
                                String statusVal = srRec != null && String.isNotBlank(srRec.Status__c) ? srRec.Status__c : (tRec != null && String.isNotBlank(tRec.Status__c) ? tRec.Status__c : (planData.status != null ? planData.status : 'Planned'));

                                // 1. Transfer SR
                                Map<String, Object> d = new Map<String, Object>();
                                d.put('sourceType', 'Transfer SR');
                                d.put('requestType', 'Transfer SR');
                                d.put('fromWarehouse', loc.locationName);
                                d.put('productName', item.itemName);
                                d.put('lineItemId', item.lineItemId);
                                d.put('lineItemName', item.lineItemName);
                                d.put('qty', tAlloc);
                                d.put('sourceNumber', srcNum);
                                d.put('sourceId', srcId);
                                d.put('status', statusVal);
                                if (srRec == null && tRec == null) {
                                    d.put('reason', 'Transfer record not generated yet');
                                }
                                details.add(d);
                            }
                        }
                    }

                    Decimal plannedTrans = item.transferQtyPlanned != null ? item.transferQtyPlanned : 0;
                    if (plannedTrans > itemTransferAllocated) {
                        Decimal remainingTrans = plannedTrans - itemTransferAllocated;
                        transferQty += remainingTrans;
                        remaining -= remainingTrans;

                        Supply_Request__c srRec = transSrMap.get(item.lineItemId);
                        Inventory_Transfer__c tRec = transMap.get(item.lineItemId);
                        String srcNum = srRec != null ? srRec.Name : (tRec != null ? tRec.Name : 'Not Generated');
                        Id srcId = srRec != null ? srRec.Id : (tRec != null ? tRec.Id : null);
                        String statusVal = srRec != null && String.isNotBlank(srRec.Status__c) ? srRec.Status__c : (tRec != null && String.isNotBlank(tRec.Status__c) ? tRec.Status__c : (planData.status != null ? planData.status : 'Planned'));
                        String fromLocName = (planData.transferLocations != null && !planData.transferLocations.isEmpty()) 
                            ? planData.transferLocations[0].locationName 
                            : 'Transfer Location';

                        Map<String, Object> d = new Map<String, Object>();
                        d.put('sourceType', 'Transfer SR');
                        d.put('requestType', 'Transfer SR');
                        d.put('fromWarehouse', fromLocName);
                        d.put('productName', item.itemName);
                        d.put('lineItemId', item.lineItemId);
                        d.put('lineItemName', item.lineItemName);
                        d.put('qty', remainingTrans);
                        d.put('sourceNumber', srcNum);
                        d.put('sourceId', srcId);
                        d.put('status', statusVal);
                        if (srRec == null && tRec == null) {
                            d.put('reason', 'Transfer record not generated yet (Plan status: ' + (planData.status != null ? planData.status : 'Planned') + ')');
                        }
                        details.add(d);
                    }
                } else {
                    if (item.transferStocks != null) {
                        for (SupplyOrderPlanner.LocationInfo loc : planData.transferLocations) {
                            Decimal tStock = item.transferStocks.get(loc.locationId);
                            if (tStock == null) tStock = 0;
                            Decimal tAlloc = Math.min(remaining, tStock);
                            if (tAlloc > 0) {
                                transferQty += tAlloc;
                                remaining -= tAlloc;
                                Inventory_Transfer__c tRec = transMap.get(item.lineItemId);
                                Map<String, Object> d = new Map<String, Object>();
                                d.put('sourceType', 'Transfer SR');
                                d.put('requestType', 'Transfer SR');
                                d.put('fromWarehouse', loc.locationName);
                                d.put('productName', item.itemName);
                                d.put('lineItemId', item.lineItemId);
                                d.put('lineItemName', item.lineItemName);
                                d.put('qty', tAlloc);
                                d.put('sourceNumber', tRec != null ? tRec.Name : 'Not Generated');
                                d.put('sourceId', tRec != null ? tRec.Id : null);
                                d.put('status', tRec != null && String.isNotBlank(tRec.Status__c) ? tRec.Status__c : (planData.status != null ? planData.status : 'Draft'));
                                if (tRec == null) {
                                    d.put('reason', 'Transfer record not generated yet (Plan status: ' + (planData.status != null ? planData.status : 'Draft') + ')');
                                }
                                details.add(d);
                            }
                        }
                    }
                }
                
                Decimal proc = 0;
                if (isExecuted) {
                    proc = item.procureQtyPlanned != null ? item.procureQtyPlanned : 0;
                } else {
                    proc = remaining;
                }
                
                if (proc > 0) {
                    procurementQty += proc;
                }

                // Add all related Purchase Orders for this item
                if (itemToPolisMap.containsKey(item.itemId)) {
                    for (Purchase_Order_Line_Item__c poli : itemToPolisMap.get(item.itemId)) {
                        Map<String, Object> d = new Map<String, Object>();
                        d.put('sourceType', 'Purchase Order');
                        d.put('requestType', 'Purchase Order');
                        d.put('fromWarehouse', poli.Purchase_Order__r != null && poli.Purchase_Order__r.Supplying_Account__r != null ? poli.Purchase_Order__r.Supplying_Account__r.Name : 'Parent Account');
                        d.put('productName', item.itemName);
                        d.put('lineItemId', item.lineItemId);
                        d.put('lineItemName', item.lineItemName);
                        d.put('qty', poli.Ordered_Qty__c != null ? poli.Ordered_Qty__c : 0);
                        d.put('sourceNumber', poli.Purchase_Order__r != null ? poli.Purchase_Order__r.Name : 'Not Generated');
                        d.put('sourceId', poli.Purchase_Order__c);
                        d.put('status', poli.Purchase_Order__r != null && String.isNotBlank(poli.Purchase_Order__r.Status__c) ? poli.Purchase_Order__r.Status__c : 'Draft');
                        details.add(d);
                    }
                } else if (proc > 0) {
                    // Placeholder when PO record is not yet in DB
                    Purchase_Requisition_Line__c prlRec = prLineMap.get(item.itemId);
                    String fromAccountName = (prlRec != null && prlRec.Purchase_Requisition__r != null && prlRec.Purchase_Requisition__r.Supplying_Account__r != null)
                        ? prlRec.Purchase_Requisition__r.Supplying_Account__r.Name
                        : (planData.procurementAccountName != null ? planData.procurementAccountName : 'Parent Account');

                    Map<String, Object> d = new Map<String, Object>();
                    d.put('sourceType', 'Purchase Order');
                    d.put('requestType', 'Purchase Order');
                    d.put('fromWarehouse', fromAccountName);
                    d.put('productName', item.itemName);
                    d.put('lineItemId', item.lineItemId);
                    d.put('lineItemName', item.lineItemName);
                    d.put('qty', proc);
                    d.put('sourceNumber', (prlRec != null && prlRec.Purchase_Requisition__r != null) ? prlRec.Purchase_Requisition__r.Name : 'Not Generated');
                    d.put('sourceId', prlRec != null ? prlRec.Purchase_Requisition__c : null);
                    d.put('status', prlRec != null && prlRec.Purchase_Requisition__r != null && String.isNotBlank(prlRec.Purchase_Requisition__r.Status__c) ? prlRec.Purchase_Requisition__r.Status__c : (planData.status != null ? planData.status : 'Draft'));
                    if (prlRec == null) {
                        d.put('reason', 'Purchase Order record not generated yet (Plan status: ' + (planData.status != null ? planData.status : 'Draft') + ')');
                    }
                    details.add(d);
                }

                // Add Purchase SR if present
                if (procSrMap.containsKey(item.lineItemId)) {
                    Supply_Request__c pSr = procSrMap.get(item.lineItemId);
                    Map<String, Object> d = new Map<String, Object>();
                    d.put('sourceType', 'Purchase SR');
                    d.put('requestType', 'Purchase SR');
                    d.put('fromWarehouse', pSr.Supplying_Account__r != null ? pSr.Supplying_Account__r.Name : 'Parent Account');
                    d.put('productName', item.itemName);
                    d.put('lineItemId', item.lineItemId);
                    d.put('lineItemName', item.lineItemName);
                    d.put('qty', proc);
                    d.put('sourceNumber', pSr.Name);
                    d.put('sourceId', pSr.Id);
                    d.put('status', String.isNotBlank(pSr.Status__c) ? pSr.Status__c : 'Open');
                    details.add(d);
                }
            }
            
            Decimal totalCovered = reservedQty + transferQty + procurementQty;
            
            result.put('isFound', true);
            result.put('totalRequired', totalRequired);
            result.put('reservedQty', reservedQty);
            result.put('transferQty', transferQty);
            result.put('procurementQty', procurementQty);
            result.put('totalCovered', totalCovered);
            
            result.put('reservedPercent', totalRequired > 0 ? (reservedQty / totalRequired) * 100 : 0);
            result.put('transferPercent', totalRequired > 0 ? (transferQty / totalRequired) * 100 : 0);
            result.put('procurementPercent', totalRequired > 0 ? (procurementQty / totalRequired) * 100 : 0);
            result.put('totalCoveredPercent', totalRequired > 0 ? (totalCovered / totalRequired) * 100 : 0);
            
            result.put('planDetails', details);
            result.put('status', planData.status);
            
        } catch (Exception e) {
            result.put('isFound', false);
            result.put('error', e.getMessage());
        }
        return result;
    }

}