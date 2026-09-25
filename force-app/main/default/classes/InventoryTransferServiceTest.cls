/**
 * @description Comprehensive unit tests for InventoryTransferService and
 *              OrderAllocationLineItemTriggerHandler partial transfer creation.
 *              Verifies support for multiple partial Inventory Transfers for the same OALI
 *              without relying on OALI Status__c, while ensuring duplicate prevention.
 */
@IsTest
public class InventoryTransferServiceTest {

    // =========================================================================
    // TEST DATA SETUP
    // =========================================================================

    @TestSetup
    static void setupTestData() {
        // 1. Create test Item
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
            Name = 'Mac Mini M2',
            Item_Code__c = 'MACMINI-M2',
            Base_Tax__c = 18,
            Default_Supply_Method__c = defaultSupplyMethod,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = unitOfMeasure,
            Target_Stock_Level__c = 500,
            Stock_Low_Level_Quantity__c = 10,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 200
        );
        insert item;

        // 2. Create Accounts in a single DML to minimize trigger SOQL
        Account dealerA = new Account(Name = 'Dealer A', Type = 'Dealer');
        Account retailerA = new Account(Name = 'Retailer A', Type = 'Retailer');
        Account retailerB = new Account(Name = 'Retailer B', Type = 'Retailer');
        Account distributorA = new Account(Name = 'Distributor A', Type = 'Distributor');
        insert new List<Account>{ dealerA, retailerA, retailerB, distributorA };

