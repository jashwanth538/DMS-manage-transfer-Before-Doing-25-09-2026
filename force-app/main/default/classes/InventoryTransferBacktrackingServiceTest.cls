/**
 * @description Comprehensive unit tests for InventoryTransferBacktrackingService covering all 12 scenarios:
 *  1. Single-level chain with subtype mismatch (STOP)
 *  2. Two-level chain with exact subtype match (CONTINUE)
 *  3. Three-level chain with mismatch at level 3 (STOP at mismatch)
 *  4. Multiple source SR references with FIFO allocation
 *  5. Partial quantity propagation and status updates
 *  6. Full quantity propagation and terminal status transitions
 *  7. Already completed OALI skips without regression
 *  8. Multiple transfers accepted in bulk
 *  9. Circular references safe termination (cycle protection)
 *  10. Source SR exists without OALI (OALI-first rule skips SR)
 *  11. OALI exists but has no remaining capacity (SKIP)
 *  12. Subtype reference missing/unpopulated (STOP)
 */
@IsTest
public class InventoryTransferBacktrackingServiceTest {

    @TestSetup
    static void setupTestData() {
        // Base Item
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

        // Base Accounts
        Account dealerAcc = new Account(Name = 'Dealer Hub', Type = 'Dealer');
        Account retailerAcc1 = new Account(Name = 'Retailer Alpha', Type = 'Retailer');
        Account retailerAcc2 = new Account(Name = 'Retailer Beta', Type = 'Retailer');
        insert new List<Account>{ dealerAcc, retailerAcc1, retailerAcc2 };

        // Base Locations
        Inventory_Location__c locDealer = new Inventory_Location__c(
            Name = 'Dealer Loc',
            Inventory_Location_Code__c = 'DLR-LOC-01',
            Account__c = dealerAcc.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locRetailer1 = new Inventory_Location__c(
            Name = 'Retailer 1 Loc',
            Inventory_Location_Code__c = 'RET-LOC-01',
            Account__c = retailerAcc1.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locRetailer2 = new Inventory_Location__c(
            Name = 'Retailer 2 Loc',
            Inventory_Location_Code__c = 'RET-LOC-02',
            Account__c = retailerAcc2.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locDealer, locRetailer1, locRetailer2 };

        // Base Inventories
        Inventory__c invDealer = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locDealer.Id,
            Available__c = 100,
            Transit_Out_Quantity__c = 0,
            Reserved_Sale_Order__c = 0
        );
        Inventory__c invRet1 = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locRetailer1.Id,
            Available__c = 0,
            Transit_In_Quantity__c = 50,
            Reserved_Sale_Order__c = 0
        );
        insert new List<Inventory__c>{ invDealer, invRet1 };
    }

    // =========================================================================
    // HELPER METHODS FOR TEST CREATION
    // =========================================================================

    private static Item__c getItem() {
        return [SELECT Id FROM Item__c LIMIT 1];
    }

    private static Map<String, Account> getAccounts() {
        Map<String, Account> accMap = new Map<String, Account>();
        for (Account a : [SELECT Id, Name FROM Account]) {
            accMap.put(a.Name, a);
        }
        return accMap;
    }

    private static Map<String, Inventory_Location__c> getLocations() {
        Map<String, Inventory_Location__c> locMap = new Map<String, Inventory_Location__c>();
        for (Inventory_Location__c l : [SELECT Id, Name FROM Inventory_Location__c]) {
            locMap.put(l.Name, l);
        }
        return locMap;
    }

    private static Id transferSrRtId = null;
    private static Id purchaseSrRtId = null;

    private static Id getTransferSrRtId() {
        if (transferSrRtId == null) {
            Schema.RecordTypeInfo rti = Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName().get('Transfer_Supply_Request');
            transferSrRtId = (rti != null) ? rti.getRecordTypeId() : null;
        }
        return transferSrRtId;
    }

    private static Id getPurchaseSrRtId() {
        if (purchaseSrRtId == null) {
            Schema.RecordTypeInfo rti = Schema.SObjectType.Supply_Request__c.getRecordTypeInfosByDeveloperName().get('Purchase_Supply_Request');
            purchaseSrRtId = (rti != null) ? rti.getRecordTypeId() : null;
        }
        return purchaseSrRtId;
    }


