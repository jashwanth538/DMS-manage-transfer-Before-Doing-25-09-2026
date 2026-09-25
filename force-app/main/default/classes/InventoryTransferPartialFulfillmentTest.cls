@IsTest
public class InventoryTransferPartialFulfillmentTest {

    @TestSetup
    static void setupTestData() {
        InventoryTransferPending.testIsAdminOverride = true;

        String defaultSupplyMethod = 'In-house';
        List<Schema.PicklistEntry> supplyEntries = Item__c.Default_Supply_Method__c.getDescribe().getPicklistValues();
        if (!supplyEntries.isEmpty()) {
            defaultSupplyMethod = supplyEntries[0].getValue();
        }

        String unitOfMeasure = 'PCS';
        List<Schema.PicklistEntry> uomEntries = Item__c.Unit_Of_Measure__c.getDescribe().getPicklistValues();
        if (!uomEntries.isEmpty()) {
            unitOfMeasure = uomEntries[0].getValue();
        }

        Item__c item = new Item__c(
            Name = 'Partial Test Part',
            Item_Code__c = 'PART-001',
            Base_Tax__c = 18,
            Default_Supply_Method__c = defaultSupplyMethod,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = unitOfMeasure,
            Target_Stock_Level__c = 500,
            Stock_Low_Level_Quantity__c = 20,
            Stock_Medium_Level_Quantity__c = 100,
            Stock_High_Level_Quantity__c = 500
        );
        insert item;

        Account sourceAcc = new Account(Name = 'Source Hub');
        Account destAcc = new Account(Name = 'Dest Dealer');
        insert new List<Account>{ sourceAcc, destAcc };

        Inventory_Location__c locSource = new Inventory_Location__c(
            Name = 'Source Hub Loc',
            Inventory_Location_Code__c = 'SHL',
            Account__c = sourceAcc.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locDest = new Inventory_Location__c(
            Name = 'Dest Dealer Loc',
            Inventory_Location_Code__c = 'DDL',
            Account__c = destAcc.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locSource, locDest };

        Inventory__c sourceInv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locSource.Id,
            Available__c = 200,
            Reserved_Sale_Order__c = 500,
            Transit_Out_Quantity__c = 0,
            Transit_In_Quantity__c = 0
        );
        Inventory__c destInv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locDest.Id,
            Available__c = 0,
            Reserved_Sale_Order__c = 0,
            Transit_Out_Quantity__c = 0,
            Transit_In_Quantity__c = 0
        );
        insert new List<Inventory__c>{ sourceInv, destInv };
    }

    private static Id getTransferSrRtId() {
        if (Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName().containsKey('Transfer_Supply_Request')) {
            return Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName().get('Transfer_Supply_Request').getRecordTypeId();
        }
        return null;
    }

    private static Id getCustomerDemandSrRtId() {
        if (Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName().containsKey('Purchase_Supply_Request')) {
            return Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName().get('Purchase_Supply_Request').getRecordTypeId();
        }
        return null;
    }

    // =========================================================================
    // 1. UNIT TEST: determineShipmentStatus and determineDeliveryStatus helpers
    // =========================================================================
    @IsTest
    static void testHelperFunctionsDirectly() {
        // Shipment Status tests
        Assert.areEqual('Shipped', InventoryTransferBacktrackingService.determineShipmentStatus(100.0, 100.0, 'Planned'), '100/100 should be Shipped');
        Assert.areEqual('Shipped', InventoryTransferBacktrackingService.determineShipmentStatus(100.0, 120.0, 'Planned'), '120/100 should be Shipped');
        Assert.areEqual('Partially Shipped', InventoryTransferBacktrackingService.determineShipmentStatus(100.0, 30.0, 'Planned'), '30/100 should be Partially Shipped');
        Assert.areEqual('Partially Shipped', InventoryTransferBacktrackingService.determineShipmentStatus(100.0, 99.9, 'Planned'), '99.9/100 should be Partially Shipped');
        Assert.areEqual('Planned', InventoryTransferBacktrackingService.determineShipmentStatus(100.0, 0.0, 'Planned'), '0/100 should remain Planned');
        Assert.areEqual('Delivered', InventoryTransferBacktrackingService.determineShipmentStatus(100.0, 50.0, 'Delivered'), 'Delivered status must not regress to Partially Shipped');
        Assert.areEqual('Partially Delivered', InventoryTransferBacktrackingService.determineShipmentStatus(100.0, 50.0, 'Partially Delivered'), 'Partially Delivered must not regress');

        // Delivery Status tests
        Assert.areEqual('Delivered', InventoryTransferBacktrackingService.determineDeliveryStatus(100.0, 100.0, 'Shipped'), '100/100 should be Delivered');
        Assert.areEqual('Delivered', InventoryTransferBacktrackingService.determineDeliveryStatus(100.0, 150.0, 'Shipped'), '150/100 should be Delivered');
        Assert.areEqual('Partially Delivered', InventoryTransferBacktrackingService.determineDeliveryStatus(100.0, 40.0, 'Shipped'), '40/100 should be Partially Delivered');
        Assert.areEqual('Shipped', InventoryTransferBacktrackingService.determineDeliveryStatus(100.0, 0.0, 'Shipped'), '0/100 should not mark Delivered');
    }

    // =========================================================================
    // 2. LIFECYCLE: Sequential Multi-Transfer (30 -> 20 -> 50) on OALI (100)
    // =========================================================================
    @IsTest
    static void testSequentialMultiTransferLifecycle() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'Source Hub' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Dest Dealer' LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SHL' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DDL' LIMIT 1];

        // Create OA & OALI with Ordered_Qty__c = 100
        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Planned'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Status__c = 'Ready to Ship'
        );
        insert oali;

        // Create 3 Inventory Transfers: IT-1 (30), IT-2 (20), IT-3 (50)
        Inventory_Transfer__c it1 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 30,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = oali.Id
        );
        Inventory_Transfer__c it2 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 20,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = oali.Id
        );
        Inventory_Transfer__c it3 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 50,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = oali.Id
        );
        insert new List<Inventory_Transfer__c>{ it1, it2, it3 };

        // --- STEP 1: Initiate IT-1 (30 / 100) ---
        InventoryTransferPending.initiateTransfers(new List<Id>{ it1.Id });

        Order_Allocation_Line_Item__c oaliStep1 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        Assert.areEqual('Partially Shipped', oaliStep1.Status__c, 'OALI should be Partially Shipped after IT-1 initiation (30/100)');

        // --- STEP 2: Initiate IT-2 (20 / 100, cumulative 50/100) ---
        InventoryTransferPending.initiateTransfers(new List<Id>{ it2.Id });

        Order_Allocation_Line_Item__c oaliStep2 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        Assert.areEqual('Partially Shipped', oaliStep2.Status__c, 'OALI should still be Partially Shipped after IT-2 initiation (50/100)');

        // --- STEP 3: Initiate IT-3 (50 / 100, cumulative 100/100) ---
        InventoryTransferPending.initiateTransfers(new List<Id>{ it3.Id });

        Order_Allocation_Line_Item__c oaliStep3 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        Assert.areEqual('Shipped', oaliStep3.Status__c, 'OALI should be fully Shipped after IT-3 initiation (100/100)');

        // --- STEP 4: Accept IT-1 (30 / 100) ---
        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it1.Id });

        Order_Allocation_Line_Item__c oaliStep4 = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        Assert.areEqual('Partially Delivered', oaliStep4.Status__c, 'OALI should be Partially Delivered after IT-1 acceptance (30/100)');
        Assert.areEqual(30, oaliStep4.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c should be 30');

        // --- STEP 5: Accept IT-2 (20 / 100, cumulative 50/100) ---
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it2.Id });

        Order_Allocation_Line_Item__c oaliStep5 = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        Assert.areEqual('Partially Delivered', oaliStep5.Status__c, 'OALI should be Partially Delivered after IT-2 acceptance (50/100)');
        Assert.areEqual(50, oaliStep5.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c should be 50');

        // --- STEP 6: Accept IT-3 (50 / 100, cumulative 100/100) ---
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it3.Id });
        Test.stopTest();

        Order_Allocation_Line_Item__c oaliStep6 = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        Assert.areEqual('Delivered', oaliStep6.Status__c, 'OALI should be Delivered after IT-3 acceptance (100/100)');
        Assert.areEqual(100, oaliStep6.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c should be 100');
    }

    // =========================================================================
    // 3. UPSTREAM / PARENT OALI PROPAGATION: Multi-Tier Transfer SR Flow
    // =========================================================================
    @IsTest
    static void testUpstreamParentOaliPartialPropagation() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'Source Hub' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Dest Dealer' LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SHL' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DDL' LIMIT 1];

        // 1. Parent Customer OA & OALI at Destination Dealer
        Order_Allocation__c parentOa = new Order_Allocation__c(
            Supplying_Account__c = destAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Draft'
        );
        insert parentOa;

        Order_Allocation_Line_Item__c parentOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = parentOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned'
        );
        insert parentOali;

        // 2. Transfer Supply Request linked to parent OALI
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = destAcc.Id,
            Supplying_Account__c = sourceAcc.Id,
            Target_Location__c = locDest.Id,
            Order_Allocation_Line_Item__c = parentOali.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        // 3. Fulfilling OA & OALI at Source Hub
        Order_Allocation__c fulfillingOa = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Draft'
        );
        insert fulfillingOa;

        Order_Allocation_Line_Item__c fulfillingOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = fulfillingOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':100'
        );
        insert fulfillingOali;

        // 4. Create Two Partial Transfers: IT-A (40), IT-B (60)
        Inventory_Transfer__c itA = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 40,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = fulfillingOali.Id
        );
        Inventory_Transfer__c itB = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 60,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = fulfillingOali.Id
        );
        insert new List<Inventory_Transfer__c>{ itA, itB };

        // Initiate IT-A (40 / 100)
        InventoryTransferPending.initiateTransfers(new List<Id>{ itA.Id });

        Order_Allocation_Line_Item__c chkParent1 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentOali.Id];
        Order_Allocation_Line_Item__c chkChild1 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillingOali.Id];
        Assert.areEqual('Partially Shipped', chkChild1.Status__c, 'Child OALI should be Partially Shipped (40/100)');
        Assert.areEqual('Partially Shipped', chkParent1.Status__c, 'Parent OALI should be Partially Shipped (40/100)');

        // Initiate IT-B (60 / 100, cumulative 100)
        InventoryTransferPending.initiateTransfers(new List<Id>{ itB.Id });

        Order_Allocation_Line_Item__c chkParent2 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentOali.Id];
        Order_Allocation_Line_Item__c chkChild2 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillingOali.Id];
        Assert.areEqual('Shipped', chkChild2.Status__c, 'Child OALI should be Shipped (100/100)');
        Assert.areEqual('Shipped', chkParent2.Status__c, 'Parent OALI should be Shipped (100/100)');

        // Accept IT-A (40 / 100)
        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ itA.Id });

        Order_Allocation_Line_Item__c chkParent3 = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentOali.Id];
        Order_Allocation_Line_Item__c chkChild3 = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillingOali.Id];
        Assert.areEqual('Partially Delivered', chkChild3.Status__c, 'Child OALI should be Partially Delivered after IT-A (40/100)');
        Assert.areEqual('Partially Delivered', chkParent3.Status__c, 'Parent OALI should be Partially Delivered after IT-A (40/100)');
        Assert.areEqual(40, chkParent3.Transfer_Qty_Received__c, 'Parent Transfer_Qty_Received__c should be 40');

        Supply_Request__c chkSr1 = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :transferSr.Id];
        Assert.areEqual(40, chkSr1.Received_Qty__c, 'Transfer SR Received_Qty__c should be 40 after IT-A');
        Assert.areEqual('Partially Received', chkSr1.Status__c, 'Transfer SR Status__c should be Partially Received after IT-A');

        // Accept IT-B (60 / 100, cumulative 100)
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ itB.Id });
        Test.stopTest();

        Order_Allocation_Line_Item__c chkParent4 = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentOali.Id];
        Order_Allocation_Line_Item__c chkChild4 = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillingOali.Id];
        Assert.areEqual('Delivered', chkChild4.Status__c, 'Child OALI should be Delivered after IT-B (100/100)');
        Assert.areEqual('Delivered', chkParent4.Status__c, 'Parent OALI should be Delivered after IT-B (100/100)');
        Assert.areEqual(100, chkParent4.Transfer_Qty_Received__c, 'Parent Transfer_Qty_Received__c should be 100');

        Supply_Request__c chkSr2 = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :transferSr.Id];
        Assert.areEqual(100, chkSr2.Received_Qty__c, 'Transfer SR Received_Qty__c should be 100 after IT-B');
        Assert.areEqual('Completed', chkSr2.Status__c, 'Transfer SR Status__c should be Completed after IT-B');
    }

    // =========================================================================
    // 4. DOUBLE COUNTING & CANCELLED TRANSFERS
    // =========================================================================
    @IsTest
    static void testDoubleCountingProtectionWithCancelledTransfers() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'Source Hub' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Dest Dealer' LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SHL' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DDL' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Planned'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Status__c = 'Planned'
        );
        insert oali;

        // Cancelled transfer of 50
        Inventory_Transfer__c itCancelled = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 50,
            Status__c = 'Cancelled',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = oali.Id
        );
        // Active transfer of 40
        Inventory_Transfer__c itActive = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 40,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = oali.Id
        );
        insert new List<Inventory_Transfer__c>{ itCancelled, itActive };

        InventoryTransferPending.initiateTransfers(new List<Id>{ itActive.Id });

        Order_Allocation_Line_Item__c oaliUpdated = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        Assert.areEqual('Partially Shipped', oaliUpdated.Status__c, 'Cancelled transfer must NOT be counted; only active 40 should be counted');
    }

    // =========================================================================
    // 5. BULK EXECUTION TEST (Multiple Transfers)
    // =========================================================================
    @IsTest
    static void testBulkTransferInitiationAndAcceptance() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'Source Hub' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Dest Dealer' LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SHL' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DDL' LIMIT 1];

        // Create 10 OALIs with 10 transfers each (each transfer qty 5, ordered qty 10)
        List<Order_Allocation__c> oas = new List<Order_Allocation__c>();
        for (Integer i = 0; i < 5; i++) {
            oas.add(new Order_Allocation__c(
                Supplying_Account__c = sourceAcc.Id,
                Requesting_Account__c = destAcc.Id,
                Status__c = 'Planned'
            ));
        }
        insert oas;

        List<Order_Allocation_Line_Item__c> oalis = new List<Order_Allocation_Line_Item__c>();
        for (Order_Allocation__c oaRec : oas) {
            oalis.add(new Order_Allocation_Line_Item__c(
                Order_Allocation__c = oaRec.Id,
                Item__c = item.Id,
                Ordered_Qty__c = 10,
                Transfer_Qty_Planned__c = 10,
                Status__c = 'Ready to Ship'
            ));
        }
        insert oalis;

        List<Inventory_Transfer__c> transfers = new List<Inventory_Transfer__c>();
        for (Order_Allocation_Line_Item__c oaliRec : oalis) {
            transfers.add(new Inventory_Transfer__c(
                Item__c = item.Id,
                Source_Inventory_Location__c = locSource.Id,
                Destination_Inventory_Location__c = locDest.Id,
                From_Account__c = sourceAcc.Id,
                To_Account__c = destAcc.Id,
                Transfer_Qty__c = 5,
                Status__c = 'Requested',
                Request_Type__c = 'Transfer SR',
                Order_Allocation_Line_Item__c = oaliRec.Id
            ));
        }
        insert transfers;

        List<Id> transferIds = new List<Id>();
        for (Inventory_Transfer__c t : transfers) {
            transferIds.add(t.Id);
        }

        InventoryTransferPending.initiateTransfers(transferIds);

        List<Order_Allocation_Line_Item__c> oalisAfterInit = [
            SELECT Id, Status__c FROM Order_Allocation_Line_Item__c WHERE Id IN :oalis
        ];
        for (Order_Allocation_Line_Item__c o : oalisAfterInit) {
            Assert.areEqual('Partially Shipped', o.Status__c, 'Bulk initiated OALIs should be Partially Shipped (5/10)');
        }

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(transferIds);
        Test.stopTest();

        List<Order_Allocation_Line_Item__c> oalisAfterAccept = [
            SELECT Id, Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id IN :oalis
        ];
        for (Order_Allocation_Line_Item__c o : oalisAfterAccept) {
            Assert.areEqual('Partially Delivered', o.Status__c, 'Bulk accepted OALIs should be Partially Delivered (5/10)');
            Assert.areEqual(5, o.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c should be 5');
        }
    }

    // =========================================================================
    // 6. CUSTOMER DEMAND & TRANSFER SR PARTIAL FULFILLMENT TEST
    // =========================================================================
    @IsTest
    static void testCustomerDemandAndTransferSrPartialFulfillment() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'Source Hub' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Dest Dealer' LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SHL' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DDL' LIMIT 1];

        // 1. Root Customer Demand SR for 100
        Supply_Request__c custSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getCustomerDemandSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = destAcc.Id,
            Supplying_Account__c = sourceAcc.Id,
            Target_Location__c = locDest.Id
        );
        insert custSr;
        custSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :custSr.Id];

        // 2. Fulfilling OA & OALI
        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Planned'
        );
        insert oa;

        // 3. Direct Transfer SR for 50
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = destAcc.Id,
            Supplying_Account__c = sourceAcc.Id,
            Target_Location__c = locDest.Id
        );
        insert transferSr;

        Order_Allocation_Line_Item__c fulfillingOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = custSr.Name,
            Source_SR_Allocation__c = custSr.Name + ':100'
        );
        insert fulfillingOali;

        transferSr.Order_Allocation_Line_Item__c = fulfillingOali.Id;
        update transferSr;

        // 4. Inventory Transfer of 50
        Inventory_Transfer__c it = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 50,
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = fulfillingOali.Id
        );
        insert it;

        InventoryTransferPending.initiateTransfers(new List<Id>{ it.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it.Id });
        Test.stopTest();

        // Direct OALI: 50 received / 100 ordered -> Partially Delivered
        Order_Allocation_Line_Item__c oaliAfter = [
            SELECT Status__c, Transfer_Qty_Received__c, Secured_Qty__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :fulfillingOali.Id
        ];
        Assert.areEqual('Partially Delivered', oaliAfter.Status__c, 'OALI should be Partially Delivered (50/100 received)');
        Assert.areEqual(50, oaliAfter.Transfer_Qty_Received__c, 'OALI Transfer_Qty_Received__c should be 50');

        // Direct Transfer SR: 50 requested, 50 received -> Completed
        Supply_Request__c transferSrAfter = [
            SELECT Status__c, Received_Qty__c, Remaining_Quantity__c 
            FROM Supply_Request__c 
            WHERE Id = :transferSr.Id
        ];
        Assert.areEqual(50, transferSrAfter.Received_Qty__c, 'Transfer SR Received_Qty__c should be 50');
        Assert.areEqual('Completed', transferSrAfter.Status__c, 'Transfer SR should be Completed');

        // Root Customer Demand SR: 100 requested, 50 received -> Partially Received
        Supply_Request__c custSrAfter = [
            SELECT Status__c, Received_Qty__c, Remaining_Quantity__c 
            FROM Supply_Request__c 
            WHERE Id = :custSr.Id
        ];
        Assert.areEqual(50, custSrAfter.Received_Qty__c, 'Customer Demand SR Received_Qty__c should be 50');
        Assert.areEqual('Partially Received', custSrAfter.Status__c, 'Customer Demand SR should be Partially Received');
        Assert.areEqual(50, custSrAfter.Remaining_Quantity__c, 'Customer Demand SR Remaining_Quantity__c should be 50');
    }
}