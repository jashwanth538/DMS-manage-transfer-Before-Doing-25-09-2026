@isTest
private class InventoryAvailabilityControllerTest {

    @testSetup
    static void setupTestData() {
        // Create Inventory Location
        Inventory_Location__c loc1 = new Inventory_Location__c(Name = 'Location 1', Is_Active__c = true);
        Inventory_Location__c loc2 = new Inventory_Location__c(Name = 'Location 2', Is_Active__c = true);
        insert new List<Inventory_Location__c>{ loc1, loc2 };

        // Create Items
        Item__c item1 = new Item__c(
            Name = 'Test Product 1',
            Item_Code__c = 'TP-001',
            Default_Supply_Method__c = 'Purchase',
            Base_Tax__c = 0,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'EA',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 10,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100
        );
        Item__c item2 = new Item__c(
            Name = 'Test Product 2',
            Item_Code__c = 'TP-002',
            Default_Supply_Method__c = 'Manufacture',
            Base_Tax__c = 0,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 5,
            Unit_Of_Measure__c = 'EA',
            Target_Stock_Level__c = 50,
            Stock_Low_Level_Quantity__c = 5,
            Stock_Medium_Level_Quantity__c = 25,
            Stock_High_Level_Quantity__c = 50
        );
        insert new List<Item__c>{ item1, item2 };

        // Create Inventory Records with non-null values for item1
        Inventory__c inv1 = new Inventory__c(
            Item__c = item1.Id,
            Inventory_Location__c = loc1.Id,
            Available__c = 100,
            Reserved_Sale_Order__c = 10,
            Reserved_Transfer__c = 5,
            Damaged__c = 2,
            Transit_In_Quantity__c = 25,
            Transit_Out_Quantity__c = 10
        );

        // Create Inventory Records with null values for item2 to test null fallbacks
        Inventory__c inv2 = new Inventory__c(
            Item__c = item2.Id,
            Inventory_Location__c = loc2.Id,
            Available__c = null,
            Reserved_Sale_Order__c = null,
            Reserved_Transfer__c = null,
            Damaged__c = null,
            Transit_In_Quantity__c = null,
            Transit_Out_Quantity__c = null
        );

        insert new List<Inventory__c>{ inv1, inv2 };

        // Create Order Allocation
        Order_Allocation__c plan1 = new Order_Allocation__c(
            Target_Location__c = loc1.Id,
            Status__c = 'Draft'
        );
        Order_Allocation__c planEmpty = new Order_Allocation__c(
            Target_Location__c = loc1.Id,
            Status__c = 'Draft'
        );
        insert new List<Order_Allocation__c>{ plan1, planEmpty };

        // Create Order Allocation Line Items (including duplicate item reference for item1 to test wrapper map containment)
        List<Order_Allocation_Line_Item__c> lineItems = new List<Order_Allocation_Line_Item__c>();
        lineItems.add(new Order_Allocation_Line_Item__c(Order_Allocation__c = plan1.Id, Item__c = item1.Id, Ordered_Qty__c = 50));
        lineItems.add(new Order_Allocation_Line_Item__c(Order_Allocation__c = plan1.Id, Item__c = item1.Id, Ordered_Qty__c = 30));
        lineItems.add(new Order_Allocation_Line_Item__c(Order_Allocation__c = plan1.Id, Item__c = item2.Id, Ordered_Qty__c = 20));
        insert lineItems;
    }

