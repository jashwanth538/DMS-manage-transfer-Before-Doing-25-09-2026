@isTest
private class OrderAllocationStatusServiceTest {

    @isTest
    static void testRollupWhenPassedOaIdOnly() {
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

        Test.startTest();
        // Invoke passing parent OA Id only
        OrderAllocationStatusService.processStatus(null, new Set<Id>{ oa.Id });
        Test.stopTest();

        // Verify child line items are updated to Ready to Ship
        List<Order_Allocation_Line_Item__c> updatedLines = [
            SELECT Id, Status__c, Ready_to_Ship_Date__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Order_Allocation__c = :oa.Id
        ];
        System.assertEquals(2, updatedLines.size());
        for (Order_Allocation_Line_Item__c li : updatedLines) {
            System.assertEquals('Ready to Ship', li.Status__c, 'Child OALI must be updated to Ready to Ship');
            System.assertNotEquals(null, li.Ready_to_Ship_Date__c, 'Child OALI Ready_to_Ship_Date__c must be set');
        }

        // Verify parent OA rolled up to Ready to Ship
        Order_Allocation__c updatedOa = [
            SELECT Id, Status__c, Ready_to_Ship_Date__c 
            FROM Order_Allocation__c 
            WHERE Id = :oa.Id
        ];
        System.assertEquals('Ready to Ship', updatedOa.Status__c, 'Parent OA status should be updated to Ready to Ship');
        System.assertNotEquals(null, updatedOa.Ready_to_Ship_Date__c, 'Parent OA Ready_to_Ship_Date__c must be set');
    }

    @isTest
    static void testRollupWhenPassedOaliIdOnly() {
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
        insert oali1;

        Test.startTest();
        // Invoke passing child OALI Id only
        OrderAllocationStatusService.processStatus(new Set<Id>{ oali1.Id }, null);
        Test.stopTest();

        Order_Allocation__c updatedOa = [SELECT Id, Status__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Ready to Ship', updatedOa.Status__c, 'Parent OA should roll up when only OALI ID passed');
    }

    @isTest
    static void testInvocableMethodExecution() {
        Order_Allocation__c oa = new Order_Allocation__c(
            Status__c = 'Confirmed Planning'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Planned',
            Ordered_Qty__c = 20,
            Transfer_Qty_Received__c = 20
        );
        insert oali;

        OrderAllocationStatusService.StatusRequest req = new OrderAllocationStatusService.StatusRequest();
        req.oaId = oa.Id;

        Test.startTest();
        OrderAllocationStatusService.processRecordsInvocable(new List<OrderAllocationStatusService.StatusRequest>{ req });
        Test.stopTest();

        Order_Allocation__c updatedOa = [SELECT Id, Status__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Ready to Ship', updatedOa.Status__c);
    }

    @isTest
    static void testShippedAndDeliveredRollups() {
        Order_Allocation__c oaS = new Order_Allocation__c(Status__c = 'Ready to Ship');
        Order_Allocation__c oaD = new Order_Allocation__c(Status__c = 'Shipped');
        insert new List<Order_Allocation__c>{ oaS, oaD };

        Order_Allocation_Line_Item__c liS1 = new Order_Allocation_Line_Item__c(Order_Allocation__c = oaS.Id, Status__c = 'Shipped', Ordered_Qty__c = 5);
        Order_Allocation_Line_Item__c liS2 = new Order_Allocation_Line_Item__c(Order_Allocation__c = oaS.Id, Status__c = 'Shipped', Ordered_Qty__c = 5);
        Order_Allocation_Line_Item__c liD1 = new Order_Allocation_Line_Item__c(Order_Allocation__c = oaD.Id, Status__c = 'Delivered', Ordered_Qty__c = 5);
        insert new List<Order_Allocation_Line_Item__c>{ liS1, liS2, liD1 };

        Test.startTest();
        OrderAllocationStatusService.processStatus(null, new Set<Id>{ oaS.Id, oaD.Id });
        Test.stopTest();

        Order_Allocation__c resS = [SELECT Status__c, Shipped_Date__c FROM Order_Allocation__c WHERE Id = :oaS.Id];
        System.assertEquals('Shipped', resS.Status__c);
        System.assertNotEquals(null, resS.Shipped_Date__c);

        Order_Allocation__c resD = [SELECT Status__c FROM Order_Allocation__c WHERE Id = :oaD.Id];
        System.assertEquals('Delivered', resD.Status__c);
    }

    @isTest
    static void testPartialFulfillmentDoesNotRollup() {
        Order_Allocation__c oa = new Order_Allocation__c(Status__c = 'Confirmed Planning');
        insert oa;

        // Line 1 fulfilled, Line 2 partially fulfilled
        Order_Allocation_Line_Item__c oali1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Planned',
            Ordered_Qty__c = 10,
            Reserved_Quantity__c = 10
        );
        Order_Allocation_Line_Item__c oali2 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Planned',
            Ordered_Qty__c = 10,
            Reserved_Quantity__c = 5 // remaining 5
        );
        insert new List<Order_Allocation_Line_Item__c>{ oali1, oali2 };

        Test.startTest();
        OrderAllocationStatusService.processStatus(null, new Set<Id>{ oa.Id });
        Test.stopTest();

        // Line 1 should be Ready to Ship, Line 2 should remain Planned
        Order_Allocation_Line_Item__c updatedLi1 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali1.Id];
        Order_Allocation_Line_Item__c updatedLi2 = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali2.Id];
        System.assertEquals('Ready to Ship', updatedLi1.Status__c);
        System.assertEquals('Planned', updatedLi2.Status__c);

        // Parent OA must not become Ready to Ship because line 2 is still Planned
        Order_Allocation__c updatedOa = [SELECT Status__c FROM Order_Allocation__c WHERE Id = :oa.Id];
        System.assertEquals('Confirmed Planning', updatedOa.Status__c);
    }

    @isTest
    static void testNullAndEmptyInputs() {
        Test.startTest();
        OrderAllocationStatusService.processRecordsInvocable(null);
        OrderAllocationStatusService.processRecordsInvocable(new List<OrderAllocationStatusService.StatusRequest>());
        OrderAllocationStatusService.processStatus(null, null);
        OrderAllocationStatusService.processStatus(new Set<Id>(), new Set<Id>());
        Test.stopTest();
        System.assert(true, 'Must handle null and empty inputs gracefully');
    }
}