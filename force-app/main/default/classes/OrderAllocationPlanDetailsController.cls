public with sharing class OrderAllocationPlanDetailsController {
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSupplyPlanSummary(String searchTerm) {
        if (String.isBlank(searchTerm)) {
            Map<String, Object> result = new Map<String, Object>();
            result.put('isFound', false);
            return result;
        }

        Id planId;
        String status;

        Boolean isId = false;
        try {
            Id tempId = (Id)searchTerm.trim();
            isId = true;
        } catch (Exception e) {
            isId = false;
        }

        List<Order_Allocation__c> plans = new List<Order_Allocation__c>();
        if (isId) {
            plans = [
                SELECT Id, Status__c, Target_Location__c, Supplying_Account__c, Target_Location__r.Account__c
                FROM Order_Allocation__c
                WHERE Id = :searchTerm.trim()
                WITH USER_MODE
                LIMIT 1
            ];
        } else {
            plans = [
                SELECT Id, Status__c, Target_Location__c, Supplying_Account__c, Target_Location__r.Account__c
                FROM Order_Allocation__c
                WHERE Name = :searchTerm.trim()
                WITH USER_MODE
                LIMIT 1
            ];
        }
        if (plans.isEmpty()) {
            String searchTermLike = '%' + searchTerm.replaceAll('\\s+', '%') + '%';
            plans = [
                SELECT Id, Status__c, Target_Location__c, Supplying_Account__c, Target_Location__r.Account__c
                FROM Order_Allocation__c
                WHERE Name LIKE :searchTermLike
                WITH USER_MODE
                LIMIT 1
            ];
        }
        if (!plans.isEmpty()) {
            Order_Allocation__c plan = plans[0];
            planId = plan.Id;
            status = plan.Status__c;
        }

        if (planId != null) {
            List<Map<String, Object>> details = new List<Map<String, Object>>();
            Decimal totalRequired = 0;
            Decimal reservedQtySum = 0;
            Decimal transferQtySum = 0;
            Decimal procurementQtySum = 0;

            // 1. Query Line Items for Total Required Qty, Supply Requests, and direct PO links
            List<Order_Allocation_Line_Item__c> items = [
                SELECT Id, Name, Ordered_Qty__c, Reserved_Qty_Planned__c, Transfer_Qty_Planned__c, Procurement_Qty_Planned__c,
                       Reserved_Quantity__c, Status__c, Item__c, Item__r.Name,
                       Supply_Request__c, Supply_Request__r.Name, Supply_Request__r.Status__c,
                       Supply_Request__r.Requested_Qty__c, Supply_Request__r.Supply_Method__c,
                       Supply_Request__r.Request_Type__c, Supply_Request__r.Type__c,
                       Supply_Request__r.Supplying_Account__r.Name, Supply_Request__r.Source_Location__r.Name,
                       Purchase_Order_Line_Item__c, Purchase_Order_Line_Item__r.Name,
                       Purchase_Order_Line_Item__r.Ordered_Qty__c,
                       Purchase_Order_Line_Item__r.Purchase_Order__c,
                       Purchase_Order_Line_Item__r.Purchase_Order__r.Name,
                       Purchase_Order_Line_Item__r.Purchase_Order__r.Status__c,
                       Purchase_Order_Line_Item__r.Purchase_Order__r.Supplying_Account__r.Name,
                       Order_Allocation__r.Source_Location__r.Name
                FROM Order_Allocation_Line_Item__c
                WHERE Order_Allocation__c = :planId
                WITH USER_MODE
            ];
            Set<Id> lineItemIds = new Set<Id>();
            Map<Id, Order_Allocation_Line_Item__c> itemToLineItemMap = new Map<Id, Order_Allocation_Line_Item__c>();
            for (Order_Allocation_Line_Item__c item : items) {
                totalRequired += (item.Ordered_Qty__c != null ? item.Ordered_Qty__c : 0);
                lineItemIds.add(item.Id);
                if (item.Item__c != null && !itemToLineItemMap.containsKey(item.Item__c)) {
                    itemToLineItemMap.put(item.Item__c, item);
                }
            }

            // 2. Query Reservations
            List<Inventory_Reservation__c> reservations = [
                SELECT Id, Name, Reserved_Qty__c, Order_Allocation_Line_Item__c, Order_Allocation_Line_Item__r.Name,
                       Item__r.Name, Inventory_Location__r.Name, Status__c
                FROM Inventory_Reservation__c
                WHERE Order_Allocation_Line_Item__r.Order_Allocation__c = :planId
                WITH USER_MODE
            ];

            // 3. Query Transfers
            List<Inventory_Transfer__c> transfers = [
                SELECT Id, Name, Transfer_Qty__c, Order_Allocation_Line_Item__c, Order_Allocation_Line_Item__r.Name,
                       Item__r.Name, Source_Inventory_Location__r.Name, Status__c
                FROM Inventory_Transfer__c
                WHERE Order_Allocation_Line_Item__r.Order_Allocation__c = :planId AND Status__c != 'Cancelled'
                WITH USER_MODE
            ];

            // 4. Query Supply Requests linked to Order Allocation Line Items
            List<Supply_Request__c> supplyRequests = [
                SELECT Id, Name, Status__c, Requested_Qty__c, Supply_Method__c, Request_Type__c, Type__c,
                       Supplying_Account__r.Name, Source_Location__r.Name,
                       Order_Allocation_Line_Item__c, Order_Allocation_Line_Item__r.Name,
                       Item__r.Name
                FROM Supply_Request__c
                WHERE Order_Allocation_Line_Item__r.Order_Allocation__c = :planId
                WITH USER_MODE
            ];

            // 5. Query ALL Purchase Orders and Line Items where Sales_Allocation__c = planId (or linked directly via line item)
            Set<Id> directPoIds = new Set<Id>();
            for (Order_Allocation_Line_Item__c li : items) {
                if (li.Purchase_Order_Line_Item__c != null && li.Purchase_Order_Line_Item__r != null && li.Purchase_Order_Line_Item__r.Purchase_Order__c != null) {
                    directPoIds.add(li.Purchase_Order_Line_Item__r.Purchase_Order__c);
                }
            }

            List<Purchase_Order_Line_Item__c> allRelatedPolis = [
                SELECT Id, Name, Ordered_Qty__c, Status__c, Item__c, Item__r.Name,
                       Purchase_Order__c, Purchase_Order__r.Name, Purchase_Order__r.Status__c,
                       Purchase_Order__r.Supplying_Account__r.Name,
                       Purchase_Order__r.Requesting_Account__r.Name,
                       Purchase_Order__r.Sales_Allocation__c
                FROM Purchase_Order_Line_Item__c
                WHERE Purchase_Order__r.Sales_Allocation__c = :planId
                   OR Purchase_Order__c IN :directPoIds
                WITH USER_MODE
                ORDER BY CreatedDate ASC
            ];

            if (!reservations.isEmpty() || !transfers.isEmpty() || !supplyRequests.isEmpty() || !allRelatedPolis.isEmpty() || !items.isEmpty() || (status != 'Draft' && String.isNotBlank(status))) {
                Map<Id, Decimal> lineItemTransferQtyMap = new Map<Id, Decimal>();
                Map<Id, Decimal> lineItemReservedQtyMap = new Map<Id, Decimal>();
                Map<Id, Decimal> lineItemProcurementQtyMap = new Map<Id, Decimal>();

                // A. Reservations
                for (Inventory_Reservation__c r : reservations) {
                    Decimal qty = r.Reserved_Qty__c != null ? r.Reserved_Qty__c : 0;
                    reservedQtySum += qty;
                    lineItemReservedQtyMap.put(r.Order_Allocation_Line_Item__c, (lineItemReservedQtyMap.containsKey(r.Order_Allocation_Line_Item__c) ? lineItemReservedQtyMap.get(r.Order_Allocation_Line_Item__c) : 0) + qty);
                    Map<String, Object> d = new Map<String, Object>();
                    d.put('sourceType', 'Reservation');
                    d.put('requestType', 'Reservation');
                    d.put('status', r.Status__c != null ? r.Status__c : 'Reserved');
                    d.put('fromWarehouse', r.Inventory_Location__r != null ? r.Inventory_Location__r.Name : '');
                    d.put('productName', r.Item__r != null ? r.Item__r.Name : '');
                    d.put('supplyMethod', '');
                    d.put('lineItemId', r.Order_Allocation_Line_Item__c);
                    d.put('lineItemName', r.Order_Allocation_Line_Item__r != null ? r.Order_Allocation_Line_Item__r.Name : '');
                    d.put('qty', qty);
                    d.put('sourceNumber', String.isNotBlank(r.Name) ? r.Name : 'Not Generated');
                    d.put('sourceId', r.Id);
                    details.add(d);
                }

                // B. Inventory Transfers (if any recorded in DB)
                for (Inventory_Transfer__c t : transfers) {
                    Decimal qty = t.Transfer_Qty__c != null ? t.Transfer_Qty__c : 0;
                    transferQtySum += qty;
                    lineItemTransferQtyMap.put(t.Order_Allocation_Line_Item__c, (lineItemTransferQtyMap.containsKey(t.Order_Allocation_Line_Item__c) ? lineItemTransferQtyMap.get(t.Order_Allocation_Line_Item__c) : 0) + qty);
                    Map<String, Object> d = new Map<String, Object>();
                    d.put('sourceType', 'Transfer SR');
                    d.put('requestType', 'Transfer SR');
                    d.put('status', t.Status__c != null ? t.Status__c : 'Open');
                    d.put('fromWarehouse', t.Source_Inventory_Location__r != null ? t.Source_Inventory_Location__r.Name : '');
                    d.put('productName', t.Item__r != null ? t.Item__r.Name : '');
                    d.put('supplyMethod', '');
                    d.put('lineItemId', t.Order_Allocation_Line_Item__c);
                    d.put('lineItemName', t.Order_Allocation_Line_Item__r != null ? t.Order_Allocation_Line_Item__r.Name : '');
                    d.put('qty', qty);
                    d.put('sourceNumber', String.isNotBlank(t.Name) ? t.Name : 'Not Generated');
                    d.put('sourceId', t.Id);
                    details.add(d);
                }

                // C. Supply Requests linked via Order_Allocation_Line_Item__c
                Set<Id> addedSrIds = new Set<Id>();
                for (Supply_Request__c sr : supplyRequests) {
                    addedSrIds.add(sr.Id);
                    Decimal qty = sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0;
                    String fromAccName = (sr.Supplying_Account__r != null && String.isNotBlank(sr.Supplying_Account__r.Name))
                        ? sr.Supplying_Account__r.Name
                        : (sr.Source_Location__r != null ? sr.Source_Location__r.Name : 'Parent Account');

                    String srRequestType = 'Purchase SR';
                    if (sr.Request_Type__c == 'Transfer SR' || sr.Type__c == 'Transfer' || (sr.Name != null && sr.Name.contains('Transfer')) || sr.RecordType.DeveloperName == 'Transfer_Supply_Request') {
                        srRequestType = 'Transfer SR';
                    } else if (String.isNotBlank(sr.Request_Type__c)) {
                        srRequestType = sr.Request_Type__c;
                    }
                    if (srRequestType != 'Transfer SR' && srRequestType != 'Purchase SR') {
                        srRequestType = 'Purchase SR';
                    }

                    if (srRequestType == 'Transfer SR') {
                        transferQtySum += qty;
                        lineItemTransferQtyMap.put(sr.Order_Allocation_Line_Item__c, (lineItemTransferQtyMap.containsKey(sr.Order_Allocation_Line_Item__c) ? lineItemTransferQtyMap.get(sr.Order_Allocation_Line_Item__c) : 0) + qty);
                    } else {
                        procurementQtySum += qty;
                        lineItemProcurementQtyMap.put(sr.Order_Allocation_Line_Item__c, (lineItemProcurementQtyMap.containsKey(sr.Order_Allocation_Line_Item__c) ? lineItemProcurementQtyMap.get(sr.Order_Allocation_Line_Item__c) : 0) + qty);
                    }

                    Map<String, Object> d = new Map<String, Object>();
                    d.put('sourceType', srRequestType);
                    d.put('requestType', srRequestType);
                    d.put('status', sr.Status__c != null ? sr.Status__c : 'Open');
                    d.put('fromWarehouse', fromAccName);
                    d.put('productName', sr.Item__r != null ? sr.Item__r.Name : '');
                    d.put('supplyMethod', sr.Supply_Method__c != null ? sr.Supply_Method__c : 'Purchase');
                    d.put('lineItemId', sr.Order_Allocation_Line_Item__c);
                    d.put('lineItemName', sr.Order_Allocation_Line_Item__r != null ? sr.Order_Allocation_Line_Item__r.Name : '');
                    d.put('qty', qty);
                    d.put('sourceNumber', sr.Name);
                    d.put('sourceId', sr.Id);
                    details.add(d);
                }

                // Fallback for Supply Requests linked directly via li.Supply_Request__c
                for (Order_Allocation_Line_Item__c li : items) {
                    if (li.Supply_Request__c != null && li.Supply_Request__r != null && !addedSrIds.contains(li.Supply_Request__c)) {
                        addedSrIds.add(li.Supply_Request__c);
                        Decimal qty = li.Supply_Request__r.Requested_Qty__c != null 
                            ? li.Supply_Request__r.Requested_Qty__c 
                            : (li.Procurement_Qty_Planned__c != null ? li.Procurement_Qty_Planned__c : (li.Ordered_Qty__c != null ? li.Ordered_Qty__c : 0));
                        String fromAccName = (li.Supply_Request__r.Supplying_Account__r != null && String.isNotBlank(li.Supply_Request__r.Supplying_Account__r.Name))
                            ? li.Supply_Request__r.Supplying_Account__r.Name
                            : (li.Supply_Request__r.Source_Location__r != null ? li.Supply_Request__r.Source_Location__r.Name : 'Parent Account');

                        String srRequestType = 'Purchase SR';
                        if (li.Supply_Request__r.Request_Type__c == 'Transfer SR' || (li.Supply_Request__r.Name != null && li.Supply_Request__r.Name.contains('Transfer'))) {
                            srRequestType = 'Transfer SR';
                        } else if (String.isNotBlank(li.Supply_Request__r.Request_Type__c)) {
                            srRequestType = li.Supply_Request__r.Request_Type__c;
                        }
                        if (srRequestType != 'Transfer SR' && srRequestType != 'Purchase SR') {
                            srRequestType = 'Purchase SR';
                        }

                        if (srRequestType == 'Transfer SR') {
                            transferQtySum += qty;
                            lineItemTransferQtyMap.put(li.Id, (lineItemTransferQtyMap.containsKey(li.Id) ? lineItemTransferQtyMap.get(li.Id) : 0) + qty);
                        } else {
                            procurementQtySum += qty;
                            lineItemProcurementQtyMap.put(li.Id, (lineItemProcurementQtyMap.containsKey(li.Id) ? lineItemProcurementQtyMap.get(li.Id) : 0) + qty);
                        }

                        Map<String, Object> d = new Map<String, Object>();
                        d.put('sourceType', srRequestType);
                        d.put('requestType', srRequestType);
                        d.put('status', li.Supply_Request__r.Status__c != null ? li.Supply_Request__r.Status__c : 'Open');
                        d.put('fromWarehouse', fromAccName);
                        d.put('productName', li.Item__r != null ? li.Item__r.Name : '');
                        d.put('supplyMethod', li.Supply_Request__r.Supply_Method__c != null ? li.Supply_Request__r.Supply_Method__c : 'Purchase');
                        d.put('lineItemId', li.Id);
                        d.put('lineItemName', li.Name);
                        d.put('qty', qty);
                        d.put('sourceNumber', li.Supply_Request__r.Name);
                        d.put('sourceId', li.Supply_Request__c);
                        details.add(d);
                    }
                }

                // D. ALL Purchase Orders linked to this Order Allocation (via Sales_Allocation__c or direct POLI)
                Set<Id> addedPoliIds = new Set<Id>();
                for (Purchase_Order_Line_Item__c poli : allRelatedPolis) {
                    if (addedPoliIds.contains(poli.Id)) {
                        continue;
                    }
                    addedPoliIds.add(poli.Id);

                    Order_Allocation_Line_Item__c matchedLi = (poli.Item__c != null && itemToLineItemMap.containsKey(poli.Item__c))
                        ? itemToLineItemMap.get(poli.Item__c)
                        : (!items.isEmpty() ? items[0] : null);

                    Decimal qty = poli.Ordered_Qty__c != null ? poli.Ordered_Qty__c : 0;
                    String fromAccName = (poli.Purchase_Order__r != null && poli.Purchase_Order__r.Supplying_Account__r != null)
                        ? poli.Purchase_Order__r.Supplying_Account__r.Name
                        : 'Parent Account';

                    Map<String, Object> d = new Map<String, Object>();
                    d.put('sourceType', 'Purchase Order');
                    d.put('requestType', 'Purchase Order');
                    d.put('status', (poli.Purchase_Order__r != null && poli.Purchase_Order__r.Status__c != null) ? poli.Purchase_Order__r.Status__c : 'Draft');
                    d.put('fromWarehouse', fromAccName);
                    d.put('productName', (poli.Item__r != null && String.isNotBlank(poli.Item__r.Name)) ? poli.Item__r.Name : (matchedLi != null && matchedLi.Item__r != null ? matchedLi.Item__r.Name : ''));
                    d.put('supplyMethod', 'Purchase');
                    d.put('lineItemId', matchedLi != null ? matchedLi.Id : null);
                    d.put('lineItemName', matchedLi != null ? matchedLi.Name : '');
                    d.put('qty', qty);
                    d.put('sourceNumber', poli.Purchase_Order__r != null ? poli.Purchase_Order__r.Name : 'Not Generated');
                    d.put('sourceId', poli.Purchase_Order__c);
                    details.add(d);
                }

                // Fallback for planned quantities on line items that are not yet generated as DB records
                for (Order_Allocation_Line_Item__c li : items) {
                    // A. Planned Transfers
                    Decimal plannedTrans = li.Transfer_Qty_Planned__c != null ? li.Transfer_Qty_Planned__c : 0;
                    Decimal existingTrans = lineItemTransferQtyMap.containsKey(li.Id) ? lineItemTransferQtyMap.get(li.Id) : 0;
                    if (plannedTrans > existingTrans) {
                        Decimal remainingTrans = plannedTrans - existingTrans;
                        transferQtySum += remainingTrans;
                        lineItemTransferQtyMap.put(li.Id, existingTrans + remainingTrans);

                        String fromWarehouse = (li.Order_Allocation__r != null && li.Order_Allocation__r.Source_Location__r != null)
                            ? li.Order_Allocation__r.Source_Location__r.Name
                            : 'Transfer Location';

                        Map<String, Object> d = new Map<String, Object>();
                        d.put('sourceType', 'Transfer SR');
                        d.put('requestType', 'Transfer SR');
                        d.put('status', String.isNotBlank(li.Status__c) ? li.Status__c : (status != null ? status : 'Planned'));
                        d.put('fromWarehouse', fromWarehouse);
                        d.put('productName', li.Item__r != null ? li.Item__r.Name : '');
                        d.put('supplyMethod', '');
                        d.put('lineItemId', li.Id);
                        d.put('lineItemName', li.Name);
                        d.put('qty', remainingTrans);
                        d.put('sourceNumber', 'Not Generated');
                        d.put('sourceId', null);
                        d.put('reason', 'Transfer record not generated yet (Plan status: ' + (status != null ? status : 'Planned') + ')');
                        details.add(d);
                    }

                    // B. Planned Reservations
                    Decimal plannedRes = li.Reserved_Qty_Planned__c != null ? li.Reserved_Qty_Planned__c : (li.Reserved_Quantity__c != null ? li.Reserved_Quantity__c : 0);
                    Decimal existingRes = lineItemReservedQtyMap.containsKey(li.Id) ? lineItemReservedQtyMap.get(li.Id) : 0;
                    if (plannedRes > existingRes) {
                        Decimal remainingRes = plannedRes - existingRes;
                        reservedQtySum += remainingRes;
                        lineItemReservedQtyMap.put(li.Id, existingRes + remainingRes);

                        Map<String, Object> d = new Map<String, Object>();
                        d.put('sourceType', 'Reservation');
                        d.put('requestType', 'Reservation');
                        d.put('status', String.isNotBlank(li.Status__c) ? li.Status__c : (status != null ? status : 'Planned'));
                        d.put('fromWarehouse', 'Current Location');
                        d.put('productName', li.Item__r != null ? li.Item__r.Name : '');
                        d.put('supplyMethod', '');
                        d.put('lineItemId', li.Id);
                        d.put('lineItemName', li.Name);
                        d.put('qty', remainingRes);
                        d.put('sourceNumber', 'Not Generated');
                        d.put('sourceId', null);
                        d.put('reason', 'Reservation record not generated yet (Plan status: ' + (status != null ? status : 'Planned') + ')');
                        details.add(d);
                    }

                    // C. Planned Procurement (if not generated as PO / SR)
                    Decimal plannedProc = li.Procurement_Qty_Planned__c != null ? li.Procurement_Qty_Planned__c : 0;
                    Decimal existingProc = lineItemProcurementQtyMap.containsKey(li.Id) ? lineItemProcurementQtyMap.get(li.Id) : 0;
                    if (plannedProc > existingProc && plannedProc > 0 && existingProc == 0) {
                        Decimal remainingProc = plannedProc - existingProc;
                        procurementQtySum += remainingProc;
                        lineItemProcurementQtyMap.put(li.Id, existingProc + remainingProc);

                        Map<String, Object> d = new Map<String, Object>();
                        d.put('sourceType', 'Purchase Order');
                        d.put('requestType', 'Purchase Order');
                        d.put('status', String.isNotBlank(li.Status__c) ? li.Status__c : (status != null ? status : 'Planned'));
                        d.put('fromWarehouse', 'Parent Account');
                        d.put('productName', li.Item__r != null ? li.Item__r.Name : '');
                        d.put('supplyMethod', 'Purchase');
                        d.put('lineItemId', li.Id);
                        d.put('lineItemName', li.Name);
                        d.put('qty', remainingProc);
                        d.put('sourceNumber', 'Not Generated');
                        d.put('sourceId', null);
                        d.put('reason', 'Procurement record not generated yet (Plan status: ' + (status != null ? status : 'Planned') + ')');
                        details.add(d);
                    }
                }

                Decimal totalCovered = reservedQtySum + transferQtySum + procurementQtySum;

                Map<String, Object> result = new Map<String, Object>();
                result.put('isFound', true);
                result.put('status', status);
                result.put('planDetails', details);
                result.put('totalRequired', totalRequired);
                result.put('reservedQty', reservedQtySum);
                result.put('transferQty', transferQtySum);
                result.put('procurementQty', procurementQtySum);
                result.put('totalCovered', totalCovered);

                result.put('reservedPercent', totalRequired > 0 ? (reservedQtySum / totalRequired) * 100 : 0);
                result.put('transferPercent', totalRequired > 0 ? (transferQtySum / totalRequired) * 100 : 0);
                result.put('procurementPercent', totalRequired > 0 ? (procurementQtySum / totalRequired) * 100 : 0);
                result.put('totalCoveredPercent', totalRequired > 0 ? (totalCovered / totalRequired) * 100 : 0);

                return result;
            }
        }

        // Fallback for draft plan details / simulation
        return SupplyPlanController.getSupplyPlanSummary(searchTerm);
    }

    @AuraEnabled
    public static Map<String, Object> getLineItemSourceMap(List<Id> lineItemIds) {
        Map<String, Object> resultMap = new Map<String, Object>();
        if (lineItemIds == null || lineItemIds.isEmpty()) {
            return resultMap;
        }

        List<Order_Allocation_Line_Item__c> items = [
            SELECT Id, Order_Allocation__c, Item__c, Item__r.Name,
                   Transfer_Qty_Planned__c, Procurement_Qty_Planned__c,
                   Supply_Request__c, Supply_Request__r.Name, Supply_Request__r.Status__c,
                   Supply_Request__r.Request_Type__c, Supply_Request__r.Type__c,
                   Supply_Request__r.Supply_Method__c,
                   Purchase_Order_Line_Item__c,
                   Purchase_Order_Line_Item__r.Purchase_Order__c,
                   Purchase_Order_Line_Item__r.Purchase_Order__r.Name,
                   Purchase_Order_Line_Item__r.Purchase_Order__r.Status__c
            FROM Order_Allocation_Line_Item__c
            WHERE Id IN :lineItemIds
            WITH USER_MODE
        ];

        Set<Id> planIds = new Set<Id>();
        Set<Id> directPoliIds = new Set<Id>();
        Map<Id, List<Order_Allocation_Line_Item__c>> itemToLinesMap = new Map<Id, List<Order_Allocation_Line_Item__c>>();
        for (Order_Allocation_Line_Item__c li : items) {
            if (li.Order_Allocation__c != null) {
                planIds.add(li.Order_Allocation__c);
            }
            if (li.Purchase_Order_Line_Item__c != null) {
                directPoliIds.add(li.Purchase_Order_Line_Item__c);
            }
            if (li.Item__c != null) {
                if (!itemToLinesMap.containsKey(li.Item__c)) {
                    itemToLinesMap.put(li.Item__c, new List<Order_Allocation_Line_Item__c>());
                }
                itemToLinesMap.get(li.Item__c).add(li);
            }
        }

        // Query ALL Purchase Orders where Sales_Allocation__c is in planIds (or directly referenced)
        List<Purchase_Order_Line_Item__c> allPolis = [
            SELECT Id, Name, Ordered_Qty__c, Status__c, Item__c, Item__r.Name,
                   Purchase_Order__c, Purchase_Order__r.Name, Purchase_Order__r.Status__c,
                   Purchase_Order__r.Supplying_Account__r.Name,
                   Purchase_Order__r.Requesting_Account__r.Name,
                   Purchase_Order__r.Sales_Allocation__c
            FROM Purchase_Order_Line_Item__c
            WHERE Purchase_Order__r.Sales_Allocation__c IN :planIds
               OR Id IN :directPoliIds
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        for (Purchase_Order_Line_Item__c poli : allPolis) {
            List<Order_Allocation_Line_Item__c> matchingLines = itemToLinesMap.containsKey(poli.Item__c)
                ? itemToLinesMap.get(poli.Item__c)
                : items;

            for (Order_Allocation_Line_Item__c li : matchingLines) {
                Map<String, Object> poInfo = new Map<String, Object>();
                poInfo.put('sourceNumber', poli.Purchase_Order__r != null ? poli.Purchase_Order__r.Name : '');
                poInfo.put('sourceId', poli.Purchase_Order__c);
                poInfo.put('status', (poli.Purchase_Order__r != null && poli.Purchase_Order__r.Status__c != null) ? poli.Purchase_Order__r.Status__c : 'Draft');
                poInfo.put('qty', poli.Ordered_Qty__c);
                poInfo.put('requestType', 'Purchase Order');
                poInfo.put('supplyMethod', 'Purchase');

                resultMap.put(li.Id + '_PO_' + poli.Purchase_Order__c, poInfo);
                resultMap.put(li.Id + '_Purchase Order', poInfo);
                resultMap.put(li.Id + '_Procurement', poInfo);

                // Add to list of all POs for this line item
                String posKey = li.Id + '_POs';
                if (!resultMap.containsKey(posKey)) {
                    resultMap.put(posKey, new List<Map<String, Object>>());
                }
                ((List<Map<String, Object>>)resultMap.get(posKey)).add(poInfo);

                if (li.Transfer_Qty_Planned__c != null && poli.Ordered_Qty__c == li.Transfer_Qty_Planned__c) {
                    resultMap.put(li.Id + '_Transfer PO', poInfo);
                }
                if (li.Procurement_Qty_Planned__c != null && poli.Ordered_Qty__c == li.Procurement_Qty_Planned__c) {
                    resultMap.put(li.Id + '_Procurement PO', poInfo);
                }
            }
        }

        List<Supply_Request__c> directSRs = [
            SELECT Id, Name, Status__c, Request_Type__c, Type__c, Supply_Method__c, Requested_Qty__c, Order_Allocation_Line_Item__c
            FROM Supply_Request__c
            WHERE Order_Allocation_Line_Item__c IN :lineItemIds
            WITH USER_MODE
        ];

        for (Supply_Request__c sr : directSRs) {
            String srRequestType = 'Purchase SR';
            if (sr.Request_Type__c == 'Transfer SR' || sr.Type__c == 'Transfer' || (sr.Name != null && sr.Name.contains('Transfer'))) {
                srRequestType = 'Transfer SR';
            } else if (String.isNotBlank(sr.Request_Type__c)) {
                srRequestType = sr.Request_Type__c;
            }
            if (srRequestType != 'Transfer SR' && srRequestType != 'Purchase SR') {
                srRequestType = 'Purchase SR';
            }

            Map<String, Object> info = new Map<String, Object>();
            info.put('sourceNumber', sr.Name);
            info.put('sourceId', sr.Id);
            info.put('status', sr.Status__c != null ? sr.Status__c : 'Open');
            info.put('requestType', srRequestType);
            info.put('qty', sr.Requested_Qty__c);
            info.put('supplyMethod', sr.Supply_Method__c != null ? sr.Supply_Method__c : 'Purchase');

            resultMap.put(sr.Order_Allocation_Line_Item__c + '_Supply Request', info);
            resultMap.put(sr.Order_Allocation_Line_Item__c + '_' + srRequestType, info);
            if (srRequestType == 'Transfer SR') {
                resultMap.put(sr.Order_Allocation_Line_Item__c + '_Transfer SR', info);
                resultMap.put(sr.Order_Allocation_Line_Item__c + '_Transfer', info);
            } else {
                resultMap.put(sr.Order_Allocation_Line_Item__c + '_Purchase SR', info);
            }
        }

        List<Inventory_Reservation__c> reservations = [
            SELECT Id, Name, Status__c, Order_Allocation_Line_Item__c
            FROM Inventory_Reservation__c
            WHERE Order_Allocation_Line_Item__c IN :lineItemIds
            WITH USER_MODE
        ];
        for (Inventory_Reservation__c r : reservations) {
            Map<String, Object> info = new Map<String, Object>();
            info.put('sourceNumber', r.Name);
            info.put('sourceId', r.Id);
            info.put('status', r.Status__c);
            info.put('requestType', 'Reservation');
            resultMap.put(r.Order_Allocation_Line_Item__c + '_Reservation', info);
            resultMap.put(r.Order_Allocation_Line_Item__c + '_Reserved', info);
        }

        List<Inventory_Transfer__c> transfers = [
            SELECT Id, Name, Status__c, Order_Allocation_Line_Item__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c IN :lineItemIds AND Status__c != 'Cancelled'
            WITH USER_MODE
        ];
        for (Inventory_Transfer__c t : transfers) {
            Map<String, Object> info = new Map<String, Object>();
            info.put('sourceNumber', t.Name);
            info.put('sourceId', t.Id);
            info.put('status', t.Status__c);
            info.put('requestType', 'Transfer SR');
            resultMap.put(t.Order_Allocation_Line_Item__c + '_Transfer SR', info);
            resultMap.put(t.Order_Allocation_Line_Item__c + '_Transfer', info);
        }

        return resultMap;
    }
}