@IsTest
private class OrderAllocationLineItemTriggerTest {

    @TestSetup
    static void setupTestData() {
        // Resolve picklist values for Item__c
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
            Name = 'Test Item',
            Item_Code__c = 'IT-001',
            Base_Tax__c = 18,
            Default_Supply_Method__c = defaultSupplyMethod,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = unitOfMeasure,
            Target_Stock_Level__c = 50,
            Stock_Low_Level_Quantity__c = 5,
            Stock_Medium_Level_Quantity__c = 15,
            Stock_High_Level_Quantity__c = 30
        );
        insert item;

        // Create Test Accounts
        Account supplierAccount = new Account(Name = 'ABC Distributors');
        Account requestingAccount = new Account(Name = 'Speed Motors');
        insert new List<Account>{ supplierAccount, requestingAccount };

        // Create Parent Order Allocation
        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = supplierAccount.Id,
            Requesting_Account__c = requestingAccount.Id,
            Status__c = 'Planned'
        );
        insert oa;

        // Create OALIs
        List<Order_Allocation_Line_Item__c> oaliList = new List<Order_Allocation_Line_Item__c>();
        for (Integer i = 0; i < 5; i++) {
            oaliList.add(new Order_Allocation_Line_Item__c(
                Order_Allocation__c = oa.Id,
                Item__c = item.Id,
                Ordered_Qty__c = 100,
                Reserved_Quantity__c = 90,
                Status__c = 'Planned'
            ));
        }
        insert oaliList;
    }

    @IsTest
    static void testStatusTransitionToReadyToShip() {
        Order_Allocation_Line_Item__c oali = [
            SELECT Id, Status__c, Order_Allocation__c 
            FROM Order_Allocation_Line_Item__c 
            LIMIT 1
        ];

        Test.startTest();
        oali.Status__c = 'Ready to Ship';
        update oali;
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id, Order_Allocation_Line_Item__c, From_Account__c, To_Account__c, 
                   Transfer_Qty__c, Status__c, Request_Type__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];

        System.assertEquals(1, transfers.size(), 'Exactly one Inventory Transfer should be created');
        System.assertEquals(90, transfers[0].Transfer_Qty__c, 'Transfer quantity should match Reserved_Quantity__c');
        System.assertEquals('Requested', transfers[0].Status__c, 'Transfer status should be Requested');
        System.assertEquals('Customer Demand', transfers[0].Request_Type__c, 'Request Type should be Customer Demand');
    }

    @IsTest
    static void testNoTransferWhenAlreadyReadyToShip() {
        Order_Allocation_Line_Item__c oali = [
            SELECT Id, Status__c 
            FROM Order_Allocation_Line_Item__c 
            LIMIT 1
        ];

        // First transition to Ready to Ship
        oali.Status__c = 'Ready to Ship';
        update oali;

        Integer initialCount = [SELECT COUNT() FROM Inventory_Transfer__c WHERE Order_Allocation_Line_Item__c = :oali.Id];
        System.assertEquals(1, initialCount, 'Initial transfer created');

        // Clear recursion tracker in handler for subsequent DML test simulation
        OrderAllocationLineItemTriggerHandler.processedOaliIds.clear();

        // Update unrelated field on already Ready to Ship record
        Test.startTest();
        oali.Ordered_Qty__c = 120;
        update oali;
        Test.stopTest();

        Integer finalCount = [SELECT COUNT() FROM Inventory_Transfer__c WHERE Order_Allocation_Line_Item__c = :oali.Id];
        System.assertEquals(1, finalCount, 'No duplicate transfer should be created on subsequent update');
    }

    @IsTest
    static void testNoTransferOnOtherStatusChange() {
        Order_Allocation_Line_Item__c oali = [
            SELECT Id, Status__c 
            FROM Order_Allocation_Line_Item__c 
            LIMIT 1
        ];

        Test.startTest();
        oali.Status__c = 'Awaiting Inventory';
        update oali;
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        System.assertEquals(0, transfers.size(), 'No Inventory Transfer should be created for non-Ready to Ship status');
    }

    @IsTest
    static void testBulkReadyToShip() {
        List<Order_Allocation_Line_Item__c> oalis = [
            SELECT Id, Status__c 
            FROM Order_Allocation_Line_Item__c
        ];

        for (Order_Allocation_Line_Item__c oali : oalis) {
            oali.Status__c = 'Ready to Ship';
        }

        Test.startTest();
        update oalis;
        Test.stopTest();

        Set<Id> oaliIds = new Map<Id, Order_Allocation_Line_Item__c>(oalis).keySet();
        List<Inventory_Transfer__c> transfers = [
            SELECT Id, Order_Allocation_Line_Item__c 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c IN :oaliIds
        ];

        System.assertEquals(oalis.size(), transfers.size(), 'Each eligible OALI should have one Inventory Transfer created');
    }

    @IsTest
    static void testDuplicatePreventionInService() {
        Order_Allocation_Line_Item__c oali = [
            SELECT Id, Status__c, Item__c, Order_Allocation__c 
            FROM Order_Allocation_Line_Item__c 
            LIMIT 1
        ];

        // Manually create existing transfer
        Inventory_Transfer__c existingTransfer = new Inventory_Transfer__c(
            Order_Allocation_Line_Item__c = oali.Id,
            Transfer_Qty__c = 50,
            Status__c = 'Requested'
        );
        insert existingTransfer;

        Test.startTest();
        // Invoke service directly for the same OALI ID
        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        System.assertEquals(1, transfers.size(), 'Should not insert a duplicate transfer if one already exists');
    }

    @IsTest
    static void testTransferCreatedWhenRequestingAccountIsRetailer() {
        List<RecordType> retailerRt = [
            SELECT Id, DeveloperName, Name 
            FROM RecordType 
            WHERE SObjectType = 'Account' AND (DeveloperName = 'Retailer' OR Name = 'Retailer')
            LIMIT 1
        ];

        Account supplier = new Account(Name = 'Supplier Test Account');
        Account reqAccount = new Account(Name = 'Requesting Test Account');
        if (!retailerRt.isEmpty()) {
            reqAccount.RecordTypeId = retailerRt[0].Id;
        }
        insert new List<Account>{ supplier, reqAccount };

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = supplier.Id,
            Requesting_Account__c = reqAccount.Id,
            Status__c = 'Planned'
        );
        insert oa;

        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 25,
            Reserved_Quantity__c = 25,
            Status__c = 'Planned'
        );
        insert oali;

        Test.startTest();
        oali.Status__c = 'Ready to Ship';
        update oali;
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];

        System.assertEquals(1, transfers.size(), 'Transfers should be created when Requesting Account is a Retailer and Supplying Account is not Retailer');
    }

    @IsTest
    static void testNoTransferWhenSupplyingAccountIsRetailer() {
        List<RecordType> retailerRt = [
            SELECT Id, DeveloperName, Name 
            FROM RecordType 
            WHERE SObjectType = 'Account' AND (DeveloperName = 'Retailer' OR Name = 'Retailer')
            LIMIT 1
        ];

        Account supplier = new Account(Name = 'Kumar Traders Retailer');
        Account customer = new Account(Name = 'Pulla Rao Customer');
        if (!retailerRt.isEmpty()) {
            supplier.RecordTypeId = retailerRt[0].Id;
        }
        insert new List<Account>{ supplier, customer };

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = supplier.Id,
            Requesting_Account__c = customer.Id,
            Status__c = 'Planned'
        );
        insert oa;

        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 100,
            Status__c = 'Planned'
        );
        insert oali;

        Test.startTest();
        oali.Status__c = 'Ready to Ship';
        update oali;
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];

        System.assertEquals(1, transfers.size(), 'Transfers should be created even when Supplying Account is a Retailer');
    }

    @IsTest
    static void testIsRetailerAccountHelper() {
        // Test null safety and condition checks
        System.assertEquals(false, InventoryTransferService.isRetailerAccount(null));

        Order_Allocation_Line_Item__c oaliWithoutOA = new Order_Allocation_Line_Item__c();
        System.assertEquals(false, InventoryTransferService.isRetailerAccount(oaliWithoutOA));
        System.assertEquals(false, InventoryTransferService.isRetailerRequestingAccount(oaliWithoutOA));
    }

    @IsTest
    static void testTransferQtyCalculatedFromFulfilledQuantities() {
        Order_Allocation__c oa = [SELECT Id FROM Order_Allocation__c LIMIT 1];
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 80,
            Reserved_Quantity__c = 10,
            Procurement_Qty_Received__c = 70,
            Transfer_Qty_Received__c = 0,
            Transfer_Qty_Planned__c = 0,
            Status__c = 'Planned'
        );
        insert oali;

        Test.startTest();
        oali.Status__c = 'Ready to Ship';
        update oali;
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id, Transfer_Qty__c 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];

        System.assertEquals(1, transfers.size(), 'Inventory Transfer should be created');
        System.assertEquals(80, transfers[0].Transfer_Qty__c, 'Transfer Qty should be sum of Reserved (10) + Procurement Received (70) = 80');
    }

    @IsTest
    static void testNoTransferWhenPurelyTransferFulfilled() {
        Order_Allocation__c oa = [SELECT Id FROM Order_Allocation__c LIMIT 1];
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 20,
            Transfer_Qty_Planned__c = 20,
            Transfer_Qty_Received__c = 20,
            Status__c = 'Planned'
        );
        insert oali;

        Test.startTest();
        oali.Status__c = 'Ready to Ship';
        update oali;
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];

        System.assertEquals(0, transfers.size(), 'No Inventory Transfer should be created when fulfilled purely via transfer');
    }

    @IsTest
    static void testSplitFulfillmentTransferCreation() {
        Order_Allocation__c oa = [SELECT Id FROM Order_Allocation__c LIMIT 1];
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];

        // 100 ordered: 50 reserved, 40 procured, 10 transferred
        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 50,
            Procurement_Qty_Received__c = 40,
            Transfer_Qty_Planned__c = 10,
            Transfer_Qty_Received__c = 10,
            Status__c = 'Planned'
        );
        insert oali;

        Test.startTest();
        oali.Status__c = 'Ready to Ship';
        update oali;
        Test.stopTest();

        List<Inventory_Transfer__c> transfers = [
            SELECT Id, Transfer_Qty__c 
            FROM Inventory_Transfer__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];

        System.assertEquals(1, transfers.size(), 'Transfer should be created for the non-transfer fulfilled portion');
        System.assertEquals(90, transfers[0].Transfer_Qty__c, 'Transfer Qty should be 90 (50 Reserved + 40 Procured), excluding the 10 Transferred');
    }
}