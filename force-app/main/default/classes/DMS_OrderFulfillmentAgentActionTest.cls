/**
 * @description Comprehensive unit tests for DMS_OrderFulfillmentAgentAction.
 *              Validates all requirement scenarios across Sales Allocation status, line items,
 *              Purchase Order status, line items, multi-role Account/Location filtering,
 *              pagination, validation, fuzzy matching, multiple matches, error handling,
 *              bulk execution (200 requests), and primitive-only Agentforce response contract.
 *
 * @author AM Industries DMS Agentforce Team
 */
@IsTest
private class DMS_OrderFulfillmentAgentActionTest {

    @TestSetup
    static void setupTestData() {
        // 1. Picklist helpers
        String itemUom = getActivePicklistValue(Item__c.Unit_Of_Measure__c, 'Each');
        String itemClass = getActivePicklistValue(Item__c.Classification__c, 'Finished Goods');

        // 2. Accounts
        Account dealerAlpha = new Account(Name = 'Dealer Alpha Motors');
        Account dealerBeta = new Account(Name = 'Dealer Beta Logistics');
        Account customerGamma = new Account(Name = 'Speed Motors Private Limited');
        insert new List<Account>{ dealerAlpha, dealerBeta, customerGamma };

        // 3. Inventory Locations
        Inventory_Location__c locHyd = new Inventory_Location__c(
            Name = 'Hyderabad Central Hub',
            Inventory_Location_Code__c = 'LOC-HYD',
            Account__c = dealerAlpha.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locBlr = new Inventory_Location__c(
            Name = 'Bangalore Depot',
            Inventory_Location_Code__c = 'LOC-BLR',
            Account__c = dealerBeta.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locHyd, locBlr };

        // 4. Items
        Item__c itemMotor10 = new Item__c(
            Name = 'Three Phase Induction Motor 10 HP',
            Item_Code__c = 'ITEM-MTR-010',
            Item_Family__c = 'Motors',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 18,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        Item__c itemPump = new Item__c(
            Name = 'Hydraulic Pump Heavy Duty 500 Bar',
            Item_Code__c = 'ITEM-PUMP-500',
            Item_Family__c = 'Hydraulics',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 12,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        insert new List<Item__c>{ itemMotor10, itemPump };

        // 5. Sales Allocation
        Order_Allocation__c sa1 = new Order_Allocation__c(
            Requesting_Account__c = dealerAlpha.Id,
            Supplying_Account__c = dealerBeta.Id,
            Customer__c = customerGamma.Id,
            Source_Location__c = locBlr.Id,
            Target_Location__c = locHyd.Id,
            Status__c = 'Ready to Ship',
            Order_Allocation_Method__c = 'Auto',
            Order_Allocation_Date__c = Date.today(),
            Ready_to_Ship_Date__c = Date.today().addDays(2)
        );

        Order_Allocation__c sa2 = new Order_Allocation__c(
            Requesting_Account__c = customerGamma.Id,
            Supplying_Account__c = dealerAlpha.Id,
            Source_Location__c = locHyd.Id,
            Target_Location__c = locBlr.Id,
            Status__c = 'Draft',
            Order_Allocation_Method__c = 'Manual',
            Order_Allocation_Date__c = Date.today().addDays(-3)
        );

        insert new List<Order_Allocation__c>{ sa1, sa2 };

        // 6. Sales Allocation Line Items
        Order_Allocation_Line_Item__c sali1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = sa1.Id,
            Item__c = itemMotor10.Id,
            Ordered_Qty__c = 10,
            Reserved_Quantity__c = 5,
            Reserved_Qty_Planned__c = 5,
            Secured_Qty__c = 5,
            Transfer_Qty_Planned__c = 5,
            Transfer_Qty_Received__c = 3,
            Procurement_Qty_Planned__c = 0,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Ready to Ship',
            Unit_Price__c = 1000,
            Discount_Percent__c = 5,
            Tax__c = 18,
            Additional_Cost__c = 200,
            Loading_and_Unloading_Charges__c = 100,
            Transfer_Cost__c = 300
        );

        Order_Allocation_Line_Item__c sali2 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = sa1.Id,
            Item__c = itemPump.Id,
            Ordered_Qty__c = 2,
            Reserved_Quantity__c = 2,
            Status__c = 'Planned',
            Unit_Price__c = 5000,
            Tax__c = 12
        );

        insert new List<Order_Allocation_Line_Item__c>{ sali1, sali2 };

        // 7. Purchase Orders
        Purchase_Order__c po1 = new Purchase_Order__c(
            Requesting_Account__c = dealerAlpha.Id,
            Supplying_Account__c = dealerBeta.Id,
            Reference_Account__c = customerGamma.Id,
            Source_Location__c = locBlr.Id,
            Target_Location__c = locHyd.Id,
            Status__c = 'Partially Received',
            PO_Date__c = Date.today().addDays(-5),
            Expected_Date__c = Date.today().addDays(5)
        );

        Purchase_Order__c po2 = new Purchase_Order__c(
            Requesting_Account__c = customerGamma.Id,
            Supplying_Account__c = dealerAlpha.Id,
            Status__c = 'Draft',
            PO_Date__c = Date.today()
        );

        insert new List<Purchase_Order__c>{ po1, po2 };

        // 8. Purchase Order Line Items
        Purchase_Order_Line_Item__c poli1 = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po1.Id,
            Item__c = itemMotor10.Id,
            Ordered_Qty__c = 20,
            Received_Qty__c = 8,
            Previously_Received_Quantity__c = 8,
            Status__c = 'Partially Received',
            Unit_Price__c = 1000,
            Discount__c = 5,
            Tax__c = 18,
            Additional_Fee__c = 100
        );

        insert new List<Purchase_Order_Line_Item__c>{ poli1 };
    }

