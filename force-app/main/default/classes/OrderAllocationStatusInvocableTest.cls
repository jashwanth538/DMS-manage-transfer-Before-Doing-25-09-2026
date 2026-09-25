@isTest
public class OrderAllocationStatusInvocableTest {

    @isTest
    static void testStatusRollupToReadyToShip() {
        Order_Allocation__c oa = new Order_Allocation__c(
            Status__c = 'Confirmed Planning'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Planned',
            Ordered_Qty__c = 10,
            Reserved_Quantity__c = 10
        );
        Order_Allocation_Line_Item__c oali2 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Planned',
            Ordered_Qty__c = 5,
            Reserved_Quantity__c = 5
        );
        insert new List<Order_Allocation_Line_Item__c>{ oali1, oali2 };

        OrderAllocationStatusInvocable.Request req = new OrderAllocationStatusInvocable.Request();
        req.oaId = oa.Id;

        Test.startTest();
        OrderAllocationStatusInvocable.processRecords(new List<OrderAllocationStatusInvocable.Request>{ req });
        Test.stopTest();

        Order_Allocation__c updatedOa = [SELECT Id, Status__c, Ready_to_Ship_Date__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Ready to Ship', updatedOa.Status__c, 'Parent OA status should be updated to Ready to Ship');
        System.assertNotEquals(null, updatedOa.Ready_to_Ship_Date__c, 'Ready to Ship Date should be set');
    }

    @isTest
    static void testStatusRollupToShipped() {
        Order_Allocation__c oa = new Order_Allocation__c(
            Status__c = 'Ready to Ship'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Shipped',
            Ordered_Qty__c = 10
        );
        Order_Allocation_Line_Item__c oali2 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Shipped',
            Ordered_Qty__c = 5
        );
        insert new List<Order_Allocation_Line_Item__c>{ oali1, oali2 };

        OrderAllocationStatusInvocable.Request req = new OrderAllocationStatusInvocable.Request();
        req.oaId = oa.Id;

        Test.startTest();
        OrderAllocationStatusInvocable.processRecords(new List<OrderAllocationStatusInvocable.Request>{ req });
        Test.stopTest();

        Order_Allocation__c updatedOa = [SELECT Id, Status__c, Shipped_Date__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Shipped', updatedOa.Status__c, 'Parent OA status should be updated to Shipped');
        System.assertNotEquals(null, updatedOa.Shipped_Date__c, 'Shipped Date should be set');
    }

    @isTest
    static void testStatusRollupToDelivered() {
        Order_Allocation__c oa = new Order_Allocation__c(
            Status__c = 'Shipped'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Delivered',
            Ordered_Qty__c = 10
        );
        Order_Allocation_Line_Item__c oali2 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Delivered',
            Ordered_Qty__c = 5
        );
        insert new List<Order_Allocation_Line_Item__c>{ oali1, oali2 };

        OrderAllocationStatusInvocable.Request req = new OrderAllocationStatusInvocable.Request();
        req.oaId = oa.Id;

        Test.startTest();
        OrderAllocationStatusInvocable.processRecords(new List<OrderAllocationStatusInvocable.Request>{ req });
        Test.stopTest();

        Order_Allocation__c updatedOa = [SELECT Id, Status__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Delivered', updatedOa.Status__c, 'Parent OA status should be updated to Delivered');
    }
}