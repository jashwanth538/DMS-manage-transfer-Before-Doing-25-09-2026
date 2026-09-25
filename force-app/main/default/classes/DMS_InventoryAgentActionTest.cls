/**
 * @description Comprehensive unit tests for DMS_InventoryAgentAction.
 *              Validates all requirement scenarios across Stock retrieval, Low-Stock detection,
 *              Supply Requests, Inventory Reservations, Inventory Transfers, Inventory Locations,
 *              pagination, fuzzy matching, multiple matches, inactive filters, error handling,
 *              bulk execution (200 requests), and primitive-only Agentforce response contract.
 *
 * @author AM Industries DMS Agentforce Team
 */
@IsTest
private class DMS_InventoryAgentActionTest {

    @TestSetup
    static void setupTestData() {
        // 1. Picklist helpers
        String itemUom = getActivePicklistValue(Item__c.Unit_Of_Measure__c, 'Each');
        String itemClass = getActivePicklistValue(Item__c.Classification__c, 'Finished Goods');

        // 2. Accounts
        Account dealerAlpha = new Account(Name = 'Dealer Alpha Motors');
        Account dealerBeta = new Account(Name = 'Dealer Beta Logistics');
        Account speedMotors = new Account(Name = 'Speed Motors Private Limited');
        insert new List<Account>{ dealerAlpha, dealerBeta, speedMotors };

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
        Inventory_Location__c locInactive = new Inventory_Location__c(
            Name = 'Chennai Old Yard',
            Inventory_Location_Code__c = 'LOC-CHN-OLD',
            Account__c = speedMotors.Id,
            Is_Active__c = false
        );
        insert new List<Inventory_Location__c>{ locHyd, locBlr, locInactive };

        // 4. Items
        Item__c itemMotor10 = new Item__c(
            Name = 'Three Phase Induction Motor 10 HP',
            Item_Code__c = 'ITEM-MTR-010',
            Item_Family__c = 'Motors',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 18,
            Default_Supply_Method__c = 'Manufacture',
            Delivery_Preparation_Time__c = 5,
            Reorder_Level__c = 10,
            Stock_Low_Level_Quantity__c = 15,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100,
            Target_Stock_Level__c = 80,
            Target_Days__c = 15,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        Item__c itemMotor15 = new Item__c(
            Name = 'Three Phase Induction Motor 15 HP',
            Item_Code__c = 'ITEM-MTR-015',
            Item_Family__c = 'Motors',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 18,
            Default_Supply_Method__c = 'Manufacture',
            Delivery_Preparation_Time__c = 7,
            Reorder_Level__c = 5,
            Stock_Low_Level_Quantity__c = 8,
            Target_Stock_Level__c = 40,
            Target_Days__c = 20,
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
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 3,
            Reorder_Level__c = 20,
            Stock_Low_Level_Quantity__c = 25,
            Target_Stock_Level__c = 100,
            Target_Days__c = 30,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        Item__c itemInactive = new Item__c(
            Name = 'Legacy Transmission Filter',
            Item_Code__c = 'ITEM-FLT-LEGACY',
            Item_Family__c = 'Filters',
            Active__c = false,
            Is_Sellable__c = false,
            Is_Inventory_Item__c = true,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        insert new List<Item__c>{ itemMotor10, itemMotor15, itemPump, itemInactive };

        // 5. Inventory Stock Records
        Inventory__c invMotorHyd = new Inventory__c(
            Item__c = itemMotor10.Id,
            Inventory_Location__c = locHyd.Id,
            Account__c = dealerAlpha.Id,
            Available__c = 8, // Low stock (<= 10 reorder)
            Damaged__c = 2,
            Reserved__c = 5,
            Reserved_Sale_Order__c = 3,
            Reserved_Transfer__c = 2,
            Transit_In_Quantity__c = 10,
            Transit_Out_Quantity__c = 0,
            Reorder_Level__c = 10,
            Stock_Low_Level_Quantity__c = 15,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100,
            Target_Stock_Level__c = 80
        );

        Inventory__c invMotorBlr = new Inventory__c(
            Item__c = itemMotor10.Id,
            Inventory_Location__c = locBlr.Id,
            Account__c = dealerBeta.Id,
            Available__c = 60, // Healthy stock
            Damaged__c = 0,
            Reserved__c = 10,
            Reserved_Sale_Order__c = 10,
            Reserved_Transfer__c = 0,
            Transit_In_Quantity__c = 0,
            Transit_Out_Quantity__c = 5,
            Reorder_Level__c = 10,
            Stock_Low_Level_Quantity__c = 15,
            Target_Stock_Level__c = 80
        );

        Inventory__c invPumpHyd = new Inventory__c(
            Item__c = itemPump.Id,
            Inventory_Location__c = locHyd.Id,
            Account__c = dealerAlpha.Id,
            Available__c = 15, // Low stock (<= 20 reorder)
            Damaged__c = 1,
            Reserved__c = 4,
            Reorder_Level__c = 20,
            Stock_Low_Level_Quantity__c = 25,
            Target_Stock_Level__c = 100
        );

        insert new List<Inventory__c>{ invMotorHyd, invMotorBlr, invPumpHyd };

        // 6. Supply Requests
        Supply_Request__c sr1 = new Supply_Request__c(
            Item__c = itemMotor10.Id,
            Source_Location__c = locBlr.Id,
            Target_Location__c = locHyd.Id,
            Requesting_Account__c = dealerAlpha.Id,
            Supplying_Account__c = dealerBeta.Id,
            Request_Type__c = 'Stock Replenishment',
            Supply_Method__c = 'Manufacture',
            Status__c = 'Open',
            Requested_Qty__c = 20,
            Received_Qty__c = 0,
            Required_Date__c = Date.today().addDays(7),
            Automated_Supply_Request__c = true
        );

        Supply_Request__c srClosed = new Supply_Request__c(
            Item__c = itemPump.Id,
            Source_Location__c = locHyd.Id,
            Target_Location__c = locBlr.Id,
            Requesting_Account__c = dealerBeta.Id,
            Supplying_Account__c = dealerAlpha.Id,
            Request_Type__c = 'Customer Demand',
            Supply_Method__c = 'Purchase',
            Status__c = 'Completed',
            Requested_Qty__c = 10,
            Received_Qty__c = 10,
            Required_Date__c = Date.today().addDays(-2),
            Automated_Supply_Request__c = false
        );

        insert new List<Supply_Request__c>{ sr1, srClosed };

        // 7. Inventory Reservations
        Inventory_Reservation__c res1 = new Inventory_Reservation__c(
            Item__c = itemMotor10.Id,
            Inventory_Location__c = locHyd.Id,
            Requesting_Account__c = dealerAlpha.Id,
            Supplying_Account__c = dealerAlpha.Id,
            Request_Type__c = 'Stock Replenishment',
            Status__c = 'Partially Reserved',
            Requested_Qty__c = 10,
            Reserved_Qty__c = 5,
            Reservation_Date__c = Date.today(),
            Expiry_Date__c = Date.today().addDays(14)
        );

        Inventory_Reservation__c resClosed = new Inventory_Reservation__c(
            Item__c = itemPump.Id,
            Inventory_Location__c = locBlr.Id,
            Requesting_Account__c = speedMotors.Id,
            Request_Type__c = 'Stock Replenishment',
            Status__c = 'Consumed',
            Requested_Qty__c = 5,
            Reserved_Qty__c = 5,
            Reservation_Date__c = Date.today().addDays(-10)
        );

        insert new List<Inventory_Reservation__c>{ res1, resClosed };

        // 8. Inventory Transfers
        Inventory_Transfer__c tr1 = new Inventory_Transfer__c(
            Item__c = itemMotor10.Id,
            Source_Inventory_Location__c = locBlr.Id,
            Destination_Inventory_Location__c = locHyd.Id,
            From_Account__c = dealerBeta.Id,
            To_Account__c = dealerAlpha.Id,
            Account__c = dealerBeta.Id,
            Request_Type__c = 'Stock Replenishment',
            Status__c = 'In Transit',
            Transfer_Qty__c = 10,
            In_Transit_Qty__c = 10,
            Received_Qty__c = 0,
            Requested_Date__c = Date.today().addDays(-1),
            Required_Date__c = Date.today().addDays(3)
        );

        Inventory_Transfer__c trClosed = new Inventory_Transfer__c(
            Item__c = itemPump.Id,
            Source_Inventory_Location__c = locHyd.Id,
            Destination_Inventory_Location__c = locBlr.Id,
            From_Account__c = dealerAlpha.Id,
            To_Account__c = dealerBeta.Id,
            Account__c = dealerAlpha.Id,
            Request_Type__c = 'Stock Replenishment',
            Status__c = 'Received',
            Transfer_Qty__c = 5,
            In_Transit_Qty__c = 0,
            Received_Qty__c = 5,
            Requested_Date__c = Date.today().addDays(-5),
            Received_Date__c = Date.today()
        );

        insert new List<Inventory_Transfer__c>{ tr1, trClosed };
    }

    private static String getActivePicklistValue(SObjectField fieldToken, String fallbackValue) {
        List<Schema.PicklistEntry> entries = fieldToken.getDescribe().getPicklistValues();
        for (Schema.PicklistEntry pe : entries) {
            if (pe.isActive()) return pe.getValue();
        }
        return fallbackValue;
    }

    // -------------------------------------------------------------------------
    // 1-4. GET_STOCK TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetStock_ItemAndLocation() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
        req.itemName = 'Three Phase Induction Motor 10 HP';
        req.inventoryLocationName = 'Hyderabad Central Hub';

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.message.contains('Found 1 Inventory stock record'));
        Assert.isTrue(res.summary.contains('Hyderabad Central Hub'));

        Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(res.jsonResponse);
        Assert.areEqual('stock', jsonMap.get('type'));
        List<Object> records = (List<Object>) jsonMap.get('records');
        Assert.areEqual(1, records.size());

        Map<String, Object> rec = (Map<String, Object>) records[0];
        Map<String, Object> current = (Map<String, Object>) rec.get('current');
        Assert.areEqual(8, (Decimal) current.get('available'));
        Assert.areEqual(5, (Decimal) current.get('reserved'));
    }

    @IsTest
    static void testGetStock_ItemOnly_AllLocations() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
        req.itemName = 'Three Phase Induction Motor 10 HP';

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(2, res.totalRecords, 'Should return stock across both Hyd and Blr');
    }

