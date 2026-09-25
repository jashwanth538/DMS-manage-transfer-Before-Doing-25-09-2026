@isTest
private class OrderAllocLineItemHandlerTest {

    @isTest
    static void testTriggerAfterUpdateTriggersStatusService() {
        Order_Allocation__c oa = new Order_Allocation__c(
            Status__c = 'Confirmed Planning'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Planned',
            Ordered_Qty__c = 10,
            Reserved_Quantity__c = 0
        );
        insert oali;

        Test.startTest();
        // Update Reserved_Quantity__c to 10 (fulfilling the 10 ordered)
        oali.Reserved_Quantity__c = 10;
        update oali;
        Test.stopTest();

        // Verify Trigger -> OrderAllocationLineItemTriggerHandler -> OrderAllocationStatusService transitioned records
        Order_Allocation_Line_Item__c updatedLi = [
            SELECT Id, Status__c, Ready_to_Ship_Date__c 
            FROM Order_Allocation_Line_Item__c 
            WHERE Id = :oali.Id
        ];
        System.assertEquals('Ready to Ship', updatedLi.Status__c, 'OALI should be set to Ready to Ship via trigger');
        System.assertNotEquals(null, updatedLi.Ready_to_Ship_Date__c);

        Order_Allocation__c updatedOa = [
            SELECT Id, Status__c, Ready_to_Ship_Date__c 
            FROM Order_Allocation__c 
            WHERE Id = :oa.Id
        ];
        System.assertEquals('Ready to Ship', updatedOa.Status__c, 'OA should roll up to Ready to Ship via trigger');
        System.assertNotEquals(null, updatedOa.Ready_to_Ship_Date__c);
    }

    @isTest
    static void testTriggerTransitionToReadyToShip() {
        Order_Allocation__c oa = new Order_Allocation__c(Status__c = 'Confirmed Planning');
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Status__c = 'Planned',
            Ordered_Qty__c = 5
        );
        insert oali;

        Test.startTest();
        oali.Status__c = 'Ready to Ship';
        update oali;
        Test.stopTest();

        Order_Allocation_Line_Item__c checkLi = [SELECT Status__c FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id];
        System.assertEquals('Ready to Ship', checkLi.Status__c);
    }
}