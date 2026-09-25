@isTest
private class SupplyOrderPlannerTest {

    @testSetup
    static void setupTestData() {
        Map<String, Schema.RecordTypeInfo> accRtMap = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        Id oemRtId = accRtMap.containsKey('OEM') ? accRtMap.get('OEM').getRecordTypeId() : null;
        Id distRtId = accRtMap.containsKey('Distributor') ? accRtMap.get('Distributor').getRecordTypeId() : null;
        Id dealerRtId = accRtMap.containsKey('Dealer') ? accRtMap.get('Dealer').getRecordTypeId() : null;
        Id retailerRtId = accRtMap.containsKey('Retailer') ? accRtMap.get('Retailer').getRecordTypeId() : null;

        // Hierarchy: OEM -> Distributor -> Dealer -> Retailer A, Retailer B, Retailer C
        Account oem = new Account(Name = 'OEM Account', Type = 'OEM');
        if (oemRtId != null) oem.RecordTypeId = oemRtId;
        insert oem;

        Account dist = new Account(Name = 'Distributor Account', Type = 'Distributor', OEM__c = oem.Id);
        if (distRtId != null) dist.RecordTypeId = distRtId;
        insert dist;

        Account dealer = new Account(Name = 'Dealer Account', Type = 'Dealer', Distributor__c = dist.Id, OEM__c = oem.Id);
        if (dealerRtId != null) dealer.RecordTypeId = dealerRtId;
        insert dealer;

        Account retailerA = new Account(Name = 'Retailer A', Type = 'Retailer', Dealer__c = dealer.Id, Distributor__c = dist.Id, OEM__c = oem.Id);
        Account retailerB = new Account(Name = 'Retailer B', Type = 'Retailer', Dealer__c = dealer.Id, Distributor__c = dist.Id, OEM__c = oem.Id);
        Account retailerC = new Account(Name = 'Retailer C', Type = 'Retailer', Dealer__c = dealer.Id, Distributor__c = dist.Id, OEM__c = oem.Id);
        if (retailerRtId != null) {
            retailerA.RecordTypeId = retailerRtId;
            retailerB.RecordTypeId = retailerRtId;
            retailerC.RecordTypeId = retailerRtId;
        }
        insert new List<Account>{ retailerA, retailerB, retailerC };

        // Inventory Locations
        List<Inventory_Location__c> locs = new List<Inventory_Location__c>();
        Inventory_Location__c distLoc = new Inventory_Location__c(Name = 'Distributor Location', Is_Active__c = true, Account__c = dist.Id);
        Inventory_Location__c dealerLoc = new Inventory_Location__c(Name = 'Dealer Location', Is_Active__c = true, Account__c = dealer.Id);
        Inventory_Location__c locA = new Inventory_Location__c(Name = 'Retailer A Location', Is_Active__c = true, Account__c = retailerA.Id);
        Inventory_Location__c locB = new Inventory_Location__c(Name = 'Retailer B Location', Is_Active__c = true, Account__c = retailerB.Id);
        Inventory_Location__c locC = new Inventory_Location__c(Name = 'Retailer C Location', Is_Active__c = true, Account__c = retailerC.Id);
        Inventory_Location__c inactiveLoc = new Inventory_Location__c(Name = 'Inactive Location', Is_Active__c = false, Account__c = dealer.Id);
        locs.add(distLoc);
        locs.add(dealerLoc);
        locs.add(locA);
        locs.add(locB);
        locs.add(locC);
        locs.add(inactiveLoc);
        insert locs;

        // Items
        List<Item__c> items = new List<Item__c>();
        Item__c item1 = new Item__c(
            Name = 'Mac Mini',
            Item_Code__c = 'MAC-001',
            Default_Supply_Method__c = 'Purchase',
            Base_Tax__c = 0,
            Target_Days__c = 5,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'EA',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 10,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100
        );
        Item__c item2 = new Item__c(
            Name = 'Hydraulic Pump',
            Item_Code__c = 'HP-001',
            Default_Supply_Method__c = 'Manufacture',
            Base_Tax__c = 0,
            Target_Days__c = 10,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'EA',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 10,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100
        );
        Item__c item3 = new Item__c(
            Name = 'Solar Inverter',
            Item_Code__c = 'INV-001',
            Default_Supply_Method__c = 'Both',
            Base_Tax__c = 0,
            Target_Days__c = 7,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'EA',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 10,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100
        );
        items.add(item1);
        items.add(item2);
        items.add(item3);
        insert items;

        // Initial Inventories
        List<Inventory__c> inventories = new List<Inventory__c>();
        // Dealer has 50 Mac Minis and 30 Pumps
        inventories.add(new Inventory__c(Item__c = item1.Id, Account__c = dealer.Id, Inventory_Location__c = dealerLoc.Id, Available__c = 50, Reserved_Sale_Order__c = 0, Reserved_Transfer__c = 0, Reserved__c = 0));
        inventories.add(new Inventory__c(Item__c = item2.Id, Account__c = dealer.Id, Inventory_Location__c = dealerLoc.Id, Available__c = 30, Reserved_Sale_Order__c = 0, Reserved_Transfer__c = 0, Reserved__c = 0));
        // Retailer B has 20 Mac Minis
        inventories.add(new Inventory__c(Item__c = item1.Id, Account__c = retailerB.Id, Inventory_Location__c = locB.Id, Available__c = 20, Reserved_Sale_Order__c = 0, Reserved_Transfer__c = 0, Reserved__c = 0));
        // Retailer C has 20 Mac Minis
        inventories.add(new Inventory__c(Item__c = item1.Id, Account__c = retailerC.Id, Inventory_Location__c = locC.Id, Available__c = 20, Reserved_Sale_Order__c = 0, Reserved_Transfer__c = 0, Reserved__c = 0));
        insert inventories;

        // Item Prices for all items across all Accounts & all Locations
        List<Item_Price__c> prices = new List<Item_Price__c>();
        List<Account> allAccounts = new List<Account>{ oem, dist, dealer, retailerA, retailerB, retailerC };
        List<Inventory_Location__c> allActiveLocs = new List<Inventory_Location__c>{ distLoc, dealerLoc, locA, locB, locC };

        for (Account acc : allAccounts) {
            for (Item__c itm : items) {
                // Price record for each specific active location
                for (Inventory_Location__c loc : allActiveLocs) {
                    prices.add(new Item_Price__c(
                        Item_Price_Account__c = acc.Id,
                        Inventory_Location__c = loc.Id,
                        Item__c = itm.Id,
                        Unit_Price__c = 1000,
                        Active__c = true,
                        Discount__c = 0,
                        Tax__c = 0
                    ));
                }
                // Price record with null location (account fallback)
                prices.add(new Item_Price__c(
                    Item_Price_Account__c = acc.Id,
                    Item__c = itm.Id,
                    Unit_Price__c = 1000,
                    Active__c = true,
                    Discount__c = 0,
                    Tax__c = 0
                ));
            }
        }
        insert prices;
    }

