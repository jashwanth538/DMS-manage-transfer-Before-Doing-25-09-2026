@IsTest
public class InventoryTransferPendingTest {

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

        // Create Locations
        Inventory_Location__c locSource = new Inventory_Location__c(
            Name = 'Source Loc',
            Inventory_Location_Code__c = 'SRC',
            Is_Active__c = true
        );
        Inventory_Location__c locDest = new Inventory_Location__c(
            Name = 'Dest Loc',
            Inventory_Location_Code__c = 'DST',
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locSource, locDest };

        // Create Accounts
        Account sourceAcc = new Account(Name = 'ABC Distributors');
        Account destAcc = new Account(Name = 'Speed Motors');
        insert new List<Account>{ sourceAcc, destAcc };

        // Create Inventory Records with Reserved for Sales Order
        Inventory__c sourceInv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locSource.Id,
            Available__c = 100,
            Reserved_Sale_Order__c = 90,
            Transit_Out_Quantity__c = 0,
            Transit_In_Quantity__c = 0
        );
        Inventory__c destInv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locDest.Id,
            Available__c = 50,
            Reserved_Sale_Order__c = 0,
            Transit_Out_Quantity__c = 0,
            Transit_In_Quantity__c = 0
        );
        insert new List<Inventory__c>{ sourceInv, destInv };

        // Create Order Allocation and Line Item
        Order_Allocation__c alloc = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Draft'
        );
        insert alloc;

        Order_Allocation_Line_Item__c ali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = alloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 90,
            Reserved_Quantity__c = 90,
            Status__c = 'Ready to Ship'
        );
        insert ali;

        // Create linked Inventory Reservation
        Inventory_Reservation__c invRes = new Inventory_Reservation__c(
            Order_Allocation_Line_Item__c = ali.Id,
            Item__c = item.Id,
            Inventory_Location__c = locSource.Id,
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Requested_Qty__c = 90,
            Reserved_Qty__c = 90,
            Status__c = 'Fully Reserved'
        );
        insert invRes;

        // Create Inventory Transfer (Pending / Requested)
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 90,
            Requested_Date__c = Date.today(),
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = ali.Id
        );
        insert transfer;
    }

    @IsTest
    static void testGetPendingTransfers() {
        Test.startTest();
        List<Inventory_Transfer__c> pending = InventoryTransferPending.getPendingTransfers();
        Test.stopTest();

        System.assertEquals(1, pending.size(), 'Should return one pending transfer.');
        System.assertEquals('Requested', pending[0].Status__c, 'Status should be Requested.');
    }

    @IsTest
    static void testGetLocations() {
        Test.startTest();
        List<Inventory_Location__c> locs = InventoryTransferPending.getLocations();
        Test.stopTest();

        System.assertEquals(2, locs.size(), 'Should return two locations.');
    }

    @IsTest
    static void testValidateTransferStatus() {
        Inventory_Transfer__c transfer = [SELECT Id FROM Inventory_Transfer__c LIMIT 1];

        Test.startTest();
        Map<String, Object> resValid = InventoryTransferPending.validateTransferStatus(transfer.Id);
        Test.stopTest();

        System.assertEquals(true, resValid.get('valid'), 'Status validation should succeed for Requested status');
    }

    @IsTest
    static void testSuccessfulInitiate() {
        Inventory_Transfer__c transfer = [
            SELECT Id, Source_Inventory_Location__c, Destination_Inventory_Location__c, Item__c, 
                   Transfer_Qty__c, Order_Allocation_Line_Item__c 
            FROM Inventory_Transfer__c 
            LIMIT 1
        ];

        Test.startTest();
        Map<String, String> res = InventoryTransferPending.initiateTransfer(transfer.Id);
        Test.stopTest();

        System.assertEquals('In Transit', res.get('status'), 'Result status should be In Transit');

        // Verify Transfer record update
        Inventory_Transfer__c updatedTransfer = [
            SELECT Id, Status__c, In_Transit_Qty__c, Shipped_Date__c 
            FROM Inventory_Transfer__c 
            WHERE Id = :transfer.Id
        ];
        System.assertEquals('In Transit', updatedTransfer.Status__c, 'Transfer status must be In Transit');
        System.assertEquals(90, updatedTransfer.In_Transit_Qty__c, 'In Transit qty must be 90');

        // Verify Source Inventory movement: Reserved for Sales Order -90, Transfer Out +90
        Inventory__c sourceInv = [
            SELECT Id, Reserved_Sale_Order__c, Transit_Out_Quantity__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :transfer.Source_Inventory_Location__c 
            AND Item__c = :transfer.Item__c
        ];
        System.assertEquals(0, sourceInv.Reserved_Sale_Order__c, 'Reserved for Sales Order should decrease by 90 to 0');
        System.assertEquals(90, sourceInv.Transit_Out_Quantity__c, 'Transit Out Quantity should increase by 90');

        // Verify Target Inventory movement: Transfer In +90, Available and Reserved unchanged
        Inventory__c destInv = [
            SELECT Id, Transit_In_Quantity__c, Available__c, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :transfer.Destination_Inventory_Location__c 
            AND Item__c = :transfer.Item__c
        ];
        System.assertEquals(90, destInv.Transit_In_Quantity__c, 'Transit In Quantity at destination should increase by 90');
        System.assertEquals(50, destInv.Available__c, 'Destination Available should remain unchanged during Initiate');
        System.assertEquals(0, destInv.Reserved_Sale_Order__c, 'Destination Reserved for Sales Order should remain unchanged during Initiate');

        // Verify linked OALI status updated to 'Shipped'
        Order_Allocation_Line_Item__c oali = [
            SELECT Id, Status__c, Order_Allocation__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :transfer.Order_Allocation_Line_Item__c
        ];
        System.assertEquals('Shipped', oali.Status__c, 'OALI status must be updated to Shipped on transfer initiation');

        // Verify linked Inventory Reservation status updated to 'Consumed'
        Inventory_Reservation__c updatedInvRes = [
            SELECT Id, Status__c 
            FROM Inventory_Reservation__c 
            WHERE Order_Allocation_Line_Item__c = :oali.Id 
            LIMIT 1
        ];
        System.assertEquals('Consumed', updatedInvRes.Status__c, 'Inventory Reservation status must be Consumed upon transfer initiation');

        // Strict Event 1 Check: Verify NO receipt backtracking (Transfer Received Qty is 0 / null)
        System.assertEquals(null, updatedTransfer.Received_Qty__c, 'Initiate must NOT set Received_Qty__c');
    }

    @IsTest
    static void testInsufficientReservedQuantityFailsInitiate() {
        Inventory_Transfer__c transfer = [
            SELECT Id, Source_Inventory_Location__c, Item__c 
            FROM Inventory_Transfer__c 
            LIMIT 1
        ];

        // Reduce source reserved quantity to less than transfer qty
        Inventory__c sourceInv = [
            SELECT Id, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :transfer.Source_Inventory_Location__c 
            AND Item__c = :transfer.Item__c
        ];
        sourceInv.Reserved_Sale_Order__c = 30; // Transfer requires 90
        update sourceInv;

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            InventoryTransferPending.initiateTransfer(transfer.Id);
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Initiate must fail when Reserved for Sales Order is insufficient');

        // Verify status remained Requested
        Inventory_Transfer__c checkTransfer = [SELECT Status__c FROM Inventory_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('Requested', checkTransfer.Status__c, 'Status should remain Requested');
    }

    @IsTest
    static void testDuplicateInitiateFails() {
        Inventory_Transfer__c transfer = [SELECT Id FROM Inventory_Transfer__c LIMIT 1];

        // First initiate
        InventoryTransferPending.initiateTransfer(transfer.Id);

        // Second initiate attempt
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            InventoryTransferPending.initiateTransfer(transfer.Id);
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Second initiate attempt must throw exception');
    }

    @IsTest
    static void testBulkInitiate() {
        Inventory_Transfer__c transfer = [
            SELECT Id, Order_Allocation_Line_Item__c 
            FROM Inventory_Transfer__c 
            LIMIT 1
        ];

        Test.startTest();
        List<Map<String, String>> results = InventoryTransferPending.initiateTransfers(new List<Id>{ transfer.Id });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return 1 result');
        System.assertEquals('In Transit', results[0].get('status'), 'Status should be In Transit');

        Order_Allocation_Line_Item__c oali = [
            SELECT Id, Status__c, Order_Allocation__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :transfer.Order_Allocation_Line_Item__c
        ];
        System.assertEquals('Shipped', oali.Status__c, 'OALI status must be updated to Shipped on bulk initiate');
    }

    @IsTest
    static void testLineItemStatusWhenTransfersInitiatedIndividually() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SRC' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DST' LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Replenish source inventory reserved sales order
        Inventory__c sourceInv = [
            SELECT Id, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :locSource.Id AND Item__c = :item.Id
        ];
        sourceInv.Reserved_Sale_Order__c = 200;
        update sourceInv;

        // Create Order Allocation with 2 Line Items
        Order_Allocation__c multiAlloc = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Draft'
        );
        insert multiAlloc;

        Order_Allocation_Line_Item__c oali1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = multiAlloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 20,
            Transfer_Qty_Planned__c = 20,
            Status__c = 'Ready to Ship'
        );
        Order_Allocation_Line_Item__c oali2 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = multiAlloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 30,
            Transfer_Qty_Planned__c = 30,
            Status__c = 'Ready to Ship'
        );
        insert new List<Order_Allocation_Line_Item__c>{ oali1, oali2 };

        Inventory_Transfer__c transfer1 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 20,
            Requested_Date__c = Date.today(),
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = oali1.Id
        );
        Inventory_Transfer__c transfer2 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 30,
            Requested_Date__c = Date.today(),
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = oali2.Id
        );
        insert new List<Inventory_Transfer__c>{ transfer1, transfer2 };

        Test.startTest();
        // Initiate only first transfer (50% of line items)
        InventoryTransferPending.initiateTransfer(transfer1.Id);
        Test.stopTest();

        Order_Allocation_Line_Item__c updatedOali1 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali1.Id];
        Order_Allocation_Line_Item__c updatedOali2 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali2.Id];

        System.assertEquals('Shipped', updatedOali1.Status__c, 'First line item must be Shipped');
        System.assertEquals('Ready to Ship', updatedOali2.Status__c, 'Second line item must remain Ready to Ship');

        // Now initiate second transfer (100% of line items now shipped)
        InventoryTransferPending.initiateTransfer(transfer2.Id);

        Order_Allocation_Line_Item__c updatedOali2After = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali2.Id];
        System.assertEquals('Shipped', updatedOali2After.Status__c, 'Second line item must now be Shipped');
    }

    @IsTest
    static void testGetDashboardTransfers() {
        Test.startTest();
        List<Inventory_Transfer__c> dTransfers = InventoryTransferPending.getDashboardTransfers();
        Test.stopTest();

        System.assertNotEquals(0, dTransfers.size(), 'Should return dashboard transfers');
    }

    @IsTest
    static void testGetPendingTransfers_AccountFiltered() {
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // 1. Simulate non-admin user mapped to Source Account (ABC Distributors)
        InventoryTransferPending.testIsAdminOverride = false;
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>{ sourceAcc.Id };

        Test.startTest();
        List<Inventory_Transfer__c> sourcePending = InventoryTransferPending.getPendingTransfers();

        // 2. Simulate non-admin user mapped to Dest Account (Speed Motors - not source)
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>{ destAcc.Id };
        List<Inventory_Transfer__c> destPending = InventoryTransferPending.getPendingTransfers();

        // 3. Simulate non-admin user with no mapped accounts
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>();
        List<Inventory_Transfer__c> emptyPending = InventoryTransferPending.getPendingTransfers();

        // 4. Reset to Admin
        InventoryTransferPending.testIsAdminOverride = true;
        InventoryTransferPending.testAccountIdsOverride = null;
        List<Inventory_Transfer__c> adminPending = InventoryTransferPending.getPendingTransfers();
        Test.stopTest();

        System.assertEquals(1, sourcePending.size(), 'Source account user must see pending transfers from their account');
        System.assertEquals(0, destPending.size(), 'Destination account user must NOT see pending transfers to initiate');
        System.assertEquals(0, emptyPending.size(), 'User with no mapped accounts must see 0 pending transfers');
        System.assertEquals(1, adminPending.size(), 'System admin must see all pending transfers');
    }

    @IsTest
    static void testGetDashboardTransfers_AccountFiltered() {
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];
        Account otherAcc = new Account(Name = 'Unrelated Account');
        insert otherAcc;

        InventoryTransferPending.testIsAdminOverride = false;

        Test.startTest();
        // Source account can see in dashboard (From_Account__c IN :userAccountIds)
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>{ sourceAcc.Id };
        List<Inventory_Transfer__c> sourceDash = InventoryTransferPending.getDashboardTransfers();

        // Target account can see in dashboard (To_Account__c IN :userAccountIds)
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>{ destAcc.Id };
        List<Inventory_Transfer__c> destDash = InventoryTransferPending.getDashboardTransfers();

        // Unrelated account cannot see
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>{ otherAcc.Id };
        List<Inventory_Transfer__c> otherDash = InventoryTransferPending.getDashboardTransfers();
        Test.stopTest();

        System.assertEquals(1, sourceDash.size(), 'Source account must see transfer in dashboard');
        System.assertEquals(1, destDash.size(), 'Target account must see transfer in dashboard');
        System.assertEquals(0, otherDash.size(), 'Unrelated account must see 0 transfers in dashboard');
    }

    @IsTest
    static void testAccountPublicGroupMappingResolution() {
        Account testAcc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];

        // Create Public Group
        Group testGroup = new Group(
            Name = 'Test ABC Group',
            DeveloperName = 'Test_ABC_Group'
        );
        insert testGroup;

        // Add running user to group
        GroupMember gm = new GroupMember(
            GroupId = testGroup.Id,
            UserOrGroupId = UserInfo.getUserId()
        );
        insert gm;

        // Create Account Public Group Mapping
        Account_Public_Group_Mapping__c mapping = new Account_Public_Group_Mapping__c(
            Account__c = testAcc.Id,
            Public_Group_Id__c = String.valueOf(testGroup.Id),
            Public_Group_Name__c = testGroup.Name,
            Active__c = true,
            Access_Level__c = 'Full Access'
        );
        insert mapping;

        Test.startTest();
        // Clear test overrides so real database query is exercised
        InventoryTransferPending.testAccountIdsOverride = null;
        InventoryTransferPending.testIsAdminOverride = false;
        Set<Id> resolvedAccIds = InventoryTransferPending.getUserAccountIds();
        Test.stopTest();

        System.assert(resolvedAccIds.contains(testAcc.Id), 'Resolved Account IDs must contain the mapped Account ID');
    }

    @IsTest
    static void testRecursiveParentOaliStatusShippedOnInitiate() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SRC' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DST' LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Replenish source inventory reserved sales order
        Inventory__c sourceInv = [
            SELECT Id, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :locSource.Id AND Item__c = :item.Id
        ];
        sourceInv.Reserved_Sale_Order__c = 150;
        update sourceInv;

        // 1. Create Originating Customer Order Allocation & Parent OALI
        Order_Allocation__c customerOa = new Order_Allocation__c(
            Supplying_Account__c = destAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Planned'
        );
        insert customerOa;

        // 2. Create Supply Request
        Supply_Request__c srDemand = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = destAcc.Id,
            Supplying_Account__c = sourceAcc.Id
        );
        insert srDemand;

        Supply_Request__c queriedSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :srDemand.Id LIMIT 1];

        Order_Allocation_Line_Item__c parentOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = customerOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Procurement_Qty_Planned__c = 50,
            Status__c = 'Planned',
            Supply_Request__c = queriedSr.Id
        );
        insert parentOali;

        // 3. Create Downstream Fulfillment Order Allocation & Fulfillment OALI
        Order_Allocation__c fulfillOa = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Planned'
        );
        insert fulfillOa;

        Order_Allocation_Line_Item__c fulfillOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = fulfillOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Status__c = 'Ready to Ship',
            Supply_Request__c = queriedSr.Id,
            Source_SR_References__c = queriedSr.Name,
            Source_SR_Allocation__c = queriedSr.Name + ':50'
        );
        insert fulfillOali;

        // Create linked Inventory Reservation on parent OALI
        Inventory_Reservation__c resParent = new Inventory_Reservation__c(
            Order_Allocation_Line_Item__c = parentOali.Id,
            Item__c = item.Id,
            Inventory_Location__c = locSource.Id,
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Requested_Qty__c = 50,
            Reserved_Qty__c = 50,
            Status__c = 'Fully Reserved'
        );
        insert resParent;

        // Create Pending Inventory Transfer
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 50,
            Requested_Date__c = Date.today(),
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = fulfillOali.Id
        );
        insert transfer;

        Test.startTest();
        Map<String, String> result = InventoryTransferPending.initiateTransfer(transfer.Id);
        Test.stopTest();

        System.assertEquals('In Transit', result.get('status'), 'Initiate should succeed and return In Transit');

        // Verify transfer status
        Inventory_Transfer__c updatedTransfer = [SELECT Status__c, In_Transit_Qty__c FROM Inventory_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('In Transit', updatedTransfer.Status__c);
        System.assertEquals(50, updatedTransfer.In_Transit_Qty__c);

        // Verify downstream fulfillment OALI status updated to 'Shipped'
        Order_Allocation_Line_Item__c updatedFulfillOali = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillOali.Id];
        System.assertEquals('Shipped', updatedFulfillOali.Status__c, 'Fulfillment OALI status must be updated to Shipped');

        // Verify parent originating OALI status updated to 'Shipped' recursively
        Order_Allocation_Line_Item__c updatedParentOali = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentOali.Id];
        System.assertEquals('Shipped', updatedParentOali.Status__c, 'Parent OALI status must be recursively updated to Shipped');

        // Verify reservation status updated to 'Consumed'
        Inventory_Reservation__c updatedResParent = [SELECT Status__c FROM Inventory_Reservation__c WHERE Id = :resParent.Id];
        System.assertEquals('Consumed', updatedResParent.Status__c, 'Parent reservation must be Consumed');

        // Strict Event 1 Check: Verify SR is NOT marked Completed during initiate
        Supply_Request__c checkSR = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :srDemand.Id];
        System.assertEquals('Open', checkSR.Status__c, 'SR must NOT be marked Completed during Initiate');
        System.assertEquals(0, checkSR.Received_Qty__c, 'SR Received_Qty__c must NOT be incremented during Initiate');

        // Strict Event 1 Check: Verify Order_Allocation__c status is NOT modified by Apex
        Order_Allocation__c checkCustOa = [SELECT Status__c FROM Order_Allocation__c WHERE Id = :customerOa.Id];
        System.assertEquals('Planned', checkCustOa.Status__c, 'Order Allocation must NOT be updated by Apex during Initiate');
    }

    @IsTest
    static void testRecursiveParentOaliStatusShippedOnBulkInitiate() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SRC' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DST' LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Replenish source inventory
        Inventory__c sourceInv = [
            SELECT Id, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :locSource.Id AND Item__c = :item.Id
        ];
        sourceInv.Reserved_Sale_Order__c = 200;
        update sourceInv;

        // Create Parent OA + OALI + SR
        Order_Allocation__c custOa = new Order_Allocation__c(
            Supplying_Account__c = destAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Planned'
        );
        insert custOa;

        Supply_Request__c sr = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 30,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = destAcc.Id,
            Supplying_Account__c = sourceAcc.Id
        );
        insert sr;

        Supply_Request__c queriedSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :sr.Id LIMIT 1];

        Order_Allocation_Line_Item__c parentLine = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = custOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 30,
            Procurement_Qty_Planned__c = 30,
            Status__c = 'Planned',
            Supply_Request__c = queriedSr.Id
        );
        insert parentLine;

        Order_Allocation__c fulfillOa = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Planned'
        );
        insert fulfillOa;

        Order_Allocation_Line_Item__c fulfillLine = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = fulfillOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 30,
            Transfer_Qty_Planned__c = 30,
            Status__c = 'Ready to Ship',
            Supply_Request__c = queriedSr.Id,
            Source_SR_References__c = queriedSr.Name,
            Source_SR_Allocation__c = queriedSr.Name + ':30'
        );
        insert fulfillLine;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSource.Id,
            Destination_Inventory_Location__c = locDest.Id,
            From_Account__c = sourceAcc.Id,
            To_Account__c = destAcc.Id,
            Transfer_Qty__c = 30,
            Requested_Date__c = Date.today(),
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = fulfillLine.Id
        );
        insert transfer;

        Test.startTest();
        List<Map<String, String>> results = InventoryTransferPending.initiateTransfers(new List<Id>{ transfer.Id });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('In Transit', results[0].get('status'));

        Order_Allocation_Line_Item__c updatedFulfill = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillLine.Id];
        Order_Allocation_Line_Item__c updatedParent = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentLine.Id];
        System.assertEquals('Shipped', updatedFulfill.Status__c, 'Fulfill line must be Shipped');
        System.assertEquals('Shipped', updatedParent.Status__c, 'Parent line must be Shipped recursively');
    }

    @IsTest
    static void testTrueBulk200InitiateTransfers() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locSource = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SRC' LIMIT 1];
        Inventory_Location__c locDest = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'DST' LIMIT 1];
        Account sourceAcc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Account destAcc = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Replenish source inventory reserved quantity
        Inventory__c sourceInv = [
            SELECT Id, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :locSource.Id AND Item__c = :item.Id
        ];
        sourceInv.Reserved_Sale_Order__c = 1000;
        update sourceInv;

        Order_Allocation__c bulkAlloc = new Order_Allocation__c(
            Supplying_Account__c = sourceAcc.Id,
            Requesting_Account__c = destAcc.Id,
            Status__c = 'Draft'
        );
        insert bulkAlloc;

        List<Order_Allocation_Line_Item__c> oalis = new List<Order_Allocation_Line_Item__c>();
        for (Integer i = 0; i < 200; i++) {
            oalis.add(new Order_Allocation_Line_Item__c(
                Order_Allocation__c = bulkAlloc.Id,
                Item__c = item.Id,
                Ordered_Qty__c = 1,
                Transfer_Qty_Planned__c = 1,
                Status__c = 'Ready to Ship'
            ));
        }
        insert oalis;

        List<Inventory_Transfer__c> transfers = new List<Inventory_Transfer__c>();
        for (Integer i = 0; i < 200; i++) {
            transfers.add(new Inventory_Transfer__c(
                Item__c = item.Id,
                Source_Inventory_Location__c = locSource.Id,
                Destination_Inventory_Location__c = locDest.Id,
                From_Account__c = sourceAcc.Id,
                To_Account__c = destAcc.Id,
                Transfer_Qty__c = 1,
                Requested_Date__c = Date.today(),
                Status__c = 'Requested',
                Request_Type__c = 'Customer Demand',
                Order_Allocation_Line_Item__c = oalis[i].Id
            ));
        }
        insert transfers;

        List<Id> transferIds = new List<Id>();
        for (Inventory_Transfer__c t : transfers) {
            transferIds.add(t.Id);
        }

        Test.startTest();
        List<Map<String, String>> results = InventoryTransferPending.initiateTransfers(transferIds);
        Test.stopTest();

        System.assertEquals(200, results.size(), 'All 200 transfers should be processed');
        List<Inventory_Transfer__c> updatedTransfers = [SELECT Id, Status__c FROM Inventory_Transfer__c WHERE Id IN :transferIds];
        for (Inventory_Transfer__c t : updatedTransfers) {
            System.assertEquals('In Transit', t.Status__c);
        }
        List<Order_Allocation_Line_Item__c> updatedOalis = [SELECT Id, Status__c FROM Order_Allocation_Line_Item__c WHERE Id IN :oalis];
        for (Order_Allocation_Line_Item__c o : updatedOalis) {
            System.assertEquals('Shipped', o.Status__c);
        }
    }
}