    // =========================================================================
    // 1. TEST 1: Single-level chain with subtype mismatch (STOP)
    // =========================================================================
    @IsTest
    static void testSingleLevelChainSubtypeMismatch_StopsTraversal() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        // 1. Create Source SR and Source OALI
        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Sub_Request_Type__c = 'Dealer → Retailer'
        );
        insert sourceSr;

        Order_Allocation__c sourceOa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert sourceOa;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = sourceOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = sourceSr.Id
        );
        insert sourceOali;

        sourceSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        // 2. Create Direct Current SR with subtype 'Retailer to Retailer'
        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        // 3. Create Direct OALI referencing source SR with mismatched subtype ('Dealer to Retailer')
        Order_Allocation__c directOa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Retailer Beta').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Retailer 2 Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert directOa;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = directOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':50',
            Source_SR_Sub_Type_References__c = sourceSr.Name + ' : Dealer to Retailer'
        );
        insert directOali;

        // 4. Create Transfer
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // Verification: Direct OALI updated, but Source OALI and Source SR stopped / NOT updated
        Order_Allocation_Line_Item__c refreshedDirectOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :directOali.Id];
        Assert.areEqual(50, refreshedDirectOali.Transfer_Qty_Received__c, 'Direct OALI received quantity should be updated');

        Order_Allocation_Line_Item__c refreshedSourceOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Assert.areEqual(0, refreshedSourceOali.Transfer_Qty_Received__c, 'Source OALI should NOT be updated due to subtype mismatch STOP');

        Supply_Request__c refreshedSourceSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];
        Assert.areEqual(0, refreshedSourceSr.Received_Qty__c, 'Source SR should NOT be updated due to subtype mismatch STOP');
    }

    // =========================================================================
    // 2. TEST 2: Two-level chain with exact subtype match (CONTINUE)
    // =========================================================================
    @IsTest
    static void testTwoLevelChainSubtypeMatch_ContinuesTraversal() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert sourceSr;

        Order_Allocation__c sourceOa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert sourceOa;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = sourceOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = sourceSr.Id
        );
        insert sourceOali;

        sourceSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation__c directOa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Retailer Beta').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Retailer 2 Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert directOa;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = directOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':50',
            Source_SR_Sub_Type_References__c = sourceSr.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // Verification: Both Direct and Source should be updated
        Order_Allocation_Line_Item__c refreshedDirectOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :directOali.Id];
        Assert.areEqual(50, refreshedDirectOali.Transfer_Qty_Received__c, 'Direct OALI received quantity should be 50');

        Order_Allocation_Line_Item__c refreshedSourceOali = [SELECT Id, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Assert.areEqual(50, refreshedSourceOali.Procurement_Qty_Received__c, 'Source OALI procurement received quantity should be 50');

        Supply_Request__c refreshedSourceSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];
        Assert.areEqual(50, refreshedSourceSr.Received_Qty__c, 'Source SR received quantity should be 50');
        Assert.areEqual('Completed', refreshedSourceSr.Status__c, 'Source SR status should transition to Completed');
    }

    // =========================================================================
    // 3. TEST 3: Three-level chain with mismatch at level 3 (STOP at mismatch)
    // =========================================================================
    @IsTest
    static void testThreeLevelChain_StopsAtLevel3Mismatch() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        // Level 2 (Root): Subtype 'Plant to Dealer'
        Supply_Request__c rootSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Purchase SR',
            Sub_Request_Type__c = 'Dealer → Retailer'
        );
        insert rootSr;

        Order_Allocation__c rootOa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert rootOa;

        Order_Allocation_Line_Item__c rootOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = rootOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Procurement_Qty_Planned__c = 50,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = rootSr.Id
        );
        insert rootOali;

        rootSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :rootSr.Id];

        // Level 1: Subtype 'Retailer to Retailer', references Root with MISMATCHED reference ('Dealer to Retailer')
        Supply_Request__c midSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert midSr;

        Order_Allocation__c midOa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert midOa;

        Order_Allocation_Line_Item__c midOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = midOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = midSr.Id,
            Source_SR_References__c = rootSr.Name,
            Source_SR_Allocation__c = rootSr.Name + ':50',
            Source_SR_Sub_Type_References__c = rootSr.Name + ' : Dealer to Retailer' // Mismatch with midSr 'Retailer to Retailer'
        );
        insert midOali;

        midSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :midSr.Id];

        // Level 0 (Direct): Subtype 'Retailer to Retailer', references Mid SR with EXACT match ('Retailer to Retailer')
        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation__c directOa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Retailer Beta').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Retailer 2 Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert directOa;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = directOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = midSr.Name,
            Source_SR_Allocation__c = midSr.Name + ':50',
            Source_SR_Sub_Type_References__c = midSr.Name + ' : Retailer to Retailer' // Match!
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // Level 0 and Level 1 should be updated; Level 2 should NOT be updated
        Order_Allocation_Line_Item__c refMidOali = [SELECT Id, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :midOali.Id];
        Assert.areEqual(50, refMidOali.Transfer_Qty_Received__c, 'Mid OALI (Level 1) should be updated');

        Supply_Request__c refMidSr = [SELECT Id, Received_Qty__c FROM Supply_Request__c WHERE Id = :midSr.Id];
        Assert.areEqual(50, refMidSr.Received_Qty__c, 'Mid SR (Level 1) should be updated');

        Order_Allocation_Line_Item__c refRootOali = [SELECT Id, Procurement_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :rootOali.Id];
        Assert.areEqual(0, refRootOali.Procurement_Qty_Received__c, 'Root OALI (Level 2) should NOT be updated due to Level 2 subtype mismatch');

        Supply_Request__c refRootSr = [SELECT Id, Received_Qty__c FROM Supply_Request__c WHERE Id = :rootSr.Id];
        Assert.areEqual(0, refRootSr.Received_Qty__c, 'Root SR (Level 2) should NOT be updated due to Level 2 subtype mismatch');
    }

    // =========================================================================
    // 4. TEST 4: Multiple source SR references with FIFO allocation
    // =========================================================================
    @IsTest
    static void testMultipleSourceSrReferences_FIFOPropagation() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c srA = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 30,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        Supply_Request__c srB = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 20,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert new List<Supply_Request__c>{ srA, srB };

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oaliA = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 30,
            Transfer_Qty_Planned__c = 30,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = srA.Id
        );
        Order_Allocation_Line_Item__c oaliB = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 20,
            Transfer_Qty_Planned__c = 20,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = srB.Id
        );
        insert new List<Order_Allocation_Line_Item__c>{ oaliA, oaliB };

        srA = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :srA.Id];
        srB = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :srB.Id];

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = srA.Name + ', ' + srB.Name,
            Source_SR_Allocation__c = srA.Name + ':30, ' + srB.Name + ':20',
            Source_SR_Sub_Type_References__c = srA.Name + ' : Retailer to Retailer, ' + srB.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Supply_Request__c refA = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :srA.Id];
        Supply_Request__c refB = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :srB.Id];
        Assert.areEqual(30, refA.Received_Qty__c, 'SR A should receive 30');
        Assert.areEqual('Completed', refA.Status__c, 'SR A should be Completed');
        Assert.areEqual(20, refB.Received_Qty__c, 'SR B should receive 20');
        Assert.areEqual('Completed', refB.Status__c, 'SR B should be Completed');
    }

    // =========================================================================
    // 5. TEST 5: Partial quantity propagation
    // =========================================================================
    @IsTest
    static void testPartialQuantityPropagation() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert sourceSr;

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = sourceSr.Id
        );
        insert sourceOali;

        sourceSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':100',
            Source_SR_Sub_Type_References__c = sourceSr.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 20,
            In_Transit_Qty__c = 20,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Supply_Request__c refSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];
        Assert.areEqual(20, refSr.Received_Qty__c, 'Source SR should receive partial qty 20');
        Assert.areEqual('Partially Received', refSr.Status__c, 'Source SR status should transition to Partially Received');

        Order_Allocation_Line_Item__c refOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Assert.areEqual(20, refOali.Transfer_Qty_Received__c, 'Source OALI should have 20 received');
        Assert.areEqual('Awaiting Inventory', refOali.Status__c, 'Source OALI should transition to Awaiting Inventory');
    }

    // =========================================================================
    // 6. TEST 6: Full quantity propagation and terminal status transitions
    // =========================================================================
    @IsTest
    static void testFullQuantityPropagation_StatusTransitions() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert sourceSr;

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = sourceSr.Id
        );
        insert sourceOali;

        sourceSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':50',
            Source_SR_Sub_Type_References__c = sourceSr.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Supply_Request__c refSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];
        Assert.areEqual(50, refSr.Received_Qty__c, 'Source SR should be fully received (50)');
        Assert.areEqual('Completed', refSr.Status__c, 'Source SR status should transition to Completed');

        Order_Allocation_Line_Item__c refOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Assert.areEqual(50, refOali.Transfer_Qty_Received__c, 'Source OALI should have 50 received');
        Assert.areEqual('Ready to Ship', refOali.Status__c, 'Source OALI status should transition to Ready to Ship');
    }

    // =========================================================================
    // 7. TEST 7: Already completed OALI skips without regression
    // =========================================================================
    @IsTest
    static void testAlreadyCompletedOali_SkipsWithoutRegression() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 50,
            Status__c = 'Completed',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert sourceSr;

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Delivered'
        );
        insert oa;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 50,
            Status__c = 'Delivered',
            Supply_Request__c = sourceSr.Id
        );
        insert sourceOali;

        sourceSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':50',
            Source_SR_Sub_Type_References__c = sourceSr.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Order_Allocation_Line_Item__c refOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Assert.areEqual(50, refOali.Transfer_Qty_Received__c, 'Already completed OALI should remain at 50');
        Assert.areEqual('Delivered', refOali.Status__c, 'Already completed OALI status should remain Delivered');
    }

    // =========================================================================
    // 8. TEST 8: Multiple transfers accepted in bulk
    // =========================================================================
    @IsTest
    static void testMultipleTransfersAccepted_BulkTransaction() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        Supply_Request__c directSr1 = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 30,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        Supply_Request__c directSr2 = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 40,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert new List<Supply_Request__c>{ directSr1, directSr2 };

        Order_Allocation_Line_Item__c directOali1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 30,
            Transfer_Qty_Planned__c = 30,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr1.Id
        );
        Order_Allocation_Line_Item__c directOali2 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 40,
            Transfer_Qty_Planned__c = 40,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr2.Id
        );
        insert new List<Order_Allocation_Line_Item__c>{ directOali1, directOali2 };

        Inventory_Transfer__c transfer1 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 30,
            In_Transit_Qty__c = 30,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali1.Id
        );
        Inventory_Transfer__c transfer2 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 40,
            In_Transit_Qty__c = 40,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali2.Id
        );
        insert new List<Inventory_Transfer__c>{ transfer1, transfer2 };

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer1.Id, transfer2.Id });
        Test.stopTest();

        List<Inventory_Transfer__c> refTransfers = [SELECT Id, Status__c, Received_Qty__c FROM Inventory_Transfer__c WHERE Id IN (:transfer1.Id, :transfer2.Id)];
        Assert.areEqual(2, refTransfers.size());
        Assert.areEqual('Received', refTransfers[0].Status__c);
        Assert.areEqual('Received', refTransfers[1].Status__c);
    }

    // =========================================================================
    // 9. TEST 9: Circular references safe termination
    // =========================================================================
    @IsTest
    static void testCircularReferences_CycleProtectionTerminates() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c srA = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        Supply_Request__c srB = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert new List<Supply_Request__c>{ srA, srB };

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        srA = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :srA.Id];
        srB = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :srB.Id];

        // Mutually circular references
        Order_Allocation_Line_Item__c oaliA = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = srA.Id,
            Source_SR_References__c = srB.Name,
            Source_SR_Allocation__c = srB.Name + ':50',
            Source_SR_Sub_Type_References__c = srB.Name + ' : Retailer to Retailer'
        );
        Order_Allocation_Line_Item__c oaliB = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = srB.Id,
            Source_SR_References__c = srA.Name,
            Source_SR_Allocation__c = srA.Name + ':50',
            Source_SR_Sub_Type_References__c = srA.Name + ' : Retailer to Retailer'
        );
        insert new List<Order_Allocation_Line_Item__c>{ oaliA, oaliB };

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = oaliA.Id
        );
        insert transfer;

        Test.startTest();
        // Should terminate normally without throwing System.LimitException or infinite loop
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Order_Allocation_Line_Item__c refA = [SELECT Id, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :oaliA.Id];
        Assert.areEqual(50, refA.Transfer_Qty_Received__c, 'OALI A should be updated once');
    }

    // =========================================================================
    // 10. TEST 10: Source SR exists without OALI (OALI-first rule skips SR)
    // =========================================================================
    @IsTest
    static void testSourceSrExistsWithoutOali_SkipsSr() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        // Orphan SR with no OALI
        Supply_Request__c orphanSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert orphanSr;
        orphanSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :orphanSr.Id];

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = orphanSr.Name,
            Source_SR_Allocation__c = orphanSr.Name + ':50',
            Source_SR_Sub_Type_References__c = orphanSr.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Supply_Request__c refOrphan = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :orphanSr.Id];
        Assert.areEqual(0, refOrphan.Received_Qty__c, 'Orphan SR without an OALI must NOT be updated');
    }

    // =========================================================================
    // 11. TEST 11: OALI exists but has no remaining capacity (SKIP)
    // =========================================================================
    @IsTest
    static void testOaliHasNoRemainingCapacity_SkipsUpdate() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Purchase SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert sourceSr;

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        // OALI is 100% fulfilled already
        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Procurement_Qty_Planned__c = 50,
            Procurement_Qty_Received__c = 50,
            Status__c = 'Ready to Ship',
            Supply_Request__c = sourceSr.Id
        );
        insert sourceOali;

        sourceSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':50',
            Source_SR_Sub_Type_References__c = sourceSr.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Order_Allocation_Line_Item__c refOali = [SELECT Id, Procurement_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Assert.areEqual(50, refOali.Procurement_Qty_Received__c, 'Zero-capacity OALI should not receive additional quantity');

        Supply_Request__c refSr = [SELECT Id, Received_Qty__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];
        Assert.areEqual(0, refSr.Received_Qty__c, 'Source SR should not be updated when OALI has 0 capacity');
    }

    // =========================================================================
    // 12. TEST 12: Subtype reference missing / unpopulated (STOP)
    // =========================================================================
    @IsTest
    static void testSubtypeReferenceMissing_StopsTraversal() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert sourceSr;

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = sourceSr.Id
        );
        insert sourceOali;

        sourceSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        Supply_Request__c directSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer'
        );
        insert directSr;

        // Source_SR_Sub_Type_References__c is left NULL/unpopulated
        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directSr.Id,
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':50',
            Source_SR_Sub_Type_References__c = null
        );
        insert directOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Retailer 2 Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Supply_Request__c refSr = [SELECT Id, Received_Qty__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];
        Assert.areEqual(0, refSr.Received_Qty__c, 'Source SR should not be updated when subtype reference is missing');

        Order_Allocation_Line_Item__c refOali = [SELECT Id, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Assert.areEqual(0, refOali.Transfer_Qty_Received__c, 'Source OALI should not be updated when subtype reference is missing');
    }

    // =========================================================================
    // TEST 13: Shipped OALI fulfilled by reservation transitions to Delivered
    //          and marks standalone Source SR Completed upon transfer receipt
    // =========================================================================
    @IsTest
    static void testShippedReservedOaliTransferReceipt_MarksDeliveredAndUpdatesSourceSr() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        // 1. Create Standalone Source Supply Request (e.g. Purchase SR from ABC Distributors to XYZ Motors)
        Supply_Request__c sourceSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Ordered',
            Request_Type__c = 'Purchase SR',
            Sub_Request_Type__c = 'Retailer → Retailer',
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id
        );
        insert sourceSr;
        sourceSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :sourceSr.Id];

        // 2. Create Order Allocation and OALI (fulfilled from reservation, Status = 'Shipped')
        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = accs.get('Dealer Hub').Id,
            Requesting_Account__c = accs.get('Retailer Alpha').Id,
            Source_Location__c = locs.get('Dealer Loc').Id,
            Target_Location__c = locs.get('Retailer 1 Loc').Id,
            Status__c = 'Shipped'
        );
        insert oa;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Reserved_Qty_Planned__c = 100,
            Reserved_Quantity__c = 100,
            Transfer_Qty_Planned__c = 0,
            Transfer_Qty_Received__c = 0,
            Procurement_Qty_Planned__c = 0,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Source_SR_References__c = sourceSr.Name,
            Source_SR_Allocation__c = sourceSr.Name + ':100',
            Source_SR_Sub_Type_References__c = sourceSr.Name + ' : Retailer to Retailer'
        );
        insert directOali;

        // 3. Create Delivery Inventory Transfer in 'In Transit'
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locs.get('Dealer Loc').Id,
            Destination_Inventory_Location__c = locs.get('Retailer 1 Loc').Id,
            Transfer_Qty__c = 100,
            In_Transit_Qty__c = 100,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer;

        // 4. Accept Transfer
        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 5. Verify Direct OALI transitioned to 'Delivered'
        Order_Allocation_Line_Item__c refreshedOali = [
            SELECT Id, Status__c, Reserved_Quantity__c, Transfer_Qty_Received__c
            FROM Order_Allocation_Line_Item__c
            WHERE Id = :directOali.Id
        ];
        Assert.areEqual('Delivered', refreshedOali.Status__c, 'Direct OALI should transition to Delivered upon transfer receipt');

        // 6. Verify Source Supply Request updated to 'Completed' with full Received_Qty
        Supply_Request__c refreshedSr = [
            SELECT Id, Received_Qty__c, Status__c
            FROM Supply_Request__c
            WHERE Id = :sourceSr.Id
        ];
        Assert.areEqual(100, refreshedSr.Received_Qty__c, 'Source SR should receive all 100 units');
        Assert.areEqual('Completed', refreshedSr.Status__c, 'Source SR status should transition to Completed');
    }

    // =========================================================================
    // BUSINESS TEST CASE 1: Retailer-to-Retailer Direct Fulfillment (FULL_CHAIN)
    // Retailer B -> Retailer A directly satisfies Retailer A's customer demand chain.
    // =========================================================================
    @IsTest
    static void testTestCase1_RetailerToRetailer_DirectFulfillment_FullChain() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Account retA = accs.get('Retailer Alpha');
        Account retB = accs.get('Retailer Beta');
        Inventory_Location__c locRetA = locs.get('Retailer 1 Loc');
        Inventory_Location__c locRetB = locs.get('Retailer 2 Loc');

        // 1. Retailer A Customer Demand SR & OALI (Parent / Source requirement)
        Supply_Request__c custDemandSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Sub_Request_Type__c = 'Retailer → Retailer',
            Requesting_Account__c = retA.Id,
            Target_Location__c = locRetA.Id
        );
        insert custDemandSr;
        custDemandSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :custDemandSr.Id];

        Order_Allocation__c custDemandOa = new Order_Allocation__c(
            Requesting_Account__c = retA.Id,
            Target_Location__c = locRetA.Id,
            Status__c = 'Draft'
        );
        insert custDemandOa;

        Order_Allocation_Line_Item__c custDemandOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = custDemandOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Procurement_Qty_Planned__c = 50,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Awaiting Inventory',
            Supply_Request__c = custDemandSr.Id
        );
        insert custDemandOali;

        // 2. Direct Peer Transfer SR & OALI (Retailer B -> Retailer A)
        Supply_Request__c directPeerSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Retailer → Retailer',
            Requesting_Account__c = retA.Id,
            Supplying_Account__c = retB.Id,
            Target_Location__c = locRetA.Id
        );
        insert directPeerSr;

        Order_Allocation__c directOa = new Order_Allocation__c(
            Supplying_Account__c = retB.Id,
            Requesting_Account__c = retA.Id,
            Source_Location__c = locRetB.Id,
            Target_Location__c = locRetA.Id,
            Status__c = 'Draft'
        );
        insert directOa;

        Order_Allocation_Line_Item__c directPeerOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = directOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = directPeerSr.Id,
            Source_SR_References__c = custDemandSr.Name,
            Source_SR_Allocation__c = custDemandSr.Name + ':50',
            Source_SR_Sub_Type_References__c = custDemandSr.Name + ' : Retailer to Retailer'
        );
        insert directPeerOali;

        // 3. Inventory Transfer: Retailer B -> Retailer A
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            From_Account__c = retB.Id,
            To_Account__c = retA.Id,
            Source_Inventory_Location__c = locRetB.Id,
            Destination_Inventory_Location__c = locRetA.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directPeerOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 4. Assertions: Both Direct and Parent Customer Demand are updated (FULL_CHAIN)
        Order_Allocation_Line_Item__c refDirectOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :directPeerOali.Id];
        Assert.areEqual(50, refDirectOali.Transfer_Qty_Received__c, 'Direct Peer OALI should be received in full');
        Assert.areEqual('Delivered', refDirectOali.Status__c, 'Direct Peer OALI should be Delivered');

        Supply_Request__c refDirectSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :directPeerSr.Id];
        Assert.areEqual(50, refDirectSr.Received_Qty__c, 'Direct Peer SR should be fully received');
        Assert.areEqual('Completed', refDirectSr.Status__c, 'Direct Peer SR should be Completed');

        Order_Allocation_Line_Item__c refCustOali = [SELECT Id, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :custDemandOali.Id];
        Assert.areEqual(50, refCustOali.Procurement_Qty_Received__c, 'Customer Demand OALI should receive 50 units');
        Assert.areEqual('Ready to Ship', refCustOali.Status__c, 'Customer Demand OALI should be Ready to Ship');

        Supply_Request__c refCustSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :custDemandSr.Id];
        Assert.areEqual(50, refCustSr.Received_Qty__c, 'Customer Demand SR should receive 50 units');
        Assert.areEqual('Completed', refCustSr.Status__c, 'Customer Demand SR should be Completed');
    }

    // =========================================================================
    // BUSINESS TEST CASE 2: Dealer-to-Dealer Sourcing (ONE_LEVEL)
    // Dealer B -> Dealer A: Same account type, but intermediate sourcing.
    // Must update ONLY direct Dealer records and STOP before downstream Retailer.
    // =========================================================================
    @IsTest
    static void testTestCase2_DealerToDealer_Sourcing_OneLevelStop() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Account dealerA = accs.get('Dealer Hub');
        Account retA = accs.get('Retailer Alpha');
        Inventory_Location__c locDealerA = locs.get('Dealer Loc');
        Inventory_Location__c locRetA = locs.get('Retailer 1 Loc');

        // Create Dealer B and its location
        Account dealerB = new Account(Name = 'Dealer Beta', Type = 'Dealer');
        insert dealerB;
        Inventory_Location__c locDealerB = new Inventory_Location__c(
            Name = 'Dealer Beta Loc',
            Account__c = dealerB.Id,
            Is_Active__c = true
        );
        insert locDealerB;

        // 1. Downstream Retailer SR & OALI (Retailer A requesting from Dealer A)
        Supply_Request__c retDemandSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Sub_Request_Type__c = 'Dealer → Retailer',
            Requesting_Account__c = retA.Id,
            Supplying_Account__c = dealerA.Id,
            Target_Location__c = locRetA.Id
        );
        insert retDemandSr;
        retDemandSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :retDemandSr.Id];

        Order_Allocation__c retOa = new Order_Allocation__c(
            Supplying_Account__c = dealerA.Id,
            Requesting_Account__c = retA.Id,
            Source_Location__c = locDealerA.Id,
            Target_Location__c = locRetA.Id,
            Status__c = 'Draft'
        );
        insert retOa;

        Order_Allocation_Line_Item__c downstreamRetOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = retOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = retDemandSr.Id
        );
        insert downstreamRetOali;

        // 2. Direct Sourcing SR & OALI (Dealer A sourcing from Dealer B)
        Supply_Request__c dealerSourcingSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Dealer → Dealer',
            Requesting_Account__c = dealerA.Id,
            Supplying_Account__c = dealerB.Id,
            Target_Location__c = locDealerA.Id
        );
        insert dealerSourcingSr;

        Order_Allocation__c sourcingOa = new Order_Allocation__c(
            Supplying_Account__c = dealerB.Id,
            Requesting_Account__c = dealerA.Id,
            Source_Location__c = locDealerB.Id,
            Target_Location__c = locDealerA.Id,
            Status__c = 'Draft'
        );
        insert sourcingOa;

        Order_Allocation_Line_Item__c directSourcingOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = sourcingOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = dealerSourcingSr.Id,
            Source_SR_References__c = retDemandSr.Name,
            Source_SR_Allocation__c = retDemandSr.Name + ':100',
            Source_SR_Sub_Type_References__c = retDemandSr.Name + ' : Dealer to Retailer'
        );
        insert directSourcingOali;

        // 3. Inventory Transfer: Dealer B -> Dealer A (Same Account Type = Dealer)
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            From_Account__c = dealerB.Id,
            To_Account__c = dealerA.Id,
            Source_Inventory_Location__c = locDealerB.Id,
            Destination_Inventory_Location__c = locDealerA.Id,
            Transfer_Qty__c = 100,
            In_Transit_Qty__c = 100,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directSourcingOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 4. Assertions: Direct Dealer OALI and SR updated (Level 0)
        Order_Allocation_Line_Item__c refDirectOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :directSourcingOali.Id];
        Assert.areEqual(100, refDirectOali.Transfer_Qty_Received__c, 'Direct Dealer sourcing OALI should be received in full');
        Assert.areEqual('Delivered', refDirectOali.Status__c, 'Direct Dealer sourcing OALI should be Delivered');

        Supply_Request__c refDirectSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :dealerSourcingSr.Id];
        Assert.areEqual(100, refDirectSr.Received_Qty__c, 'Direct Dealer sourcing SR should be fully received');
        Assert.areEqual('Completed', refDirectSr.Status__c, 'Direct Dealer sourcing SR should be Completed');

        // 5. Assertions: Downstream Retailer records MUST NOT be updated (ONE_LEVEL STOP)
        Order_Allocation_Line_Item__c refRetOali = [SELECT Id, Transfer_Qty_Received__c, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :downstreamRetOali.Id];
        Assert.areEqual(0, refRetOali.Transfer_Qty_Received__c, 'Downstream Retailer OALI Transfer Qty must NOT update');
        Assert.areEqual(0, refRetOali.Procurement_Qty_Received__c, 'Downstream Retailer OALI Procurement Qty must NOT update');
        Assert.areEqual('Planned', refRetOali.Status__c, 'Downstream Retailer OALI Status must remain Planned');

        Supply_Request__c refRetSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :retDemandSr.Id];
        Assert.areEqual(0, refRetSr.Received_Qty__c, 'Downstream Retailer SR Received Qty must NOT update');
        Assert.areEqual('Open', refRetSr.Status__c, 'Downstream Retailer SR Status must remain Open');
    }

    // =========================================================================
    // BUSINESS TEST CASE 3: OEM-to-Distributor Sourcing (ONE_LEVEL)
    // OEM -> Distributor A: Inbound procurement to central warehouse.
    // Must update ONLY direct Distributor procurement records and STOP before downstream Dealer.
    // =========================================================================
    @IsTest
    static void testTestCase3_OEMToDistributor_Sourcing_OneLevelStop() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Account dealerA = accs.get('Dealer Hub');
        Inventory_Location__c locDealerA = locs.get('Dealer Loc');

        Account distAcc = new Account(Name = 'Distributor Hub', Type = 'Distributor');
        Account oemAcc = new Account(Name = 'OEM Corp', Type = 'OEM');
        insert new List<Account>{ distAcc, oemAcc };

        Inventory_Location__c locDist = new Inventory_Location__c(Name = 'Dist Loc', Account__c = distAcc.Id, Is_Active__c = true);
        Inventory_Location__c locOem = new Inventory_Location__c(Name = 'OEM Plant Loc', Account__c = oemAcc.Id, Is_Active__c = true);
        insert new List<Inventory_Location__c>{ locDist, locOem };

        // 1. Downstream Dealer SR & OALI (Dealer A requesting from Distributor)
        Supply_Request__c dealerSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 200,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Distributor→ Dealer',
            Requesting_Account__c = dealerA.Id,
            Supplying_Account__c = distAcc.Id,
            Target_Location__c = locDealerA.Id
        );
        insert dealerSr;
        dealerSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :dealerSr.Id];

        Order_Allocation__c dealerOa = new Order_Allocation__c(
            Supplying_Account__c = distAcc.Id,
            Requesting_Account__c = dealerA.Id,
            Source_Location__c = locDist.Id,
            Target_Location__c = locDealerA.Id,
            Status__c = 'Draft'
        );
        insert dealerOa;

        Order_Allocation_Line_Item__c downstreamDealerOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = dealerOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 200,
            Transfer_Qty_Planned__c = 200,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = dealerSr.Id
        );
        insert downstreamDealerOali;

        // 2. Direct Procurement SR & OALI (Distributor procuring from OEM)
        Supply_Request__c distProcurementSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 200,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Purchase SR',
            Sub_Request_Type__c = 'OEM → Distributor',
            Requesting_Account__c = distAcc.Id,
            Supplying_Account__c = oemAcc.Id,
            Target_Location__c = locDist.Id
        );
        insert distProcurementSr;

        Order_Allocation__c distProcurementOa = new Order_Allocation__c(
            Supplying_Account__c = oemAcc.Id,
            Requesting_Account__c = distAcc.Id,
            Source_Location__c = locOem.Id,
            Target_Location__c = locDist.Id,
            Status__c = 'Draft'
        );
        insert distProcurementOa;

        Order_Allocation_Line_Item__c directProcurementOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = distProcurementOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 200,
            Procurement_Qty_Planned__c = 200,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = distProcurementSr.Id,
            Source_SR_References__c = dealerSr.Name,
            Source_SR_Allocation__c = dealerSr.Name + ':200',
            Source_SR_Sub_Type_References__c = dealerSr.Name + ' : Distributor→ Dealer'
        );
        insert directProcurementOali;

        // 3. Inventory Transfer: OEM -> Distributor A
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            From_Account__c = oemAcc.Id,
            To_Account__c = distAcc.Id,
            Source_Inventory_Location__c = locOem.Id,
            Destination_Inventory_Location__c = locDist.Id,
            Transfer_Qty__c = 200,
            In_Transit_Qty__c = 200,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directProcurementOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 4. Assertions: Direct Distributor Procurement OALI & SR updated (Level 0)
        Order_Allocation_Line_Item__c refDirectOali = [SELECT Id, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :directProcurementOali.Id];
        Assert.areEqual(200, refDirectOali.Procurement_Qty_Received__c, 'Direct Distributor procurement OALI should receive 200 units');
        Assert.areEqual('Delivered', refDirectOali.Status__c, 'Direct Distributor procurement OALI should be Delivered');

        Supply_Request__c refDirectSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :distProcurementSr.Id];
        Assert.areEqual(200, refDirectSr.Received_Qty__c, 'Direct Distributor procurement SR should be fully received');
        Assert.areEqual('Completed', refDirectSr.Status__c, 'Direct Distributor procurement SR should be Completed');

        // 5. Assertions: Downstream Dealer records MUST NOT be updated (ONE_LEVEL STOP)
        Order_Allocation_Line_Item__c refDealerOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :downstreamDealerOali.Id];
        Assert.areEqual(0, refDealerOali.Transfer_Qty_Received__c, 'Downstream Dealer OALI must NOT receive quantity');
        Assert.areEqual('Planned', refDealerOali.Status__c, 'Downstream Dealer OALI must remain Planned');

        Supply_Request__c refDealerSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :dealerSr.Id];
        Assert.areEqual(0, refDealerSr.Received_Qty__c, 'Downstream Dealer SR must NOT receive quantity');
        Assert.areEqual('Open', refDealerSr.Status__c, 'Downstream Dealer SR must remain Open');
    }

    // =========================================================================
    // BUSINESS TEST CASE 4: Distributor-to-Dealer Fulfillment (ONE_LEVEL)
    // Distributor A -> Dealer A: Inbound fulfillment for Dealer A warehouse.
    // Must update Dealer A's direct fulfillment records and STOP before Retailer A.
    // =========================================================================
    @IsTest
    static void testTestCase4_DistributorToDealer_Fulfillment_OneLevelStop() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Account dealerA = accs.get('Dealer Hub');
        Account retA = accs.get('Retailer Alpha');
        Inventory_Location__c locDealerA = locs.get('Dealer Loc');
        Inventory_Location__c locRetA = locs.get('Retailer 1 Loc');

        Account distAcc = new Account(Name = 'Distributor Hub', Type = 'Distributor');
        insert distAcc;
        Inventory_Location__c locDist = new Inventory_Location__c(Name = 'Dist Loc', Account__c = distAcc.Id, Is_Active__c = true);
        insert locDist;

        // 1. Downstream Retailer SR & OALI (Retailer A requesting from Dealer A)
        Supply_Request__c retSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 75,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Sub_Request_Type__c = 'Dealer → Retailer',
            Requesting_Account__c = retA.Id,
            Supplying_Account__c = dealerA.Id,
            Target_Location__c = locRetA.Id
        );
        insert retSr;
        retSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :retSr.Id];

        Order_Allocation__c retOa = new Order_Allocation__c(
            Supplying_Account__c = dealerA.Id,
            Requesting_Account__c = retA.Id,
            Source_Location__c = locDealerA.Id,
            Target_Location__c = locRetA.Id,
            Status__c = 'Draft'
        );
        insert retOa;

        Order_Allocation_Line_Item__c downstreamRetOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = retOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 75,
            Transfer_Qty_Planned__c = 75,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = retSr.Id
        );
        insert downstreamRetOali;

        // 2. Direct SR & OALI (Dealer A requesting from Distributor A)
        Supply_Request__c dealerSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 75,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Distributor→ Dealer',
            Requesting_Account__c = dealerA.Id,
            Supplying_Account__c = distAcc.Id,
            Target_Location__c = locDealerA.Id
        );
        insert dealerSr;

        Order_Allocation__c distToDealerOa = new Order_Allocation__c(
            Supplying_Account__c = distAcc.Id,
            Requesting_Account__c = dealerA.Id,
            Source_Location__c = locDist.Id,
            Target_Location__c = locDealerA.Id,
            Status__c = 'Draft'
        );
        insert distToDealerOa;

        Order_Allocation_Line_Item__c directDistToDealerOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = distToDealerOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 75,
            Transfer_Qty_Planned__c = 75,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = dealerSr.Id,
            Source_SR_References__c = retSr.Name,
            Source_SR_Allocation__c = retSr.Name + ':75',
            Source_SR_Sub_Type_References__c = retSr.Name + ' : Dealer → Retailer'
        );
        insert directDistToDealerOali;

        // 3. Inventory Transfer: Distributor A -> Dealer A
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            From_Account__c = distAcc.Id,
            To_Account__c = dealerA.Id,
            Source_Inventory_Location__c = locDist.Id,
            Destination_Inventory_Location__c = locDealerA.Id,
            Transfer_Qty__c = 75,
            In_Transit_Qty__c = 75,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directDistToDealerOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 4. Assertions: Direct Dealer fulfillment records updated (Level 0)
        Order_Allocation_Line_Item__c refDirectOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :directDistToDealerOali.Id];
        Assert.areEqual(75, refDirectOali.Transfer_Qty_Received__c, 'Direct Dist-to-Dealer OALI should be received in full');
        Assert.areEqual('Delivered', refDirectOali.Status__c, 'Direct Dist-to-Dealer OALI should be Delivered');

        Supply_Request__c refDirectSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :dealerSr.Id];
        Assert.areEqual(75, refDirectSr.Received_Qty__c, 'Direct Dealer SR should be fully received');
        Assert.areEqual('Completed', refDirectSr.Status__c, 'Direct Dealer SR should be Completed');

        // 5. Assertions: Downstream Retailer records MUST NOT be updated (ONE_LEVEL STOP)
        Order_Allocation_Line_Item__c refRetOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :downstreamRetOali.Id];
        Assert.areEqual(0, refRetOali.Transfer_Qty_Received__c, 'Downstream Retailer OALI must NOT receive quantity');
        Assert.areEqual('Planned', refRetOali.Status__c, 'Downstream Retailer OALI must remain Planned');

        Supply_Request__c refRetSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :retSr.Id];
        Assert.areEqual(0, refRetSr.Received_Qty__c, 'Downstream Retailer SR must NOT receive quantity');
        Assert.areEqual('Open', refRetSr.Status__c, 'Downstream Retailer SR must remain Open');
    }

    // =========================================================================
    // BUSINESS TEST CASE 5: Dealer-to-Retailer Terminal Fulfillment (FULL_CHAIN)
    // Dealer A -> Retailer A: Physical goods arrive at destination Retailer A,
    // directly satisfying Retailer A's terminal Customer Demand SR/OALI.
    // =========================================================================
    @IsTest
    static void testTestCase5_DealerToRetailer_TerminalFulfillment_FullChain() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Map<String, Inventory_Location__c> locs = getLocations();

        Account dealerA = accs.get('Dealer Hub');
        Account retA = accs.get('Retailer Alpha');
        Inventory_Location__c locDealerA = locs.get('Dealer Loc');
        Inventory_Location__c locRetA = locs.get('Retailer 1 Loc');

        // 1. Retailer A Customer Demand SR & OALI (Terminal demand node at Retailer A)
        Supply_Request__c custDemandSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 60,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Sub_Request_Type__c = 'Dealer → Retailer',
            Requesting_Account__c = retA.Id,
            Target_Location__c = locRetA.Id
        );
        insert custDemandSr;
        custDemandSr = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :custDemandSr.Id];

        Order_Allocation__c custDemandOa = new Order_Allocation__c(
            Requesting_Account__c = retA.Id,
            Target_Location__c = locRetA.Id,
            Status__c = 'Draft'
        );
        insert custDemandOa;

        Order_Allocation_Line_Item__c custDemandOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = custDemandOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 60,
            Procurement_Qty_Planned__c = 60,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Awaiting Inventory',
            Supply_Request__c = custDemandSr.Id
        );
        insert custDemandOali;

        // 2. Direct SR & OALI (Retailer A requesting from Dealer A)
        Supply_Request__c retFromDealerSr = new Supply_Request__c(
            Item__c = item.Id,
                        RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 60,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Sub_Request_Type__c = 'Dealer → Retailer',
            Requesting_Account__c = retA.Id,
            Supplying_Account__c = dealerA.Id,
            Target_Location__c = locRetA.Id
        );
        insert retFromDealerSr;

        Order_Allocation__c dealerToRetOa = new Order_Allocation__c(
            Supplying_Account__c = dealerA.Id,
            Requesting_Account__c = retA.Id,
            Source_Location__c = locDealerA.Id,
            Target_Location__c = locRetA.Id,
            Status__c = 'Draft'
        );
        insert dealerToRetOa;

        Order_Allocation_Line_Item__c directDealerToRetOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = dealerToRetOa.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 60,
            Transfer_Qty_Planned__c = 60,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = retFromDealerSr.Id,
            Source_SR_References__c = custDemandSr.Name,
            Source_SR_Allocation__c = custDemandSr.Name + ':60',
            Source_SR_Sub_Type_References__c = custDemandSr.Name + ' : Dealer → Retailer'
        );
        insert directDealerToRetOali;

        // 3. Inventory Transfer: Dealer A -> Retailer A
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            From_Account__c = dealerA.Id,
            To_Account__c = retA.Id,
            Source_Inventory_Location__c = locDealerA.Id,
            Destination_Inventory_Location__c = locRetA.Id,
            Transfer_Qty__c = 60,
            In_Transit_Qty__c = 60,
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = directDealerToRetOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 4. Assertions: Direct Tier Fulfillment updated (Level 0)
        Order_Allocation_Line_Item__c refDirectOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :directDealerToRetOali.Id];
        Assert.areEqual(60, refDirectOali.Transfer_Qty_Received__c, 'Direct Dealer-to-Retailer OALI should receive 60 units');
        Assert.areEqual('Delivered', refDirectOali.Status__c, 'Direct Dealer-to-Retailer OALI should be Delivered');

        Supply_Request__c refDirectSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :retFromDealerSr.Id];
        Assert.areEqual(60, refDirectSr.Received_Qty__c, 'Direct Retailer SR should receive 60 units');
        Assert.areEqual('Completed', refDirectSr.Status__c, 'Direct Retailer SR should be Completed');

        // 5. Assertions: Terminal Customer Demand updated (FULL_CHAIN Propagates)
        Order_Allocation_Line_Item__c refCustOali = [SELECT Id, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :custDemandOali.Id];
        Assert.areEqual(60, refCustOali.Procurement_Qty_Received__c, 'Customer Demand OALI should receive 60 units');
        Assert.areEqual('Ready to Ship', refCustOali.Status__c, 'Customer Demand OALI should transition to Ready to Ship');

        Supply_Request__c refCustSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :custDemandSr.Id];
        Assert.areEqual(60, refCustSr.Received_Qty__c, 'Customer Demand SR should receive 60 units');
        Assert.areEqual('Completed', refCustSr.Status__c, 'Customer Demand SR should transition to Completed');
    }

    // =========================================================================
    // 18. TEST 18: Retailer -> Dealer -> Distributor Procurement Roll-Up
    // Requirement:
    // - Retailer demand: 100 units (SR-001) -> Dealer OA-001 / OALI-001 (Ordered=100, Reserved=10, Procurement Remaining=90)
    // - Dealer creates procurement: 90 units (SR-002) -> Distributor OA-002 / OALI-002 (Ordered=90)
    // - Distributor fulfills SR-002 via Inventory Transfer (Distributor -> Dealer, 90 units)
    // - Upon Dealer acceptance:
    //     * Direct OALI-002: Received += 90, Status = Delivered
    //     * Direct SR-002: Received += 90, Status = Completed
    //     * Parent OALI-001: Procurement_Qty_Received__c += 90, Total Secured = 100
    //     * Parent OALI-001: Status != Delivered (Status = 'Ready to Ship')
    //     * Customer SR-001: Status = 'Open', Received_Qty__c = 0 (Retailer has NOT received goods yet)
    // - Then Dealer creates & initiates Inventory Transfer to Retailer (100 units)
    // - Upon Retailer acceptance:
    //     * Parent OALI-001: Status = 'Delivered', Transfer_Qty_Received__c = 100
    //     * Customer SR-001: Status = 'Completed', Received_Qty__c = 100
    // =========================================================================
    @IsTest
    static void testRetailerDealerDistributorProcurementRollup_DoesNotMarkCustomerOaliDelivered() {
        Item__c item = getItem();

        // 1. Setup Accounts
        Account retA = new Account(Name = 'Retailer Demand Acc', Type = 'Retailer');
        Account dealerA = new Account(Name = 'Dealer Mid Hub', Type = 'Dealer');
        Account distA = new Account(Name = 'Distributor Supply Hub', Type = 'Distributor');
        insert new List<Account>{ retA, dealerA, distA };

        // 2. Setup Locations
        Inventory_Location__c locRet = new Inventory_Location__c(
            Name = 'Loc Retailer A',
            Inventory_Location_Code__c = 'LOC-RET-DEMAND',
            Account__c = retA.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locDealer = new Inventory_Location__c(
            Name = 'Loc Dealer Hub',
            Inventory_Location_Code__c = 'LOC-DLR-MID',
            Account__c = dealerA.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locDist = new Inventory_Location__c(
            Name = 'Loc Dist Hub',
            Inventory_Location_Code__c = 'LOC-DIST-SUPPLY',
            Account__c = distA.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locRet, locDealer, locDist };

        // 3. Setup Inventories:
        // - Dealer has 10 units reserved for this order
        // - Distributor has 90 units reserved to transfer
        Inventory__c invDealer = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locDealer.Id,
            Available__c = 0,
            Reserved_Sale_Order__c = 10,
            Transit_In_Quantity__c = 0,
            Transit_Out_Quantity__c = 0
        );
        Inventory__c invDist = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locDist.Id,
            Available__c = 0,
            Reserved_Sale_Order__c = 90,
            Transit_In_Quantity__c = 0,
            Transit_Out_Quantity__c = 0
        );
        Inventory__c invRet = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locRet.Id,
            Available__c = 0,
            Reserved_Sale_Order__c = 0,
            Transit_In_Quantity__c = 0,
            Transit_Out_Quantity__c = 0
        );
        insert new List<Inventory__c>{ invDealer, invDist, invRet };

        // Step 1: Retailer Demand (SR-001)
        Supply_Request__c sr001 = new Supply_Request__c(
            RecordTypeId = getTransferSrRtId(),
            Item__c = item.Id,
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Sub_Request_Type__c = 'Dealer → Retailer',
            Requesting_Account__c = retA.Id,
            Supplying_Account__c = dealerA.Id,
            Target_Location__c = locRet.Id
        );
        insert sr001;
        sr001 = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :sr001.Id];

        // Dealer creates OA-001 & OALI-001
        Order_Allocation__c oa001 = new Order_Allocation__c(
            Supplying_Account__c = dealerA.Id,
            Requesting_Account__c = retA.Id,
            Source_Location__c = locDealer.Id,
            Target_Location__c = locRet.Id,
            Status__c = 'Draft'
        );
        insert oa001;

        Order_Allocation_Line_Item__c oali001 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa001.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 10,
            Procurement_Qty_Planned__c = 90,
            Procurement_Qty_Received__c = 0,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Awaiting Inventory',
            Supply_Request__c = sr001.Id
        );
        insert oali001;

        // Step 2: Dealer creates Procurement SR-002 for remaining 90 units
        Supply_Request__c sr002 = new Supply_Request__c(
            RecordTypeId = getPurchaseSrRtId(),
            Item__c = item.Id,
            Requested_Qty__c = 90,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Purchase SR',
            Sub_Request_Type__c = 'Distributor → Dealer',
            Requesting_Account__c = dealerA.Id,
            Supplying_Account__c = distA.Id,
            Target_Location__c = locDealer.Id,
            Order_Allocation_Line_Item__c = oali001.Id,
            Supply_Request__c = sr001.Id
        );
        insert sr002;
        sr002 = [SELECT Id, Name, Sub_Request_Type__c FROM Supply_Request__c WHERE Id = :sr002.Id];

        // Step 3: Distributor fulfills SR-002 via OA-002 & OALI-002
        Order_Allocation__c oa002 = new Order_Allocation__c(
            Supplying_Account__c = distA.Id,
            Requesting_Account__c = dealerA.Id,
            Source_Location__c = locDist.Id,
            Target_Location__c = locDealer.Id,
            Status__c = 'Draft'
        );
        insert oa002;

        Order_Allocation_Line_Item__c oali002 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa002.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 90,
            Transfer_Qty_Planned__c = 90,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = sr002.Id,
            Source_SR_References__c = sr001.Name,
            Source_SR_Allocation__c = sr001.Name + ':90',
            Source_SR_Sub_Type_References__c = sr001.Name + ' : Dealer → Retailer'
        );
        insert oali002;

        // Distributor creates and initiates transfer to Dealer
        Inventory_Transfer__c transferDistToDealer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locDist.Id,
            Destination_Inventory_Location__c = locDealer.Id,
            From_Account__c = distA.Id,
            To_Account__c = dealerA.Id,
            Transfer_Qty__c = 90,
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = oali002.Id
        );
        insert transferDistToDealer;

        // Initiate transfer (Distributor -> Dealer)
        InventoryTransferPending.initiateTransfer(transferDistToDealer.Id);

        // Step 4: Dealer accepts Inventory Transfer
        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transferDistToDealer.Id);
        Test.stopTest();

        // --- ASSERTIONS AFTER DISTRIBUTOR -> DEALER TRANSFER ACCEPTED ---
        // 1. Direct Procurement Records Updated:
        Order_Allocation_Line_Item__c refOali002 = [
            SELECT Id, Status__c, Transfer_Qty_Received__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :oali002.Id
        ];
        Assert.areEqual('Delivered', refOali002.Status__c, 'Direct Distributor->Dealer OALI should be Delivered');
        Assert.areEqual(90, refOali002.Transfer_Qty_Received__c, 'Direct Distributor->Dealer OALI received qty should be 90');

        Supply_Request__c refSr002 = [
            SELECT Id, Status__c, Received_Qty__c 
            FROM Supply_Request__c 
            WHERE Id = :sr002.Id
        ];
        Assert.areEqual('Completed', refSr002.Status__c, 'Direct procurement SR-002 should be Completed');
        Assert.areEqual(90, refSr002.Received_Qty__c, 'Direct procurement SR-002 received qty should be 90');

        // 2. Parent Customer Fulfillment OALI (OALI-001) Quantity Rolled Up:
        Order_Allocation_Line_Item__c refOali001 = [
            SELECT Id, Status__c, Reserved_Quantity__c, Procurement_Qty_Received__c, 
                   Transfer_Qty_Received__c, Secured_Qty__c, Remaining_Qty__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :oali001.Id
        ];
        Assert.areEqual(10, refOali001.Reserved_Quantity__c, 'Parent OALI-001 reserved qty should remain 10');
        Assert.areEqual(90, refOali001.Procurement_Qty_Received__c, 'Parent OALI-001 procurement qty received should be 90');
        Assert.areEqual(100, refOali001.Secured_Qty__c, 'Parent OALI-001 secured qty should be 100 (10 + 90)');
        Assert.areEqual(0, refOali001.Remaining_Qty__c, 'Parent OALI-001 remaining qty should be 0');

        // CRITICAL BUSINESS RULE: Parent OALI must NOT become Delivered yet!
        Assert.areNotEqual('Delivered', refOali001.Status__c, 'Parent customer OALI must NOT be Delivered yet');
        Assert.areEqual('Ready to Ship', refOali001.Status__c, 'Parent customer OALI should transition to Ready to Ship');

        // 3. Customer SR (SR-001) Remains Open:
        Supply_Request__c refSr001 = [
            SELECT Id, Status__c, Received_Qty__c 
            FROM Supply_Request__c 
            WHERE Id = :sr001.Id
        ];
        Assert.areEqual('Open', refSr001.Status__c, 'Customer demand SR-001 must still be Open');
        Assert.areEqual(0, refSr001.Received_Qty__c, 'Customer demand SR-001 received qty must still be 0');

        // 4. Inventory physical bin check: Dealer now has 10 initial + 90 accepted = 100 in Reserved_Sale_Order__c
        Inventory__c refDealerInv = [
            SELECT Id, Reserved_Sale_Order__c, Available__c, Transit_In_Quantity__c 
            FROM Inventory__c 
            WHERE Item__c = :item.Id AND Inventory_Location__c = :locDealer.Id
        ];
        Assert.areEqual(100, refDealerInv.Reserved_Sale_Order__c, 'Dealer should have 100 units in Reserved_Sale_Order__c');
        Assert.areEqual(0, refDealerInv.Transit_In_Quantity__c, 'Dealer Transit_In_Quantity__c should be cleared');

        // Step 5: Dealer fulfills Retailer Demand
        Inventory_Transfer__c transferDealerToRetailer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locDealer.Id,
            Destination_Inventory_Location__c = locRet.Id,
            From_Account__c = dealerA.Id,
            To_Account__c = retA.Id,
            Transfer_Qty__c = 100,
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = oali001.Id
        );
        insert transferDealerToRetailer;

        // Dealer initiates transfer to Retailer (moves 100 from Reserved_Sale_Order__c to transit)
        InventoryTransferPending.initiateTransfer(transferDealerToRetailer.Id);

        // Retailer accepts delivery
        InventroyAcceptingPannel.acceptQuantity(transferDealerToRetailer.Id);

        // Final assertions on customer fulfillment records
        refOali001 = [
            SELECT Id, Status__c, Transfer_Qty_Received__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :oali001.Id
        ];
        Assert.areEqual('Delivered', refOali001.Status__c, 'Parent OALI-001 should now be Delivered upon physical delivery');
        Assert.areEqual(100, refOali001.Transfer_Qty_Received__c, 'Parent OALI-001 transfer received qty should be 100');

        refSr001 = [
            SELECT Id, Status__c, Received_Qty__c 
            FROM Supply_Request__c 
            WHERE Id = :sr001.Id
        ];
        Assert.areEqual('Completed', refSr001.Status__c, 'Customer SR-001 should now be Completed upon physical receipt');
        Assert.areEqual(100, refSr001.Received_Qty__c, 'Customer SR-001 received qty should be 100');

        Inventory__c refRetInv = [
            SELECT Id, Reserved_Sale_Order__c, Transit_In_Quantity__c 
            FROM Inventory__c 
            WHERE Item__c = :item.Id AND Inventory_Location__c = :locRet.Id
        ];
        Assert.areEqual(100, refRetInv.Reserved_Sale_Order__c, 'Retailer should receive 100 units in Reserved_Sale_Order__c');
        Assert.areEqual(0, refRetInv.Transit_In_Quantity__c, 'Retailer Transit_In_Quantity__c should be 0');
    }


    // =========================================================================
    // 14. TEST: Transfer SR Initiation - Both Source & Receiving OALI Shipped
    // =========================================================================
    @IsTest
    static void testTransferSR_Initiation_MarksBothSourceAndReceivingOaliShipped() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Account dealerAcc = accs.get('Dealer Hub');
        Account retAcc = accs.get('Retailer Alpha');
        Map<String, Inventory_Location__c> locs = getLocations();
        Inventory_Location__c locDealer = locs.get('Dealer Loc');
        Inventory_Location__c locRet = locs.get('Retailer 1 Loc');

        Supply_Request__c demandSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = retAcc.Id,
            Supplying_Account__c = dealerAcc.Id,
            Target_Location__c = locRet.Id
        );
        insert demandSr;

        Order_Allocation__c oaDealer = new Order_Allocation__c(
            Supplying_Account__c = dealerAcc.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaDealer;

        Order_Allocation_Line_Item__c receivingOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaDealer.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Status__c = 'Planned',
            Supply_Request__c = demandSr.Id
        );
        insert receivingOali;

        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = dealerAcc.Id,
            Supplying_Account__c = retAcc.Id,
            Target_Location__c = locDealer.Id,
            Order_Allocation_Line_Item__c = receivingOali.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        Order_Allocation__c oaSource = new Order_Allocation__c(
            Supplying_Account__c = retAcc.Id,
            Requesting_Account__c = dealerAcc.Id,
            Status__c = 'Draft'
        );
        insert oaSource;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaSource.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 100,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':100'
        );
        insert sourceOali;

        Inventory__c retInv = [SELECT Id, Reserved_Sale_Order__c FROM Inventory__c WHERE Inventory_Location__c = :locRet.Id AND Item__c = :item.Id];
        retInv.Reserved_Sale_Order__c = 100;
        update retInv;

        Inventory_Transfer__c it = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRet.Id,
            Destination_Inventory_Location__c = locDealer.Id,
            From_Account__c = retAcc.Id,
            To_Account__c = dealerAcc.Id,
            Transfer_Qty__c = 100,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = sourceOali.Id
        );
        insert it;

        Test.startTest();
        InventoryTransferPending.initiateTransfers(new List<Id>{ it.Id });
        Test.stopTest();

        Order_Allocation_Line_Item__c updatedSource = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Order_Allocation_Line_Item__c updatedReceiving = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :receivingOali.Id];
        Assert.areEqual('Shipped', updatedSource.Status__c, 'Source OALI must be Shipped upon transfer initiation');
        Assert.areEqual('Shipped', updatedReceiving.Status__c, 'Receiving OALI must be Shipped upon transfer initiation');
    }

    // =========================================================================
    // 15. TEST: Transfer SR Acceptance - Both Delivered & Transfer Qty Updated
    // =========================================================================
    @IsTest
    static void testTransferSR_Acceptance_MarksBothDeliveredAndUpdatesTransferQtyReceived() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Account dealerAcc = accs.get('Dealer Hub');
        Account retAcc = accs.get('Retailer Alpha');
        Map<String, Inventory_Location__c> locs = getLocations();
        Inventory_Location__c locDealer = locs.get('Dealer Loc');
        Inventory_Location__c locRet = locs.get('Retailer 1 Loc');

        Order_Allocation__c oaDealer = new Order_Allocation__c(
            Supplying_Account__c = dealerAcc.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaDealer;

        Order_Allocation_Line_Item__c receivingOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaDealer.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Status__c = 'Planned'
        );
        insert receivingOali;

        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = dealerAcc.Id,
            Supplying_Account__c = retAcc.Id,
            Target_Location__c = locDealer.Id,
            Order_Allocation_Line_Item__c = receivingOali.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        Order_Allocation__c oaSource = new Order_Allocation__c(
            Supplying_Account__c = retAcc.Id,
            Requesting_Account__c = dealerAcc.Id,
            Status__c = 'Draft'
        );
        insert oaSource;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaSource.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 100,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':100'
        );
        insert sourceOali;

        Inventory__c retInv = [SELECT Id, Reserved_Sale_Order__c FROM Inventory__c WHERE Inventory_Location__c = :locRet.Id AND Item__c = :item.Id];
        retInv.Reserved_Sale_Order__c = 100;
        update retInv;

        Inventory_Transfer__c it = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRet.Id,
            Destination_Inventory_Location__c = locDealer.Id,
            From_Account__c = retAcc.Id,
            To_Account__c = dealerAcc.Id,
            Transfer_Qty__c = 100,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = sourceOali.Id
        );
        insert it;

        InventoryTransferPending.initiateTransfers(new List<Id>{ it.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it.Id });
        Test.stopTest();

        Order_Allocation_Line_Item__c updatedSource = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :sourceOali.Id];
        Order_Allocation_Line_Item__c updatedReceiving = [
            SELECT Status__c, Transfer_Qty_Received__c, Procurement_Qty_Received__c, Remaining_Qty__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :receivingOali.Id
        ];
        Supply_Request__c updatedSr = [
            SELECT Status__c, Received_Qty__c, Remaining_Quantity__c 
            FROM Supply_Request__c 
            WHERE Id = :transferSr.Id
        ];

        Assert.areEqual('Delivered', updatedSource.Status__c, 'Source OALI must be Delivered');
        Assert.areEqual('Delivered', updatedReceiving.Status__c, 'Receiving OALI must be Delivered');
        Assert.areEqual(100, updatedReceiving.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c must be 100');
        Assert.areEqual(0, updatedReceiving.Procurement_Qty_Received__c, 'Procurement_Qty_Received__c must be 0');
        Assert.areEqual(100, updatedSr.Received_Qty__c, 'Transfer SR Received_Qty__c must be 100');
        Assert.areEqual('Completed', updatedSr.Status__c, 'Transfer SR must be Completed');
    }

    // =========================================================================
    // 16. TEST: Transfer SR Partial Quantity - Sets Partially Received
    // =========================================================================
    @IsTest
    static void testTransferSR_PartialQuantity_SetsPartiallyReceived() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Account dealerAcc = accs.get('Dealer Hub');
        Account retAcc = accs.get('Retailer Alpha');
        Map<String, Inventory_Location__c> locs = getLocations();
        Inventory_Location__c locDealer = locs.get('Dealer Loc');
        Inventory_Location__c locRet = locs.get('Retailer 1 Loc');

        Order_Allocation__c oaDealer = new Order_Allocation__c(
            Supplying_Account__c = dealerAcc.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaDealer;

        Order_Allocation_Line_Item__c receivingOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaDealer.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Status__c = 'Planned'
        );
        insert receivingOali;

        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = dealerAcc.Id,
            Supplying_Account__c = retAcc.Id,
            Target_Location__c = locDealer.Id,
            Order_Allocation_Line_Item__c = receivingOali.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        Order_Allocation__c oaSource = new Order_Allocation__c(
            Supplying_Account__c = retAcc.Id,
            Requesting_Account__c = dealerAcc.Id,
            Status__c = 'Draft'
        );
        insert oaSource;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaSource.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 60,
            Reserved_Quantity__c = 60,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':60'
        );
        insert sourceOali;

        Inventory__c retInv = [SELECT Id, Reserved_Sale_Order__c FROM Inventory__c WHERE Inventory_Location__c = :locRet.Id AND Item__c = :item.Id];
        retInv.Reserved_Sale_Order__c = 60;
        update retInv;

        Inventory_Transfer__c it = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRet.Id,
            Destination_Inventory_Location__c = locDealer.Id,
            From_Account__c = retAcc.Id,
            To_Account__c = dealerAcc.Id,
            Transfer_Qty__c = 60,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = sourceOali.Id
        );
        insert it;

        InventoryTransferPending.initiateTransfers(new List<Id>{ it.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it.Id });
        Test.stopTest();

        Order_Allocation_Line_Item__c updatedReceiving = [
            SELECT Status__c, Transfer_Qty_Received__c, Procurement_Qty_Received__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :receivingOali.Id
        ];
        Supply_Request__c updatedSr = [
            SELECT Status__c, Received_Qty__c, Requested_Qty__c 
            FROM Supply_Request__c 
            WHERE Id = :transferSr.Id
        ];

        Assert.areEqual(60, updatedReceiving.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c must be 60');
        Assert.areEqual(0, updatedReceiving.Procurement_Qty_Received__c, 'Procurement_Qty_Received__c must be 0');
        Assert.areEqual(60, updatedSr.Received_Qty__c, 'Transfer SR Received_Qty__c must be 60');
        Assert.areEqual('Partially Received', updatedSr.Status__c, 'Transfer SR must be Partially Received (NOT Completed)');
        Assert.areNotEqual('Delivered', updatedReceiving.Status__c, 'Receiving OALI must not be Delivered yet');
    }

    // =========================================================================
    // 17. TEST: Procurement SR - Updates Procurement Qty Received (NOT Transfer)
    // =========================================================================
    @IsTest
    static void testProcurementSR_UpdatesProcurementQtyReceivedNotTransferQty() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Account dealerAcc = accs.get('Dealer Hub');
        Account retAcc = accs.get('Retailer Alpha');
        Map<String, Inventory_Location__c> locs = getLocations();
        Inventory_Location__c locDealer = locs.get('Dealer Loc');
        Inventory_Location__c locRet = locs.get('Retailer 1 Loc');

        Order_Allocation__c oaDealer = new Order_Allocation__c(
            Supplying_Account__c = dealerAcc.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaDealer;

        Order_Allocation_Line_Item__c customerOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaDealer.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Procurement_Qty_Planned__c = 100,
            Status__c = 'Planned'
        );
        insert customerOali;

        Supply_Request__c purchaseSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Purchase SR',
            Requesting_Account__c = dealerAcc.Id,
            Supplying_Account__c = retAcc.Id,
            Target_Location__c = locDealer.Id,
            Order_Allocation_Line_Item__c = customerOali.Id
        );
        insert purchaseSr;
        purchaseSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :purchaseSr.Id];

        Order_Allocation__c oaSource = new Order_Allocation__c(
            Supplying_Account__c = retAcc.Id,
            Requesting_Account__c = dealerAcc.Id,
            Status__c = 'Draft'
        );
        insert oaSource;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaSource.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 100,
            Status__c = 'Ready to Ship',
            Supply_Request__c = purchaseSr.Id,
            Source_SR_References__c = purchaseSr.Name,
            Source_SR_Allocation__c = purchaseSr.Name + ':100'
        );
        insert sourceOali;

        Inventory__c retInv = [SELECT Id, Reserved_Sale_Order__c FROM Inventory__c WHERE Inventory_Location__c = :locRet.Id AND Item__c = :item.Id];
        retInv.Reserved_Sale_Order__c = 100;
        update retInv;

        Inventory_Transfer__c it = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRet.Id,
            Destination_Inventory_Location__c = locDealer.Id,
            From_Account__c = retAcc.Id,
            To_Account__c = dealerAcc.Id,
            Transfer_Qty__c = 100,
            Status__c = 'Requested',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = sourceOali.Id
        );
        insert it;

        InventoryTransferPending.initiateTransfers(new List<Id>{ it.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it.Id });
        Test.stopTest();

        Order_Allocation_Line_Item__c updatedCustomerOali = [
            SELECT Status__c, Transfer_Qty_Received__c, Procurement_Qty_Received__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :customerOali.Id
        ];
        Supply_Request__c updatedSr = [
            SELECT Status__c, Received_Qty__c 
            FROM Supply_Request__c 
            WHERE Id = :purchaseSr.Id
        ];

        Assert.areEqual(100, updatedCustomerOali.Procurement_Qty_Received__c, 'Procurement_Qty_Received__c must be 100');
        Assert.areEqual(0, updatedCustomerOali.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c must remain 0');
        Assert.areEqual('Ready to Ship', updatedCustomerOali.Status__c, 'Customer OALI should be Ready to Ship (NOT Delivered)');
        Assert.areEqual('Completed', updatedSr.Status__c, 'Purchase SR should be Completed');
    }

    // =========================================================================
    // 18. TEST: Account Type Combinations - Dealer to Dealer Transfer
    // =========================================================================
    @IsTest
    static void testAccountTypeCombinations_DealerToDealerTransferSR() {
        Item__c item = getItem();
        Account dealerA = new Account(Name = 'Dealer Alpha', Type = 'Dealer');
        Account dealerB = new Account(Name = 'Dealer Beta', Type = 'Dealer');
        insert new List<Account>{ dealerA, dealerB };

        Inventory_Location__c locDealerA = new Inventory_Location__c(
            Name = 'Dealer A Loc',
            Inventory_Location_Code__c = 'DLR-A-LOC',
            Account__c = dealerA.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locDealerB = new Inventory_Location__c(
            Name = 'Dealer B Loc',
            Inventory_Location_Code__c = 'DLR-B-LOC',
            Account__c = dealerB.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locDealerA, locDealerB };

        Inventory__c invB = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locDealerB.Id,
            Available__c = 0,
            Reserved_Sale_Order__c = 50
        );
        insert invB;

        // Dealer A demands 50 units
        Order_Allocation__c oaA = new Order_Allocation__c(
            Supplying_Account__c = dealerA.Id,
            Requesting_Account__c = dealerA.Id,
            Status__c = 'Draft'
        );
        insert oaA;

        Order_Allocation_Line_Item__c oaliA = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaA.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Status__c = 'Planned'
        );
        insert oaliA;

        // Transfer SR: Dealer A requests from Dealer B (Both Type = Dealer)
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = dealerA.Id,
            Supplying_Account__c = dealerB.Id,
            Target_Location__c = locDealerA.Id,
            Order_Allocation_Line_Item__c = oaliA.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        // Dealer B allocates stock
        Order_Allocation__c oaB = new Order_Allocation__c(
            Supplying_Account__c = dealerB.Id,
            Requesting_Account__c = dealerA.Id,
            Status__c = 'Draft'
        );
        insert oaB;

        Order_Allocation_Line_Item__c oaliB = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaB.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 50,
            Reserved_Quantity__c = 50,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':50'
        );
        insert oaliB;

        Inventory_Transfer__c it = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locDealerB.Id,
            Destination_Inventory_Location__c = locDealerA.Id,
            From_Account__c = dealerB.Id,
            To_Account__c = dealerA.Id,
            Transfer_Qty__c = 50,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = oaliB.Id
        );
        insert it;

        InventoryTransferPending.initiateTransfers(new List<Id>{ it.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ it.Id });
        Test.stopTest();

        Order_Allocation_Line_Item__c updatedA = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :oaliA.Id];
        Order_Allocation_Line_Item__c updatedB = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oaliB.Id];
        Supply_Request__c updatedSr = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :transferSr.Id];

        Assert.areEqual('Delivered', updatedB.Status__c, 'Dealer B source OALI should be Delivered');
        Assert.areEqual('Delivered', updatedA.Status__c, 'Dealer A receiving OALI should be Delivered');
        Assert.areEqual(50, updatedA.Transfer_Qty_Received__c, 'Dealer A should receive 50 in Transfer_Qty_Received__c');
        Assert.areEqual('Completed', updatedSr.Status__c, 'Transfer SR between Dealer and Dealer should be Completed');
    }


    // =========================================================================
    // 19. TEST: Transfer SR + Procurement SR combination rolls up into Parent Demand SR
    // =========================================================================
    @IsTest
    static void testTransferAndProcurementCombination_ParentCustomerDemandSrFullySatisfied() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Account dealerAcc = accs.get('Dealer Hub');
        Account retAcc = accs.get('Retailer Alpha');
        Map<String, Inventory_Location__c> locs = getLocations();
        Inventory_Location__c locDealer = locs.get('Dealer Loc');
        Inventory_Location__c locRet = locs.get('Retailer 1 Loc');

        // Customer Demand SR: 1000 units (SR-00809 equivalent)
        Supply_Request__c demandSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 1000,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = retAcc.Id,
            Supplying_Account__c = dealerAcc.Id,
            Target_Location__c = locRet.Id
        );
        insert demandSr;
        demandSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :demandSr.Id];

        // Dealer Order Allocation & OALI (SALI-00672 equivalent)
        Order_Allocation__c oaDealer = new Order_Allocation__c(
            Supplying_Account__c = dealerAcc.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaDealer;

        Order_Allocation_Line_Item__c sali00672 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaDealer.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 1000,
            Transfer_Qty_Planned__c = 900,
            Procurement_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = demandSr.Id
        );
        insert sali00672;

        // Transfer SR: 900 units (SR-00810 equivalent)
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 900,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = dealerAcc.Id,
            Supplying_Account__c = retAcc.Id,
            Target_Location__c = locDealer.Id,
            Order_Allocation_Line_Item__c = sali00672.Id,
            Supply_Request__c = demandSr.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        // Source OA and OALI for the 900 transfer
        Order_Allocation__c oaSource = new Order_Allocation__c(
            Supplying_Account__c = retAcc.Id,
            Requesting_Account__c = dealerAcc.Id,
            Status__c = 'Draft'
        );
        insert oaSource;

        Order_Allocation_Line_Item__c sourceOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaSource.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 900,
            Reserved_Quantity__c = 900,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':900'
        );
        insert sourceOali;

        Inventory__c retInv = [SELECT Id, Reserved_Sale_Order__c FROM Inventory__c WHERE Inventory_Location__c = :locRet.Id AND Item__c = :item.Id];
        retInv.Reserved_Sale_Order__c = 900;
        update retInv;

        Inventory_Transfer__c transfer900 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRet.Id,
            Destination_Inventory_Location__c = locDealer.Id,
            From_Account__c = retAcc.Id,
            To_Account__c = dealerAcc.Id,
            Transfer_Qty__c = 900,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = sourceOali.Id
        );
        insert transfer900;

        InventoryTransferPending.initiateTransfers(new List<Id>{ transfer900.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer900.Id });
        Test.stopTest();

        // Verify after 900 transfer accepted:
        Order_Allocation_Line_Item__c refSali = [
            SELECT Status__c, Transfer_Qty_Received__c, Procurement_Qty_Received__c, Secured_Qty__c, Remaining_Qty__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :sali00672.Id
        ];
        Supply_Request__c refDemandSr = [
            SELECT Status__c, Received_Qty__c, Remaining_Quantity__c 
            FROM Supply_Request__c 
            WHERE Id = :demandSr.Id
        ];
        Supply_Request__c refTransferSr = [
            SELECT Status__c, Received_Qty__c 
            FROM Supply_Request__c 
            WHERE Id = :transferSr.Id
        ];

        Assert.areEqual(900, refSali.Transfer_Qty_Received__c, 'SALI should have 900 Transfer Qty Received');
        Assert.areEqual(900, refTransferSr.Received_Qty__c, 'Transfer SR should have 900 Received');
        Assert.areEqual('Completed', refTransferSr.Status__c, 'Transfer SR should be Completed');
        Assert.areEqual(900, refDemandSr.Received_Qty__c, 'Parent Demand SR should receive 900 from Transfer SR');
        Assert.areEqual('Partially Received', refDemandSr.Status__c, 'Parent Demand SR should be Partially Received (900/1000)');
    }


    // =========================================================================
    // 20. TEST: Parent OALI Traversal - Full Quantity Completes Customer Demand SR
    // =========================================================================
    @IsTest
    static void testParentOaliTraversal_FullQuantity_CustomerDemandSrCompleted() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Account dealerAcc = accs.get('Dealer Hub');
        Account retAcc = accs.get('Retailer Alpha');
        Account retAcc2 = accs.get('Retailer Beta');
        Map<String, Inventory_Location__c> locs = getLocations();
        Inventory_Location__c locDealer = locs.get('Dealer Loc');
        Inventory_Location__c locRet1 = locs.get('Retailer 1 Loc');
        Inventory_Location__c locRet2 = locs.get('Retailer 2 Loc');

        // 1. Customer Demand SR (100 units, requested by Retailer Alpha)
        Supply_Request__c custDemandSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = retAcc.Id,
            Supplying_Account__c = dealerAcc.Id,
            Target_Location__c = locRet1.Id
        );
        insert custDemandSr;
        custDemandSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :custDemandSr.Id];

        // 2. Parent OALI (SALI-00675 equivalent at Dealer, fulfilling Customer Demand SR via Source_SR_References__c)
        Order_Allocation__c oaDealer = new Order_Allocation__c(
            Supplying_Account__c = dealerAcc.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaDealer;

        Order_Allocation_Line_Item__c parentOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaDealer.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Source_SR_References__c = custDemandSr.Name,
            Source_SR_Allocation__c = custDemandSr.Name + ':100'
        );
        insert parentOali;

        // 3. Transfer SR (SR-00814 equivalent, requested by Retailer Alpha from Retailer Beta, linked to parentOali)
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = retAcc.Id,
            Supplying_Account__c = retAcc2.Id,
            Target_Location__c = locRet1.Id,
            Order_Allocation_Line_Item__c = parentOali.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        // Ensure parentOali.Supply_Request__c points to the Transfer SR (matching live model)
        parentOali.Supply_Request__c = transferSr.Id;
        update parentOali;

        // 4. Direct Fulfilling OALI (at Retailer Beta)
        Order_Allocation__c oaBeta = new Order_Allocation__c(
            Supplying_Account__c = retAcc2.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaBeta;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaBeta.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 100,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':100'
        );
        insert directOali;

        // Inventory reservation for transfer initiation
        Inventory__c ret2Inv = [SELECT Id, Reserved_Sale_Order__c FROM Inventory__c WHERE Inventory_Location__c = :locRet2.Id AND Item__c = :item.Id];
        ret2Inv.Reserved_Sale_Order__c = 100;
        update ret2Inv;

        // 5. Inventory Transfer (Retailer Beta -> Retailer Alpha)
        Inventory_Transfer__c transfer100 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRet2.Id,
            Destination_Inventory_Location__c = locRet1.Id,
            From_Account__c = retAcc2.Id,
            To_Account__c = retAcc.Id,
            Transfer_Qty__c = 100,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer100;

        InventoryTransferPending.initiateTransfers(new List<Id>{ transfer100.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer100.Id });
        Test.stopTest();

        // Verification:
        Order_Allocation_Line_Item__c refDirect = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :directOali.Id];
        Order_Allocation_Line_Item__c refParent = [SELECT Status__c, Transfer_Qty_Received__c, Supply_Request__c, Source_SR_References__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentOali.Id];
        Supply_Request__c refTransferSr = [SELECT Status__c, Received_Qty__c, Remaining_Quantity__c FROM Supply_Request__c WHERE Id = :transferSr.Id];
        Supply_Request__c refCustDemandSr = [SELECT Status__c, Received_Qty__c, Remaining_Quantity__c FROM Supply_Request__c WHERE Id = :custDemandSr.Id];

        Assert.areEqual('Delivered', refDirect.Status__c, 'Direct OALI must be Delivered');
        Assert.areEqual(100, refTransferSr.Received_Qty__c, 'Transfer SR Received_Qty__c must be 100');
        Assert.areEqual('Completed', refTransferSr.Status__c, 'Transfer SR must be Completed');
        Assert.areEqual('Delivered', refParent.Status__c, 'Parent OALI must be Delivered');
        Assert.areEqual(100, refParent.Transfer_Qty_Received__c, 'Parent OALI Transfer_Qty_Received__c must be 100');
        Assert.areEqual(100, refCustDemandSr.Received_Qty__c, 'Customer Demand SR must receive 100 via Parent OALI Source_SR_References__c');
        Assert.areEqual('Completed', refCustDemandSr.Status__c, 'Customer Demand SR must be Completed');
        Assert.areEqual(transferSr.Id, refParent.Supply_Request__c, 'Parent OALI Supply_Request__c must still point to Transfer SR');
    }

    // =========================================================================
    // 21. TEST: Parent OALI Traversal - Partial Quantity (60/100) Does NOT Complete
    // =========================================================================
    @IsTest
    static void testParentOaliTraversal_PartialQuantity_CustomerDemandSrPartiallyReceived() {
        Item__c item = getItem();
        Map<String, Account> accs = getAccounts();
        Account dealerAcc = accs.get('Dealer Hub');
        Account retAcc = accs.get('Retailer Alpha');
        Account retAcc2 = accs.get('Retailer Beta');
        Map<String, Inventory_Location__c> locs = getLocations();
        Inventory_Location__c locDealer = locs.get('Dealer Loc');
        Inventory_Location__c locRet1 = locs.get('Retailer 1 Loc');
        Inventory_Location__c locRet2 = locs.get('Retailer 2 Loc');

        // Customer Demand SR (100 units)
        Supply_Request__c custDemandSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getPurchaseSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = retAcc.Id,
            Supplying_Account__c = dealerAcc.Id,
            Target_Location__c = locRet1.Id
        );
        insert custDemandSr;
        custDemandSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :custDemandSr.Id];

        // Parent OALI (100 units planned, referencing custDemandSr)
        Order_Allocation__c oaDealer = new Order_Allocation__c(
            Supplying_Account__c = dealerAcc.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaDealer;

        Order_Allocation_Line_Item__c parentOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaDealer.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 100,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Source_SR_References__c = custDemandSr.Name,
            Source_SR_Allocation__c = custDemandSr.Name + ':100'
        );
        insert parentOali;

        // Transfer SR (100 units requested)
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            RecordTypeId = getTransferSrRtId(),
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = retAcc.Id,
            Supplying_Account__c = retAcc2.Id,
            Target_Location__c = locRet1.Id,
            Order_Allocation_Line_Item__c = parentOali.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        parentOali.Supply_Request__c = transferSr.Id;
        update parentOali;

        // Direct Fulfilling OALI (60 units allocated)
        Order_Allocation__c oaBeta = new Order_Allocation__c(
            Supplying_Account__c = retAcc2.Id,
            Requesting_Account__c = retAcc.Id,
            Status__c = 'Draft'
        );
        insert oaBeta;

        Order_Allocation_Line_Item__c directOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oaBeta.Id,
            Item__c = item.Id,
            Unit_Price__c = 100,
            Ordered_Qty__c = 60,
            Reserved_Quantity__c = 60,
            Status__c = 'Ready to Ship',
            Supply_Request__c = transferSr.Id,
            Source_SR_References__c = transferSr.Name,
            Source_SR_Allocation__c = transferSr.Name + ':60'
        );
        insert directOali;

        Inventory__c ret2Inv = [SELECT Id, Reserved_Sale_Order__c FROM Inventory__c WHERE Inventory_Location__c = :locRet2.Id AND Item__c = :item.Id];
        ret2Inv.Reserved_Sale_Order__c = 60;
        update ret2Inv;

        // Transfer for 60 units
        Inventory_Transfer__c transfer60 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRet2.Id,
            Destination_Inventory_Location__c = locRet1.Id,
            From_Account__c = retAcc2.Id,
            To_Account__c = retAcc.Id,
            Transfer_Qty__c = 60,
            Status__c = 'Requested',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = directOali.Id
        );
        insert transfer60;

        InventoryTransferPending.initiateTransfers(new List<Id>{ transfer60.Id });

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer60.Id });
        Test.stopTest();

        // Verification:
        Order_Allocation_Line_Item__c refParent = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :parentOali.Id];
        Supply_Request__c refTransferSr = [SELECT Status__c, Received_Qty__c, Remaining_Quantity__c FROM Supply_Request__c WHERE Id = :transferSr.Id];
        Supply_Request__c refCustDemandSr = [SELECT Status__c, Received_Qty__c, Remaining_Quantity__c FROM Supply_Request__c WHERE Id = :custDemandSr.Id];

        Assert.areEqual(60, refTransferSr.Received_Qty__c, 'Transfer SR Received_Qty__c must be 60');
        Assert.areEqual('Partially Received', refTransferSr.Status__c, 'Transfer SR must be Partially Received');
        Assert.areEqual(60, refParent.Transfer_Qty_Received__c, 'Parent OALI Transfer_Qty_Received__c must be 60');
        Assert.areNotEqual('Delivered', refParent.Status__c, 'Parent OALI must NOT be Delivered');
        Assert.areEqual(60, refCustDemandSr.Received_Qty__c, 'Customer Demand SR must receive 60');
        Assert.areEqual('Partially Received', refCustDemandSr.Status__c, 'Customer Demand SR must be Partially Received');
        Assert.areNotEqual('Completed', refCustDemandSr.Status__c, 'Customer Demand SR must NOT be Completed');
    }

}