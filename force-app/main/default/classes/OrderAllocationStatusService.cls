/**
 * @description Service class handling status evaluation and rollups for 
 *              Order_Allocation__c and Order_Allocation_Line_Item__c.
 */
public without sharing class OrderAllocationStatusService {

    private static final Set<String> TERMINAL_OALI_STATUSES = new Set<String>{
        'Ready to Ship',
        'Partially Shipped',
        'Shipped',
        'Partially Delivered',
        'Delivered',
        'Closed',
        'Cancelled'
    };

    private static final Set<String> EVALUABLE_OALI_STATUSES = new Set<String>{
        'Confirmed Planning',
        'Confirmed Planned',
        'Confirmed',
        'Planned',
        'Draft',
        'Awaiting Inventory'
    };

    private static final Set<String> TERMINAL_OA_STATUSES = new Set<String>{
        'Closed',
        'Cancelled'
    };

    /**
     * @description Invocable wrapper for Flow or Process Builder execution.
     */
    public class StatusRequest {
        @InvocableVariable(label='OALI Record ID' description='ID of Order Allocation Line Item')
        public Id oaliId;

        @InvocableVariable(label='OA Record ID' description='ID of Order Allocation')
        public Id oaId;
    }

    @InvocableMethod(
        label='Evaluate Order Allocation Status'
        description='Evaluates OALI fulfillment to Ready to Ship and rolls up OA status'
    )
    public static void processRecordsInvocable(List<StatusRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> oaliIds = new Set<Id>();
        Set<Id> oaIds = new Set<Id>();

        for (StatusRequest req : requests) {
            if (req == null) continue;
            if (req.oaliId != null) {
                if (req.oaliId.getSObjectType() == Order_Allocation_Line_Item__c.SObjectType) {
                    oaliIds.add(req.oaliId);
                } else if (req.oaliId.getSObjectType() == Order_Allocation__c.SObjectType) {
                    oaIds.add(req.oaliId);
                }
            }
            if (req.oaId != null) {
                if (req.oaId.getSObjectType() == Order_Allocation__c.SObjectType) {
                    oaIds.add(req.oaId);
                } else if (req.oaId.getSObjectType() == Order_Allocation_Line_Item__c.SObjectType) {
                    oaliIds.add(req.oaId);
                }
            }
        }

        processStatus(oaliIds, oaIds);
    }

    /**
     * @description Main entry point for Apex calls (Triggers, Queueables, Services).
     */
    public static void processStatus(Set<Id> oaliIds, Set<Id> oaIds) {
        if ((oaliIds == null || oaliIds.isEmpty()) && (oaIds == null || oaIds.isEmpty())) {
            return;
        }

        Set<Id> targetOaIds = new Set<Id>();
        if (oaIds != null) {
            targetOaIds.addAll(oaIds);
        }

        // STEP 1: Query all relevant line items (explicit OALI IDs OR all line items under target OA IDs)
        List<Order_Allocation_Line_Item__c> allRelevantOalis = [
            SELECT Id, Status__c, Ordered_Qty__c, Reserved_Quantity__c,
                   Transfer_Qty_Received__c, Procurement_Qty_Received__c,
                   Remaining_Qty__c, Ready_to_Ship_Date__c,
                   Order_Allocation__c, Order_Allocation__r.Status__c
            FROM Order_Allocation_Line_Item__c
            WHERE Id IN :oaliIds 
               OR (Order_Allocation__c IN :targetOaIds AND Status__c != 'Cancelled')
        ];

        if (allRelevantOalis.isEmpty()) {
            return;
        }

        // Gather all parent OA IDs
        for (Order_Allocation_Line_Item__c oali : allRelevantOalis) {
            if (oali.Order_Allocation__c != null) {
                targetOaIds.add(oali.Order_Allocation__c);
            }
        }

        // STEP 2: Evaluate fulfillment and update eligible OALIs to 'Ready to Ship'
        List<Order_Allocation_Line_Item__c> oalisToUpdate = new List<Order_Allocation_Line_Item__c>();
        Map<Id, String> inMemoryOaliStatusMap = new Map<Id, String>();

        for (Order_Allocation_Line_Item__c oali : allRelevantOalis) {
            inMemoryOaliStatusMap.put(oali.Id, oali.Status__c);

            // Skip terminal OALI statuses
            if (TERMINAL_OALI_STATUSES.contains(oali.Status__c)) {
                continue;
            }

            // Only process valid evaluable statuses
            if (!EVALUABLE_OALI_STATUSES.contains(oali.Status__c)) {
                continue;
            }

            Decimal ordered = oali.Ordered_Qty__c != null ? oali.Ordered_Qty__c : 0;
            Decimal reserved = oali.Reserved_Quantity__c != null ? oali.Reserved_Quantity__c : 0;
            Decimal transferRecv = oali.Transfer_Qty_Received__c != null ? oali.Transfer_Qty_Received__c : 0;
            Decimal procRecv = oali.Procurement_Qty_Received__c != null ? oali.Procurement_Qty_Received__c : 0;

            Decimal calculatedRemaining = ordered - (reserved + transferRecv + procRecv);

            Boolean isFulfilled = (ordered > 0 && calculatedRemaining <= 0) || 
                                  (oali.Remaining_Qty__c != null && oali.Remaining_Qty__c <= 0 && ordered > 0);

            if (isFulfilled) {
                Order_Allocation_Line_Item__c updateOali = new Order_Allocation_Line_Item__c(
                    Id = oali.Id,
                    Status__c = 'Ready to Ship'
                );
                if (oali.Ready_to_Ship_Date__c == null) {
                    updateOali.Ready_to_Ship_Date__c = System.now(); // DateTime field on OALI
                }
                oalisToUpdate.add(updateOali);
                inMemoryOaliStatusMap.put(oali.Id, 'Ready to Ship');
            }
        }

        if (!oalisToUpdate.isEmpty()) {
            Database.SaveResult[] oaliResults = Database.update(oalisToUpdate, false);
            for (Database.SaveResult sr : oaliResults) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        System.debug(LoggingLevel.ERROR, '*** OALI Update Error: ' + err.getStatusCode() + ' - ' + err.getMessage());
                    }
                }
            }
        }

        // STEP 3: Query ALL active child OALIs under parent OAs to calculate complete status rollups
        List<Order_Allocation_Line_Item__c> fullOaliList = [
            SELECT Id, Status__c, Order_Allocation__c
            FROM Order_Allocation_Line_Item__c
            WHERE Order_Allocation__c IN :targetOaIds 
              AND Status__c != 'Cancelled'
        ];

        Map<Id, Integer> totalCountMap = new Map<Id, Integer>();
        Map<Id, Integer> readyCountMap = new Map<Id, Integer>();
        Map<Id, Integer> partiallyShippedCountMap = new Map<Id, Integer>();
        Map<Id, Integer> shippedCountMap = new Map<Id, Integer>();
        Map<Id, Integer> partiallyDeliveredCountMap = new Map<Id, Integer>();
        Map<Id, Integer> deliveredCountMap = new Map<Id, Integer>();

        for (Id oaId : targetOaIds) {
            totalCountMap.put(oaId, 0);
            readyCountMap.put(oaId, 0);
            partiallyShippedCountMap.put(oaId, 0);
            shippedCountMap.put(oaId, 0);
            partiallyDeliveredCountMap.put(oaId, 0);
            deliveredCountMap.put(oaId, 0);
        }

        for (Order_Allocation_Line_Item__c oali : fullOaliList) {
            Id oaId = oali.Order_Allocation__c;
            String currentStatus = inMemoryOaliStatusMap.containsKey(oali.Id) 
                ? inMemoryOaliStatusMap.get(oali.Id) 
                : oali.Status__c;

            totalCountMap.put(oaId, totalCountMap.get(oaId) + 1);

            if (currentStatus == 'Ready to Ship') {
                readyCountMap.put(oaId, readyCountMap.get(oaId) + 1);
            } else if (currentStatus == 'Partially Shipped') {
                partiallyShippedCountMap.put(oaId, partiallyShippedCountMap.get(oaId) + 1);
            } else if (currentStatus == 'Shipped') {
                shippedCountMap.put(oaId, shippedCountMap.get(oaId) + 1);
            } else if (currentStatus == 'Partially Delivered') {
                partiallyDeliveredCountMap.put(oaId, partiallyDeliveredCountMap.get(oaId) + 1);
            } else if (currentStatus == 'Delivered') {
                deliveredCountMap.put(oaId, deliveredCountMap.get(oaId) + 1);
            }
        }

        // STEP 4: Evaluate parent Order Allocations
        List<Order_Allocation__c> parentOAs = [
            SELECT Id, Status__c, Ready_to_Ship_Date__c, Shipped_Date__c
            FROM Order_Allocation__c
            WHERE Id IN :targetOaIds
        ];

        List<Order_Allocation__c> oasToUpdate = new List<Order_Allocation__c>();

        for (Order_Allocation__c oa : parentOAs) {
            if (TERMINAL_OA_STATUSES.contains(oa.Status__c)) {
                continue;
            }

            Integer totalActive = totalCountMap.get(oa.Id);
            Integer readyCount = readyCountMap.get(oa.Id);
            Integer partiallyShippedCount = partiallyShippedCountMap.get(oa.Id);
            Integer shippedCount = shippedCountMap.get(oa.Id);
            Integer partiallyDeliveredCount = partiallyDeliveredCountMap.get(oa.Id);
            Integer deliveredCount = deliveredCountMap.get(oa.Id);

            if (totalActive == null || totalActive == 0) {
                continue;
            }

            String targetStatus = null;
            if (deliveredCount == totalActive) {
                targetStatus = 'Delivered';
            } else if (deliveredCount > 0 || partiallyDeliveredCount > 0) {
                targetStatus = 'Partially Delivered';
            } else if ((shippedCount + deliveredCount) == totalActive) {
                targetStatus = 'Shipped';
            } else if (shippedCount > 0 || partiallyShippedCount > 0) {
                targetStatus = 'Partially Shipped';
            } else if ((readyCount + shippedCount + deliveredCount + partiallyShippedCount + partiallyDeliveredCount) == totalActive) {
                targetStatus = 'Ready to Ship';
            }

            if (targetStatus == null) {
                continue;
            }

            Boolean shouldUpdate = false;
            if (targetStatus == 'Delivered' && oa.Status__c != 'Delivered') {
                shouldUpdate = true;
            } else if (targetStatus == 'Partially Delivered' && oa.Status__c != 'Partially Delivered' && oa.Status__c != 'Delivered') {
                shouldUpdate = true;
            } else if (targetStatus == 'Shipped' && oa.Status__c != 'Shipped' && oa.Status__c != 'Partially Delivered' && oa.Status__c != 'Delivered') {
                shouldUpdate = true;
            } else if (targetStatus == 'Partially Shipped' && oa.Status__c != 'Partially Shipped' && oa.Status__c != 'Shipped' && oa.Status__c != 'Partially Delivered' && oa.Status__c != 'Delivered') {
                shouldUpdate = true;
            } else if (targetStatus == 'Ready to Ship' && oa.Status__c != 'Ready to Ship' && oa.Status__c != 'Partially Shipped' && oa.Status__c != 'Shipped' && oa.Status__c != 'Partially Delivered' && oa.Status__c != 'Delivered') {
                shouldUpdate = true;
            }

            if (shouldUpdate) {
                Order_Allocation__c updateOA = new Order_Allocation__c(
                    Id = oa.Id,
                    Status__c = targetStatus
                );

                if (targetStatus == 'Ready to Ship' || targetStatus == 'Partially Shipped' || targetStatus == 'Shipped' || targetStatus == 'Partially Delivered' || targetStatus == 'Delivered') {
                    if (oa.Ready_to_Ship_Date__c == null) {
                        updateOA.Ready_to_Ship_Date__c = Date.today(); // Date field on OA
                    }
                }
                if (targetStatus == 'Partially Shipped' || targetStatus == 'Shipped' || targetStatus == 'Partially Delivered' || targetStatus == 'Delivered') {
                    if (oa.Shipped_Date__c == null) {
                        updateOA.Shipped_Date__c = Date.today(); // Date field on OA
                    }
                }

                oasToUpdate.add(updateOA);
            }
        }

        if (!oasToUpdate.isEmpty()) {
            Database.SaveResult[] oaResults = Database.update(oasToUpdate, false);
            for (Database.SaveResult sr : oaResults) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        System.debug(LoggingLevel.ERROR, '*** OA Update Error: ' + err.getStatusCode() + ' - ' + err.getMessage());
                    }
                }
            }
        }
    }
}