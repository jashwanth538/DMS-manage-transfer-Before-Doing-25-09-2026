/**
 * @description Comprehensive unit tests for DMSFulfillmentTraceController.
 *              Tests upstream root discovery, multi-branch downstream traversal (Reserved,
 *              Procurement, Transfer), reconciliation, search, and edge/cycle handling.
 */
@IsTest
public class DMSFulfillmentTraceControllerTest {

    @TestSetup
    static void setupTestData() {
        // 1. Create Item
        String defaultSupplyMethod = 'In-house';
        List<Schema.PicklistEntry> supplyEntries = Item__c.Default_Supply_Method__c.getDescribe().getPicklistValues();
        if (!supplyEntries.isEmpty()) {
            defaultSupplyMethod = supplyEntries[0].getValue();
        }

        Item__c item = new Item__c(
            Name = 'MacBook Pro 16',
            Item_Code__c = 'MBP-16',
            Base_Tax__c = 18,
            Default_Supply_Method__c = defaultSupplyMethod,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Target_Stock_Level__c = 500
        );
        insert item;

        // 2. Create Accounts
        Account dealer = new Account(Name = 'Primary Dealer', Type = 'Dealer');
        Account retailer = new Account(Name = 'City Retailer', Type = 'Retailer');
        Account distributor = new Account(Name = 'National Distributor', Type = 'Distributor');
        insert new List<Account>{ dealer, retailer, distributor };

        // 3. Create Locations
        Inventory_Location__c dealerLoc = new Inventory_Location__c(
            Name = 'Dealer Main Warehouse',
            Inventory_Location_Code__c = 'DLR-WH',
            Account__c = dealer.Id,
            Is_Active__c = true
        );
        Inventory_Location__c retailerLoc = new Inventory_Location__c(
            Name = 'Retailer Store Loc',
            Inventory_Location_Code__c = 'RET-LOC',
            Account__c = retailer.Id,
            Is_Active__c = true
        );
        Inventory_Location__c distLoc = new Inventory_Location__c(
            Name = 'Distributor Central Hub',
            Inventory_Location_Code__c = 'DIST-HUB',
            Account__c = distributor.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ dealerLoc, retailerLoc, distLoc };

        // 4. Create Root Supply Request (Retailer -> Dealer, 100 Qty)
        Supply_Request__c rootSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 100,
            Received_Qty__c = 20,
            Requesting_Account__c = retailer.Id,
            Supplying_Account__c = dealer.Id,
            Source_Location__c = dealerLoc.Id,
            Target_Location__c = retailerLoc.Id,
            Request_Type__c = 'Customer Demand',
            Status__c = 'Partially Received'
        );
        insert rootSR;