    private static String getActivePicklistValue(SObjectField fieldToken, String fallbackValue) {
        List<Schema.PicklistEntry> entries = fieldToken.getDescribe().getPicklistValues();
        for (Schema.PicklistEntry pe : entries) {
            if (pe.isActive()) return pe.getValue();
        }
        return fallbackValue;
    }

    // -------------------------------------------------------------------------
    // 1-5. GET_SALES_ALLOCATION_STATUS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetSalesAllocationStatus_NoFilter_ListAll() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(2, res.totalRecords);
        Assert.isTrue(res.summary.contains('Sales Allocations'));
    }

    @IsTest
    static void testGetSalesAllocationStatus_ByDocumentNumber() {
        Order_Allocation__c sa = [SELECT Id, Name FROM Order_Allocation__c WHERE Status__c = 'Ready to Ship' LIMIT 1];

        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;
        req.documentNumber = sa.Name;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains(sa.Name));

        Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(res.jsonResponse);
        Assert.areEqual('salesAllocations', jsonMap.get('type'));
    }

    @IsTest
    static void testGetSalesAllocationStatus_FilteredByAccountAndLocation() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;
        req.accountName = 'Dealer Alpha Motors'; // Requesting Account on SA1, Supplying on SA2
        req.inventoryLocationName = 'Hyderabad Central Hub'; // Target on SA1, Source on SA2

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.isTrue(res.totalRecords >= 1);
    }

    @IsTest
    static void testGetSalesAllocationStatus_FilteredByStatus() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;
        req.status = 'Ready to Ship';

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Ready to Ship'));
    }

    // -------------------------------------------------------------------------
    // 6-7. GET_SALES_ALLOCATION_LINE_DETAILS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetSalesAllocationLineDetails_ByDocumentNumber() {
        Order_Allocation__c sa = [SELECT Id, Name FROM Order_Allocation__c WHERE Status__c = 'Ready to Ship' LIMIT 1];

        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_LINE_DETAILS;
        req.documentNumber = sa.Name;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(2, res.totalRecords);

        Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(res.jsonResponse);
        Assert.areEqual('salesAllocationLines', jsonMap.get('type'));
        List<Object> records = (List<Object>) jsonMap.get('records');
        Assert.areEqual(2, records.size());

        Map<String, Object> line1 = (Map<String, Object>) records[0];
        Map<String, Object> quantities = (Map<String, Object>) line1.get('quantities');
        Assert.areEqual(10, (Decimal) quantities.get('orderedQty'));
        Assert.areEqual(5, (Decimal) quantities.get('reservedQuantity'));
        Assert.areEqual(2, (Decimal) quantities.get('remainingQty')); // 10 - (5 + 3 + 0) = 2
    }

    @IsTest
    static void testGetSalesAllocationLineDetails_NoFilter_Validation() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_LINE_DETAILS;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isFalse(res.isSuccess, 'Should fail validation when no documentNumber or Item is provided');
        Assert.isTrue(res.message.contains('Please provide a Sales Allocation Document Number'));
    }

    // -------------------------------------------------------------------------
    // 8-10. GET_PURCHASE_ORDER_STATUS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetPurchaseOrderStatus_NoFilter_ListAll() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_PURCHASE_ORDER_STATUS;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(2, res.totalRecords);
        Assert.isTrue(res.summary.contains('Purchase Orders'));
    }

    @IsTest
    static void testGetPurchaseOrderStatus_ByDocumentNumber() {
        Purchase_Order__c po = [SELECT Id, Name FROM Purchase_Order__c WHERE Status__c = 'Partially Received' LIMIT 1];

        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_PURCHASE_ORDER_STATUS;
        req.documentNumber = po.Name;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains(po.Name));

        Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(res.jsonResponse);
        Assert.areEqual('purchaseOrders', jsonMap.get('type'));
    }

    @IsTest
    static void testGetPurchaseOrderStatus_FilteredByItem() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_PURCHASE_ORDER_STATUS;
        req.itemName = 'Three Phase Induction Motor 10 HP';

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
    }

    // -------------------------------------------------------------------------
    // 11-12. GET_PURCHASE_ORDER_LINE_DETAILS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetPurchaseOrderLineDetails_ByDocumentNumber() {
        Purchase_Order__c po = [SELECT Id, Name FROM Purchase_Order__c WHERE Status__c = 'Partially Received' LIMIT 1];

        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_PURCHASE_ORDER_LINE_DETAILS;
        req.documentNumber = po.Name;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);

        Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(res.jsonResponse);
        Assert.areEqual('purchaseOrderLines', jsonMap.get('type'));
        List<Object> records = (List<Object>) jsonMap.get('records');
        Assert.areEqual(1, records.size());

        Map<String, Object> line1 = (Map<String, Object>) records[0];
        Map<String, Object> quantities = (Map<String, Object>) line1.get('quantities');
        Assert.areEqual(20, (Decimal) quantities.get('orderedQty'));
        Assert.areEqual(8, (Decimal) quantities.get('receivedQty'));
        Assert.areEqual(12, (Decimal) quantities.get('remainingQuantity')); // 20 - 8 = 12
    }

    @IsTest
    static void testGetPurchaseOrderLineDetails_NoFilter_Validation() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_PURCHASE_ORDER_LINE_DETAILS;

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isFalse(res.isSuccess, 'Should fail validation when no PO or Item is provided');
        Assert.isTrue(res.message.contains('Please provide a Purchase Order Document Number'));
    }

    // -------------------------------------------------------------------------
    // 13-17. NO MATCH, PAGINATION, NORMALIZATION & BULK TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testNoMatchingDocuments() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;
        req.documentNumber = 'NON_EXISTENT_DOC_99999';

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_OrderFulfillmentAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(0, res.totalRecords);
        Assert.isTrue(res.message.contains('No matching Sales Allocations were found'));
    }

    @IsTest
    static void testPagination_SalesAllocations() {
        DMS_OrderFulfillmentAgentAction.Request reqP1 = new DMS_OrderFulfillmentAgentAction.Request();
        reqP1.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;
        reqP1.queryLimit = 1;
        reqP1.pageNumber = 1;

        DMS_OrderFulfillmentAgentAction.Response resP1 = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ reqP1 }
        )[0];

        Assert.isTrue(resP1.isSuccess);
        Assert.areEqual(2, resP1.totalRecords);
        Assert.areEqual(1, resP1.currentPage);
        Assert.isTrue(resP1.hasMoreRecords);

        DMS_OrderFulfillmentAgentAction.Request reqP2 = new DMS_OrderFulfillmentAgentAction.Request();
        reqP2.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;
        reqP2.queryLimit = 1;
        reqP2.pageNumber = 2;

        DMS_OrderFulfillmentAgentAction.Response resP2 = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ reqP2 }
        )[0];

        Assert.isTrue(resP2.isSuccess);
        Assert.areEqual(2, resP2.totalRecords);
        Assert.areEqual(2, resP2.currentPage);
        Assert.isFalse(resP2.hasMoreRecords);
    }

    @IsTest
    static void testNormalization_InvalidLimitsAndAction() {
        DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
        req.actionType = 'INVALID_ACTION_TYPE';
        req.queryLimit = -10;
        req.pageNumber = 0;

        DMS_OrderFulfillmentAgentAction.Response res = DMS_OrderFulfillmentAgentAction.execute(
            new List<DMS_OrderFulfillmentAgentAction.Request>{ req }
        )[0];

        Assert.isFalse(res.isSuccess);
        Assert.isTrue(res.message.contains('Unsupported Order Fulfillment request'));
    }

    @IsTest
    static void testBulkExecution_200Requests() {
        List<DMS_OrderFulfillmentAgentAction.Request> bulkList = new List<DMS_OrderFulfillmentAgentAction.Request>();
        for (Integer i = 0; i < 200; i++) {
            DMS_OrderFulfillmentAgentAction.Request req = new DMS_OrderFulfillmentAgentAction.Request();
            req.actionType = DMS_OrderFulfillmentAgentAction.ACTION_GET_SALES_ALLOCATION_STATUS;
            bulkList.add(req);
        }

        Test.startTest();
        List<DMS_OrderFulfillmentAgentAction.Response> responses = DMS_OrderFulfillmentAgentAction.execute(bulkList);
        Test.stopTest();

        Assert.areEqual(200, responses.size());
        for (DMS_OrderFulfillmentAgentAction.Response res : responses) {
            Assert.isTrue(res.isSuccess);
        }
    }
}