    @IsTest
    static void testGetStock_ItemExists_NoStockAtLocation() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
        req.itemName = 'Hydraulic Pump Heavy Duty 500 Bar';
        req.inventoryLocationName = 'Bangalore Depot'; // Pump only exists in Hyd

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(0, res.totalRecords);
        Assert.isTrue(res.message.contains('no Inventory record exists'));
    }

    @IsTest
    static void testGetStock_ItemNotFound() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
        req.itemName = 'Completely NonExistent Motor SKU 999';

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(0, res.totalRecords);
        Assert.isTrue(res.message.contains('No matching Item was found'));
    }

    // -------------------------------------------------------------------------
    // 5-6. LIST_LOW_STOCK TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testListLowStock_NoFilter() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_LIST_LOW_STOCK;

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.isTrue(res.totalRecords >= 2, 'Motor10 in Hyd (8<=10) and Pump in Hyd (15<=20) are low stock');
        Assert.isTrue(res.summary.contains('Low Stock Alert'));
    }

    @IsTest
    static void testListLowStock_FilteredByLocation() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_LIST_LOW_STOCK;
        req.inventoryLocationName = 'Bangalore Depot'; // Blr has 60 available (> 10 reorder), so 0 low stock

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(0, res.totalRecords);
        Assert.isTrue(res.summary.contains('All checked items are currently above their reorder'));
    }

    // -------------------------------------------------------------------------
    // 7-9. SUPPLY REQUEST STATUS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetSupplyRequestStatus_DefaultOpen() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_SUPPLY_REQUEST_STATUS;

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords, 'Should return only open SRs by default');
    }

    @IsTest
    static void testGetSupplyRequestStatus_FilteredByItem() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_SUPPLY_REQUEST_STATUS;
        req.itemName = 'Three Phase Induction Motor 10 HP';

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
    }

    @IsTest
    static void testGetSupplyRequestStatus_FilteredByStatus() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_SUPPLY_REQUEST_STATUS;
        req.status = 'Completed';

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Completed'));
    }

    // -------------------------------------------------------------------------
    // 10-11. RESERVATION STATUS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetReservationStatus_DefaultOpen() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_RESERVATION_STATUS;

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords, 'Only open reservation (Partially Reserved) returned');
    }

    @IsTest
    static void testGetReservationStatus_ItemAndLocation() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_RESERVATION_STATUS;
        req.itemName = 'Three Phase Induction Motor 10 HP';
        req.inventoryLocationName = 'Hyderabad Central Hub';

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
    }

    // -------------------------------------------------------------------------
    // 12. TRANSFER STATUS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetTransferStatus_DefaultOpen() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_TRANSFER_STATUS;

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords, 'In Transit transfer returned; Received excluded by default');
    }

    // -------------------------------------------------------------------------
    // 13-15. LIST INVENTORY LOCATIONS TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testListInventoryLocations_ActiveDefault() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_LIST_INVENTORY_LOCATIONS;

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(2, res.totalRecords, 'Should return only 2 active locations by default');
    }

    @IsTest
    static void testListInventoryLocations_IncludeInactive() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_LIST_INVENTORY_LOCATIONS;
        req.includeInactive = true;

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(3, res.totalRecords, 'Should return all 3 locations when includeInactive=true');
    }

    @IsTest
    static void testListInventoryLocations_NameSearch() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_LIST_INVENTORY_LOCATIONS;
        req.inventoryLocationName = 'Hyderabad';

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Hyderabad Central Hub'));
    }

    // -------------------------------------------------------------------------
    // 16-17. AMBIGUOUS & NO MATCH RESOLUTION
    // -------------------------------------------------------------------------
    @IsTest
    static void testMultipleItemMatches_Ambiguity() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
        req.itemName = 'Three Phase Induction Motor'; // Matches 10 HP & 15 HP

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_InventoryAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.isTrue(res.totalRecords >= 2);
    }

    // -------------------------------------------------------------------------
    // 18-22. PAGINATION, NORMALIZATION & ERROR HANDLING
    // -------------------------------------------------------------------------
    @IsTest
    static void testPagination_Stock() {
        DMS_InventoryAgentAction.Request reqP1 = new DMS_InventoryAgentAction.Request();
        reqP1.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
        reqP1.queryLimit = 2;
        reqP1.pageNumber = 1;

        DMS_InventoryAgentAction.Response resP1 = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ reqP1 }
        )[0];

        Assert.isTrue(resP1.isSuccess);
        Assert.areEqual(3, resP1.totalRecords);
        Assert.areEqual(1, resP1.currentPage);
        Assert.isTrue(resP1.hasMoreRecords);

        DMS_InventoryAgentAction.Request reqP2 = new DMS_InventoryAgentAction.Request();
        reqP2.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
        reqP2.queryLimit = 2;
        reqP2.pageNumber = 2;

        DMS_InventoryAgentAction.Response resP2 = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ reqP2 }
        )[0];

        Assert.isTrue(resP2.isSuccess);
        Assert.areEqual(3, resP2.totalRecords);
        Assert.areEqual(2, resP2.currentPage);
        Assert.isFalse(resP2.hasMoreRecords);
    }

    @IsTest
    static void testNormalization_InvalidLimitsAndAction() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.actionType = 'INVALID_ACTION_TYPE';
        req.queryLimit = -10;
        req.pageNumber = 0;

        DMS_InventoryAgentAction.Response res = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        )[0];

        Assert.isFalse(res.isSuccess);
        Assert.isTrue(res.message.contains('Unsupported Inventory request'));
    }

    @IsTest
    static void testMissingActionType_Inference() {
        DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
        req.itemName = 'Hydraulic Pump Heavy Duty 500 Bar'; // Infers GET_STOCK

        DMS_InventoryAgentAction.Response res = DMS_InventoryAgentAction.execute(
            new List<DMS_InventoryAgentAction.Request>{ req }
        )[0];

        Assert.isTrue(res.isSuccess);
        Assert.areEqual(DMS_InventoryAgentAction.ACTION_GET_STOCK, res.actionExecuted);
    }

    @IsTest
    static void testBulkExecution_200Requests() {
        List<DMS_InventoryAgentAction.Request> bulkList = new List<DMS_InventoryAgentAction.Request>();
        for (Integer i = 0; i < 200; i++) {
            DMS_InventoryAgentAction.Request req = new DMS_InventoryAgentAction.Request();
            req.actionType = DMS_InventoryAgentAction.ACTION_GET_STOCK;
            req.itemName = 'Three Phase Induction Motor 10 HP';
            bulkList.add(req);
        }

        Test.startTest();
        List<DMS_InventoryAgentAction.Response> responses = DMS_InventoryAgentAction.execute(bulkList);
        Test.stopTest();

        Assert.areEqual(200, responses.size());
        for (DMS_InventoryAgentAction.Response res : responses) {
            Assert.isTrue(res.isSuccess);
        }
    }
}