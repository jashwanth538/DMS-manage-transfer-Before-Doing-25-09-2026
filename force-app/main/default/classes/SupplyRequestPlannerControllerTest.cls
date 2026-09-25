@isTest
private class SupplyRequestPlannerControllerTest {

    @isTest
    static void testGetPendingSupplyRequestsAndConfirmPlan() {
        Account accReq = new Account(Name = 'Kumar Traders(Retailer)');
        Account accSup = new Account(Name = 'Speed Motors(Dealer)');
        Account accOther = new Account(Name = 'Ravi Traders(Retailer)');
        insert new List<Account>{ accReq, accSup, accOther };

        Item__c item = new Item__c(Name = 'Hydraulic Pump');
        insert item;

        Inventory_Location__c locSup = new Inventory_Location__c(Account__c = accSup.Id);
        Inventory_Location__c locOther = new Inventory_Location__c(Account__c = accOther.Id);
        insert new List<Inventory_Location__c>{ locSup, locOther };

        Inventory__c invSup = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locSup.Id,
            Account__c = accSup.Id,
            Available__c = 800
        );
        Inventory__c invOther = new Inventory__c(
            Item__c = item.Id,
            Inventory_Location__c = locOther.Id,
            Account__c = accOther.Id,
            Available__c = 500
        );
        insert new List<Inventory__c>{ invSup, invOther };

        Supply_Request__c sr = new Supply_Request__c(
            Item__c = item.Id,
            Requesting_Account__c = accReq.Id,
            Supplying_Account__c = accSup.Id,
            Requested_Qty__c = 100,
            Status__c = 'Open'
        );
        insert sr;

        Test.startTest();
        List<SupplyRequestPlannerController.SupplyRequestDTO> dtoList = SupplyRequestPlannerController.getPendingSupplyRequests();
        List<SupplyRequestPlannerController.OrderAllocationDTO> planResults = SupplyRequestPlannerController.confirmPlan(new List<Id>{ sr.Id });
        Test.stopTest();

        System.assertNotEquals(0, dtoList.size(), 'Should return pending supply requests');
        System.assertEquals(1, planResults.size(), 'Should return confirm plan result');
    }
}