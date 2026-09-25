@isTest
private class ItemPriceServiceTest {

    @TestSetup
    static void setupTestData() {
        // Create Accounts (Distributor & Dealer)
        Account abcDistributors = new Account(Name = 'ABC Distributors');
        Account speedMotors = new Account(Name = 'Speed Motors');
        insert new List<Account>{ abcDistributors, speedMotors };

        // Create Inventory Locations
        Inventory_Location__c abcLocation = new Inventory_Location__c(
            Name = 'ABC Hyderabad',
            Account__c = abcDistributors.Id,
            Is_Active__c = true
        );
        Inventory_Location__c speedLocation = new Inventory_Location__c(
            Name = 'Speed Motors Location',
            Account__c = speedMotors.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ abcLocation, speedLocation };

        // Create Item
        Item__c pump = new Item__c(
            Name = 'Hydraulic Pump',
            Item_Code__c = 'HP-001',
            Active__c = true
        );
        insert pump;

        // Create Active Item Price for Speed Motors (₹6,000, 10% Discount, 18% Tax)
        Item_Price__c speedPrice = new Item_Price__c(
            Item_Price_Account__c = speedMotors.Id,
            Inventory_Location__c = speedLocation.Id,
            Item__c = pump.Id,
            Unit_Price__c = 6000,
            Discount__c = 10,
            Tax__c = 18,
            Active__c = true
        );

        // Create Active Item Price for ABC Distributors (₹5,500, 5% Discount, 18% Tax)
        Item_Price__c abcPrice = new Item_Price__c(
            Item_Price_Account__c = abcDistributors.Id,
            Inventory_Location__c = abcLocation.Id,
            Item__c = pump.Id,
            Unit_Price__c = 5500,
            Discount__c = 5,
            Tax__c = 18,
            Active__c = true
        );

        insert new List<Item_Price__c>{ speedPrice, abcPrice };
    }

    /**
     * TEST 1: External Order Item already has price ₹6,000 -> Price remains ₹6,000.
     */
    @isTest
    static void testExternalOrderItemPreservesPrice() {
        OrderItem itemWithPrice = new OrderItem(UnitPrice = 6000);
        Test.startTest();
        ItemPriceService.applyOrderItemPricing(new List<OrderItem>{ itemWithPrice });
        Test.stopTest();

        System.assertEquals(6000, itemWithPrice.UnitPrice, 'Existing external order item price must be preserved.');
    }

    /**
     * TEST 2: Order Item has no price -> Matching active Item_Price__c exists at ₹6,000 -> Price becomes ₹6,000.
     */
    @isTest
    static void testOrderItemDefaultsPriceFromItemPrice() {
        Account speedMotors = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];
        Inventory_Location__c speedLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Speed Motors Location' LIMIT 1];
        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        Test.startTest();
        Decimal resolvedPrice = ItemPriceService.resolvePrice(speedMotors.Id, pump.Id, speedLoc.Id);
        ItemPriceService.PriceResolutionResult fullRes = ItemPriceService.resolveFullPricing(speedMotors.Id, pump.Id, speedLoc.Id);
        Test.stopTest();