        // 3. Create Locations in a single DML
        Inventory_Location__c locDealer = new Inventory_Location__c(
            Name = 'Dealer Loc',
            Inventory_Location_Code__c = 'DLR-LOC',
            Account__c = dealerA.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locRetailerA = new Inventory_Location__c(
            Name = 'Retailer A Loc',
            Inventory_Location_Code__c = 'RET-A-LOC',
            Account__c = retailerA.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locRetailerB = new Inventory_Location__c(
            Name = 'Retailer B Loc',
            Inventory_Location_Code__c = 'RET-B-LOC',
            Account__c = retailerB.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locDistributor = new Inventory_Location__c(
            Name = 'Distributor Loc',
            Inventory_Location_Code__c = 'DIST-LOC',
            Account__c = distributorA.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locDealer, locRetailerA, locRetailerB, locDistributor };

        // 4. Create initial Inventory records
        Inventory__c invDealer = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locDealer.Id,
            Available__c = 0,
            Reserved_Sale_Order__c = 0
        );
        Inventory__c invRetailerA = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locRetailerA.Id,
            Available__c = 0,
            Reserved_Sale_Order__c = 0
        );
        insert new List<Inventory__c>{ invDealer, invRetailerA };

        // 5. Create Order Allocation
        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = dealerA.Id,
            Requesting_Account__c = retailerA.Id,
            Source_Location__c = locDealer.Id,
            Target_Location__c = locRetailerA.Id,
            Status__c = 'Draft'
        );
        insert oa;
    }

    // =========================================================================
    // UNIT TEST METHODS
    // =========================================================================

    /**
     * @description Verifies that transfer received quantities NEVER create inventory transfers,
     *              and that transfers are strictly created for Reserved and Procurement:
     * - Ordered_Qty__c = 100
     * - Reserved: Reserved_Qty_Planned__c = 50, Reserved_Quantity__c = 50
     * - Procurement: Procurement_Qty_Planned__c = 50, Procurement_Qty_Received__c = 0
     * - Transfer: Transfer_Qty_Planned__c = 50, Transfer_Qty_Received__c = 0
     * 1. Reserved stock fulfilled:
     *    -> Inventory Transfer #1 created: Dealer A -> Retailer A = 50
     * 2. Transfer stock arrives (Transfer_Qty_Received__c = 50):
     *    -> System must NEVER create a transfer for received transfer quantity (count remains 1).
     * 3. Procurement arrives (Procurement_Qty_Received__c = 50):
     *    -> System creates Inventory Transfer #2: Dealer A -> Retailer A = 50
     * 4. Duplicate prevention: repeated call creates no extra transfers (total remains 2).
     */
    @IsTest
    static void testExactMultiplePartialTransfers_SisterTransferAndProcurement() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Order_Allocation__c oa = [SELECT Id, Supplying_Account__c, Requesting_Account__c FROM Order_Allocation__c LIMIT 1];

        // Create OALI with 50 reserved, 50 procurement planned, 50 transfer planned
        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Qty_Planned__c = 50,
            Reserved_Quantity__c = 50,
            Procurement_Qty_Planned__c = 50,
            Procurement_Qty_Received__c = 0,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned'
        );
        insert oali;

        Test.startTest();

        // ---------------------------------------------------------------------
        // Step 1: Reserved quantity is eligible -> Transfer #1 created (50)
        // ---------------------------------------------------------------------
        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });

        List<Inventory_Transfer__c> transfersAfterPhase1 = [
            SELECT Id, Order_Allocation_Line_Item__c, From_Account__c, To_Account__c, Transfer_Qty__c, Status__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];

        Assert.areEqual(1, transfersAfterPhase1.size(), 'Exactly 1 Inventory Transfer should be created for reserved 50 units');
        Assert.areEqual(50, transfersAfterPhase1[0].Transfer_Qty__c, 'Transfer #1 quantity should be 50');
        Assert.areEqual(oa.Supplying_Account__c, transfersAfterPhase1[0].From_Account__c, 'From Account should be Dealer A');
        Assert.areEqual(oa.Requesting_Account__c, transfersAfterPhase1[0].To_Account__c, 'To Account should be Retailer A');
        Assert.areEqual('Requested', transfersAfterPhase1[0].Status__c, 'Transfer #1 should be in Requested status');

        // ---------------------------------------------------------------------
        // Step 2: Transfer arrives (Transfer_Qty_Received = 50)
        // System must NEVER create a transfer for transfer received quantity!
        // ---------------------------------------------------------------------
        oali.Transfer_Qty_Received__c = 50;
        update oali;

        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });

        List<Inventory_Transfer__c> transfersAfterTransferReceived = [
            SELECT Id
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        Assert.areEqual(1, transfersAfterTransferReceived.size(), 'Transfer received must NEVER create an Inventory Transfer (count remains 1)');

        // ---------------------------------------------------------------------
        // Step 3: Distributor A stock arrives (Procurement_Qty_Received = 50)
        // ---------------------------------------------------------------------
        oali.Status__c = 'Shipped';
        oali.Procurement_Qty_Received__c = 50;
        update oali;

        // System must create Inventory Transfer #2 for Procurement
        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });

        List<Inventory_Transfer__c> transfersAfterPhase2 = [
            SELECT Id, Order_Allocation_Line_Item__c, From_Account__c, To_Account__c, Transfer_Qty__c, Status__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
            ORDER BY CreatedDate ASC
        ];

        Assert.areEqual(2, transfersAfterPhase2.size(), 'A second Inventory Transfer must be created for procurement');
        Assert.areEqual(50, transfersAfterPhase2[1].Transfer_Qty__c, 'Transfer #2 quantity should be 50');
        Assert.areEqual(oa.Supplying_Account__c, transfersAfterPhase2[1].From_Account__c, 'Transfer #2 From Account should be Dealer A');
        Assert.areEqual(oa.Requesting_Account__c, transfersAfterPhase2[1].To_Account__c, 'Transfer #2 To Account should be Retailer A');

        Decimal totalTransferQty = transfersAfterPhase2[0].Transfer_Qty__c + transfersAfterPhase2[1].Transfer_Qty__c;
        Assert.areEqual(100, totalTransferQty, 'Total customer fulfillment transfers must equal the 100 units');

        // ---------------------------------------------------------------------
        // Step 4: Duplicate Prevention Check
        // ---------------------------------------------------------------------
        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });

        List<Inventory_Transfer__c> transfersAfterDupCheck = [
            SELECT Id
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        Assert.areEqual(2, transfersAfterDupCheck.size(), 'No duplicate transfers should be created when all eligible qty is already planned/fulfilled');

        Test.stopTest();
    }

    /**
     * @description Verifies partial reservation + partial procurement scenario:
     * - Ordered_Qty = 100
     * - Reserved_Qty_Planned__c = 40, Reserved_Quantity__c = 40
     * - Procurement_Qty_Planned__c = 60, Procurement_Qty_Received__c = 0 initially
     * - Verifies incomplete procurement (30 < 60) does NOT prematurely trigger Transfer #2.
     * - Verifies full procurement (60 == 60) triggers Transfer #2 with remaining 60.
     */
    @IsTest
    static void testPartialReservationAndProcurement() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Order_Allocation__c oa = [SELECT Id, Supplying_Account__c, Requesting_Account__c FROM Order_Allocation__c LIMIT 1];

        // 40 reserved immediately, 60 planned for procurement
        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Qty_Planned__c = 40,
            Reserved_Quantity__c = 40,
            Procurement_Qty_Planned__c = 60,
            Procurement_Qty_Received__c = 0,
            Transfer_Qty_Planned__c = 0,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned'
        );
        insert oali;

        Test.startTest();

        // 1. Initial creation for reserved stock (40)
        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });

        List<Inventory_Transfer__c> initialTransfers = [
            SELECT Id, Transfer_Qty__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        Assert.areEqual(1, initialTransfers.size(), 'Transfer #1 should be created for reserved 40 units');
        Assert.areEqual(40, initialTransfers[0].Transfer_Qty__c, 'Transfer #1 quantity should be 40');

        // 2. Partial incomplete procurement (only 30 received out of 60 planned)
        oali.Procurement_Qty_Received__c = 30;
        update oali;

        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });

        List<Inventory_Transfer__c> intermediateTransfers = [
            SELECT Id
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        Assert.areEqual(1, intermediateTransfers.size(), 'No second transfer should be created until procurement is fully received (30 != 60)');

        // 3. Complete procurement (60 received == 60 planned)
        oali.Procurement_Qty_Received__c = 60;
        oali.Status__c = 'Shipped'; // Even if already shipped
        update oali;

        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>{ oali.Id });

        List<Inventory_Transfer__c> finalTransfers = [
            SELECT Id, Transfer_Qty__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
            ORDER BY CreatedDate ASC
        ];
        Assert.areEqual(2, finalTransfers.size(), 'Second transfer should be created when procurement is fully received');
        Assert.areEqual(60, finalTransfers[1].Transfer_Qty__c, 'Transfer #2 quantity should be 60');

        Test.stopTest();
    }

    /**
     * @description Verifies trigger integration: when OALI is updated with new fulfillment quantity
     *              even while in 'Shipped' status, the trigger handler initiates transfer creation.
     *              Also verifies that updating Transfer_Qty_Received__c does NOT create transfers.
     */
    @IsTest
    static void testTriggerFiresTransferCreationOnFulfillmentUpdateEvenWhenShipped() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Order_Allocation__c oa = [SELECT Id FROM Order_Allocation__c LIMIT 1];

        // OALI with 50 reserved quantity
        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Qty_Planned__c = 50,
            Reserved_Quantity__c = 50,
            Procurement_Qty_Planned__c = 50,
            Procurement_Qty_Received__c = 0,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Draft'
        );
        insert oali;

        Test.startTest();

        // 1. Transitioning to 'Ready to Ship' fires trigger to create Transfer #1 (50) for Reserved
        oali.Status__c = 'Ready to Ship';
        update oali;

        List<Inventory_Transfer__c> step1Transfers = [
            SELECT Id, Transfer_Qty__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        Assert.areEqual(1, step1Transfers.size(), 'Trigger should create Transfer #1 on Ready to Ship transition');
        Assert.areEqual(50, step1Transfers[0].Transfer_Qty__c, 'Transfer #1 qty should be 50');

        // 2. Transitioning to 'Shipped'
        oali.Status__c = 'Shipped';
        update oali;

        // 3. Updating Transfer_Qty_Received__c must NOT create another transfer via trigger
        oali.Transfer_Qty_Received__c = 50;
        update oali;

        List<Inventory_Transfer__c> step2Transfers = [
            SELECT Id
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        Assert.areEqual(1, step2Transfers.size(), 'Trigger must NOT create transfers for Transfer_Qty_Received__c');

        // 4. Procurement arrives: update Procurement_Qty_Received__c = 50
        // Trigger should detect fulfillment qty update and create Transfer #2 despite 'Shipped' status
        oali.Procurement_Qty_Received__c = 50;
        update oali;

        List<Inventory_Transfer__c> step3Transfers = [
            SELECT Id, Transfer_Qty__c
            FROM Inventory_Transfer__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
            ORDER BY CreatedDate ASC
        ];
        Assert.areEqual(2, step3Transfers.size(), 'Trigger should create Transfer #2 when procurement fulfillment qty is updated even if Shipped');
        Assert.areEqual(50, step3Transfers[1].Transfer_Qty__c, 'Transfer #2 qty should be 50');

        Test.stopTest();
    }

    /**
     * @description Tests edge cases: null/empty sets, retailer helper methods.
     */
    @IsTest
    static void testEdgeCasesAndHelpers() {
        Test.startTest();

        // Null and empty safety
        InventoryTransferService.createInventoryTransfersForOALIs(null);
        InventoryTransferService.createInventoryTransfersForOALIs(new Set<Id>());

        // Helper method validations
        Assert.isFalse(InventoryTransferService.isRetailerAccount(null), 'Null OALI should return false');
        Assert.isFalse(InventoryTransferService.isRetailerRequestingAccount(null), 'Null OALI should return false');

        Test.stopTest();
    }
}