@isTest
private class GRNControllerTest {
    
    @testSetup
    static void setupTestData() {
        // Create Accounts
        Account suppAcc = new Account(Name = 'Kumar Traders');
        Account reqAcc = new Account(Name = 'Speed Motors');
        insert new List<Account>{ suppAcc, reqAcc };
        
        // Create Locations
        Inventory_Location__c sourceLoc = new Inventory_Location__c(
            Name = 'Kumar Location',
            Account__c = suppAcc.Id,
            Is_Active__c = true
        );
        Inventory_Location__c targetLoc = new Inventory_Location__c(
            Name = 'Speed Warehouse',
            Account__c = reqAcc.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ sourceLoc, targetLoc };
        
        // Create Item
        Item__c item = new Item__c(
            Name = 'Hydraulic Pump',
            Item_Code__c = 'HYD-01',
            Target_Days__c = 5
        );
        insert item;

        // Create Inventories: Speed Motors (Target Transit In = 150), Kumar Traders (Source Transit Out = 150)
        Inventory__c targetInv = new Inventory__c(
            Inventory_Location__c = targetLoc.Id,
            Item__c = item.Id,
            Account__c = reqAcc.Id,
            Available__c = 0,
            Transit_In_Quantity__c = 150,
            Transit_Out_Quantity__c = 0
        );
        Inventory__c sourceInv = new Inventory__c(
            Inventory_Location__c = sourceLoc.Id,
            Item__c = item.Id,
            Account__c = suppAcc.Id,
            Available__c = 4100,
            Transit_In_Quantity__c = 0,
            Transit_Out_Quantity__c = 150
        );
        insert new List<Inventory__c>{ targetInv, sourceInv };
        
        // Create Purchase Order
        Purchase_Order__c po = new Purchase_Order__c(
            Requesting_Account__c = reqAcc.Id,
            Supplying_Account__c = suppAcc.Id,
            Source_Location__c = sourceLoc.Id,
            Target_Location__c = targetLoc.Id,
            PO_Date__c = System.today(),
            Expected_Date__c = System.today().addDays(5),
            Status__c = 'Issued'
        );
        insert po;
        
        // Create Purchase Order Line Items
        Purchase_Order_Line_Item__c poli1 = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 100,
            Unit_Price__c = 150.00,
            Status__c = 'Open'
        );
        Purchase_Order_Line_Item__c poli2 = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 50,
            Unit_Price__c = 200.00,
            Status__c = 'Open'
        );
        insert new List<Purchase_Order_Line_Item__c>{poli1, poli2};

        // Create Supply Request & Purchase Order Allocation
        Supply_Request__c sr = new Supply_Request__c(
            Item__c = item.Id,
            Requested_Qty__c = 130,
            Status__c = 'Open'
        );
        insert sr;

        Purchase_Order_Allocation__c poa = new Purchase_Order_Allocation__c(
            Purchase_Order__c = po.Id,
            Supply_Request__c = sr.Id
        );
        insert poa;
    }
    
    @isTest
    static void testGetPurchaseOrderDetails() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        
        Test.startTest();
        LWCServerCalloutWrapper wrapper = GRNController.getPurchaseOrderDetails(po.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, wrapper, 'Wrapper should not be null');
        System.assertEquals(true, wrapper.isSuccess, 'Callout should be successful');
        GRNController.PODetailWrapper result = (GRNController.PODetailWrapper) wrapper.result;
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(po.Id, result.po.Id, 'Correct PO should be retrieved');
        System.assertEquals(2, result.lines.size(), 'Two line items should be retrieved');
        System.assertEquals(0, result.lines[0].previouslyReceivedQty, 'Previously received qty should be 0');
        System.assertEquals(100, result.lines[0].remainingQty, 'Remaining qty should equal ordered qty');
    }
    
    @isTest
    static void testSaveGoodsReceiptDraft() {
        Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c LIMIT 1];
        List<Purchase_Order_Line_Item__c> lines = [SELECT Id, Unit_Price__c FROM Purchase_Order_Line_Item__c WHERE Purchase_Order__c = :po.Id];
        
        GRN__c grn = new GRN__c(
            Purchase_Order__c = po.Id,
            Receipt_Date__c = System.today(),
            Delivery_Note_No__c = 'DN-DRAFT-123',
            Remarks__c = 'Draft GRN',
            Status__c = 'Draft'
        );
        
        List<GRN_Line_Item__c> grnLines = new List<GRN_Line_Item__c>{
            new GRN_Line_Item__c(
                Purchase_Order_Line_Item__c = lines[0].Id,
                Received_Qty__c = 40,
                Unit_Price__c = lines[0].Unit_Price__c
            )
        };
        
        Test.startTest();
        LWCServerCalloutWrapper wrapper = GRNController.saveGoodsReceipt(grn, grnLines);
        Test.stopTest();
        
        System.assertNotEquals(null, wrapper, 'Wrapper should not be null');
        System.assertEquals(true, wrapper.isSuccess, 'Callout should be successful');
        Id grnId = ((GRN__c) wrapper.result).Id;
        System.assertNotEquals(null, grnId, 'GRN Id should be returned');
        
        GRN__c savedGRN = [SELECT Id, Status__c FROM GRN__c WHERE Id = :grnId];
        System.assertEquals('Draft', savedGRN.Status__c, 'Status should be Draft');
    }
    
    @isTest
    static void testSaveGoodsReceiptReceivedSuccess() {
        Purchase_Order__c po = [SELECT Id, Target_Location__c, Source_Location__c FROM Purchase_Order__c LIMIT 1];
        List<Purchase_Order_Line_Item__c> lines = [SELECT Id, Unit_Price__c, Item__c FROM Purchase_Order_Line_Item__c WHERE Purchase_Order__c = :po.Id ORDER BY Name ASC];
        
        GRN__c grn = new GRN__c(
            Purchase_Order__c = po.Id,
            Receipt_Date__c = System.today(),
            Delivery_Note_No__c = 'DN-REC-123',
            Remarks__c = 'Received GRN',
            Status__c = 'Received'
        );
        
        List<GRN_Line_Item__c> grnLines = new List<GRN_Line_Item__c>{
            new GRN_Line_Item__c(
                Purchase_Order_Line_Item__c = lines[0].Id,
                Received_Qty__c = 80,
                Unit_Price__c = lines[0].Unit_Price__c
            ),
            new GRN_Line_Item__c(
                Purchase_Order_Line_Item__c = lines[1].Id,
                Received_Qty__c = 50,
                Unit_Price__c = lines[1].Unit_Price__c
            )
        };
        
        Test.startTest();
        LWCServerCalloutWrapper wrapper = GRNController.saveGoodsReceipt(grn, grnLines);
        Test.stopTest();
        
        System.assertNotEquals(null, wrapper, 'Wrapper should not be null');
        System.assertEquals(true, wrapper.isSuccess, 'Callout should be successful');
        Id grnId = ((GRN__c) wrapper.result).Id;
        
        // 1. Verify GRN Status
        GRN__c savedGRN = [SELECT Id, Status__c FROM GRN__c WHERE Id = :grnId];
        System.assertEquals('Received', savedGRN.Status__c, 'Status should be Received');
        
        // 2. Verify Target Inventory: Transit Out ↓ (150 -> 20)
        Inventory__c targetInv = [SELECT Id, Available__c, Transit_Out_Quantity__c FROM Inventory__c WHERE Inventory_Location__c = :po.Target_Location__c LIMIT 1];
        System.assertEquals(20, targetInv.Transit_Out_Quantity__c, 'Target Transit Out should decrease to 20');
        
        // 3. Verify Source Inventory: Transit In ↓ (150 -> 20), Available ↑ (4100 -> 4230)
        Inventory__c sourceInv = [SELECT Id, Available__c, Transit_In_Quantity__c FROM Inventory__c WHERE Inventory_Location__c = :po.Source_Location__c LIMIT 1];
        System.assertEquals(4230, sourceInv.Available__c, 'Source Available should increase to 4230');
        System.assertEquals(20, sourceInv.Transit_In_Quantity__c, 'Source Transit In should decrease to 20');

        // 4. Verify Supply Request completion status
        Supply_Request__c sr = [SELECT Id, Status__c, Received_Qty__c FROM Supply_Request__c LIMIT 1];
        System.assertEquals('Completed', sr.Status__c, 'Supply Request should be Completed');
        System.assertEquals(130, sr.Received_Qty__c, 'Supply Request Received Qty should be 130');
    }
    
    @isTest
    static void testSaveGoodsReceiptValidationFailures() {
        Purchase_Order__c po = [SELECT Id, Target_Location__c, Source_Location__c FROM Purchase_Order__c LIMIT 1];
        List<Purchase_Order_Line_Item__c> lines = [SELECT Id, Unit_Price__c FROM Purchase_Order_Line_Item__c WHERE Purchase_Order__c = :po.Id];
        
        GRN__c grn = new GRN__c(
            Purchase_Order__c = po.Id,
            Receipt_Date__c = System.today(),
            Delivery_Note_No__c = 'DN-ERR-123',
            Status__c = 'Received'
        );
        
        // Excess receive quantity exceeding Transit In
        List<GRN_Line_Item__c> grnLinesExcess = new List<GRN_Line_Item__c>{
            new GRN_Line_Item__c(
                Purchase_Order_Line_Item__c = lines[0].Id,
                Received_Qty__c = 999,
                Unit_Price__c = lines[0].Unit_Price__c
            )
        };
        
        Test.startTest();
        LWCServerCalloutWrapper wrapperExcess = GRNController.saveGoodsReceipt(grn, grnLinesExcess);
        Test.stopTest();
        
        System.assertEquals(false, wrapperExcess.isSuccess, 'Should fail when received qty exceeds Transit In');
    }

    @isTest
    static void testSearchPurchaseOrders() {
        Purchase_Order__c po = [SELECT Id, Name FROM Purchase_Order__c LIMIT 1];
        
        Test.startTest();
        LWCServerCalloutWrapper wrapper = GRNController.searchPurchaseOrders(po.Name);
        LWCServerCalloutWrapper emptyWrapper = GRNController.searchPurchaseOrders('');
        Test.stopTest();
        
        System.assertEquals(true, wrapper.isSuccess, 'Search should be successful');
        System.assertNotEquals(null, wrapper.resultList, 'Result list should not be null');
        System.assertEquals(1, wrapper.resultList.size(), 'Should find 1 PO');
    }
}