        // 5. Create Order Allocation & OALI fulfilling the Root SR
        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = dealer.Id,
            Requesting_Account__c = retailer.Id,
            Source_Location__c = dealerLoc.Id,
            Target_Location__c = retailerLoc.Id,
            Status__c = 'Planned',
            Order_Allocation_Date__c = Date.today()
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Qty_Planned__c = 20,
            Reserved_Quantity__c = 20,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Procurement_Qty_Planned__c = 30,
            Procurement_Qty_Received__c = 0,
            Supply_Request__c = rootSR.Id,
            Source_SR_References__c = rootSR.Name,
            Status__c = 'Planned'
        );
        insert oali;

        // 6. Create Reserved Branch: Inventory Reservation (20 units)
        Inventory_Reservation__c ir = new Inventory_Reservation__c(
            Order_Allocation_Line_Item__c = oali.Id,
            Item__c = item.Id,
            Supplying_Account__c = dealer.Id,
            Requesting_Account__c = retailer.Id,
            Inventory_Location__c = dealerLoc.Id,
            Requested_Qty__c = 20,
            Reserved_Qty__c = 20,
            Status__c = 'Active',
            Reservation_Date__c = Date.today()
        );
        insert ir;

        // 7. Create Transfer Branch: Transfer SR (50 units) + Inventory Transfer
        Supply_Request__c transferSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Requesting_Account__c = dealer.Id,
            Supplying_Account__c = distributor.Id,
            Source_Location__c = distLoc.Id,
            Target_Location__c = dealerLoc.Id,
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = oali.Id,
            Supply_Request__c = rootSR.Id,
            Status__c = 'In Transit'
        );
        insert transferSR;

        Inventory_Transfer__c it = new Inventory_Transfer__c(
            Order_Allocation_Line_Item__c = oali.Id,
            Item__c = item.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Received_Qty__c = 0,
            From_Account__c = distributor.Id,
            To_Account__c = dealer.Id,
            Source_Inventory_Location__c = distLoc.Id,
            Destination_Inventory_Location__c = dealerLoc.Id,
            Request_Type__c = 'Transfer SR',
            Status__c = 'In Transit',
            Requested_Date__c = Date.today()
        );
        insert it;

        // 8. Create Procurement Branch: Procurement SR (30 units) + PO + POLI
        Supply_Request__c procSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 30,
            Received_Qty__c = 0,
            Requesting_Account__c = dealer.Id,
            Supplying_Account__c = distributor.Id,
            Source_Location__c = distLoc.Id,
            Target_Location__c = dealerLoc.Id,
            Request_Type__c = 'Purchase SR',
            Order_Allocation_Line_Item__c = oali.Id,
            Supply_Request__c = rootSR.Id,
            Status__c = 'Open'
        );
        insert procSR;

        Purchase_Order__c po = new Purchase_Order__c(
            Supplying_Account__c = distributor.Id,
            Requesting_Account__c = dealer.Id,
            Source_Location__c = distLoc.Id,
            Target_Location__c = dealerLoc.Id,
            Sales_Allocation__c = oa.Id,
            Status__c = 'Submitted',
            PO_Date__c = Date.today()
        );
        insert po;

        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Sales_Allocation_Line_Item__c = oali.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 30,
            Received_Qty__c = 0,
            Status__c = 'Open'
        );
        insert poli;
    }

    @IsTest
    static void testGetTrace_StartingFromRootSR() {
        Supply_Request__c rootSR = [SELECT Id, Name FROM Supply_Request__c WHERE Request_Type__c = 'Customer Demand' LIMIT 1];

        Test.startTest();
        DMSFulfillmentTraceController.TraceResult result = DMSFulfillmentTraceController.getTrace(rootSR.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Trace should succeed');
        Assert.areEqual(rootSR.Id, (Id)result.summary.rootRecordId, 'Root record should match Root SR');
        Assert.areEqual(100, result.summary.totalRequiredQty, 'Total required should be 100');
        Assert.areEqual(20, result.summary.totalReservedQty, 'Total reserved should be 20');
        Assert.areEqual(50, result.summary.totalTransferQty, 'Total transfer should be 50');
        Assert.areEqual(30, result.summary.totalProcurementQty, 'Total procurement should be 30');
        Assert.isNotNull(result.rootNode, 'Root node must exist');
        Assert.isFalse(result.rootNode.children.isEmpty(), 'Root node should have child OALI');

        // Check node map entries
        Assert.isTrue(result.allNodesMap.containsKey(String.valueOf(rootSR.Id)), 'All nodes map should contain root SR');
    }

    @IsTest
    static void testGetTrace_StartingFromOALI() {
        Order_Allocation_Line_Item__c oali = [SELECT Id FROM Order_Allocation_Line_Item__c LIMIT 1];
        Supply_Request__c rootSR = [SELECT Id FROM Supply_Request__c WHERE Request_Type__c = 'Customer Demand' LIMIT 1];

        Test.startTest();
        // Passing child OALI should discover root SR upstream
        DMSFulfillmentTraceController.TraceResult result = DMSFulfillmentTraceController.getTrace(oali.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Trace should succeed when starting from OALI');
        Assert.areEqual(rootSR.Id, (Id)result.summary.rootRecordId, 'Upstream traversal should resolve to Root SR');
    }

    @IsTest
    static void testGetTrace_StartingFromOrderAllocation() {
        Order_Allocation__c oa = [SELECT Id FROM Order_Allocation__c LIMIT 1];
        Supply_Request__c rootSR = [SELECT Id FROM Supply_Request__c WHERE Request_Type__c = 'Customer Demand' LIMIT 1];

        Test.startTest();
        DMSFulfillmentTraceController.TraceResult result = DMSFulfillmentTraceController.getTrace(oa.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Trace should succeed when starting from OA');
        Assert.areEqual(rootSR.Id, (Id)result.summary.rootRecordId, 'Should resolve upstream root SR via OALI');
    }

    @IsTest
    static void testGetTrace_StartingFromInventoryTransfer() {
        Inventory_Transfer__c it = [SELECT Id FROM Inventory_Transfer__c LIMIT 1];
        Supply_Request__c rootSR = [SELECT Id FROM Supply_Request__c WHERE Request_Type__c = 'Customer Demand' LIMIT 1];

        Test.startTest();
        DMSFulfillmentTraceController.TraceResult result = DMSFulfillmentTraceController.getTrace(it.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Trace should succeed when starting from Inventory Transfer');
        Assert.areEqual(rootSR.Id, (Id)result.summary.rootRecordId, 'Should resolve upstream from IT to Root SR');
    }

    @IsTest
    static void testGetTraceBySearch_ValidNameAndId() {
        Supply_Request__c rootSR = [SELECT Id, Name FROM Supply_Request__c WHERE Request_Type__c = 'Customer Demand' LIMIT 1];

        Test.startTest();
        // Search by Name
        DMSFulfillmentTraceController.TraceResult nameResult = DMSFulfillmentTraceController.getTraceBySearch(rootSR.Name);
        // Search by Id string
        DMSFulfillmentTraceController.TraceResult idResult = DMSFulfillmentTraceController.getTraceBySearch(rootSR.Id);
        Test.stopTest();

        Assert.isTrue(nameResult.success, 'Search by name should succeed');
        Assert.areEqual(rootSR.Id, (Id)nameResult.summary.rootRecordId, 'Root ID should match');
        Assert.isTrue(idResult.success, 'Search by ID string should succeed');
    }

    @IsTest
    static void testReconciliationAndMismatch() {
        Order_Allocation__c oa = [SELECT Id FROM Order_Allocation__c LIMIT 1];
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];

        // Create an intentional mismatch OALI: Required 50, but planned channels = 80
        Order_Allocation_Line_Item__c mismatchOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Reserved_Qty_Planned__c = 30,
            Reserved_Quantity__c = 30,
            Transfer_Qty_Planned__c = 50,
            Status__c = 'Planned'
        );
        insert mismatchOali;

        Test.startTest();
        DMSFulfillmentTraceController.TraceResult result = DMSFulfillmentTraceController.getTrace(mismatchOali.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Trace should succeed');
        // Summary should detect mismatch
        Assert.isTrue(result.summary.hasMismatch, 'Summary should flag mismatch');
    }

    @IsTest
    static void testNegativeAndEdgeCases() {
        Test.startTest();
        // Null ID
        DMSFulfillmentTraceController.TraceResult nullResult = DMSFulfillmentTraceController.getTrace(null);
        Assert.isFalse(nullResult.success, 'Null ID should fail gracefully');

        // Blank search
        DMSFulfillmentTraceController.TraceResult blankSearchResult = DMSFulfillmentTraceController.getTraceBySearch('   ');
        Assert.isFalse(blankSearchResult.success, 'Blank search should fail gracefully');

        // Non-existent search
        DMSFulfillmentTraceController.TraceResult notFoundResult = DMSFulfillmentTraceController.getTraceBySearch('NON_EXISTENT_RECORD_9999');
        Assert.isFalse(notFoundResult.success, 'Non-existent record search should fail gracefully');
        Test.stopTest();
    }

    @IsTest
    static void testOrderAllocationWithDirectPOWithoutOALI() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Primary Dealer' LIMIT 1];
        Account distributor = [SELECT Id FROM Account WHERE Name = 'National Distributor' LIMIT 1];
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c dealerLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Dealer Main Warehouse' LIMIT 1];
        Inventory_Location__c distLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Distributor Central Hub' LIMIT 1];

        // Create an Order Allocation without OALIs (like SA - 00441)
        Order_Allocation__c directOa = new Order_Allocation__c(
            Supplying_Account__c = dealer.Id,
            Source_Location__c = dealerLoc.Id,
            Customer_Name__c = 'Pulla Rao(Customer)',
            Status__c = 'Confirmed Planning',
            Order_Allocation_Date__c = Date.today()
        );
        insert directOa;

        // Create Purchase Order linked directly to this OA
        Purchase_Order__c directPo = new Purchase_Order__c(
            Supplying_Account__c = distributor.Id,
            Requesting_Account__c = dealer.Id,
            Source_Location__c = distLoc.Id,
            Target_Location__c = dealerLoc.Id,
            Sales_Allocation__c = directOa.Id,
            Status__c = 'Draft',
            PO_Date__c = Date.today()
        );
        insert directPo;

        // Create POLI with Sales_Allocation_Line_Item__c = null
        Purchase_Order_Line_Item__c directPoli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = directPo.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 20,
            Received_Qty__c = 0,
            Status__c = 'Open'
        );
        insert directPoli;

        Test.startTest();
        // Trace starting from Order Allocation
        DMSFulfillmentTraceController.TraceResult oaResult = DMSFulfillmentTraceController.getTrace(directOa.Id);

        // Trace starting from POLI without OALI lookup (should resolve upstream to directOa)
        DMSFulfillmentTraceController.TraceResult poliResult = DMSFulfillmentTraceController.getTrace(directPoli.Id);
        Test.stopTest();

        Assert.isTrue(oaResult.success, 'Trace on direct OA should succeed');
        Assert.areEqual(20, oaResult.summary.totalProcurementQty, 'Procurement qty should be 20');
        Assert.areEqual(20, oaResult.summary.totalRequiredQty, 'Required qty should default to 20');
        Assert.areEqual(0, oaResult.summary.totalReceivedQty, 'Received qty should be 0');
        Assert.areEqual(20, oaResult.summary.totalRemainingQty, 'Remaining qty should be 20');
        Assert.isFalse(oaResult.rootNode.children.isEmpty(), 'Root node should contain child POLI');
        Assert.isFalse(oaResult.reconciliations.isEmpty(), 'Reconciliations should have direct PO entry');

        Assert.isTrue(poliResult.success, 'Trace starting from direct POLI should succeed');
        Assert.areEqual(directOa.Id, (Id)poliResult.summary.rootRecordId, 'POLI should resolve upstream to direct OA');
    }

    @IsTest
    static void testSearchWithDifferentSpacing() {
        Order_Allocation__c oa = [SELECT Id, Name FROM Order_Allocation__c LIMIT 1];

        Test.startTest();
        // Search with space-normalized variations
        String noSpaceName = oa.Name.replace(' ', '');
        DMSFulfillmentTraceController.TraceResult res1 = DMSFulfillmentTraceController.getTraceBySearch(noSpaceName);
        DMSFulfillmentTraceController.TraceResult res2 = DMSFulfillmentTraceController.getTraceBySearch(oa.Name);
        Test.stopTest();

        Assert.isTrue(res1.success, 'Search without space should succeed: ' + noSpaceName);
        Assert.isTrue(res2.success, 'Search with original name should succeed: ' + oa.Name);
    }
}