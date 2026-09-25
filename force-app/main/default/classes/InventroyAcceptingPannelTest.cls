@IsTest
public class InventroyAcceptingPannelTest {

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
            Name = 'Hydraulic Pump',
            Item_Code__c = 'PUMP-01',
            Base_Tax__c = 18,
            Default_Supply_Method__c = defaultSupplyMethod,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = unitOfMeasure,
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 10,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100
        );
        insert item;

        // Create Locations
        Inventory_Location__c locKumar = new Inventory_Location__c(
            Name = 'Kumar Location',
            Inventory_Location_Code__c = 'KMR',
            Is_Active__c = true
        );
        Inventory_Location__c locSpeed = new Inventory_Location__c(
            Name = 'Speed Location',
            Inventory_Location_Code__c = 'SPD',
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locKumar, locSpeed };

        // Create Accounts
        Account accKumar = new Account(Name = 'Kumar Traders');
        Account accSpeed = new Account(Name = 'Speed Motors');
        insert new List<Account>{ accKumar, accSpeed };

        // Create Inventory Records
        Inventory__c kumarInv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locKumar.Id,
            Available__c = 50,
            Reserved_Sale_Order__c = 50,
            Transit_Out_Quantity__c = 0,
            Transit_In_Quantity__c = 50
        );
        Inventory__c speedInv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locSpeed.Id,
            Available__c = 20,
            Reserved_Sale_Order__c = 0,
            Transit_Out_Quantity__c = 50,
            Transit_In_Quantity__c = 0
        );
        insert new List<Inventory__c>{ kumarInv, speedInv };

        // 1. Create Originating Customer Order Allocation & OALI (OALI-00067)
        Order_Allocation__c customerOa = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Source_Location__c = locKumar.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Planned'
        );
        insert customerOa;

        // 2. Create Supply Request (SR-00046)
        Supply_Request__c sr46 = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locKumar.Id
        );
        insert sr46;

        Order_Allocation_Line_Item__c customerOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = customerOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 50,
            Procurement_Qty_Planned__c = 50,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Planned',
            Supply_Request__c = sr46.Id
        );
        insert customerOali;

        // 3. Create Speed Motors Downstream Fulfillment OA & OALI (OALI-00068)
        Supply_Request__c queriedSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :sr46.Id LIMIT 1];

        Order_Allocation__c speedOa = new Order_Allocation__c(
            Supplying_Account__c = accSpeed.Id,
            Requesting_Account__c = accKumar.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Planned'
        );
        insert speedOa;

        Order_Allocation_Line_Item__c fulfillmentOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = speedOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Status__c = 'Shipped',
            Supply_Request__c = queriedSR.Id,
            Source_SR_References__c = queriedSR.Name,
            Source_SR_Allocation__c = queriedSR.Name + ':50'
        );
        insert fulfillmentOali;

        // 4. Create In-Transit Inventory Transfer
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            From_Account__c = accSpeed.Id,
            To_Account__c = accKumar.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = fulfillmentOali.Id
        );
        insert transfer;
    }

    @IsTest
    static void testGetApprovedTransfers() {
        Test.startTest();
        List<Inventory_Transfer__c> approvedTransfers = InventroyAcceptingPannel.getApprovedTransfers();
        Test.stopTest();

        System.assertEquals(1, approvedTransfers.size(), 'Should return one in-transit transfer.');
        System.assertEquals('In Transit', approvedTransfers[0].Status__c, 'Status should be In Transit.');
    }

    @IsTest
    static void testGetLocations() {
        Test.startTest();
        List<Inventory_Location__c> locations = InventroyAcceptingPannel.getLocations();
        Test.stopTest();

        System.assertEquals(2, locations.size(), 'Should return active locations.');
    }

    @IsTest
    static void testValidateAcceptStatus() {
        Inventory_Transfer__c transfer = [SELECT Id FROM Inventory_Transfer__c LIMIT 1];

        Test.startTest();
        Map<String, Object> result = InventroyAcceptingPannel.validateAcceptStatus(transfer.Id);
        Test.stopTest();

        System.assertEquals(true, result.get('valid'), 'Status should be valid for In Transit record');
    }

    @IsTest
    static void testCustomerDemandBacktrackingAcceptance() {
        Inventory_Transfer__c transfer = [
            SELECT Id, Source_Inventory_Location__c, Destination_Inventory_Location__c, Item__c, 
                   Transfer_Qty__c, Order_Allocation_Line_Item__c 
            FROM Inventory_Transfer__c 
            LIMIT 1
        ];

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 1. Verify Transfer record status is Received
        Inventory_Transfer__c updatedTransfer = [
            SELECT Id, Status__c, Received_Qty__c, In_Transit_Qty__c 
            FROM Inventory_Transfer__c 
            WHERE Id = :transfer.Id
        ];
        System.assertEquals('Received', updatedTransfer.Status__c, 'Transfer status should be Received');
        System.assertEquals(50, updatedTransfer.Received_Qty__c, 'Received quantity should be 50');
        System.assertEquals(0, updatedTransfer.In_Transit_Qty__c, 'In-transit quantity should be reset to 0');

        // 2. Verify Speed Motors Location: Transfer Out reduced by 50 to 0
        Inventory__c speedInv = [
            SELECT Id, Transit_Out_Quantity__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :transfer.Source_Inventory_Location__c 
            AND Item__c = :transfer.Item__c
        ];
        System.assertEquals(0, speedInv.Transit_Out_Quantity__c, 'Speed Transit Out should decrease to 0');

        // 3. Verify Kumar Traders Location: Transfer In reduced by 50 to 0, Reserved for Sales Order increased by 50 (50 + 50 = 100)
        Inventory__c kumarInv = [
            SELECT Id, Transit_In_Quantity__c, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :transfer.Destination_Inventory_Location__c 
            AND Item__c = :transfer.Item__c
        ];
        System.assertEquals(0, kumarInv.Transit_In_Quantity__c, 'Kumar Transit In should decrease to 0');
        System.assertEquals(100, kumarInv.Reserved_Sale_Order__c, 'Kumar Reserved for Sales Order should increase to 100');

        // 4. Verify SR-00046 fulfilled and Completed
        Supply_Request__c sr = [SELECT Id, Status__c, Received_Qty__c FROM Supply_Request__c LIMIT 1];
        System.assertEquals(50, sr.Received_Qty__c, 'SR Received Qty should be 50');
        System.assertEquals('Completed', sr.Status__c, 'SR should be Completed when fully fulfilled');

        // 5. Verify Original Customer OALI (OALI-00067) backtracked and updated to 'Ready to Ship'
        Order_Allocation_Line_Item__c origOali = [
            SELECT Id, Procurement_Qty_Received__c, Status__c, Order_Allocation__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Supply_Request__c = :sr.Id AND Ordered_Qty__c = 100
            LIMIT 1
        ];
        System.assertEquals(50, origOali.Procurement_Qty_Received__c, 'Procurement_Qty_Received__c should be 50 on customer OALI');
        System.assertEquals('Ready to Ship', origOali.Status__c, 'Parent/Customer OALI status should be Ready to Ship when total secured >= ordered qty');

        // 6. Verify Transfer's own direct OALI (OALI-00068) updated to 'Delivered' and Transfer_Qty_Received__c incremented
        Order_Allocation_Line_Item__c transferOali = [
            SELECT Id, Status__c, Transfer_Qty_Received__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :transfer.Order_Allocation_Line_Item__c
        ];
        System.assertEquals('Delivered', transferOali.Status__c, 'Transfer OALI status must be Delivered upon acceptance');
        System.assertEquals(50, transferOali.Transfer_Qty_Received__c, 'Transfer OALI Transfer_Qty_Received__c must be incremented by transfer qty');

        // 7. Verify Order_Allocation__c status is NOT modified by Apex
        Order_Allocation__c checkCustomerOa = [SELECT Status__c FROM Order_Allocation__c WHERE Id = :origOali.Order_Allocation__c];
        System.assertEquals('Planned', checkCustomerOa.Status__c, 'Order_Allocation__c must NOT be modified by Apex');

        // 8. Confirm NO new PO or POLI records created
        System.assertEquals(0, [SELECT COUNT() FROM Purchase_Order__c], 'No PO should be created during transfer accept');
        System.assertEquals(0, [SELECT COUNT() FROM Purchase_Order_Line_Item__c], 'No POLI should be created during transfer accept');
    }

    @IsTest
    static void testMultiSRConsolidatedBacktrackingFIFO() {
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Create 2 SRs
        Supply_Request__c srA = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 30,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id
        );
        Supply_Request__c srB = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 20,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Manual Request',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id
        );
        insert new List<Supply_Request__c>{ srA, srB };

        List<Supply_Request__c> insertedSRs = [SELECT Id, Name FROM Supply_Request__c WHERE Id IN (:srA.Id, :srB.Id) ORDER BY CreatedDate ASC];

        // Customer OALI for srA
        Order_Allocation__c custOa = new Order_Allocation__c(Supplying_Account__c = accKumar.Id, Status__c = 'Planned');
        insert custOa;

        Order_Allocation_Line_Item__c custOaliA = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = custOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 30,
            Reserved_Quantity__c = 0,
            Procurement_Qty_Planned__c = 30,
            Status__c = 'Planned',
            Supply_Request__c = insertedSRs[0].Id
        );
        insert custOaliA;

        // Downstream Fulfillment OALI consolidating srA and srB
        Order_Allocation__c speedOa = new Order_Allocation__c(Supplying_Account__c = accSpeed.Id, Status__c = 'Planned');
        insert speedOa;

        String srRefs = insertedSRs[0].Name + ',' + insertedSRs[1].Name;
        String srAllocs = insertedSRs[0].Name + ':30,' + insertedSRs[1].Name + ':20';

        Order_Allocation_Line_Item__c consolidatedOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = speedOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Status__c = 'Shipped',
            Source_SR_References__c = srRefs,
            Source_SR_Allocation__c = srAllocs
        );
        insert consolidatedOali;

        // Transfer with 40 units (30 fulfills srA Customer Demand, 10 partially fulfills srB Manual Request)
        Inventory_Transfer__c multiTransfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            Transfer_Qty__c = 40,
            In_Transit_Qty__c = 40,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = consolidatedOali.Id
        );
        insert multiTransfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(multiTransfer.Id);
        Test.stopTest();

        // srA (Customer Demand 30) should be Completed
        Supply_Request__c updatedSrA = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :insertedSRs[0].Id];
        System.assertEquals(30, updatedSrA.Received_Qty__c);
        System.assertEquals('Completed', updatedSrA.Status__c);

        // srB (Manual Request 20) should have 10 received and be Partially Received
        Supply_Request__c updatedSrB = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :insertedSRs[1].Id];
        System.assertEquals(10, updatedSrB.Received_Qty__c);
        System.assertEquals('Partially Received', updatedSrB.Status__c);

        // custOaliA backtracked +30
        Order_Allocation_Line_Item__c updatedCustOaliA = [SELECT Procurement_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :custOaliA.Id];
        System.assertEquals(30, updatedCustOaliA.Procurement_Qty_Received__c);
    }

    @IsTest
    static void testRecursiveMultiTierBacktracking() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Tier 1 (Parent SR)
        Supply_Request__c parentSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 25,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand'
        );
        insert parentSR;

        // Tier 2 (Child SR referencing parentSR)
        Supply_Request__c childSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 25,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Supply_Request__c = parentSR.Id
        );
        insert childSR;

        Supply_Request__c queriedChildSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :childSR.Id];

        // Parent Customer OALI
        Order_Allocation__c rootOa = new Order_Allocation__c(Supplying_Account__c = accKumar.Id, Status__c = 'Planned');
        insert rootOa;

        Order_Allocation_Line_Item__c rootOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = rootOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 25,
            Reserved_Quantity__c = 0,
            Supply_Request__c = parentSR.Id,
            Status__c = 'Planned'
        );
        insert rootOali;

        // Downstream fulfillment OALI
        Order_Allocation__c speedOa = new Order_Allocation__c(Supplying_Account__c = accSpeed.Id, Status__c = 'Planned');
        insert speedOa;

        Order_Allocation_Line_Item__c fulfillmentOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = speedOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 25,
            Status__c = 'Shipped',
            Source_SR_References__c = queriedChildSR.Name,
            Source_SR_Allocation__c = queriedChildSR.Name + ':25'
        );
        insert fulfillmentOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            Transfer_Qty__c = 25,
            In_Transit_Qty__c = 25,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = fulfillmentOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // Both childSR and parentSR should be fulfilled
        Supply_Request__c updatedChild = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :childSR.Id];
        System.assertEquals(25, updatedChild.Received_Qty__c);
        System.assertEquals('Completed', updatedChild.Status__c);

        Supply_Request__c updatedParent = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :parentSR.Id];
        System.assertEquals(25, updatedParent.Received_Qty__c);
        System.assertEquals('Completed', updatedParent.Status__c);

        // Root OALI updated
        Order_Allocation_Line_Item__c updatedRootOali = [SELECT Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :rootOali.Id];
        System.assertEquals(25, updatedRootOali.Procurement_Qty_Received__c);
        System.assertEquals('Ready to Ship', updatedRootOali.Status__c, 'Root OALI should become Ready to Ship');
    }

    @IsTest
    static void testAcceptTransferWithoutOALI() {
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];

        // Non-OALI Transfer (Manual Request)
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            Transfer_Qty__c = 25,
            In_Transit_Qty__c = 25,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Manual Request'
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Inventory_Transfer__c updated = [SELECT Status__c, Received_Qty__c FROM Inventory_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('Received', updated.Status__c, 'Non-OALI transfer should accept successfully');
        System.assertEquals(25, updated.Received_Qty__c, 'Received Qty should match');

        // Verify destination stock incremented Available (since Manual Request is NOT reserved for sale order)
        Inventory__c kumarInv = [
            SELECT Available__c, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Inventory_Location__c = :locKumar.Id AND Item__c = :item.Id
        ];
        System.assertEquals(75, kumarInv.Available__c, 'Destination Available should increase by 25 (50 + 25 = 75)');
        System.assertEquals(50, kumarInv.Reserved_Sale_Order__c, 'Destination Reserved for Sales Order should remain unchanged');
    }

    @IsTest
    static void testDuplicateAcceptFails() {
        Inventory_Transfer__c transfer = [SELECT Id FROM Inventory_Transfer__c LIMIT 1];

        // First accept
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);

        // Second accept attempt
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Second accept attempt must fail with ALREADY_ACTIONED exception');
    }

    @IsTest
    static void testBulkAcceptQuantities() {
        Inventory_Transfer__c transfer = [SELECT Id FROM Inventory_Transfer__c LIMIT 1];

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer.Id });
        Test.stopTest();

        Inventory_Transfer__c updated = [SELECT Status__c, Received_Qty__c FROM Inventory_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('Received', updated.Status__c, 'Status should be Received after bulk accept');
    }

    @IsTest
    static void testGetApprovedTransfers_AccountFiltered() {
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // 1. Receiving account (Speed Motors) - should see in-transit transfer
        InventoryTransferPending.testIsAdminOverride = false;
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>{ accSpeed.Id };

        Test.startTest();
        List<Inventory_Transfer__c> receivingTransfers = InventroyAcceptingPannel.getApprovedTransfers();

        // 2. Supplying account (Kumar Traders) - should NOT see in-transit transfers to accept
        InventoryTransferPending.testAccountIdsOverride = new Set<Id>{ accKumar.Id };
        List<Inventory_Transfer__c> supplyingTransfers = InventroyAcceptingPannel.getApprovedTransfers();

        // 3. Admin - should see all
        InventoryTransferPending.testIsAdminOverride = true;
        InventoryTransferPending.testAccountIdsOverride = null;
        List<Inventory_Transfer__c> adminTransfers = InventroyAcceptingPannel.getApprovedTransfers();
        Test.stopTest();

        System.assertEquals(1, receivingTransfers.size(), 'Receiving account must see transfers coming to them');
        System.assertEquals(0, supplyingTransfers.size(), 'Supplying account must NOT see in-transit transfers to accept');
        System.assertEquals(1, adminTransfers.size(), 'System admin must see all in-transit transfers');
    }

    @IsTest
    static void testPOLIFullReceipt() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Create PO and POLI
        Purchase_Order__c po = new Purchase_Order__c();
        insert po;

        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open'
        );
        insert poli;

        Order_Allocation__c alloc = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Requesting_Account__c = accSpeed.Id,
            Status__c = 'Confirmed Planning'
        );
        insert alloc;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = alloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Purchase_Order_Line_Item__c = poli.Id,
            Status__c = 'Shipped'
        );
        insert oali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locKumar.Id,
            Destination_Inventory_Location__c = locSpeed.Id,
            From_Account__c = accKumar.Id,
            To_Account__c = accSpeed.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Branch Request',
            Order_Allocation_Line_Item__c = oali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Purchase_Order_Line_Item__c updatedPoli = [
            SELECT Received_Qty__c, Status__c 
            FROM Purchase_Order_Line_Item__c 
            WHERE Id = :poli.Id
        ];
        System.assertEquals(50, updatedPoli.Received_Qty__c, 'POLI Received Qty should be 50 after full receipt');
        System.assertEquals('Fully Received', updatedPoli.Status__c, 'POLI Status should be Fully Received when Received Qty >= Ordered Qty');
        System.assertNotEquals('Closed', updatedPoli.Status__c, 'POLI Status should NOT automatically be Closed');

        Order_Allocation_Line_Item__c updatedOali = [
            SELECT Transfer_Qty_Received__c, Status__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :oali.Id
        ];
        System.assertEquals(50, updatedOali.Transfer_Qty_Received__c, 'Direct OALI Transfer_Qty_Received__c should be 50');
        System.assertEquals('Delivered', updatedOali.Status__c, 'Direct OALI Status should be Delivered');

        // Confirm NO new PO or POLI was created
        System.assertEquals(1, [SELECT COUNT() FROM Purchase_Order__c], 'No new Purchase Order should be created');
        System.assertEquals(1, [SELECT COUNT() FROM Purchase_Order_Line_Item__c], 'No new POLI should be created');
    }

    @IsTest
    static void testPOLIPartialReceipt() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        Purchase_Order__c po = new Purchase_Order__c();
        insert po;

        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open'
        );
        insert poli;

        Order_Allocation__c alloc = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Requesting_Account__c = accSpeed.Id,
            Status__c = 'Confirmed Planning'
        );
        insert alloc;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = alloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Transfer_Qty_Planned__c = 40,
            Purchase_Order_Line_Item__c = poli.Id,
            Status__c = 'Shipped'
        );
        insert oali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locKumar.Id,
            Destination_Inventory_Location__c = locSpeed.Id,
            From_Account__c = accKumar.Id,
            To_Account__c = accSpeed.Id,
            Transfer_Qty__c = 40,
            In_Transit_Qty__c = 40,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = oali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        Purchase_Order_Line_Item__c updatedPoli = [
            SELECT Received_Qty__c, Status__c 
            FROM Purchase_Order_Line_Item__c 
            WHERE Id = :poli.Id
        ];
        System.assertEquals(40, updatedPoli.Received_Qty__c, 'POLI Received Qty should be 40 after partial receipt');
        System.assertEquals('Partially Received', updatedPoli.Status__c, 'POLI Status should be Partially Received');
    }

    @IsTest
    static void testPOLIMultipleTransfersAccumulation() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        Purchase_Order__c po = new Purchase_Order__c();
        insert po;

        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open'
        );
        insert poli;

        Order_Allocation__c alloc = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Requesting_Account__c = accSpeed.Id,
            Status__c = 'Confirmed Planning'
        );
        insert alloc;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = alloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Purchase_Order_Line_Item__c = poli.Id,
            Status__c = 'Shipped'
        );
        insert oali;

        Inventory_Transfer__c transfer1 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locKumar.Id,
            Destination_Inventory_Location__c = locSpeed.Id,
            From_Account__c = accKumar.Id,
            To_Account__c = accSpeed.Id,
            Transfer_Qty__c = 20,
            In_Transit_Qty__c = 20,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Branch Request',
            Order_Allocation_Line_Item__c = oali.Id
        );
        Inventory_Transfer__c transfer2 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locKumar.Id,
            Destination_Inventory_Location__c = locSpeed.Id,
            From_Account__c = accKumar.Id,
            To_Account__c = accSpeed.Id,
            Transfer_Qty__c = 30,
            In_Transit_Qty__c = 30,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Branch Request',
            Order_Allocation_Line_Item__c = oali.Id
        );
        insert new List<Inventory_Transfer__c>{ transfer1, transfer2 };

        Test.startTest();
        // Accept transfer 1 (20)
        InventroyAcceptingPannel.acceptQuantity(transfer1.Id);

        Purchase_Order_Line_Item__c poliAfterT1 = [
            SELECT Received_Qty__c, Status__c 
            FROM Purchase_Order_Line_Item__c 
            WHERE Id = :poli.Id
        ];
        System.assertEquals(20, poliAfterT1.Received_Qty__c, 'POLI Received Qty should be 20 after first transfer');
        System.assertEquals('Partially Received', poliAfterT1.Status__c, 'POLI should be Partially Received');

        // Accept transfer 2 (30) - accumulating to full receipt (50)
        InventroyAcceptingPannel.acceptQuantity(transfer2.Id);
        Test.stopTest();

        Purchase_Order_Line_Item__c poliAfterT2 = [
            SELECT Received_Qty__c, Status__c 
            FROM Purchase_Order_Line_Item__c 
            WHERE Id = :poli.Id
        ];
        System.assertEquals(50, poliAfterT2.Received_Qty__c, 'POLI Received Qty should accumulate to 50');
        System.assertEquals('Fully Received', poliAfterT2.Status__c, 'POLI should be Fully Received after 2 transfers accumulate');
    }

    @IsTest
    static void testPurchaseSRAndTransferSRAcceptance() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // 1. Purchase SR & Parent OALI in Kumar Traders
        Supply_Request__c poSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 30,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Purchase SR',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id
        );
        insert poSR;
        Supply_Request__c queriedPoSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :poSR.Id];

        Order_Allocation__c poAlloc = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Requesting_Account__c = accKumar.Id,
            Status__c = 'Confirmed Planning'
        );
        insert poAlloc;

        Order_Allocation_Line_Item__c poOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = poAlloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 30,
            Procurement_Qty_Planned__c = 30,
            Supply_Request__c = queriedPoSR.Id,
            Status__c = 'Planned'
        );
        insert poOali;

        // Downstream fulfillment OALI in Speed Motors for Purchase SR
        Order_Allocation__c speedPoOa = new Order_Allocation__c(
            Supplying_Account__c = accSpeed.Id,
            Requesting_Account__c = accKumar.Id,
            Status__c = 'Confirmed Planning'
        );
        insert speedPoOa;

        Order_Allocation_Line_Item__c poFulfillOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = speedPoOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 30,
            Transfer_Qty_Planned__c = 30,
            Status__c = 'Shipped',
            Source_SR_References__c = queriedPoSR.Name,
            Source_SR_Allocation__c = queriedPoSR.Name + ':30'
        );
        insert poFulfillOali;

        Inventory_Transfer__c poTransfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            From_Account__c = accSpeed.Id,
            To_Account__c = accKumar.Id,
            Transfer_Qty__c = 30,
            In_Transit_Qty__c = 30,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Purchase SR',
            Order_Allocation_Line_Item__c = poFulfillOali.Id
        );
        insert poTransfer;

        // 2. Transfer SR & Parent OALI in Kumar Traders
        Supply_Request__c trSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 20,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id
        );
        insert trSR;
        Supply_Request__c queriedTrSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :trSR.Id];

        Order_Allocation__c trAlloc = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Requesting_Account__c = accKumar.Id,
            Status__c = 'Confirmed Planning'
        );
        insert trAlloc;

        Order_Allocation_Line_Item__c trOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = trAlloc.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 20,
            Transfer_Qty_Planned__c = 20,
            Supply_Request__c = queriedTrSR.Id,
            Status__c = 'Planned'
        );
        insert trOali;

        // Downstream fulfillment OALI in Speed Motors for Transfer SR
        Order_Allocation__c speedTrOa = new Order_Allocation__c(
            Supplying_Account__c = accSpeed.Id,
            Requesting_Account__c = accKumar.Id,
            Status__c = 'Confirmed Planning'
        );
        insert speedTrOa;

        Order_Allocation_Line_Item__c trFulfillOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = speedTrOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 20,
            Transfer_Qty_Planned__c = 20,
            Status__c = 'Shipped',
            Source_SR_References__c = queriedTrSR.Name,
            Source_SR_Allocation__c = queriedTrSR.Name + ':20'
        );
        insert trFulfillOali;

        Inventory_Transfer__c trTransfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            From_Account__c = accSpeed.Id,
            To_Account__c = accKumar.Id,
            Transfer_Qty__c = 20,
            In_Transit_Qty__c = 20,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = trFulfillOali.Id
        );
        insert trTransfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ poTransfer.Id, trTransfer.Id });
        Test.stopTest();

        // Verify Parent OALI Status became Ready to Ship or Delivered and appropriate Received fields are updated
        Order_Allocation_Line_Item__c updatedPoOali = [
            SELECT Procurement_Qty_Received__c, Transfer_Qty_Received__c, Status__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :poOali.Id
        ];
        System.assertEquals(30, updatedPoOali.Procurement_Qty_Received__c, 'Purchase SR should update Procurement_Qty_Received__c on parent OALI');
        System.assertEquals(null, updatedPoOali.Transfer_Qty_Received__c, 'Transfer_Qty_Received__c should remain untouched for Purchase SR parent OALI');
        System.assertEquals('Ready to Ship', updatedPoOali.Status__c, 'Purchase SR parent OALI should become Ready to Ship when fully received');

        Order_Allocation_Line_Item__c updatedTrOali = [
            SELECT Procurement_Qty_Received__c, Transfer_Qty_Received__c, Status__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :trOali.Id
        ];
        System.assertEquals(20, updatedTrOali.Transfer_Qty_Received__c, 'Transfer SR should update Transfer_Qty_Received__c on parent OALI');
        System.assertEquals(null, updatedTrOali.Procurement_Qty_Received__c, 'Procurement_Qty_Received__c should remain untouched for Transfer SR parent OALI');
        System.assertEquals('Delivered', updatedTrOali.Status__c, 'Transfer SR parent OALI should become Delivered when fully received via transfer');

        // Verify Direct fulfillment OALIs are Delivered
        Order_Allocation_Line_Item__c updatedPoFulfill = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :poFulfillOali.Id];
        System.assertEquals('Delivered', updatedPoFulfill.Status__c, 'Direct fulfillment OALI must be Delivered');
        System.assertEquals(30, updatedPoFulfill.Transfer_Qty_Received__c);

        Order_Allocation_Line_Item__c updatedTrFulfill = [SELECT Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id = :trFulfillOali.Id];
        System.assertEquals('Delivered', updatedTrFulfill.Status__c, 'Direct fulfillment OALI must be Delivered');
        System.assertEquals(20, updatedTrFulfill.Transfer_Qty_Received__c);
    }

    @IsTest
    static void testThreeTierRecursiveBacktracking() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Tier 1: Grandparent / Root SR (Customer Demand)
        Supply_Request__c grandParentSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 40,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand'
        );
        insert grandParentSR;

        // Root Customer OALI
        Order_Allocation__c rootOa = new Order_Allocation__c(Supplying_Account__c = accKumar.Id, Status__c = 'Planned');
        insert rootOa;
        Order_Allocation_Line_Item__c rootOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = rootOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 40,
            Reserved_Quantity__c = 0,
            Transfer_Qty_Planned__c = 40,
            Supply_Request__c = grandParentSR.Id,
            Status__c = 'Planned'
        );
        insert rootOali;

        // Tier 2: Parent / Intermediate SR
        Supply_Request__c parentSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 40,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Supply_Request__c = grandParentSR.Id
        );
        insert parentSR;

        // Intermediate OALI
        Order_Allocation__c interOa = new Order_Allocation__c(Supplying_Account__c = accSpeed.Id, Status__c = 'Planned');
        insert interOa;
        Order_Allocation_Line_Item__c interOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = interOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 40,
            Reserved_Quantity__c = 0,
            Transfer_Qty_Planned__c = 40,
            Supply_Request__c = parentSR.Id,
            Status__c = 'Planned'
        );
        insert interOali;

        // Tier 3: Child SR
        Supply_Request__c childSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 40,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Supply_Request__c = parentSR.Id
        );
        insert childSR;

        Supply_Request__c queriedChildSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :childSR.Id];

        // Fulfillment OALI
        Order_Allocation__c fulfillOa = new Order_Allocation__c(Supplying_Account__c = accSpeed.Id, Status__c = 'Planned');
        insert fulfillOa;
        Order_Allocation_Line_Item__c fulfillOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = fulfillOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 40,
            Status__c = 'Shipped',
            Source_SR_References__c = queriedChildSR.Name,
            Source_SR_Allocation__c = queriedChildSR.Name + ':40'
        );
        insert fulfillOali;

        // Inventory Transfer of 40 units
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            Transfer_Qty__c = 40,
            In_Transit_Qty__c = 40,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = fulfillOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // Check all 3 tiers of SRs are Completed and Received_Qty__c = 40
        Supply_Request__c updChild = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :childSR.Id];
        System.assertEquals(40, updChild.Received_Qty__c);
        System.assertEquals('Completed', updChild.Status__c);

        Supply_Request__c updParent = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :parentSR.Id];
        System.assertEquals(40, updParent.Received_Qty__c);
        System.assertEquals('Completed', updParent.Status__c);

        Supply_Request__c updGrandParent = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :grandParentSR.Id];
        System.assertEquals(40, updGrandParent.Received_Qty__c);
        System.assertEquals('Completed', updGrandParent.Status__c);

        // Check root and intermediate OALIs are Ready to Ship with Procurement_Qty_Received__c = 40
        Order_Allocation_Line_Item__c updRootOali = [SELECT Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :rootOali.Id];
        System.assertEquals(40, updRootOali.Procurement_Qty_Received__c);
        System.assertEquals('Ready to Ship', updRootOali.Status__c);

        Order_Allocation_Line_Item__c updInterOali = [SELECT Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :interOali.Id];
        System.assertEquals(40, updInterOali.Procurement_Qty_Received__c);
        System.assertEquals('Ready to Ship', updInterOali.Status__c);
    }

    @IsTest
    static void testTransferSROrderAllocationLineItemTwoWayBacktracking() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // 1. Customer Demand SR
        Supply_Request__c custSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand'
        );
        insert custSR;

        // 2. Customer OALI linked to custSR
        Order_Allocation__c custOa = new Order_Allocation__c(Supplying_Account__c = accKumar.Id, Status__c = 'Planned');
        insert custOa;
        Order_Allocation_Line_Item__c custOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = custOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Reserved_Quantity__c = 0,
            Transfer_Qty_Planned__c = 50,
            Supply_Request__c = custSR.Id,
            Status__c = 'Planned'
        );
        insert custOali;

        // 3. Child Transfer SR generated by planner with Order_Allocation_Line_Item__c = custOali.Id and Supply_Request__c = custSR.Id
        Supply_Request__c transferSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Supply_Request__c = custSR.Id,
            Order_Allocation_Line_Item__c = custOali.Id
        );
        insert transferSR;

        Supply_Request__c queriedTransferSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSR.Id];

        // 4. Fulfillment OALI in Speed Motors
        Order_Allocation__c speedOa = new Order_Allocation__c(Supplying_Account__c = accSpeed.Id, Status__c = 'Planned');
        insert speedOa;
        Order_Allocation_Line_Item__c fulfillOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = speedOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Status__c = 'Shipped',
            Source_SR_References__c = queriedTransferSR.Name,
            Source_SR_Allocation__c = queriedTransferSR.Name + ':50'
        );
        insert fulfillOali;

        // 5. Inventory Transfer
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Customer Demand',
            Order_Allocation_Line_Item__c = fulfillOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 6. Verify Transfer SR is Completed
        Supply_Request__c updTransferSR = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :transferSR.Id];
        System.assertEquals(50, updTransferSR.Received_Qty__c);
        System.assertEquals('Completed', updTransferSR.Status__c);

        // 7. Verify Customer SR is Completed
        Supply_Request__c updCustSR = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :custSR.Id];
        System.assertEquals(50, updCustSR.Received_Qty__c);
        System.assertEquals('Completed', updCustSR.Status__c);

        // 8. Verify Customer OALI is Delivered with Transfer_Qty_Received__c = 50
        Order_Allocation_Line_Item__c updCustOali = [SELECT Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :custOali.Id];
        System.assertEquals(50, updCustOali.Transfer_Qty_Received__c);
        System.assertEquals('Delivered', updCustOali.Status__c);

        // 9. Verify Fulfillment OALI is Delivered
        Order_Allocation_Line_Item__c updFulfillOali = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillOali.Id];
        System.assertEquals('Delivered', updFulfillOali.Status__c);
    }

    @IsTest
    static void testCustomerDemandSRViaOALISourceReferences() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // 1. Root Customer Order Allocation & Customer Demand SR
        Order_Allocation__c custOa = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Source_Location__c = locKumar.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Confirmed Planning'
        );
        insert custOa;

        Supply_Request__c custSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 20,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Customer Demand',
            Requesting_Account__c = accKumar.Id,
            Target_Location__c = locKumar.Id
        );
        insert custSR;

        Supply_Request__c queriedCustSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :custSR.Id];

        // 2. Customer OALI referencing Customer Demand SR by name
        Order_Allocation_Line_Item__c custOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = custOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 20,
            Transfer_Qty_Planned__c = 20,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Source_SR_References__c = queriedCustSR.Name,
            Source_SR_Allocation__c = queriedCustSR.Name + ':20'
        );
        insert custOali;

        // 3. Transfer SR pointing to Customer OALI
        Supply_Request__c transferSR = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 20,
            Received_Qty__c = 0,
            Status__c = 'Ordered',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = custOali.Id
        );
        insert transferSR;

        Supply_Request__c queriedTransferSR = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSR.Id];

        custOali.Supply_Request__c = transferSR.Id;
        update custOali;

        // 4. Fulfillment Order Allocation & OALI
        Order_Allocation__c speedOa = new Order_Allocation__c(
            Supplying_Account__c = accSpeed.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locSpeed.Id,
            Status__c = 'Confirmed Planning'
        );
        insert speedOa;

        Order_Allocation_Line_Item__c fulfillOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = speedOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 20,
            Status__c = 'Shipped',
            Source_SR_References__c = queriedTransferSR.Name,
            Source_SR_Allocation__c = queriedTransferSR.Name + ':20'
        );
        insert fulfillOali;

        // 5. Inventory Transfer
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            Transfer_Qty__c = 20,
            In_Transit_Qty__c = 20,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = fulfillOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantity(transfer.Id);
        Test.stopTest();

        // 6. Verify Transfer SR updated to Completed
        Supply_Request__c updTransferSR = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :transferSR.Id];
        System.assertEquals(20, updTransferSR.Received_Qty__c);
        System.assertEquals('Completed', updTransferSR.Status__c);

        // 7. Verify Customer Demand SR updated to Completed
        Supply_Request__c updCustSR = [SELECT Status__c, Received_Qty__c FROM Supply_Request__c WHERE Id = :custSR.Id];
        System.assertEquals(20, updCustSR.Received_Qty__c);
        System.assertEquals('Completed', updCustSR.Status__c);

        // 8. Verify Customer OALI is Delivered
        Order_Allocation_Line_Item__c updCustOali = [SELECT Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :custOali.Id];
        System.assertEquals(20, updCustOali.Transfer_Qty_Received__c);
        System.assertEquals('Delivered', updCustOali.Status__c);

        // 9. Verify Fulfillment OALI is Delivered
        Order_Allocation_Line_Item__c updFulfillOali = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :fulfillOali.Id];
        System.assertEquals('Delivered', updFulfillOali.Status__c);
    }

    @IsTest
    static void testTrueBulk200AcceptTransfers() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Replenish transit in / out
        Inventory__c speedInv = [SELECT Id, Transit_Out_Quantity__c FROM Inventory__c WHERE Inventory_Location__c = :locSpeed.Id AND Item__c = :item.Id];
        speedInv.Transit_Out_Quantity__c = 500;
        Inventory__c kumarInv = [SELECT Id, Transit_In_Quantity__c FROM Inventory__c WHERE Inventory_Location__c = :locKumar.Id AND Item__c = :item.Id];
        kumarInv.Transit_In_Quantity__c = 500;
        update new List<Inventory__c>{ speedInv, kumarInv };

        Order_Allocation__c bulkAlloc = new Order_Allocation__c(
            Supplying_Account__c = accSpeed.Id,
            Requesting_Account__c = accKumar.Id,
            Status__c = 'Confirmed Planning'
        );
        insert bulkAlloc;

        List<Order_Allocation_Line_Item__c> oalis = new List<Order_Allocation_Line_Item__c>();
        for (Integer i = 0; i < 200; i++) {
            oalis.add(new Order_Allocation_Line_Item__c(
                Order_Allocation__c = bulkAlloc.Id,
                Item__c = item.Id,
                Ordered_Qty__c = 1,
                Transfer_Qty_Planned__c = 1,
                Status__c = 'Shipped'
            ));
        }
        insert oalis;

        List<Inventory_Transfer__c> transfers = new List<Inventory_Transfer__c>();
        for (Integer i = 0; i < 200; i++) {
            transfers.add(new Inventory_Transfer__c(
                Item__c = item.Id,
                Source_Inventory_Location__c = locSpeed.Id,
                Destination_Inventory_Location__c = locKumar.Id,
                From_Account__c = accSpeed.Id,
                To_Account__c = accKumar.Id,
                Transfer_Qty__c = 1,
                In_Transit_Qty__c = 1,
                Requested_Date__c = Date.today(),
                Status__c = 'In Transit',
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
        InventroyAcceptingPannel.acceptQuantities(transferIds);
        Test.stopTest();

        List<Inventory_Transfer__c> updatedTransfers = [SELECT Id, Status__c, Received_Qty__c FROM Inventory_Transfer__c WHERE Id IN :transferIds];
        for (Inventory_Transfer__c t : updatedTransfers) {
            System.assertEquals('Received', t.Status__c);
            System.assertEquals(1, t.Received_Qty__c);
        }
        List<Order_Allocation_Line_Item__c> updatedOalis = [SELECT Id, Status__c, Transfer_Qty_Received__c FROM Order_Allocation_Line_Item__c WHERE Id IN :oalis];
        for (Order_Allocation_Line_Item__c o : updatedOalis) {
            System.assertEquals('Delivered', o.Status__c);
            System.assertEquals(1, o.Transfer_Qty_Received__c);
        }
    }

    @IsTest
    static void testMultiTierBacktracking_ExactDmsBusinessFlow() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Third party: Retailer B
        Account accRetailerB = new Account(Name = 'Retailer B');
        insert accRetailerB;
        Inventory_Location__c locRetailerB = new Inventory_Location__c(
            Name = 'Retailer B Location',
            Inventory_Location_Code__c = 'RTB',
            Is_Active__c = true
        );
        insert locRetailerB;

        Inventory__c retailerBInv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locRetailerB.Id,
            Available__c = 50,
            Transit_Out_Quantity__c = 50,
            Transit_In_Quantity__c = 0
        );
        insert retailerBInv;

        // 1. Retailer A Demand OA & OALI (100 units)
        Order_Allocation__c retAOa = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Source_Location__c = locKumar.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Planned'
        );
        insert retAOa;

        Order_Allocation_Line_Item__c retADemandOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = retAOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Procurement_Qty_Planned__c = 100,
            Procurement_Qty_Received__c = 0,
            Status__c = 'Planned'
        );
        insert retADemandOali;

        // 2. Purchase SR: Retailer A -> Dealer A (Speed Motors), Qty = 100
        Supply_Request__c purchaseSr = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 100,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Purchase SR',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locKumar.Id,
            Order_Allocation_Line_Item__c = retADemandOali.Id
        );
        insert purchaseSr;
        purchaseSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :purchaseSr.Id];

        // 3. Dealer A converts Purchase SR to OA & OALI (Qty = 100: 50 Reserved, 50 Transfer)
        Order_Allocation__c dealerOa = new Order_Allocation__c(
            Supplying_Account__c = accSpeed.Id,
            Requesting_Account__c = accKumar.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Planned'
        );
        insert dealerOa;

        Order_Allocation_Line_Item__c dealerOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = dealerOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Reserved_Quantity__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Planned',
            Source_SR_References__c = purchaseSr.Name,
            Source_SR_Allocation__c = purchaseSr.Name + ':50'
        );
        insert dealerOali;

        // 4. Transfer SR: Retailer A -> Retailer B, Qty = 50
        // Real DMS flow: Supply_Request__c is null; it links upward via dealerOali (Order_Allocation_Line_Item__c)
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accRetailerB.Id,
            Source_Location__c = locRetailerB.Id,
            Target_Location__c = locKumar.Id,
            Supply_Request__c = null,
            Order_Allocation_Line_Item__c = dealerOali.Id
        );
        insert transferSr;
        transferSr = [SELECT Id, Name FROM Supply_Request__c WHERE Id = :transferSr.Id];

        // 5. Retailer B creates OA & OALI for Transfer SR
        Order_Allocation__c retBOa = new Order_Allocation__c(
            Supplying_Account__c = accRetailerB.Id,
            Requesting_Account__c = accKumar.Id,
            Source_Location__c = locRetailerB.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Planned'
        );
        insert retBOa;

        Order_Allocation_Line_Item__c transferOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = retBOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = transferSr.Id
        );
        insert transferOali;

        // 6. Physical Inventory Transfer 1: Retailer B -> Retailer A, Qty = 50
        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locRetailerB.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            From_Account__c = accRetailerB.Id,
            To_Account__c = accKumar.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = transferOali.Id
        );
        insert transfer;

        Test.startTest();
        // First acceptance of 50
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer.Id });
        Test.stopTest();

        // Verification 1: Transfer SR
        Supply_Request__c updatedTransferSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :transferSr.Id];
        Assert.areEqual(50, updatedTransferSr.Received_Qty__c, 'Transfer SR should have 50 received');
        Assert.areEqual('Completed', updatedTransferSr.Status__c, 'Transfer SR should be Completed');

        // Verification 2: Dealer OALI
        Order_Allocation_Line_Item__c updatedDealerOali = [SELECT Id, Transfer_Qty_Received__c, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :dealerOali.Id];
        Assert.areEqual(50, updatedDealerOali.Transfer_Qty_Received__c, 'Dealer OALI should have 50 Transfer received');
        Assert.areEqual(0, updatedDealerOali.Procurement_Qty_Received__c, 'Dealer OALI should have 0 Procurement received (no double counting)');
        Assert.areEqual('Ready to Ship', updatedDealerOali.Status__c, 'Dealer OALI (50 res + 50 trans = 100 ordered) should be Ready to Ship');

        // Verification 3: Purchase SR (Retailer A -> Dealer A)
        Supply_Request__c updatedPurchaseSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :purchaseSr.Id];
        Assert.areEqual(50, updatedPurchaseSr.Received_Qty__c, 'Purchase SR should have 50 received');
        Assert.areEqual('Partially Received', updatedPurchaseSr.Status__c, 'Purchase SR should be Partially Received');

        // Verification 4: Retailer Demand OALI
        Order_Allocation_Line_Item__c updatedDemandOali = [SELECT Id, Procurement_Qty_Received__c, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :retADemandOali.Id];
        Assert.areEqual(50, updatedDemandOali.Procurement_Qty_Received__c, 'Demand OALI should have 50 Procurement received');
        Assert.areEqual(0, updatedDemandOali.Transfer_Qty_Received__c, 'Demand OALI should not have transfer received');
        Assert.areEqual('Awaiting Inventory', updatedDemandOali.Status__c, 'Demand OALI should remain Awaiting Inventory (partial 50/100)');

        // Verification 5: Transfer OALI
        Order_Allocation_Line_Item__c updatedTransferOali = [SELECT Id, Transfer_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :transferOali.Id];
        Assert.areEqual(50, updatedTransferOali.Transfer_Qty_Received__c, 'Transfer OALI should have 50 received (not 100 from Step D + Step E)');
        Assert.areEqual('Delivered', updatedTransferOali.Status__c, 'Transfer OALI should be Delivered');

        // Verification 6: Second legitimate transfer of 50 completes the remaining requirement
        // Create 2nd transfer directly for the remaining 50 on Dealer OALI / Purchase SR
        Inventory_Transfer__c transfer2 = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            From_Account__c = accSpeed.Id,
            To_Account__c = accKumar.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Purchase SR',
            Order_Allocation_Line_Item__c = dealerOali.Id
        );
        insert transfer2;

        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer2.Id });

        // Final verification after 2nd acceptance
        Supply_Request__c finalPurchaseSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :purchaseSr.Id];
        Assert.areEqual(100, finalPurchaseSr.Received_Qty__c, 'Purchase SR should now have 100 received (50 + 50)');
        Assert.areEqual('Completed', finalPurchaseSr.Status__c, 'Purchase SR should be Completed');

        Order_Allocation_Line_Item__c finalDemandOali = [SELECT Id, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :retADemandOali.Id];
        Assert.areEqual(100, finalDemandOali.Procurement_Qty_Received__c, 'Demand OALI should now have 100 Procurement received');
        Assert.areEqual('Ready to Ship', finalDemandOali.Status__c, 'Demand OALI should be Ready to Ship when 100 fulfilled');
    }

    @IsTest
    static void testQuantityCapping_NeverExceedOrdered() {
        Item__c item = [SELECT Id FROM Item__c LIMIT 1];
        Inventory_Location__c locKumar = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'KMR' LIMIT 1];
        Inventory_Location__c locSpeed = [SELECT Id FROM Inventory_Location__c WHERE Inventory_Location_Code__c = 'SPD' LIMIT 1];
        Account accKumar = [SELECT Id FROM Account WHERE Name = 'Kumar Traders' LIMIT 1];
        Account accSpeed = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];

        // Demand OALI: Ordered = 100, existing received = 90
        Order_Allocation__c demandOa = new Order_Allocation__c(
            Supplying_Account__c = accKumar.Id,
            Source_Location__c = locKumar.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Planned'
        );
        insert demandOa;

        Order_Allocation_Line_Item__c demandOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = demandOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Procurement_Qty_Planned__c = 100,
            Procurement_Qty_Received__c = 90,
            Status__c = 'Awaiting Inventory'
        );
        insert demandOali;

        // Purchase SR: Requested = 100, existing received = 90
        Supply_Request__c purchaseSr = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 100,
            Received_Qty__c = 90,
            Status__c = 'Partially Received',
            Request_Type__c = 'Purchase SR',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locKumar.Id,
            Order_Allocation_Line_Item__c = demandOali.Id
        );
        insert purchaseSr;

        // Transfer SR for 50
        Supply_Request__c transferSr = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 50,
            Received_Qty__c = 0,
            Status__c = 'Open',
            Request_Type__c = 'Transfer SR',
            Requesting_Account__c = accKumar.Id,
            Supplying_Account__c = accSpeed.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locKumar.Id,
            Supply_Request__c = purchaseSr.Id
        );
        insert transferSr;

        Order_Allocation__c transferOa = new Order_Allocation__c(
            Supplying_Account__c = accSpeed.Id,
            Source_Location__c = locSpeed.Id,
            Target_Location__c = locKumar.Id,
            Status__c = 'Planned'
        );
        insert transferOa;

        Order_Allocation_Line_Item__c transferOali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = transferOa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Transfer_Qty_Planned__c = 50,
            Transfer_Qty_Received__c = 0,
            Status__c = 'Shipped',
            Supply_Request__c = transferSr.Id
        );
        insert transferOali;

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Item__c = item.Id,
            Source_Inventory_Location__c = locSpeed.Id,
            Destination_Inventory_Location__c = locKumar.Id,
            From_Account__c = accSpeed.Id,
            To_Account__c = accKumar.Id,
            Transfer_Qty__c = 50,
            In_Transit_Qty__c = 50,
            Requested_Date__c = Date.today(),
            Status__c = 'In Transit',
            Request_Type__c = 'Transfer SR',
            Order_Allocation_Line_Item__c = transferOali.Id
        );
        insert transfer;

        Test.startTest();
        InventroyAcceptingPannel.acceptQuantities(new List<Id>{ transfer.Id });
        Test.stopTest();

        // Demand OALI should be capped at 100, never 140
        Order_Allocation_Line_Item__c updatedDemandOali = [SELECT Id, Procurement_Qty_Received__c, Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :demandOali.Id];
        Assert.areEqual(100, updatedDemandOali.Procurement_Qty_Received__c, 'Demand OALI must be capped at 100, never 140');
        Assert.areEqual('Ready to Ship', updatedDemandOali.Status__c, 'Demand OALI should be Ready to Ship when 100% fulfilled');

        // Purchase SR should be capped at 100, never 140
        Supply_Request__c updatedPurchaseSr = [SELECT Id, Received_Qty__c, Status__c FROM Supply_Request__c WHERE Id = :purchaseSr.Id];
        Assert.areEqual(100, updatedPurchaseSr.Received_Qty__c, 'Purchase SR must be capped at 100, never 140');
        Assert.areEqual('Completed', updatedPurchaseSr.Status__c, 'Purchase SR should be Completed');
    }
}