    @isTest
    static void testGetInventoryData_WithData() {
        Order_Allocation__c plan = [SELECT Id FROM Order_Allocation__c WHERE Status__c = 'Draft' AND Id IN (SELECT Order_Allocation__c FROM Order_Allocation_Line_Item__c) LIMIT 1];

        Test.startTest();
        List<InventoryAvailabilityController.ProductInventoryWrapper> results = InventoryAvailabilityController.getInventoryData(plan.Id, null, null, null);
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results list should not be null');
        System.assertEquals(2, results.size(), 'Should return 2 distinct product wrappers');

        // Verify product 1 wrapper
        InventoryAvailabilityController.ProductInventoryWrapper prod1Wrapper;
        InventoryAvailabilityController.ProductInventoryWrapper prod2Wrapper;
        for (InventoryAvailabilityController.ProductInventoryWrapper wrapper : results) {
            if (wrapper.productCode == 'TP-001') {
                prod1Wrapper = wrapper;
            } else if (wrapper.productCode == 'TP-002') {
                prod2Wrapper = wrapper;
            }
        }

        System.assertNotEquals(null, prod1Wrapper, 'Product 1 wrapper should be found');
        System.assertEquals('Test Product 1', prod1Wrapper.productName);
        System.assertEquals(null, prod1Wrapper.productFamily);
        System.assertNotEquals(null, prod1Wrapper.locations, 'Locations list should not be null');
        System.assertEquals(1, prod1Wrapper.locations.size(), 'Product 1 should have 1 location record');

        InventoryAvailabilityController.LocationInventoryWrapper loc1 = prod1Wrapper.locations[0];
        System.assertEquals('Location 1', loc1.locationName);
        System.assertEquals(100, loc1.availableQty);
        System.assertEquals(137, loc1.onHandQty);
        System.assertEquals(10, loc1.reservedSaleOrderQty);
        System.assertEquals(5, loc1.reservedTransferQty);
        System.assertEquals(2, loc1.damagedQty);
        System.assertEquals(25, loc1.transitInQty);
        System.assertEquals(10, loc1.transitOutQty);

        // Verify product 2 wrapper (testing null value fallbacks to 0)
        System.assertNotEquals(null, prod2Wrapper, 'Product 2 wrapper should be found');
        System.assertEquals('Test Product 2', prod2Wrapper.productName);
        System.assertEquals(null, prod2Wrapper.productFamily);
        System.assert(prod2Wrapper.locations.size() > 0, 'Product 2 should have at least 1 location record');

        InventoryAvailabilityController.LocationInventoryWrapper loc2 = prod2Wrapper.locations[0];
        System.assertEquals('Location 2', loc2.locationName);
        System.assertEquals(0, loc2.availableQty);
        System.assertEquals(0, loc2.onHandQty);
        System.assertEquals(0, loc2.reservedSaleOrderQty);
        System.assertEquals(0, loc2.reservedTransferQty);
        System.assertEquals(0, loc2.damagedQty);
        System.assertEquals(0, loc2.transitInQty);
        System.assertEquals(0, loc2.transitOutQty);
    }

    @isTest
    static void testGetInventoryData_FilteredByItemAndLocation() {
        Order_Allocation__c plan = [SELECT Id FROM Order_Allocation__c WHERE Status__c = 'Draft' AND Id IN (SELECT Order_Allocation__c FROM Order_Allocation_Line_Item__c) LIMIT 1];
        Item__c item1 = [SELECT Id FROM Item__c WHERE Item_Code__c = 'TP-001' LIMIT 1];
        Inventory_Location__c loc1 = [SELECT Id FROM Inventory_Location__c WHERE Name = 'Location 1' LIMIT 1];

        Test.startTest();
        List<InventoryAvailabilityController.ProductInventoryWrapper> results = InventoryAvailabilityController.getInventoryData(plan.Id, item1.Id, loc1.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, results);
        System.assertEquals(1, results.size(), 'Should return 1 filtered product');
        System.assertEquals('TP-001', results[0].productCode);
    }

    @isTest
    static void testGetInventoryData_EmptyLineItems() {
        Order_Allocation__c planEmpty = [SELECT Id FROM Order_Allocation__c WHERE Status__c = 'Draft' AND Id NOT IN (SELECT Order_Allocation__c FROM Order_Allocation_Line_Item__c) LIMIT 1];

        Test.startTest();
        List<InventoryAvailabilityController.ProductInventoryWrapper> results = InventoryAvailabilityController.getInventoryData(planEmpty.Id, null, null, null);
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results list should not be null');
        System.assertEquals(0, results.size(), 'Results list should be empty when no line items exist');
    }

    @isTest
    static void testGetInventoryData_NullId() {
        Test.startTest();
        List<InventoryAvailabilityController.ProductInventoryWrapper> results = InventoryAvailabilityController.getInventoryData(null, null, null, null);
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results list should not be null for null input ID');
        System.assertEquals(0, results.size(), 'Results list should be empty for null input ID');
    }
}