    /* =========================================================================
       SCENARIO 1: FULL INVENTORY RESERVATION
       Order Allocation fulfills 100% via Inventory Reservation from Supplying Account.
       ========================================================================= */
    @isTest
    static void testScenario1_FullInventoryReservation() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Inventory_Location__c dealerLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :dealer.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Item__c macMini = [SELECT Id FROM Item__c WHERE Item_Code__c = 'MAC-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealer.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 30,
            Is_Reviewed__c = false
        );
        insert oali;

        // Fully reserve 30 out of 30 ordered
        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = oali.Id;
        alloc.reserveQty = 30;
        alloc.procureQty = 0;
        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>();

        Test.startTest();
        SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });
        Test.stopTest();

        // 1. Verify Inventory Reservation created
        List<Inventory_Reservation__c> reservations = [
            SELECT Id, Item__c, Requesting_Account__c, Supplying_Account__c, Inventory_Location__c,
                   Requested_Qty__c, Reserved_Qty__c, Status__c, Order_Allocation_Line_Item__c
            FROM Inventory_Reservation__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id
        ];
        System.assertEquals(1, reservations.size(), 'Exactly 1 Inventory Reservation must be created');
        System.assertEquals(30, reservations[0].Reserved_Qty__c, 'Reserved quantity must be 30');
        System.assertEquals('Fully Reserved', reservations[0].Status__c, 'Status must be Fully Reserved');
        System.assertEquals(dealerLoc.Id, reservations[0].Inventory_Location__c, 'Reservation location must be Dealer reserve location');

        // 2. Verify Dealer Inventory stock updated (Available 50 - 30 = 20, Reserved_Sale_Order 0 + 30 = 30)
        Inventory__c dealerStock = [
            SELECT Available__c, Reserved_Sale_Order__c 
            FROM Inventory__c 
            WHERE Account__c = :dealer.Id AND Item__c = :macMini.Id AND Inventory_Location__c = :dealerLoc.Id
            LIMIT 1
        ];
        System.assertEquals(20, dealerStock.Available__c, 'Dealer Available stock must be reduced to 20');
        System.assertEquals(30, dealerStock.Reserved_Sale_Order__c, 'Dealer Reserved_Sale_Order stock must increase to 30');

        // 3. Verify NO Supply Requests or Purchase Orders created for pure reservation
        List<Supply_Request__c> srs = [SELECT Id FROM Supply_Request__c WHERE Order_Allocation_Line_Item__c = :oali.Id];
        System.assertEquals(0, srs.size(), 'No Supply Requests should be created for pure reservation');

        List<Purchase_Order__c> pos = [SELECT Id FROM Purchase_Order__c WHERE Sales_Allocation__c = :oa.Id];
        System.assertEquals(0, pos.size(), 'No Purchase Orders should be created for pure reservation');

        // 4. Verify OALI and OA Status updated
        Order_Allocation_Line_Item__c updatedOali = [SELECT Status__c, Reserved_Qty_Planned__c, Transfer_Qty_Planned__c, Procurement_Qty_Planned__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        System.assertEquals('Planned', updatedOali.Status__c);
        System.assertEquals(30, updatedOali.Reserved_Qty_Planned__c);
        System.assertEquals(0, updatedOali.Transfer_Qty_Planned__c);
        System.assertEquals(0, updatedOali.Procurement_Qty_Planned__c);

        Order_Allocation__c updatedOa = [SELECT Status__c, Confirmed_Plan_Date__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Confirmed Planning', updatedOa.Status__c);
        System.assertNotEquals(null, updatedOa.Confirmed_Plan_Date__c);
    }

    /* =========================================================================
       SCENARIO 2: FULL PROCUREMENT
       Order Allocation fulfills 100% via Upstream Procurement from Parent Account.
       ========================================================================= */
    @isTest
    static void testScenario2_FullProcurement() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Distributor Account' LIMIT 1];
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Inventory_Location__c distLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :dist.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c dealerLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :dealer.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealer.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 40,
            Is_Reviewed__c = false
        );
        insert oali;

        // Fully procure 40 out of 40 ordered
        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = oali.Id;
        alloc.reserveQty = 0;
        alloc.procureQty = 40;
        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>();

        Test.startTest();
        SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });
        Test.stopTest();

        // 1. Verify Procurement Supply Request created
        List<Supply_Request__c> procSRs = [
            SELECT Id, Item__c, Requested_Qty__c, Requesting_Account__c, Supplying_Account__c,
                   Source_Location__c, Target_Location__c, Reference_Account__c, Request_Type__c, Status__c,
                   Order_Allocation_Line_Item__c
            FROM Supply_Request__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id AND Request_Type__c = 'Purchase SR'
        ];
        System.assertEquals(1, procSRs.size(), 'Exactly 1 Procurement SR must be created');
        System.assertEquals(40, procSRs[0].Requested_Qty__c, 'Procurement SR quantity must be 40');
        System.assertEquals(dealer.Id, procSRs[0].Requesting_Account__c, 'Procurement SR Requesting Account is Dealer');
        System.assertEquals(dist.Id, procSRs[0].Supplying_Account__c, 'Procurement SR Supplying Account is Distributor (Dealer Parent)');
        System.assertEquals(distLoc.Id, procSRs[0].Source_Location__c, 'Procurement SR Source Location is Distributor Location');
        System.assertEquals(dealerLoc.Id, procSRs[0].Target_Location__c, 'Procurement SR Target Location is Dealer Location');
        System.assertEquals(null, procSRs[0].Reference_Account__c, 'Procurement SR Reference Account must be null');

        // 2. Verify Procurement Purchase Order created
        List<Purchase_Order__c> pos = [
            SELECT Id, Requesting_Account__c, Supplying_Account__c, Source_Location__c, Target_Location__c, Status__c, Sales_Allocation__c
            FROM Purchase_Order__c
            WHERE Sales_Allocation__c = :oa.Id
        ];
        System.assertEquals(1, pos.size(), 'Exactly 1 Procurement PO must be created');
        System.assertEquals(dealer.Id, pos[0].Requesting_Account__c, 'PO Requesting Account is Dealer');
        System.assertEquals(dist.Id, pos[0].Supplying_Account__c, 'PO Supplying Account is Distributor');
        System.assertEquals(distLoc.Id, pos[0].Source_Location__c, 'PO Source Location is Distributor Location');
        System.assertEquals(dealerLoc.Id, pos[0].Target_Location__c, 'PO Target Location is Dealer Location');
        System.assertEquals('Draft', pos[0].Status__c, 'PO Status is Draft');

        // 3. Verify POLI created
        List<Purchase_Order_Line_Item__c> polis = [
            SELECT Id, Item__c, Ordered_Qty__c, Status__c, Purchase_Order__c, Sales_Allocation_Line_Item__c
            FROM Purchase_Order_Line_Item__c
            WHERE Purchase_Order__c = :pos[0].Id
        ];
        System.assertEquals(1, polis.size(), 'Exactly 1 POLI must be created');
        System.assertEquals(40, polis[0].Ordered_Qty__c, 'POLI quantity must be 40');
        System.assertEquals(pump.Id, polis[0].Item__c);
        System.assertEquals(oali.Id, polis[0].Sales_Allocation_Line_Item__c, 'POLI must link to OALI via Sales_Allocation_Line_Item__c');

        // 4. Verify OALI linked to created POLI and SR
        Order_Allocation_Line_Item__c updatedOali = [
            SELECT Id, Purchase_Order_Line_Item__c, Supply_Request__c, Procurement_Qty_Planned__c, Status__c
            FROM Order_Allocation_Line_Item__c
            WHERE Id = :oali.Id
        ];
        System.assertEquals(polis[0].Id, updatedOali.Purchase_Order_Line_Item__c);
        System.assertEquals(procSRs[0].Id, updatedOali.Supply_Request__c);
        System.assertEquals('Planned', updatedOali.Status__c);
    }

    /* =========================================================================
       SCENARIO 3: SINGLE TRANSFER PURCHASE REQUEST + PO CREATION
       Order Allocation fulfills via a single peer transfer location.
       Core Rule:
       - Transfer SR: Requesting = OA Requesting, Supplying = Selected Location Account, Reference = OA Supplying
       - PO: Requesting = OA Requesting, Supplying = OA Supplying (NOT Selected Location Account)
       ========================================================================= */
    @isTest
    static void testScenario3_SingleTransferSRAndPOCreation() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Account retailerB = [SELECT Id FROM Account WHERE Name = 'Retailer B' LIMIT 1];
        Inventory_Location__c dealerLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :dealer.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Inventory_Location__c locB = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerB.Id LIMIT 1];
        Item__c macMini = [SELECT Id FROM Item__c WHERE Item_Code__c = 'MAC-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealer.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 15,
            Is_Reviewed__c = false
        );
        insert oali;

        // Allocate 15 via Transfer from Retailer B
        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = oali.Id;
        alloc.reserveQty = 0;
        alloc.procureQty = 0;

        SupplyOrderPlanner.TransferWrapper transB = new SupplyOrderPlanner.TransferWrapper();
        transB.locationId = locB.Id;
        transB.qty = 15;
        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>{ transB };

        Test.startTest();
        SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });
        Test.stopTest();

        // 1. Verify Transfer SR
        List<Supply_Request__c> transferSRs = [
            SELECT Id, Item__c, Requested_Qty__c, Requesting_Account__c, Supplying_Account__c,
                   Reference_Account__c, Source_Location__c, Target_Location__c, Request_Type__c, Status__c,
                   Order_Allocation_Line_Item__c
            FROM Supply_Request__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id AND Request_Type__c = 'Transfer SR'
        ];
        System.assertEquals(1, transferSRs.size(), 'Exactly 1 Transfer SR must be created');
        System.assertEquals(15, transferSRs[0].Requested_Qty__c, 'Transfer SR quantity must be 15');
        System.assertEquals(retailerA.Id, transferSRs[0].Requesting_Account__c, 'Transfer SR Requesting Account = OA Requesting Account (Retailer A)');
        System.assertEquals(retailerB.Id, transferSRs[0].Supplying_Account__c, 'Transfer SR Supplying Account = Selected Location Account (Retailer B)');
        System.assertEquals(dealer.Id, transferSRs[0].Reference_Account__c, 'Transfer SR Reference Account = OA Supplying Account (Dealer)');
        System.assertEquals(locB.Id, transferSRs[0].Source_Location__c, 'Source Location = Retailer B Location');
        System.assertEquals(locA.Id, transferSRs[0].Target_Location__c, 'Target Location = Retailer A Location');
        System.assertEquals('Open', transferSRs[0].Status__c);

        // 2. Verify Transfer Purchase Order
        List<Purchase_Order__c> pos = [
            SELECT Id, Requesting_Account__c, Supplying_Account__c, Reference_Account__c, Source_Location__c, Target_Location__c, Status__c, Sales_Allocation__c
            FROM Purchase_Order__c
            WHERE Sales_Allocation__c = :oa.Id
        ];
        System.assertEquals(1, pos.size(), 'Exactly 1 Transfer PO must be created');
        System.assertEquals(retailerA.Id, pos[0].Requesting_Account__c, 'PO Requesting Account = OA Requesting Account (Retailer A)');
        System.assertEquals(retailerB.Id, pos[0].Supplying_Account__c, 'PO Supplying Account = Selected Location Account (Retailer B)');
        System.assertEquals(dealer.Id, pos[0].Reference_Account__c, 'PO Reference Account = OA Supplying Account (Dealer)');
        System.assertEquals(locB.Id, pos[0].Source_Location__c, 'PO Source Location = Retailer B Location');
        System.assertEquals(locA.Id, pos[0].Target_Location__c, 'PO Target Location = Retailer A Location');

        // 3. Verify POLI
        List<Purchase_Order_Line_Item__c> polis = [
            SELECT Id, Item__c, Ordered_Qty__c, Status__c, Purchase_Order__c, Sales_Allocation_Line_Item__c
            FROM Purchase_Order_Line_Item__c
            WHERE Purchase_Order__c = :pos[0].Id
        ];
        System.assertEquals(1, polis.size(), 'Exactly 1 POLI must be created');
        System.assertEquals(15, polis[0].Ordered_Qty__c, 'POLI quantity must be 15');
        System.assertEquals(oali.Id, polis[0].Sales_Allocation_Line_Item__c, 'POLI must link to OALI via Sales_Allocation_Line_Item__c');
        System.assertEquals('Open', polis[0].Status__c);

        // 4. Verify OALI is linked to the created Transfer SR
        Order_Allocation_Line_Item__c updatedOali = [
            SELECT Id, Supply_Request__c, Transfer_Qty_Planned__c, Status__c
            FROM Order_Allocation_Line_Item__c
            WHERE Id = :oali.Id
        ];
        System.assertEquals(transferSRs[0].Id, updatedOali.Supply_Request__c, 'OALI Supply_Request__c must be linked to the Transfer SR');
        System.assertEquals('Planned', updatedOali.Status__c);
    }

    /* =========================================================================
       SCENARIO 4: BULK TRANSFER PURCHASE REQUEST + BULK PO CREATION
       Order Allocation selects multiple transfer locations (Retailer B = 10, Retailer C = 10).
       Verifies:
       - 2 independent Transfer SRs created in bulk.
       - 2 independent POs created in bulk with Supplying Account = Dealer (OA Supplying).
       - Discrete processing with no merging across locations.
       ========================================================================= */
    @isTest
    static void testScenario4_BulkTransferSRAndPOCreation() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Account retailerB = [SELECT Id FROM Account WHERE Name = 'Retailer B' LIMIT 1];
        Account retailerC = [SELECT Id FROM Account WHERE Name = 'Retailer C' LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Inventory_Location__c locB = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerB.Id LIMIT 1];
        Inventory_Location__c locC = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerC.Id LIMIT 1];
        Item__c macMini = [SELECT Id FROM Item__c WHERE Item_Code__c = 'MAC-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealer.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 20,
            Is_Reviewed__c = false
        );
        insert oali;

        // Allocate Retailer B = 10, Retailer C = 10
        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = oali.Id;
        alloc.reserveQty = 0;
        alloc.procureQty = 0;

        SupplyOrderPlanner.TransferWrapper transB = new SupplyOrderPlanner.TransferWrapper();
        transB.locationId = locB.Id;
        transB.qty = 10;

        SupplyOrderPlanner.TransferWrapper transC = new SupplyOrderPlanner.TransferWrapper();
        transC.locationId = locC.Id;
        transC.qty = 10;

        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>{ transB, transC };

        Test.startTest();
        SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });
        Test.stopTest();

        // 1. Verify 2 Transfer SRs created
        List<Supply_Request__c> transferSRs = [
            SELECT Id, Item__c, Requested_Qty__c, Requesting_Account__c, Supplying_Account__c,
                   Reference_Account__c, Source_Location__c, Target_Location__c, Request_Type__c, Status__c
            FROM Supply_Request__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id AND Request_Type__c = 'Transfer SR'
            ORDER BY Supplying_Account__c ASC
        ];
        System.assertEquals(2, transferSRs.size(), 'Exactly 2 Transfer SRs must be created');

        // SR for Retailer B
        Supply_Request__c srB = transferSRs[0].Supplying_Account__c == retailerB.Id ? transferSRs[0] : transferSRs[1];
        System.assertEquals(retailerA.Id, srB.Requesting_Account__c, 'SR B Requesting Account = Retailer A');
        System.assertEquals(retailerB.Id, srB.Supplying_Account__c, 'SR B Supplying Account = Retailer B');
        System.assertEquals(dealer.Id, srB.Reference_Account__c, 'SR B Reference Account = Dealer');
        System.assertEquals(10, srB.Requested_Qty__c);
        System.assertEquals('Open', srB.Status__c);

        // SR for Retailer C
        Supply_Request__c srC = transferSRs[0].Supplying_Account__c == retailerC.Id ? transferSRs[0] : transferSRs[1];
        System.assertEquals(retailerA.Id, srC.Requesting_Account__c, 'SR C Requesting Account = Retailer A');
        System.assertEquals(retailerC.Id, srC.Supplying_Account__c, 'SR C Supplying Account = Retailer C');
        System.assertEquals(dealer.Id, srC.Reference_Account__c, 'SR C Reference Account = Dealer');
        System.assertEquals(10, srC.Requested_Qty__c);
        System.assertEquals('Open', srC.Status__c);

        // 2. Verify 2 POs created
        List<Purchase_Order__c> poList = [
            SELECT Id, Requesting_Account__c, Supplying_Account__c, Reference_Account__c, Sales_Allocation__c, Target_Location__c, Status__c
            FROM Purchase_Order__c
            WHERE Sales_Allocation__c = :oa.Id
        ];
        System.assertEquals(2, poList.size(), 'Exactly 2 Transfer POs must be created');

        for (Purchase_Order__c po : poList) {
            System.assertEquals(retailerA.Id, po.Requesting_Account__c, 'PO Requesting Account must be Retailer A');
            System.assertEquals(dealer.Id, po.Reference_Account__c, 'PO Reference Account must be Dealer A');
            System.assert(po.Supplying_Account__c == retailerB.Id || po.Supplying_Account__c == retailerC.Id, 'PO Supplying Account must be the selected transfer location account');
        }

        // 3. Verify POLIs
        List<Purchase_Order_Line_Item__c> poliList = [
            SELECT Id, Item__c, Ordered_Qty__c, Status__c, Purchase_Order__c, Sales_Allocation_Line_Item__c
            FROM Purchase_Order_Line_Item__c
            WHERE Item__c = :macMini.Id
        ];
        System.assertEquals(2, poliList.size(), '2 POLIs must be created (1 per PO)');
        for (Purchase_Order_Line_Item__c poli : poliList) {
            System.assertEquals(10, poli.Ordered_Qty__c);
            System.assertEquals(oali.Id, poli.Sales_Allocation_Line_Item__c, 'POLI must link to OALI via Sales_Allocation_Line_Item__c');
            System.assertEquals('Open', poli.Status__c);
        }
    }

    /* =========================================================================
       SCENARIO 5: MULTI-FULFILLMENT BLEND (RESERVATION + TRANSFERS + PROCUREMENT)
       Scenario: Retailer A orders 100 Mac Minis from Dealer A.
       Fulfillment:
       - Reserve 10 from Dealer A
       - Transfer 10 from Retailer B
       - Transfer 10 from Retailer C
       - Procure 70 from Distributor A
       ========================================================================= */
    @isTest
    static void testScenario5_MultiFulfillmentBlend() {
        Account distA = [SELECT Id FROM Account WHERE Name = 'Distributor Account' LIMIT 1];
        Account dealerA = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Account retailerB = [SELECT Id FROM Account WHERE Name = 'Retailer B' LIMIT 1];
        Account retailerC = [SELECT Id FROM Account WHERE Name = 'Retailer C' LIMIT 1];

        Inventory_Location__c distLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :distA.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c dealerLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :dealerA.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Inventory_Location__c locB = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerB.Id LIMIT 1];
        Inventory_Location__c locC = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerC.Id LIMIT 1];
        Item__c macMini = [SELECT Id FROM Item__c WHERE Item_Code__c = 'MAC-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealerA.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 100,
            Is_Reviewed__c = false
        );
        insert oali;

        // Plan: Reserve 10 + Transfer 10 (from B) + Transfer 10 (from C) + Procure 70 (from Dist A)
        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = oali.Id;
        alloc.reserveQty = 10;
        alloc.procureQty = 70;

        SupplyOrderPlanner.TransferWrapper transB = new SupplyOrderPlanner.TransferWrapper();
        transB.locationId = locB.Id;
        transB.qty = 10;

        SupplyOrderPlanner.TransferWrapper transC = new SupplyOrderPlanner.TransferWrapper();
        transC.locationId = locC.Id;
        transC.qty = 10;

        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>{ transB, transC };

        Test.startTest();
        SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });
        Test.stopTest();

        // 1. Verify Inventory Reservation (Qty 10)
        List<Inventory_Reservation__c> resList = [SELECT Id, Reserved_Qty__c, Status__c, Supplying_Account__c FROM Inventory_Reservation__c WHERE Order_Allocation_Line_Item__c = :oali.Id];
        System.assertEquals(1, resList.size(), '1 Reservation record must be created');
        System.assertEquals(10, resList[0].Reserved_Qty__c, 'Reserved quantity is 10');
        System.assertEquals('Partially Reserved', resList[0].Status__c);

        // 2. Verify Dealer A inventory updated (50 - 10 = 40, Reserved_Sale_Order 0 + 10 = 10)
        Inventory__c dealerInv = [SELECT Available__c, Reserved_Sale_Order__c FROM Inventory__c WHERE Item__c = :macMini.Id AND Inventory_Location__c = :dealerLoc.Id LIMIT 1];
        System.assertEquals(40, dealerInv.Available__c, 'Dealer A available stock should be 40');
        System.assertEquals(10, dealerInv.Reserved_Sale_Order__c, 'Dealer A reserved stock should be 10');

        // 3. Verify Transfer SRs (2 records: Retailer B -> 10, Retailer C -> 10)
        List<Supply_Request__c> transferSRs = [
            SELECT Id, Requested_Qty__c, Requesting_Account__c, Supplying_Account__c, Reference_Account__c, Request_Type__c
            FROM Supply_Request__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id AND Request_Type__c = 'Transfer SR'
        ];
        System.assertEquals(2, transferSRs.size(), '2 Transfer SRs must be created');
        for (Supply_Request__c sr : transferSRs) {
            System.assertEquals(10, sr.Requested_Qty__c);
            System.assertEquals(retailerA.Id, sr.Requesting_Account__c);
            System.assertEquals(dealerA.Id, sr.Reference_Account__c, 'Reference Account must be Dealer A');
        }

        // 4. Verify Procurement Purchase SR (1 record: 70 Qty)
        List<Supply_Request__c> procSRs = [
            SELECT Id, Requested_Qty__c, Requesting_Account__c, Supplying_Account__c, Reference_Account__c, Request_Type__c
            FROM Supply_Request__c
            WHERE Order_Allocation_Line_Item__c = :oali.Id AND Request_Type__c = 'Purchase SR'
        ];
        System.assertEquals(1, procSRs.size(), '1 Purchase SR of 70 Qty should be created');
        System.assertEquals(dealerA.Id, procSRs[0].Requesting_Account__c);
        System.assertEquals(distA.Id, procSRs[0].Supplying_Account__c);
        System.assertEquals(null, procSRs[0].Reference_Account__c);

        // 5. Verify Purchase Orders (3 POs total: 1 Distributor PO + 2 Transfer POs)
        List<Purchase_Order__c> poList = [
            SELECT Id, Requesting_Account__c, Supplying_Account__c, Reference_Account__c, Target_Location__c
            FROM Purchase_Order__c
            WHERE Sales_Allocation__c = :oa.Id
        ];
        System.assertEquals(3, poList.size(), '3 Purchase Orders must be created');
        for (Purchase_Order__c po : poList) {
            if (po.Supplying_Account__c == distA.Id) {
                System.assertEquals(dealerA.Id, po.Requesting_Account__c, 'Distributor PO Requesting Account is Dealer A');
                System.assertEquals(dealerLoc.Id, po.Target_Location__c, 'Distributor PO Target Location is Dealer A location');
                System.assertEquals(null, po.Reference_Account__c, 'Distributor PO Reference Account is null');
            } else {
                System.assertEquals(retailerA.Id, po.Requesting_Account__c, 'Transfer PO Requesting Account is Retailer A (OA Requesting Account)');
                System.assertEquals(dealerA.Id, po.Reference_Account__c, 'Transfer PO Reference Account is Dealer A (OA Supplying Account)');
                System.assert(po.Supplying_Account__c == retailerB.Id || po.Supplying_Account__c == retailerC.Id, 'Transfer PO Supplying Account is the Transfer Location Account');
            }
        }

        // 6. Verify Line Item Summary Fields
        Order_Allocation_Line_Item__c updatedOALI = [
            SELECT Id, Ordered_Qty__c, Reserved_Qty_Planned__c, Transfer_Qty_Planned__c, Procurement_Qty_Planned__c, Status__c
            FROM Order_Allocation_Line_Item__c
            WHERE Id = :oali.Id
        ];
        System.assertEquals(100, updatedOALI.Ordered_Qty__c);
        System.assertEquals(10, updatedOALI.Reserved_Qty_Planned__c);
        System.assertEquals(20, updatedOALI.Transfer_Qty_Planned__c);
        System.assertEquals(70, updatedOALI.Procurement_Qty_Planned__c);
        System.assertEquals('Planned', updatedOALI.Status__c);
    }

    /* =========================================================================
       SCENARIO 6: VALIDATION & ERROR HANDLING
       - Total allocated quantity exceeds ordered quantity
       - Negative quantity validation
       - Transfer source equals OA supplying account
       - Insufficient inventory stock for reservation
       - Submitting already confirmed plan
       - Null / Empty allocations
       ========================================================================= */
    @isTest
    static void testScenario6_ValidationsAndErrorHandling() {
        Account dealerA = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Account retailerB = [SELECT Id FROM Account WHERE Name = 'Retailer B' LIMIT 1];
        Inventory_Location__c dealerLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :dealerA.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Inventory_Location__c locB = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerB.Id LIMIT 1];
        Item__c macMini = [SELECT Id FROM Item__c WHERE Item_Code__c = 'MAC-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealerA.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 10,
            Is_Reviewed__c = false
        );
        insert oali;

        Test.startTest();

        // 1. Exceeds Ordered Quantity (Reserve 10 + Procure 5 = 15 > 10)
        SupplyOrderPlanner.AllocationWrapper allocExceed = new SupplyOrderPlanner.AllocationWrapper();
        allocExceed.lineItemId = oali.Id;
        allocExceed.reserveQty = 10;
        allocExceed.procureQty = 5;
        try {
            SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ allocExceed });
            System.assert(false, 'Should throw exception when allocated exceeds ordered');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 2. Negative Quantity
        SupplyOrderPlanner.AllocationWrapper allocNeg = new SupplyOrderPlanner.AllocationWrapper();
        allocNeg.lineItemId = oali.Id;
        allocNeg.reserveQty = -5;
        allocNeg.procureQty = 0;
        try {
            SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ allocNeg });
            System.assert(false, 'Should throw exception for negative quantity');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 3. Transfer Source equals Supplying Account
        SupplyOrderPlanner.AllocationWrapper allocSameSource = new SupplyOrderPlanner.AllocationWrapper();
        allocSameSource.lineItemId = oali.Id;
        allocSameSource.reserveQty = 0;
        allocSameSource.procureQty = 0;
        SupplyOrderPlanner.TransferWrapper transDealer = new SupplyOrderPlanner.TransferWrapper();
        transDealer.locationId = dealerLoc.Id;
        transDealer.qty = 5;
        allocSameSource.transfers = new List<SupplyOrderPlanner.TransferWrapper>{ transDealer };
        try {
            SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ allocSameSource });
            System.assert(false, 'Should throw exception when transfer source matches supplying account');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 4. Insufficient stock (Dealer has 50, request 100)
        Order_Allocation_Line_Item__c oaliBig = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 100,
            Is_Reviewed__c = false
        );
        insert oaliBig;

        SupplyOrderPlanner.AllocationWrapper allocBigRes = new SupplyOrderPlanner.AllocationWrapper();
        allocBigRes.lineItemId = oaliBig.Id;
        allocBigRes.reserveQty = 100;
        allocBigRes.procureQty = 0;
        try {
            SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ allocBigRes });
            System.assert(false, 'Should throw insufficient stock exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 5. Already Confirmed Plan
        oa.Status__c = 'Confirmed Planning';
        update oa;

        SupplyOrderPlanner.AllocationWrapper allocConfirmed = new SupplyOrderPlanner.AllocationWrapper();
        allocConfirmed.lineItemId = oali.Id;
        allocConfirmed.reserveQty = 1;
        allocConfirmed.procureQty = 0;
        try {
            SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ allocConfirmed });
            System.assert(false, 'Should throw exception for confirmed plan');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 6. Null and Empty allocations
        try {
            SupplyOrderPlanner.submitPlanning(null);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>());
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        Test.stopTest();
    }

    /* =========================================================================
       SCENARIO 7: GET SUPPLY PLAN DATA & REVIEW STATUS HELPERS
       Verifies wrapper initialization, fuzzy name matching, and review toggles.
       ========================================================================= */
    @isTest
    static void testScenario7_GetSupplyPlanDataAndReviewStatus() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Account retailerB = [SELECT Id FROM Account WHERE Name = 'Retailer B' LIMIT 1];
        Inventory_Location__c dealerLoc = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :dealer.Id AND Is_Active__c = true LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Inventory_Location__c locB = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerB.Id LIMIT 1];
        Item__c macMini = [SELECT Id FROM Item__c WHERE Item_Code__c = 'MAC-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealer.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 50,
            Is_Reviewed__c = false
        );
        insert oali;

        Test.startTest();

        // 1. Fetch by Record ID
        SupplyOrderPlanner.PlanWrapper wrapperById = SupplyOrderPlanner.getSupplyPlanData(oa.Id);
        System.assertNotEquals(null, wrapperById);
        System.assertEquals(oa.Id, wrapperById.planId);
        System.assertEquals('Distributor Account', wrapperById.procurementAccountName, 'Procurement Account should resolve to Distributor');
        System.assertEquals(dealerLoc.Id, wrapperById.destinationLocationId, 'Reserve location should resolve to Dealer location');
        System.assertEquals(1, wrapperById.lineItems.size());
        System.assertEquals(50, wrapperById.lineItems[0].destinationStock, 'Destination stock is 50');

        // Verify transferLocations does not contain Requesting Account location
        for (SupplyOrderPlanner.LocationInfo tLoc : wrapperById.transferLocations) {
            System.assertNotEquals(locA.Id, tLoc.locationId, 'Requesting location must be excluded from transfer columns');
        }

        // 2. Fetch by Plan Name (re-query to get auto-number Name)
        Order_Allocation__c reQueriedOa = [SELECT Id, Name FROM Order_Allocation__c WHERE Id = :oa.Id];
        SupplyOrderPlanner.PlanWrapper wrapperByName = SupplyOrderPlanner.getSupplyPlanData(reQueriedOa.Name);
        System.assertEquals(oa.Id, wrapperByName.planId);

        // 3. Update single line item review status
        SupplyOrderPlanner.updateLineItemReviewStatus(oali.Id, true);
        Order_Allocation_Line_Item__c reviewedLi = [SELECT Is_Reviewed__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        System.assertEquals(true, reviewedLi.Is_Reviewed__c);

        // 4. Update bulk line items review status
        SupplyOrderPlanner.updateBulkLineItemReviewStatus(new List<Id>{ oali.Id }, false);
        Order_Allocation_Line_Item__c unReviewedLi = [SELECT Is_Reviewed__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        System.assertEquals(false, unReviewedLi.Is_Reviewed__c);

        // 5. Invalid query parameters
        try {
            SupplyOrderPlanner.getSupplyPlanData('');
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            SupplyOrderPlanner.getSupplyPlanData('NON_EXISTENT_ID');
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        Test.stopTest();
    }

    @isTest
    static void testSubmitPlanningRollbackOnFailure() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer Account' LIMIT 1];
        Account retailerA = [SELECT Id FROM Account WHERE Name = 'Retailer A' LIMIT 1];
        Inventory_Location__c locA = [SELECT Id FROM Inventory_Location__c WHERE Account__c = :retailerA.Id LIMIT 1];
        Item__c macMini = [SELECT Id FROM Item__c WHERE Item_Code__c = 'MAC-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailerA.Id,
            Supplying_Account__c = dealer.Id,
            Target_Location__c = locA.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = macMini.Id,
            Ordered_Qty__c = 500,
            Is_Reviewed__c = false
        );
        insert oali;

        // Attempt to reserve 500 when only 50 available in stock -> throws INSUFFICIENT_STOCK
        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = oali.Id;
        alloc.reserveQty = 500;
        alloc.procureQty = 0;
        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>();

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            SupplyOrderPlanner.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });
        } catch (AuraHandledException aex) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Exception should be thrown for insufficient stock');

        // Verify status rolled back to Draft on Order Allocation and not Planned on OALI
        Order_Allocation__c rolledBackOa = [SELECT Status__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Draft', rolledBackOa.Status__c, 'Order Allocation status must remain Draft after rollback');

        Order_Allocation_Line_Item__c rolledBackOali = [SELECT Status__c, Reserved_Qty_Planned__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        System.assertNotEquals('Planned', rolledBackOali.Status__c, 'OALI status must not be Planned after rollback');
    }
}