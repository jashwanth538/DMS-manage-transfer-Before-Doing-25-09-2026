public without sharing class OrderAllocationLineItemTriggerHandler {
    public static Boolean isExecuting = false;

    @TestVisible
    private static Set<Id> processedOaliIds = new Set<Id>();

    private static Boolean isStatusProcessing = false;

    /**
     * Handles before insert trigger event on Order_Allocation_Line_Item__c.
     * Applies fallback pricing logic from Item_Price__c master.
     *
     * @param newList List of new Order_Allocation_Line_Item__c records
     */
    public static void handleBeforeInsert(List<Order_Allocation_Line_Item__c> newList) {
        try {
            Type itemPriceServiceType = Type.forName('ItemPriceService');
            if (itemPriceServiceType != null) {
                ItemPriceService.applyOALIPricing(newList);
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'ItemPriceService error: ' + ex.getMessage());
        }
    }

    /**
     * Handles after update trigger event on Order_Allocation_Line_Item__c.
     * Filters for records transitioning to 'Ready to Ship' status and creates
     * inventory transfers, while invoking OrderAllocationStatusService to
     * process fulfillment and parent Order Allocation statuses.
     *
     * @param newList List of updated Order_Allocation_Line_Item__c records
     * @param oldMap  Map of old Order_Allocation_Line_Item__c records by Id
     */
    public static void handleAfterUpdate(
        List<Order_Allocation_Line_Item__c> newList,
        Map<Id, Order_Allocation_Line_Item__c> oldMap
    ) {
        if (newList == null || oldMap == null) {
            return;
        }

        Set<Id> eligibleOaliIds = new Set<Id>();
        Set<Id> oaliIdsToProcess = new Set<Id>();
        Set<Id> parentOaIdsToProcess = new Set<Id>();

        for (Order_Allocation_Line_Item__c newOali : newList) {
            Order_Allocation_Line_Item__c oldOali = oldMap.get(newOali.Id);

            if (oldOali != null) {
                // Collect OALIs transitioning to 'Ready to Ship', in 'Ready to Ship' status, or with updated fulfillment quantities (Reserved) for Inventory Transfer Creation
                Boolean isReadyToShipTransition = (newOali.Status__c == 'Ready to Ship' &&
                                                   oldOali.Status__c != 'Ready to Ship' &&
                                                   !processedOaliIds.contains(newOali.Id));
                Boolean isFulfillmentQtyUpdated = (newOali.Reserved_Quantity__c != oldOali.Reserved_Quantity__c);
                Boolean isReadyToShipEligible = (newOali.Status__c == 'Ready to Ship' && 
                                                 newOali.Reserved_Quantity__c > 0 &&
                                                 !processedOaliIds.contains(newOali.Id));

                if (isReadyToShipTransition || isReadyToShipEligible) {
                    eligibleOaliIds.add(newOali.Id);
                    processedOaliIds.add(newOali.Id);
                } else if (isFulfillmentQtyUpdated) {
                    // Supports multiple partial transfers even if OALI Status__c is already 'Shipped'
                    eligibleOaliIds.add(newOali.Id);
                }

                // Collect for status recalculation if Status or relevant Qty changed and not already in status loop
                if (!isStatusProcessing && (
                    newOali.Status__c != oldOali.Status__c ||
                    newOali.Remaining_Qty__c != oldOali.Remaining_Qty__c ||
                    newOali.Transfer_Qty_Received__c != oldOali.Transfer_Qty_Received__c ||
                    newOali.Procurement_Qty_Received__c != oldOali.Procurement_Qty_Received__c ||
                    newOali.Reserved_Quantity__c != oldOali.Reserved_Quantity__c
                )) {
                    oaliIdsToProcess.add(newOali.Id);
                    if (newOali.Order_Allocation__c != null) {
                        parentOaIdsToProcess.add(newOali.Order_Allocation__c);
                    }
                }
            }
        }

        // 1. Create Inventory Transfers for eligible OALIs transitioning to 'Ready to Ship'
        if (!eligibleOaliIds.isEmpty()) {
            try {
                Type inventoryTransferServiceType = Type.forName('InventoryTransferService');
                if (inventoryTransferServiceType != null) {
                    InventoryTransferService.createInventoryTransfersForOALIs(eligibleOaliIds);
                }
            } catch (Exception ex) {
                System.debug(LoggingLevel.WARN, 'InventoryTransferService error: ' + ex.getMessage());
            }
        }

        // 2. Process status evaluation & rollup via OrderAllocationStatusService (guarded against recursion)
        if ((!oaliIdsToProcess.isEmpty() || !parentOaIdsToProcess.isEmpty()) && !isStatusProcessing) {
            isStatusProcessing = true;
            try {
                OrderAllocationStatusService.processStatus(oaliIdsToProcess, parentOaIdsToProcess);
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR, '*** OrderAllocationStatusService error in trigger: ' + ex.getMessage());
            } finally {
                isStatusProcessing = false;
            }
        }
    }
}