@isTest
private class SupplyPlanControllerTest {

    @testSetup
    static void setupTestData() {
        Account customer = new Account(Name = 'Test Customer');
        insert customer;

        Contact contact = new Contact(FirstName = 'John', LastName = 'Doe', AccountId = customer.Id);
        insert contact;

        Inventory_Location__c destLoc = new Inventory_Location__c(Name = 'Dest Warehouse', Is_Active__c = true);
        Inventory_Location__c sourceLoc = new Inventory_Location__c(Name = 'Source Warehouse', Is_Active__c = true);
        insert new List<Inventory_Location__c>{ destLoc, sourceLoc };

        Item__c item1 = new Item__c(
            Name = 'Item 1',
            Item_Code__c = 'ITM-001',
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
            Name = 'Item 2',
            Item_Code__c = 'ITM-002',
            Default_Supply_Method__c = 'Manufacture',
            Base_Tax__c = 0,
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'EA',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 10,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 100
        );
        insert new List<Item__c>{ item1, item2 };

        Inventory__c inv1 = new Inventory__c(
            Item__c = item1.Id,
            Inventory_Location__c = destLoc.Id,
            Available__c = 50
        );
        Inventory__c inv2 = new Inventory__c(
            Item__c = item1.Id,
            Inventory_Location__c = sourceLoc.Id,
            Available__c = 30
        );
        insert new List<Inventory__c>{ inv1, inv2 };

        Order_Allocation__c draftPlan = new Order_Allocation__c(
            Target_Location__c = destLoc.Id,
            Customer__c = customer.Id,
            Requesting_Account__c = customer.Id,
            Supplying_Account__c = customer.Id,
            Bill_To_Contact__c = contact.Id,
            Status__c = 'Draft'
        );
        Order_Allocation__c executedPlan = new Order_Allocation__c(
            Target_Location__c = destLoc.Id,
            Customer__c = customer.Id,
            Requesting_Account__c = customer.Id,
            Supplying_Account__c = customer.Id,
            Bill_To_Contact__c = contact.Id,
            Status__c = 'Confirmed Planning'
        );
        insert new List<Order_Allocation__c>{ draftPlan, executedPlan };

        Order_Allocation_Line_Item__c draftLine = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = draftPlan.Id,
            Item__c = item1.Id,
            Ordered_Qty__c = 100
        );
        Order_Allocation_Line_Item__c executedLine = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = executedPlan.Id,
            Item__c = item1.Id,
            Ordered_Qty__c = 100,
            Reserved_Qty_Planned__c = 40,
            Transfer_Qty_Planned__c = 30
        );
        insert new List<Order_Allocation_Line_Item__c>{ draftLine, executedLine };

        Inventory_Transfer__c transfer = new Inventory_Transfer__c(
            Order_Allocation_Line_Item__c = executedLine.Id,
            Item__c = item1.Id,
            Source_Inventory_Location__c = sourceLoc.Id,
            Destination_Inventory_Location__c = destLoc.Id,
            Transfer_Qty__c = 30,
            Status__c = 'Requested'
        );
        insert transfer;
    }

    @isTest
    static void testSearchSupplyPlans_BlankKey() {
        Test.startTest();
        LWCServerCalloutWrapper wrapper = SupplyPlanController.searchSupplyPlans('');
        Test.stopTest();

        System.assertEquals(true, wrapper.isSuccess);
        System.assertNotEquals(null, wrapper.resultList, 'Result list should return recent records for blank search key');
    }

    @isTest
    static void testSearchSupplyPlans_Success() {
        Order_Allocation__c plan = [SELECT Id, Name FROM Order_Allocation__c LIMIT 1];

        Test.startTest();
        LWCServerCalloutWrapper wrapper = SupplyPlanController.searchSupplyPlans(plan.Name);
        Test.stopTest();

        System.assertEquals(true, wrapper.isSuccess);
        System.assertNotEquals(null, wrapper.resultList);
        System.assert(wrapper.resultList.size() > 0);
    }

    @isTest
    static void testGetSupplyPlanDetails_BlankId() {
        Test.startTest();
        LWCServerCalloutWrapper wrapper = SupplyPlanController.getSupplyPlanDetails('');
        Test.stopTest();

        System.assertEquals(false, wrapper.isSuccess);
        System.assertEquals('Invalid Plan Identifier', wrapper.errorMsg);
    }

    @isTest
    static void testGetSupplyPlanDetails_ById() {
        Order_Allocation__c plan = [SELECT Id FROM Order_Allocation__c WHERE Status__c = 'Draft' LIMIT 1];

        Test.startTest();
        LWCServerCalloutWrapper wrapper = SupplyPlanController.getSupplyPlanDetails(String.valueOf(plan.Id));
        Test.stopTest();

        System.assertEquals(true, wrapper.isSuccess);
        System.assertNotEquals(null, wrapper.result);
        System.assert(wrapper.referenceCache.containsKey('inventories'));
        System.assert(wrapper.referenceCache.containsKey('transferCount'));
    }

    @isTest
    static void testGetSupplyPlanDetails_ByName() {
        Order_Allocation__c plan = [SELECT Id, Name FROM Order_Allocation__c WHERE Status__c = 'Draft' LIMIT 1];

        Test.startTest();
        LWCServerCalloutWrapper wrapper = SupplyPlanController.getSupplyPlanDetails(plan.Name);
        Test.stopTest();

        System.assertEquals(true, wrapper.isSuccess);
        System.assertNotEquals(null, wrapper.result);
    }

    @isTest
    static void testGetSupplyPlanDetails_NotFound() {
        Test.startTest();
        LWCServerCalloutWrapper wrapper = SupplyPlanController.getSupplyPlanDetails('NON_EXISTENT_PLAN_123');
        Test.stopTest();

        System.assertEquals(false, wrapper.isSuccess);
        System.assertEquals('Plan not found', wrapper.errorMsg);
    }

    @isTest
    static void testGetSupplyPlanSummary_BlankSearch() {
        Test.startTest();
        Map<String, Object> result = SupplyPlanController.getSupplyPlanSummary('');
        Test.stopTest();

        System.assertEquals(false, result.get('isFound'));
    }

    @isTest
    static void testGetSupplyPlanSummary_DraftPlan() {
        Order_Allocation__c draftPlan = [SELECT Id, Name FROM Order_Allocation__c WHERE Status__c = 'Draft' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = SupplyPlanController.getSupplyPlanSummary(draftPlan.Name);
        Test.stopTest();

        System.assertEquals(true, result.get('isFound'));
        System.assertNotEquals(null, result.get('totalRequired'));
        System.assertNotEquals(null, result.get('planDetails'));
    }

    @isTest
    static void testGetSupplyPlanSummary_ExecutedPlan() {
        Order_Allocation__c executedPlan = [SELECT Id, Name FROM Order_Allocation__c WHERE Status__c = 'Confirmed Planning' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = SupplyPlanController.getSupplyPlanSummary(executedPlan.Name);
        Test.stopTest();

        System.assertEquals(true, result.get('isFound'));
        System.assertEquals('Confirmed Planning', result.get('status'));
        System.assertEquals(100, result.get('totalRequired'));
        System.assertEquals(40, result.get('reservedQty'));
        System.assertEquals(30, result.get('transferQty'));
        System.assertEquals(30, result.get('procurementQty'));
        System.assertEquals(100, result.get('totalCovered'));
    }
}