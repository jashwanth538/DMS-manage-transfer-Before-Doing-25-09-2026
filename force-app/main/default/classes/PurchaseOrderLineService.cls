/**
 * @description Service class handling business logic for Purchase Order Line Items
 *              and automatic parent Purchase Order status evaluation.
 *              Includes Invocable Apex method for Record-Triggered Flows.
 */
public with sharing class PurchaseOrderLineService {

    // POLI Status Constants
    public static final String POLI_STATUS_OPEN = 'Open';
    public static final String POLI_STATUS_PARTIALLY_RECEIVED = 'Partially Received';
    public static final String POLI_STATUS_FULLY_RECEIVED = 'Fully Received';
    public static final String POLI_STATUS_CLOSED = 'Closed';
    public static final String POLI_STATUS_CANCELLED = 'Cancelled';

    // PO Status Constants
    public static final String PO_STATUS_DRAFT = 'Draft';
    public static final String PO_STATUS_PARTIALLY_RECEIVED = 'Partially Received';
    public static final String PO_STATUS_FULLY_RECEIVED = 'Fully Received';
    public static final String PO_STATUS_RECEIVED = 'Received';
    public static final String PO_STATUS_CLOSED = 'Closed';
    public static final String PO_STATUS_CANCELLED = 'Cancelled';

    /**
     * @description Request wrapper for Invocable Method inputs from Flow Builder.
     */
    public class EvaluationRequest {
        @InvocableVariable(label='Purchase Order ID' description='ID of the parent Purchase Order to evaluate' required=false)
        public Id purchaseOrderId;

        @InvocableVariable(label='Purchase Order Line Item Record' description='The POLI record passed from Flow ($Record)' required=false)
        public Purchase_Order_Line_Item__c purchaseOrderLineItem;

        @InvocableVariable(label='Purchase Order Line Item ID' description='ID of the POLI record' required=false)
        public Id purchaseOrderLineItemId;
    }

    /**
     * @description Invocable Method called by Record-Triggered Flow to evaluate parent Purchase Order status.
     * @param requests List of EvaluationRequest inputs from Flow
     */
    @InvocableMethod(label='Evaluate Purchase Order Receipt Status' description='Evaluates and updates parent PO status based on POLI receipt status' category='Purchase Order')
    public static void evaluateReceiptStatus(List<EvaluationRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> poIds = new Set<Id>();
        Set<Id> poliIds = new Set<Id>();

        for (EvaluationRequest req : requests) {
            if (req == null) {
                continue;
            }
            if (req.purchaseOrderId != null) {
                poIds.add(req.purchaseOrderId);
            }
            if (req.purchaseOrderLineItem != null && req.purchaseOrderLineItem.Purchase_Order__c != null) {
                poIds.add(req.purchaseOrderLineItem.Purchase_Order__c);
            }
            if (req.purchaseOrderLineItemId != null) {
                poliIds.add(req.purchaseOrderLineItemId);
            }
        }

        if (!poliIds.isEmpty()) {
            for (Purchase_Order_Line_Item__c poli : [
                SELECT Id, Purchase_Order__c
                FROM Purchase_Order_Line_Item__c
                WHERE Id IN :poliIds
            ]) {
                if (poli.Purchase_Order__c != null) {
                    poIds.add(poli.Purchase_Order__c);
                }
            }
        }

        if (!poIds.isEmpty()) {
            evaluatePurchaseOrders(poIds);
        }
    }

    /**
     * @description Evaluates and updates parent Purchase Orders for a given list of POLI records.
     * @param lines List of Purchase_Order_Line_Item__c records
     */
    public static void evaluatePurchaseOrdersFromLines(List<Purchase_Order_Line_Item__c> lines) {
        if (lines == null || lines.isEmpty()) {
            return;
        }

        Set<Id> poIds = new Set<Id>();
        for (Purchase_Order_Line_Item__c line : lines) {
            if (line != null && line.Purchase_Order__c != null) {
                poIds.add(line.Purchase_Order__c);
            }
        }

        evaluatePurchaseOrders(poIds);
    }

    /**
     * @description Evaluates and updates parent Purchase Orders given a set of PO IDs.
     * @param poIds Set of Purchase_Order__c record IDs
     */
    public static void evaluatePurchaseOrders(Set<Id> poIds) {
        if (poIds == null || poIds.isEmpty()) {
            return;
        }

        // Remove any null IDs
        poIds.remove(null);
        if (poIds.isEmpty()) {
            return;
        }

        // Query all parent POs and all their child POLIs in a single bulkified query
        List<Purchase_Order__c> parentOrders = [
            SELECT Id, Status__c,
                   (SELECT Id, Status__c FROM Purchase_Order_Line_Item__r)
            FROM Purchase_Order__c
            WHERE Id IN :poIds
        ];

        List<Purchase_Order__c> poToUpdate = new List<Purchase_Order__c>();

        for (Purchase_Order__c po : parentOrders) {
            String currentStatus = po.Status__c;

            // Preserve terminal/unrelated statuses (e.g. Closed, Cancelled)
            if (currentStatus == PO_STATUS_CLOSED || currentStatus == PO_STATUS_CANCELLED) {
                continue;
            }

            List<Purchase_Order_Line_Item__c> poliList = po.Purchase_Order_Line_Item__r;
            Integer totalLines = (poliList != null) ? poliList.size() : 0;

            String targetStatus;

            if (totalLines == 0) {
                // Rule: A PO with zero POLIs should NEVER be marked Fully Received or Partially Received
                if (currentStatus == PO_STATUS_FULLY_RECEIVED ||
                    currentStatus == PO_STATUS_RECEIVED ||
                    currentStatus == PO_STATUS_PARTIALLY_RECEIVED) {
                    targetStatus = PO_STATUS_DRAFT;
                } else {
                    targetStatus = currentStatus;
                }
            } else {
                Integer fullyReceivedCount = 0;
                Integer partiallyReceivedCount = 0;

                for (Purchase_Order_Line_Item__c poli : poliList) {
                    if (POLI_STATUS_FULLY_RECEIVED.equalsIgnoreCase(poli.Status__c)) {
                        fullyReceivedCount++;
                    } else if (POLI_STATUS_PARTIALLY_RECEIVED.equalsIgnoreCase(poli.Status__c)) {
                        partiallyReceivedCount++;
                    }
                }

                if (fullyReceivedCount == totalLines) {
                    // All POLIs are Fully Received
                    targetStatus = PO_STATUS_FULLY_RECEIVED;
                } else if (fullyReceivedCount > 0 || partiallyReceivedCount > 0) {
                    // At least one POLI is received (partial or fully), but not all lines are fully received
                    targetStatus = PO_STATUS_PARTIALLY_RECEIVED;
                } else {
                    // No lines are received (all Open/others)
                    // If PO was previously marked Fully Received or Partially Received, revert to Draft
                    if (currentStatus == PO_STATUS_FULLY_RECEIVED ||
                        currentStatus == PO_STATUS_RECEIVED ||
                        currentStatus == PO_STATUS_PARTIALLY_RECEIVED) {
                        targetStatus = PO_STATUS_DRAFT;
                    } else {
                        targetStatus = currentStatus;
                    }
                }
            }

            // Only update if status actually changed
            if (targetStatus != null && !targetStatus.equalsIgnoreCase(currentStatus)) {
                poToUpdate.add(new Purchase_Order__c(
                    Id = po.Id,
                    Status__c = targetStatus
                ));
            }
        }

        if (!poToUpdate.isEmpty()) {
            update poToUpdate;
        }
    }
}