@isTest
private class FinancialRecordServiceTest {

    @testSetup
    static void setupTestData() {
        // Create OEM / Supplying Account
        Account supplyingAcc = new Account(
            Name = 'Supplying Account OEM',
            Type = 'OEM'
        );
        insert supplyingAcc;

        // Create Distributor Account (Child of OEM)
        Account requestingAcc = new Account(
            Name = 'Requesting Account Distributor',
            Type = 'Distributor',
            ParentId = supplyingAcc.Id,
            OEM__c = supplyingAcc.Id
        );
        insert requestingAcc;

        // Create Inventory Locations
        Inventory_Location__c suppLoc = new Inventory_Location__c(
            Name = 'Supplying Warehouse',
            Account__c = supplyingAcc.Id,
            Is_Active__c = true
        );
        insert suppLoc;

        Inventory_Location__c reqLoc = new Inventory_Location__c(
            Name = 'Requesting Warehouse',
            Account__c = requestingAcc.Id,
            Is_Active__c = true
        );
        insert reqLoc;

        // Create Item
        Item__c item = new Item__c(
            Name = 'Widget A',
            Item_Code__c = 'WDG-001',
            Target_Days__c = 7,
            Default_Supply_Method__c = 'Purchase'
        );
        insert item;

        // Create Inventory
        Inventory__c inv = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = suppLoc.Id,
            Account__c = supplyingAcc.Id,
            Available__c = 100
        );
        insert inv;

