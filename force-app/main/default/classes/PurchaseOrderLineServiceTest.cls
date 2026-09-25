/**
 * @description Comprehensive unit tests for PurchaseOrderLineService.
 *              Validates all status synchronization scenarios between POLI and parent PO.
 */
@IsTest
private class PurchaseOrderLineServiceTest {

    /**
     * Helper to create a Purchase Order
     */
    private static Purchase_Order__c createPurchaseOrder(String initialStatus) {
        Purchase_Order__c po = new Purchase_Order__c(
            Status__c = initialStatus
        );
        insert po;
        return po;
    }

    /**
     * Helper to create a POLI record
     */
    private static Purchase_Order_Line_Item__c createPOLI(Id poId, String status) {
        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = poId,
            Status__c = status,
            Ordered_Qty__c = 10,
            Received_Qty__c = (status == 'Fully Received' ? 10 : (status == 'Partially Received' ? 5 : 0))
        );
        return poli;
    }

    /**
     * Test Case 1: PO with 1 POLI → Fully Received → PO becomes Fully Received.
     */
    @IsTest
    static void testSinglePOLIFullyReceived() {
        Purchase_Order__c po = createPurchaseOrder('Draft');
        Purchase_Order_Line_Item__c poli = createPOLI(po.Id, 'Fully Received');
        insert poli;

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Test.stopTest();

        Purchase_Order__c updatedPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Fully Received', updatedPO.Status__c, 'PO status should be Fully Received when the single POLI is Fully Received');
    }

    /**
     * Test Case 2: PO with 2 POLIs → only 1 Fully Received → PO does NOT become Fully Received.
     */
    @IsTest
    static void testTwoPOLIsOnlyOneFullyReceived() {
        Purchase_Order__c po = createPurchaseOrder('Draft');
        List<Purchase_Order_Line_Item__c> lines = new List<Purchase_Order_Line_Item__c>{
            createPOLI(po.Id, 'Fully Received'),
            createPOLI(po.Id, 'Open')
        };
        insert lines;

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Test.stopTest();

        Purchase_Order__c updatedPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertNotEquals('Fully Received', updatedPO.Status__c, 'PO status must NOT be Fully Received if only 1 of 2 POLIs is Fully Received');
        System.assertEquals('Partially Received', updatedPO.Status__c, 'PO status should be Partially Received');
    }

    /**
     * Test Case 3: PO with 2 POLIs → both Fully Received → PO becomes Fully Received.
     */
    @IsTest
    static void testTwoPOLIsBothFullyReceived() {
        Purchase_Order__c po = createPurchaseOrder('Draft');
        List<Purchase_Order_Line_Item__c> lines = new List<Purchase_Order_Line_Item__c>{
            createPOLI(po.Id, 'Fully Received'),
            createPOLI(po.Id, 'Fully Received')
        };
        insert lines;

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Test.stopTest();

        Purchase_Order__c updatedPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Fully Received', updatedPO.Status__c, 'PO status should be Fully Received when all POLIs are Fully Received');
    }

    /**
     * Test Case 4: PO with multiple POLIs → last remaining POLI becomes Fully Received → PO becomes Fully Received.
     */
    @IsTest
    static void testMultiplePOLIsLastOneBecomesFullyReceived() {
        Purchase_Order__c po = createPurchaseOrder('Partially Received');
        List<Purchase_Order_Line_Item__c> lines = new List<Purchase_Order_Line_Item__c>{
            createPOLI(po.Id, 'Fully Received'),
            createPOLI(po.Id, 'Fully Received'),
            createPOLI(po.Id, 'Partially Received'),
            createPOLI(po.Id, 'Open')
        };
        insert lines;

        // Step 1: Intermediate evaluation
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Purchase_Order__c intermediatePO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Partially Received', intermediatePO.Status__c);

        // Step 2: Update remaining POLIs to Fully Received
        lines[2].Status__c = 'Fully Received';
        lines[3].Status__c = 'Fully Received';
        update new List<Purchase_Order_Line_Item__c>{ lines[2], lines[3] };

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrdersFromLines(new List<Purchase_Order_Line_Item__c>{ lines[3] });
        Test.stopTest();

        Purchase_Order__c finalPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Fully Received', finalPO.Status__c, 'PO status should become Fully Received when all POLIs are now Fully Received');
    }

    /**
     * Test Case 5: PO currently Fully Received → one POLI becomes Partially Received / Open
     *              → PO is re-evaluated and no longer remains incorrectly Fully Received.
     */
    @IsTest
    static void testDowngradePOLIStatusReevaluatesPO() {
        Purchase_Order__c po = createPurchaseOrder('Fully Received');
        List<Purchase_Order_Line_Item__c> lines = new List<Purchase_Order_Line_Item__c>{
            createPOLI(po.Id, 'Fully Received'),
            createPOLI(po.Id, 'Fully Received')
        };
        insert lines;

        // Downgrade one POLI to Partially Received
        lines[0].Status__c = 'Partially Received';
        update lines[0];

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Test.stopTest();

        Purchase_Order__c updatedPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertNotEquals('Fully Received', updatedPO.Status__c, 'PO must not remain Fully Received');
        System.assertEquals('Partially Received', updatedPO.Status__c, 'PO should revert to Partially Received');

        // Downgrade both POLIs to Open
        lines[0].Status__c = 'Open';
        lines[1].Status__c = 'Open';
        update lines;

        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Purchase_Order__c draftPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Draft', draftPO.Status__c, 'PO should revert to Draft when all lines are Open');
    }

    /**
     * Test Case 6: Multiple POs and POLIs updated in the same transaction (Bulkified test).
     */
    @IsTest
    static void testBulkEvaluationMultiplePOsAndPOLIs() {
        List<Purchase_Order__c> poList = new List<Purchase_Order__c>();
        for (Integer i = 0; i < 20; i++) {
            poList.add(new Purchase_Order__c(Status__c = 'Draft'));
        }
        insert poList;

        List<Purchase_Order_Line_Item__c> linesToInsert = new List<Purchase_Order_Line_Item__c>();
        Set<Id> allPoIds = new Set<Id>();

        for (Integer i = 0; i < 20; i++) {
            Id currentPoId = poList[i].Id;
            allPoIds.add(currentPoId);

            if (Math.mod(i, 2) == 0) {
                // Even indices: All 3 POLIs are Fully Received
                linesToInsert.add(createPOLI(currentPoId, 'Fully Received'));
                linesToInsert.add(createPOLI(currentPoId, 'Fully Received'));
                linesToInsert.add(createPOLI(currentPoId, 'Fully Received'));
            } else {
                // Odd indices: 2 Fully Received, 1 Open
                linesToInsert.add(createPOLI(currentPoId, 'Fully Received'));
                linesToInsert.add(createPOLI(currentPoId, 'Fully Received'));
                linesToInsert.add(createPOLI(currentPoId, 'Open'));
            }
        }
        insert linesToInsert;

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrders(allPoIds);
        Test.stopTest();

        Map<Id, Purchase_Order__c> resultMap = new Map<Id, Purchase_Order__c>(
            [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id IN :allPoIds]
        );

        for (Integer i = 0; i < 20; i++) {
            Id currentPoId = poList[i].Id;
            Purchase_Order__c evaluatedPO = resultMap.get(currentPoId);
            if (Math.mod(i, 2) == 0) {
                System.assertEquals('Fully Received', evaluatedPO.Status__c, 'Even index PO should be Fully Received');
            } else {
                System.assertEquals('Partially Received', evaluatedPO.Status__c, 'Odd index PO should be Partially Received');
            }
        }
    }

    /**
     * Test Case 7: PO with no POLIs → never mark as Fully Received.
     */
    @IsTest
    static void testPOWithNoPOLIsNeverFullyReceived() {
        Purchase_Order__c po = createPurchaseOrder('Draft');

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Test.stopTest();

        Purchase_Order__c updatedPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Draft', updatedPO.Status__c, 'PO with 0 POLIs must remain Draft and never be marked Fully Received');

        // Even if someone erroneously set status to Fully Received on an empty PO, service reverts it to Draft
        po.Status__c = 'Fully Received';
        update po;

        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ po.Id });
        Purchase_Order__c correctedPO = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po.Id];
        System.assertEquals('Draft', correctedPO.Status__c, 'Empty PO incorrectly marked Fully Received should be reverted to Draft');
    }

    /**
     * Test Case 8: Invocable Apex Action test (PurchaseOrderLineService.evaluateReceiptStatus).
     */
    @IsTest
    static void testInvocableEvaluatorExecution() {
        Purchase_Order__c po1 = createPurchaseOrder('Draft');
        Purchase_Order__c po2 = createPurchaseOrder('Draft');

        Purchase_Order_Line_Item__c poli1 = createPOLI(po1.Id, 'Fully Received');
        Purchase_Order_Line_Item__c poli2 = createPOLI(po2.Id, 'Fully Received');
        insert new List<Purchase_Order_Line_Item__c>{ poli1, poli2 };

        List<PurchaseOrderLineService.EvaluationRequest> requests = new List<PurchaseOrderLineService.EvaluationRequest>();

        // Request 1: using purchaseOrderId
        PurchaseOrderLineService.EvaluationRequest req1 = new PurchaseOrderLineService.EvaluationRequest();
        req1.purchaseOrderId = po1.Id;
        requests.add(req1);

        // Request 2: using purchaseOrderLineItem record
        PurchaseOrderLineService.EvaluationRequest req2 = new PurchaseOrderLineService.EvaluationRequest();
        req2.purchaseOrderLineItem = poli2;
        requests.add(req2);

        // Request 3: using purchaseOrderLineItemId
        PurchaseOrderLineService.EvaluationRequest req3 = new PurchaseOrderLineService.EvaluationRequest();
        req3.purchaseOrderLineItemId = poli1.Id;
        requests.add(req3);

        Test.startTest();
        PurchaseOrderLineService.evaluateReceiptStatus(requests);
        Test.stopTest();

        Purchase_Order__c res1 = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po1.Id];
        Purchase_Order__c res2 = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :po2.Id];

        System.assertEquals('Fully Received', res1.Status__c);
        System.assertEquals('Fully Received', res2.Status__c);
    }

    /**
     * Test Case 9: Preserve terminal statuses (Closed, Cancelled).
     */
    @IsTest
    static void testPreserveTerminalStatuses() {
        Purchase_Order__c closedPO = createPurchaseOrder('Closed');
        Purchase_Order__c cancelledPO = createPurchaseOrder('Cancelled');

        Purchase_Order_Line_Item__c poli1 = createPOLI(closedPO.Id, 'Fully Received');
        Purchase_Order_Line_Item__c poli2 = createPOLI(cancelledPO.Id, 'Fully Received');
        insert new List<Purchase_Order_Line_Item__c>{ poli1, poli2 };

        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>{ closedPO.Id, cancelledPO.Id });
        Test.stopTest();

        Purchase_Order__c resClosed = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :closedPO.Id];
        Purchase_Order__c resCancelled = [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id = :cancelledPO.Id];

        System.assertEquals('Closed', resClosed.Status__c, 'Closed status must be preserved');
        System.assertEquals('Cancelled', resCancelled.Status__c, 'Cancelled status must be preserved');
    }

    /**
     * Test Case 10: Null and empty collections handling.
     */
    @IsTest
    static void testNullAndEmptyInputs() {
        Test.startTest();
        PurchaseOrderLineService.evaluatePurchaseOrdersFromLines(null);
        PurchaseOrderLineService.evaluatePurchaseOrdersFromLines(new List<Purchase_Order_Line_Item__c>());
        PurchaseOrderLineService.evaluatePurchaseOrders(null);
        PurchaseOrderLineService.evaluatePurchaseOrders(new Set<Id>());
        PurchaseOrderLineService.evaluateReceiptStatus(null);
        PurchaseOrderLineService.evaluateReceiptStatus(new List<PurchaseOrderLineService.EvaluationRequest>());
        Test.stopTest();
        // Should complete smoothly without unhandled exceptions
        System.assert(true, 'Null and empty inputs handled gracefully');
    }
}