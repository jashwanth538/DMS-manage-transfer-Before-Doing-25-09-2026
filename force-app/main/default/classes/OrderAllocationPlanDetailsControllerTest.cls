@isTest
private class OrderAllocationPlanDetailsControllerTest {

    @testSetup
    static void setupTestData() {
        Account customer = new Account(Name = 'Test Customer');
        Account supplyingAcc = new Account(Name = 'Supplying Distributor');
        insert new List<Account>{ customer, supplyingAcc };

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
            Unit_Of_Measure__c = 'EA'
        );
        insert item1;

        Supply_Request__c transferSR = new Supply_Request__c(
            Item__c = item1.Id,
            Requested_Qty__c = 20,
            Request_Type__c = 'Transfer SR',
            Status__c = 'Draft',
            Requesting_Account__c = customer.Id,
            Supplying_Account__c = customer.Id,
            Source_Location__c = sourceLoc.Id,
            Target_Location__c = destLoc.Id
        );
        insert transferSR;

        Purchase_Order__c po = new Purchase_Order__c(
            Requesting_Account__c = customer.Id,
            Supplying_Account__c = supplyingAcc.Id,
            Target_Location__c = destLoc.Id,
            Status__c = 'Draft'
        );
        insert po;

        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = item1.Id,
            Ordered_Qty__c = 30
        );
        insert poli;

        Order_Allocation__c plan = new Order_Allocation__c(
            Target_Location__c = destLoc.Id,
            Customer__c = customer.Id,
            Requesting_Account__c = customer.Id,
            Supplying_Account__c = supplyingAcc.Id,
            Bill_To_Contact__c = contact.Id,
            Status__c = 'Confirmed Planning'
        );
        insert plan;

        po.Sales_Allocation__c = plan.Id;
        update po;

        // Second PO linked to the Order Allocation (e.g., Transfer PO)
        Purchase_Order__c transferPo = new Purchase_Order__c(
            Requesting_Account__c = customer.Id,
            Supplying_Account__c = supplyingAcc.Id,
            Sales_Allocation__c = plan.Id,
            Target_Location__c = destLoc.Id,
            Status__c = 'Draft'
        );
        insert transferPo;

        Purchase_Order_Line_Item__c transferPoli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = transferPo.Id,
            Item__c = item1.Id,
            Ordered_Qty__c = 20
        );
        insert transferPoli;

        Order_Allocation_Line_Item__c line1 = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = plan.Id,
            Item__c = item1.Id,
            Ordered_Qty__c = 100,
            Supply_Request__c = transferSR.Id,
            Purchase_Order_Line_Item__c = poli.Id
        );
        insert line1;

        transferSR.Order_Allocation_Line_Item__c = line1.Id;
        update transferSR;

        Inventory_Reservation__c res = new Inventory_Reservation__c(
            Order_Allocation_Line_Item__c = line1.Id,
            Item__c = item1.Id,
            Inventory_Location__c = destLoc.Id,
            Reserved_Qty__c = 10,
            Status__c = 'Reserved'
        );
        insert res;

        Inventory_Transfer__c trf = new Inventory_Transfer__c(
            Order_Allocation_Line_Item__c = line1.Id,
            Item__c = item1.Id,
            Source_Inventory_Location__c = sourceLoc.Id,
            Destination_Inventory_Location__c = destLoc.Id,
            Transfer_Qty__c = 20,
            Status__c = 'Requested'
        );
        insert trf;
    }

    @isTest
    static void testGetSupplyPlanSummary_ById() {
        Order_Allocation__c plan = [SELECT Id, Name FROM Order_Allocation__c LIMIT 1];
        Test.startTest();
        Map<String, Object> result = OrderAllocationPlanDetailsController.getSupplyPlanSummary(plan.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, (Boolean)result.get('isFound'));
        List<Map<String, Object>> details = (List<Map<String, Object>>)result.get('planDetails');
        System.assertNotEquals(0, details.size());

        Boolean hasPurchaseOrder = false;
        Boolean hasTransferSr = false;
        Boolean hasReservation = false;
        Integer poCount = 0;
        for (Map<String, Object> d : details) {
            String st = (String)d.get('sourceType');
            if (st == 'Purchase Order') {
                hasPurchaseOrder = true;
                poCount++;
            } else if (st == 'Transfer SR') {
                hasTransferSr = true;
            } else if (st == 'Reservation') {
                hasReservation = true;
            }
        }
        System.assertEquals(true, hasPurchaseOrder, 'Must contain Purchase Order row');
        System.assert(poCount >= 2, 'Must query both Purchase Orders linked to the Order Allocation');
        System.assertEquals(true, hasTransferSr, 'Must contain Transfer SR row');
        System.assertEquals(true, hasReservation, 'Must contain Reservation row');
    }

    @isTest
    static void testGetSupplyPlanSummary_ByName() {
        Order_Allocation__c plan = [SELECT Id, Name FROM Order_Allocation__c LIMIT 1];
        Test.startTest();
        Map<String, Object> result = OrderAllocationPlanDetailsController.getSupplyPlanSummary(plan.Name);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, (Boolean)result.get('isFound'));
    }

    @isTest
    static void testGetSupplyPlanSummary_Blank() {
        Test.startTest();
        Map<String, Object> result = OrderAllocationPlanDetailsController.getSupplyPlanSummary('');
        Test.stopTest();

        System.assertEquals(false, (Boolean)result.get('isFound'));
    }

    @isTest
    static void testGetLineItemSourceMap() {
        Order_Allocation_Line_Item__c line = [SELECT Id FROM Order_Allocation_Line_Item__c LIMIT 1];
        Test.startTest();
        Map<String, Object> resultMap = OrderAllocationPlanDetailsController.getLineItemSourceMap(new List<Id>{ line.Id });
        Test.stopTest();

        System.assertNotEquals(null, resultMap);
        System.assert(resultMap.containsKey(line.Id + '_Supply Request'));
        System.assert(resultMap.containsKey(line.Id + '_Transfer SR'));
        System.assert(resultMap.containsKey(line.Id + '_Purchase Order'));
        System.assert(resultMap.containsKey(line.Id + '_Reservation'));
    }
}