        // Create Order Allocation Header
        Order_Allocation__c plan = new Order_Allocation__c(
            Requesting_Account__c = requestingAcc.Id,
            Supplying_Account__c = supplyingAcc.Id,
            Source_Location__c = suppLoc.Id,
            Target_Location__c = reqLoc.Id,
            Order_Allocation_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert plan;

        // Create Order Allocation Line Item
        Order_Allocation_Line_Item__c planLine = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = plan.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 10,
            Unit_Price__c = 50.00,
            Tax__c = 10.00,
            Discount_Percent__c = 5.00,
            Status__c = 'New'
        );
        insert planLine;
    }

    @isTest
    static void testFinancialRecordCreationOnSubmitPlanning() {
        Order_Allocation_Line_Item__c lineItem = [SELECT Id, Order_Allocation__c FROM Order_Allocation_Line_Item__c LIMIT 1];

        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = lineItem.Id;
        alloc.reserveQty = 0;
        alloc.procureQty = 10;
        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>();

        Test.startTest();
        SupplyOrderGenService.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });
        Test.stopTest();

        // Verify Purchase Order creation
        List<Purchase_Order__c> pos = [SELECT Id, Supplying_Account__c, Requesting_Account__c, Sales_Allocation__c FROM Purchase_Order__c];
        System.assertEquals(1, pos.size(), 'Expected 1 Purchase Order to be created');
        Purchase_Order__c po = pos[0];

        // Verify Purchase Order Line Item creation
        List<Purchase_Order_Line_Item__c> polis = [SELECT Id, Unit_Price__c, Ordered_Qty__c, Tax__c, Discount_Amount__c FROM Purchase_Order_Line_Item__c WHERE Purchase_Order__c = :po.Id];
        System.assertEquals(1, polis.size(), 'Expected 1 Purchase Order Line Item to be created');

        // Verify Invoice creation
        List<Invoice__c> invoices = [SELECT Id, Supplying_Account__c, Requesting_Account__c, Purchase_Order__c, Subtotal__c, Tax_Amount__c, Discount_Amount__c, Total_Amount__c, Status__c FROM Invoice__c WHERE Purchase_Order__c = :po.Id];
        System.assertEquals(1, invoices.size(), 'Expected 1 Invoice to be created');
        Invoice__c inv = invoices[0];
        System.assertEquals(po.Supplying_Account__c, inv.Supplying_Account__c, 'Invoice Supplying Account should match PO Supplying Account');
        System.assertEquals(po.Requesting_Account__c, inv.Requesting_Account__c, 'Invoice Requesting Account should match PO Requesting Account');
        System.assertEquals('Approved', inv.Status__c, 'Invoice Status should be Approved');
        System.assertEquals(500.00, inv.Subtotal__c, 'Subtotal should be 10 * 50 = 500');

        // Verify Invoice Line Item creation
        List<Invoice_Line_Item__c> ilis = [SELECT Id, Invoice__c, Quantity__c, Unit_Price__c, Tax_Rate__c, Discount_Amount__c FROM Invoice_Line_Item__c WHERE Invoice__c = :inv.Id];
        System.assertEquals(1, ilis.size(), 'Expected 1 Invoice Line Item to be created');
        Invoice_Line_Item__c ili = ilis[0];
        System.assertEquals(10, ili.Quantity__c);
        System.assertEquals(50.00, ili.Unit_Price__c);
        System.assertEquals(25.00, ili.Discount_Amount__c);

        // Verify Payable creation
        List<Payable__c> payables = [SELECT Id, Supplying_Account__c, Requesting_Account__c, Purchase_Order__c, Invoice__c, Status__c, Total_Amount__c FROM Payable__c WHERE Purchase_Order__c = :po.Id];
        System.assertEquals(1, payables.size(), 'Expected 1 Payable to be created');
        Payable__c payable = payables[0];
        System.assertEquals(po.Supplying_Account__c, payable.Supplying_Account__c, 'Payable Supplying Account should match PO Supplying Account');
        System.assertEquals(po.Requesting_Account__c, payable.Requesting_Account__c, 'Payable Requesting Account should match PO Requesting Account');
        System.assertEquals(inv.Id, payable.Invoice__c, 'Payable should reference created Invoice');
        System.assertEquals('Unpaid', payable.Status__c, 'Payable Status should be Unpaid');

        // Verify Receivable creation
        List<Receivable__c> receivables = [SELECT Id, Supplying_Account__c, Requesting_Account__c, Purchase_Order__c, Invoice__c, Status__c, Total_Amount__c FROM Receivable__c WHERE Purchase_Order__c = :po.Id];
        System.assertEquals(1, receivables.size(), 'Expected 1 Receivable to be created');
        Receivable__c receivable = receivables[0];
        System.assertEquals(po.Supplying_Account__c, receivable.Supplying_Account__c, 'Receivable Supplying Account should match PO Supplying Account');
        System.assertEquals(po.Requesting_Account__c, receivable.Requesting_Account__c, 'Receivable Requesting Account should match PO Requesting Account');
        System.assertEquals(inv.Id, receivable.Invoice__c, 'Receivable should reference created Invoice');
        System.assertEquals('Unpaid', receivable.Status__c, 'Receivable Status should be Unpaid');
    }

    @isTest
    static void testDuplicatePrevention() {
        Order_Allocation_Line_Item__c lineItem = [SELECT Id, Order_Allocation__c FROM Order_Allocation_Line_Item__c LIMIT 1];

        SupplyOrderPlanner.AllocationWrapper alloc = new SupplyOrderPlanner.AllocationWrapper();
        alloc.lineItemId = lineItem.Id;
        alloc.reserveQty = 0;
        alloc.procureQty = 10;
        alloc.transfers = new List<SupplyOrderPlanner.TransferWrapper>();

        SupplyOrderGenService.submitPlanning(new List<SupplyOrderPlanner.AllocationWrapper>{ alloc });

        Set<Id> poIds = new Map<Id, Purchase_Order__c>([SELECT Id FROM Purchase_Order__c]).keySet();
        System.assert(!poIds.isEmpty());

        Test.startTest();
        // Invoke generation again for the same POs
        FinancialRecordService.generateFinancialRecordsForPOs(poIds);
        Test.stopTest();

        // Assert count remains 1 for each object
        System.assertEquals(1, [SELECT COUNT() FROM Payable__c WHERE Purchase_Order__c IN :poIds]);
        System.assertEquals(1, [SELECT COUNT() FROM Invoice__c WHERE Purchase_Order__c IN :poIds]);
        System.assertEquals(1, [SELECT COUNT() FROM Receivable__c WHERE Purchase_Order__c IN :poIds]);
    }

    @isTest
    static void testNullAndEmptyHandling() {
        Test.startTest();
        FinancialRecordService.generateFinancialRecordsForPOs(null);
        FinancialRecordService.generateFinancialRecordsForPOs(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c]);
    }
}