        System.assertEquals(6000, resolvedPrice, 'OrderItem price should be resolved to 6000.');
        System.assertEquals(10, fullRes.discountPercent, 'Discount % should be resolved to 10.');
        System.assertEquals(18, fullRes.taxPercent, 'Tax % should be resolved to 18.');
    }

    /**
     * TEST 3: OALI already has price ₹6,000 -> Price remains ₹6,000.
     */
    @isTest
    static void testOALIPreservesExistingPrice() {
        Account speedMotors = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];
        Inventory_Location__c speedLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Speed Motors Location' LIMIT 1];
        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = speedMotors.Id,
            Source_Location__c = speedLoc.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 10,
            Unit_Price__c = 6000,
            Discount_Percent__c = 15,
            Tax__c = 12
        );

        Test.startTest();
        insert oali;
        Test.stopTest();

        Order_Allocation_Line_Item__c result = [SELECT Id, Unit_Price__c, Discount_Percent__c, Tax__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        System.assertEquals(6000, result.Unit_Price__c, 'Existing OALI price of 6000 must not be overwritten.');
        System.assertEquals(15, result.Discount_Percent__c, 'Existing discount percent of 15% must not be overwritten.');
        System.assertEquals(12, result.Tax__c, 'Existing tax percent of 12% must not be overwritten.');
    }

    /**
     * TEST 4: OALI has no price -> Matching active Item_Price__c exists at ₹5,500 -> OALI price, discount, tax default.
     */
    @isTest
    static void testOALIDefaultsPriceDiscountAndTax() {
        Account abc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Inventory_Location__c abcLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'ABC Hyderabad' LIMIT 1];
        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = abc.Id,
            Source_Location__c = abcLoc.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 50,
            Unit_Price__c = null // Blank price
        );

        Test.startTest();
        insert oali;
        Test.stopTest();

        Order_Allocation_Line_Item__c result = [SELECT Id, Unit_Price__c, Discount_Percent__c, Tax__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        System.assertEquals(5500, result.Unit_Price__c, 'OALI price should default to 5500 from active Item_Price__c.');
        System.assertEquals(5, result.Discount_Percent__c, 'OALI discount should default to 5% from active Item_Price__c.');
        System.assertEquals(18, result.Tax__c, 'OALI tax should default to 18% from active Item_Price__c.');
    }

    /**
     * TEST 5: Purchase Order Line Item (POLI) defaults Price, Discount %, and Tax %.
     */
    @isTest
    static void testPOLIDefaultsPriceDiscountAndTax() {
        Account speedMotors = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];
        Inventory_Location__c speedLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Speed Motors Location' LIMIT 1];
        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        Purchase_Order__c po = new Purchase_Order__c(
            Supplying_Account__c = speedMotors.Id,
            Source_Location__c = speedLoc.Id,
            Status__c = 'Draft'
        );
        insert po;

        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 20,
            Unit_Price__c = null // Blank price
        );

        Test.startTest();
        insert poli;
        Test.stopTest();

        Purchase_Order_Line_Item__c result = [SELECT Id, Unit_Price__c, Discount__c, Tax__c FROM Purchase_Order_Line_Item__c WHERE Id = :poli.Id];
        System.assertEquals(6000, result.Unit_Price__c, 'POLI price should default to 6000 from active Item_Price__c.');
        System.assertEquals(10, result.Discount__c, 'POLI discount should default to 10% from active Item_Price__c.');
        System.assertEquals(18, result.Tax__c, 'POLI tax should default to 18% from active Item_Price__c.');
    }

    /**
     * TEST 6: No active Item_Price__c exists -> Transaction creation fails with a clear pricing configuration error.
     */
    @isTest
    static void testMissingActiveItemPriceFailsValidation() {
        Account unconfiguredAcc = new Account(Name = 'Unconfigured Supplier');
        insert unconfiguredAcc;

        Inventory_Location__c unconfiguredLoc = new Inventory_Location__c(
            Name = 'Unconfigured Loc',
            Account__c = unconfiguredAcc.Id,
            Is_Active__c = true
        );
        insert unconfiguredLoc;

        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = unconfiguredAcc.Id,
            Source_Location__c = unconfiguredLoc.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 10,
            Unit_Price__c = null
        );

        Test.startTest();
        Boolean errorThrown = false;
        try {
            insert oali;
        } catch (DmlException e) {
            errorThrown = true;
            System.assert(e.getMessage().contains('Active Item Price is not configured'), 
                'Expected not configured error message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(errorThrown, 'Expected DmlException when no active Item Price exists.');
    }

    /**
     * TEST 7: Inactive Item_Price__c exists -> Inactive price is ignored, error returned if no active price exists.
     */
    @isTest
    static void testInactiveItemPriceIsIgnored() {
        Account inactiveAcc = new Account(Name = 'Inactive Supplier');
        insert inactiveAcc;

        Inventory_Location__c inactiveLoc = new Inventory_Location__c(
            Name = 'Inactive Loc',
            Account__c = inactiveAcc.Id,
            Is_Active__c = true
        );
        insert inactiveLoc;

        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        // Create INACTIVE Item_Price__c
        Item_Price__c inactivePrice = new Item_Price__c(
            Item_Price_Account__c = inactiveAcc.Id,
            Inventory_Location__c = inactiveLoc.Id,
            Item__c = pump.Id,
            Unit_Price__c = 4000,
            Discount__c = 5,
            Tax__c = 18,
            Active__c = false // Inactive
        );
        insert inactivePrice;

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = inactiveAcc.Id,
            Source_Location__c = inactiveLoc.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 10,
            Unit_Price__c = null
        );

        Test.startTest();
        Boolean errorThrown = false;
        try {
            insert oali;
        } catch (DmlException e) {
            errorThrown = true;
            System.assert(e.getMessage().contains('Active Item Price is not configured'), 
                'Expected not configured error message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(errorThrown, 'Inactive Item Price must be ignored and cause failure.');
    }

    /**
     * TEST 8: Two active Item_Price__c records exist for same Account + Item + Inventory Location -> Duplicate error.
     */
    @isTest
    static void testDuplicateActiveItemPricesFailValidation() {
        Account speedMotors = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];
        Inventory_Location__c speedLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Speed Motors Location' LIMIT 1];
        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        // Insert a duplicate active price for Speed Motors
        Item_Price__c dupPrice = new Item_Price__c(
            Item_Price_Account__c = speedMotors.Id,
            Inventory_Location__c = speedLoc.Id,
            Item__c = pump.Id,
            Unit_Price__c = 6200,
            Active__c = true
        );
        insert dupPrice;

        Order_Allocation__c oa = new Order_Allocation__c(
            Supplying_Account__c = speedMotors.Id,
            Source_Location__c = speedLoc.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 10,
            Unit_Price__c = null
        );

        Test.startTest();
        Boolean errorThrown = false;
        try {
            insert oali;
        } catch (DmlException e) {
            errorThrown = true;
            System.assert(e.getMessage().contains('Multiple active Item Price records exist'), 
                'Expected duplicate active error message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(errorThrown, 'Duplicate active Item Prices must cause a validation error.');
    }

    /**
     * TEST 9: Upstream Procurement Hierarchy Scenario.
     */
    @isTest
    static void testUpstreamProcurementPricingHierarchy() {
        Account speedMotors = [SELECT Id FROM Account WHERE Name = 'Speed Motors' LIMIT 1];
        Inventory_Location__c speedLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Speed Motors Location' LIMIT 1];

        Account abc = [SELECT Id FROM Account WHERE Name = 'ABC Distributors' LIMIT 1];
        Inventory_Location__c abcLoc = [SELECT Id FROM Inventory_Location__c WHERE Name = 'ABC Hyderabad' LIMIT 1];

        Item__c pump = [SELECT Id FROM Item__c WHERE Item_Code__c = 'HP-001' LIMIT 1];

        // 1. Customer Order Allocation for Speed Motors
        Order_Allocation__c customerOA = new Order_Allocation__c(
            Supplying_Account__c = speedMotors.Id,
            Source_Location__c = speedLoc.Id,
            Status__c = 'Draft'
        );
        insert customerOA;

        // Customer OALI with external price ₹6,000
        Order_Allocation_Line_Item__c customerOALI = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = customerOA.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 100,
            Unit_Price__c = 6000 // Preserved external selling price
        );

        // 2. Upstream Order Allocation for ABC Distributors
        Order_Allocation__c upstreamOA = new Order_Allocation__c(
            Supplying_Account__c = abc.Id,
            Source_Location__c = abcLoc.Id,
            Status__c = 'Draft'
        );
        insert upstreamOA;

        // Upstream OALI created without price (should default to ABC's ₹5,500)
        Order_Allocation_Line_Item__c upstreamOALI = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = upstreamOA.Id,
            Item__c = pump.Id,
            Ordered_Qty__c = 50,
            Unit_Price__c = null
        );

        Test.startTest();
        insert new List<Order_Allocation_Line_Item__c>{ customerOALI, upstreamOALI };
        Test.stopTest();

        Order_Allocation_Line_Item__c savedCustOALI = [SELECT Id, Unit_Price__c, Discount_Percent__c, Tax__c FROM Order_Allocation_Line_Item__c WHERE Id = :customerOALI.Id];
        Order_Allocation_Line_Item__c savedUpstreamOALI = [SELECT Id, Unit_Price__c, Discount_Percent__c, Tax__c FROM Order_Allocation_Line_Item__c WHERE Id = :upstreamOALI.Id];

        System.assertEquals(6000, savedCustOALI.Unit_Price__c, 'Customer OALI price must remain 6000.');
        System.assertEquals(5500, savedUpstreamOALI.Unit_Price__c, 'Upstream OALI price must resolve to 5500 from ABC Item_Price__c.');
        System.assertEquals(5, savedUpstreamOALI.Discount_Percent__c, 'Upstream OALI discount should default to 5% from ABC Item_Price__c.');
        System.assertEquals(18, savedUpstreamOALI.Tax__c, 'Upstream OALI tax should default to 18% from ABC Item_Price__c.');
    }
}