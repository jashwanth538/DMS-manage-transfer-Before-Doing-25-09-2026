@isTest
private class OrderAllocationLineItemsComponentsTest {

    @testSetup
    static void setupTestData() {
        Inventory_Location__c loc = new Inventory_Location__c(Name = 'Test Location', Is_Active__c = true);
        insert loc;

        Item__c item = new Item__c(
            Name = 'Test Item',
            Item_Code__c = 'TI-001',
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
        insert item;

        Order_Allocation__c plan = new Order_Allocation__c(
            Target_Location__c = loc.Id,
            Status__c = 'Draft'
        );
        insert plan;

        Order_Allocation_Line_Item__c lineItem = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = plan.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50
        );
        insert lineItem;
    }

    @isTest
    static void testGetOrderAllocationDetails_NullId() {
        Test.startTest();
        Order_Allocation__c result = OrderAllocationLineItemsComponents.getOrderAllocationDetails(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for null recordId');
    }

    @isTest
    static void testGetOrderAllocationDetails_NonExistentId() {
        // Generate a fake Order_Allocation__c Id using key prefix
        String keyPrefix = Order_Allocation__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeId = (Id)(keyPrefix + '000000000001');

        Test.startTest();
        Order_Allocation__c result = OrderAllocationLineItemsComponents.getOrderAllocationDetails(fakeId);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null when no record matches');
    }

    @isTest
    static void testGetOrderAllocationDetails_Success() {
        Order_Allocation__c plan = [SELECT Id FROM Order_Allocation__c LIMIT 1];

        Test.startTest();
        Order_Allocation__c result = OrderAllocationLineItemsComponents.getOrderAllocationDetails(plan.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(plan.Id, result.Id, 'Plan Id should match');
        System.assertNotEquals(null, result.Order_Allocation_Line_Items__r, 'Child line items should be returned');
        System.assertEquals(1, result.Order_Allocation_Line_Items__r.size(), 'Should have 1 child line item');
    }
}