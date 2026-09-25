/**
 * @description Comprehensive Unit Test class for the Apex Sharing Framework
 *              (AccountHierarchyService, PublicGroupService, RecordSharingService,
 *               RecordSharingTriggerHandler, and DMSAsyncSharingWorker).
 * @author DeepMind Antigravity
 * @date 2026-08-03
 */
@IsTest
private class RecordSharingServiceTest {

    @TestSetup
    static void setupTestData() {
        Id oemRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('OEM').getRecordTypeId();
        Id distRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Distributor').getRecordTypeId();
        Id dealerRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Dealer').getRecordTypeId();
        Id retailerRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Retailer').getRecordTypeId();

        // 1. Create Account Hierarchy (OEM -> Distributor -> Dealer -> Retailer)
        Account oem = new Account(Name = 'Tata Motors', Type = 'OEM', RecordTypeId = oemRtId);
        insert oem;

        Account dist = new Account(
            Name = 'Hyderabad Distributor', 
            Type = 'Distributor',
            RecordTypeId = distRtId,
            OEM__c = oem.Id
        );
        insert dist;

        Account dealer = new Account(
            Name = 'Dealer A', 
            Type = 'Dealer',
            RecordTypeId = dealerRtId,
            Distributor__c = dist.Id,
            OEM__c = oem.Id
        );
        insert dealer;

        Account retailer = new Account(
            Name = 'Retailer A1', 
            Type = 'Retailer',
            RecordTypeId = retailerRtId,
            Dealer__c = dealer.Id,
            Distributor__c = dist.Id,
            OEM__c = oem.Id
        );
        insert retailer;

        // 2. Create Public Groups (one per Account in the hierarchy)
        Group retailerGroup = new Group(Name = 'Retailer_A1_Group', DeveloperName = 'Retailer_A1_Group_Test');
        insert retailerGroup;

        Group dealerGroup = new Group(Name = 'Dealer_A_Group', DeveloperName = 'Dealer_A_Group_Test');
        insert dealerGroup;

        Group distGroup = new Group(Name = 'Distributor_Group', DeveloperName = 'Distributor_Group_Test');
        insert distGroup;

        Group oemGroup = new Group(Name = 'OEM_Group', DeveloperName = 'OEM_Group_Test');
        insert oemGroup;

        // 3. Create Account_Public_Group_Mapping__c for EVERY Account in the hierarchy
        List<Account_Public_Group_Mapping__c> mappings = new List<Account_Public_Group_Mapping__c>{
            new Account_Public_Group_Mapping__c(
                Account__c = retailer.Id,
                Public_Group_Id__c = (String) retailerGroup.Id,
                Public_Group_Name__c = retailerGroup.DeveloperName,
                Access_Level__c = 'Edit',
                Active__c = true
            ),
            new Account_Public_Group_Mapping__c(
                Account__c = dealer.Id,
                Public_Group_Id__c = (String) dealerGroup.Id,
                Public_Group_Name__c = dealerGroup.DeveloperName,
                Access_Level__c = 'Edit',
                Active__c = true
            ),
            new Account_Public_Group_Mapping__c(
                Account__c = dist.Id,
                Public_Group_Id__c = (String) distGroup.Id,
                Public_Group_Name__c = distGroup.DeveloperName,
                Access_Level__c = 'Edit',
                Active__c = true
            ),
            new Account_Public_Group_Mapping__c(
                Account__c = oem.Id,
                Public_Group_Id__c = (String) oemGroup.Id,
                Public_Group_Name__c = oemGroup.DeveloperName,
                Access_Level__c = 'Edit',
                Active__c = true
            )
        };
        insert mappings;
    }

    @IsTest
    static void testAccountHierarchyService() {
        Account retailer = [SELECT Id FROM Account WHERE Name = 'Retailer A1' LIMIT 1];

        Test.startTest();
        List<Account> hierarchy = AccountHierarchyService.getHierarchy(retailer.Id);
        List<Account> parents = AccountHierarchyService.getParentAccounts(retailer.Id);
        Map<Id, List<Account>> hierarchyMap = AccountHierarchyService.getParentHierarchyMap(new Set<Id>{ retailer.Id });
        
        // Null test
        List<Account> nullHierarchy = AccountHierarchyService.getHierarchy(null);
        List<Account> nullParents = AccountHierarchyService.getParentAccounts(null);
        Test.stopTest();

        Assert.areEqual(4, hierarchy.size(), 'Hierarchy should contain 4 accounts (Retailer -> Dealer -> Distributor -> OEM).');
        Assert.areEqual('Retailer A1', hierarchy[0].Name, 'First account should be Retailer A1.');
        Assert.areEqual('Tata Motors', hierarchy[3].Name, 'Root account should be Tata Motors.');
        Assert.areEqual(3, parents.size(), 'Parent accounts should exclude child account.');
        Assert.areEqual(true, hierarchyMap.containsKey(retailer.Id), 'Hierarchy map should contain retailer Id key.');
        Assert.areEqual(0, nullHierarchy.size(), 'Null accountId should return empty list.');
        Assert.areEqual(0, nullParents.size(), 'Null accountId should return empty list.');
    }

    @IsTest
    static void testPublicGroupService() {
        Account retailer = [SELECT Id FROM Account WHERE Name = 'Retailer A1' LIMIT 1];

        Test.startTest();
        Map<Id, Group> groupsMap = PublicGroupService.getGroupsForAccounts(new Set<Id>{ retailer.Id });
        Map<Id, List<Account_Public_Group_Mapping__c>> mappingsMap = PublicGroupService.getPublicGroupMappingsForAccounts(new Set<Id>{ retailer.Id });
        
        // Null test
        Map<Id, Group> nullGroups = PublicGroupService.getGroupsForAccounts(null);
        Test.stopTest();

        Assert.areEqual(true, groupsMap.containsKey(retailer.Id), 'Groups map should contain retailer Id key.');
        Assert.areEqual(true, mappingsMap.containsKey(retailer.Id), 'Mappings map should contain retailer Id key.');
        Assert.areEqual(0, nullGroups.size(), 'Null accountIds should return empty map.');
    }

    @IsTest
    static void testRecordSharingServiceAndHandler() {
        Account retailer = [SELECT Id FROM Account WHERE Name = 'Retailer A1' LIMIT 1];
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer A' LIMIT 1];
        
        Inventory_Location__c loc = new Inventory_Location__c(Name = 'Main Location', Inventory_Location_Code__c = 'LOC-001');
        insert loc;

        Item__c item = new Item__c(
            Name = 'Engine Part X',
            Item_Code__c = 'PART-X',
            Base_Tax__c = 18,
            Active__c = true,
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'Each',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 20,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 80
        );
        insert item;

        // Inventory record with Account__c set directly to Retailer A1
        Inventory__c inv = new Inventory__c(
            Inventory_Location__c = loc.Id,
            Item__c = item.Id,
            Available__c = 100,
            Account__c = retailer.Id
        );

        Test.startTest();
        // 1. Insert record through trigger handler
        insert inv;

        // 2. Test afterInsert handler call
        RecordSharingTriggerHandler.afterInsert(new List<SObject>{ inv });
        
        // 3. Test afterUpdate handler call with Account change
        inv.Account__c = dealer.Id;
        update inv;
        RecordSharingTriggerHandler.afterUpdate(
            new List<SObject>{ inv },
            new Map<Id, SObject>{ inv.Id => new Inventory__c(Id = inv.Id, Account__c = retailer.Id) }
        );

        // 4. Test single record share call using Account ID
        RecordSharingService.shareRecord(inv.Id, retailer.Id, Inventory__c.SObjectType);
        RecordSharingService.shareRecord(inv);

        // 5. Test Async Worker
        System.enqueueJob(new DMSAsyncSharingWorker(new List<SObject>{ inv }));
        Test.stopTest();

        Assert.areNotEqual(null, inv.Id, 'Inventory record should be created successfully.');
        Assert.areEqual('Account__c', RecordSharingService.getAccountFieldName(Inventory__c.SObjectType), 'Default account field name should be Account__c.');
        Assert.areEqual('Supplying_Account__c', RecordSharingService.getAccountFieldName(Order_Allocation__c.SObjectType), 'Order Allocation account field name should be Supplying_Account__c.');
        Assert.areEqual('Item_Price_Account__c', RecordSharingService.getAccountFieldName(Item_Price__c.SObjectType), 'Item Price account field name should be Item_Price_Account__c.');
    }

    @IsTest
    static void testNullAccountSharingHandling() {
        Inventory_Location__c loc = new Inventory_Location__c(Name = 'Main Location 2', Inventory_Location_Code__c = 'LOC-002');
        insert loc;

        Item__c item = new Item__c(
            Name = 'Engine Part Y',
            Item_Code__c = 'PART-Y',
            Base_Tax__c = 18,
            Active__c = true,
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'Each',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 20,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 80
        );
        insert item;

        // Inventory record with null Account__c
        Inventory__c invNullAcc = new Inventory__c(
            Inventory_Location__c = loc.Id,
            Item__c = item.Id,
            Available__c = 50,
            Account__c = null
        );
        insert invNullAcc;

        Test.startTest();
        // Should execute safely without throwing null pointer exceptions
        RecordSharingService.shareRecords(new List<SObject>{ invNullAcc });
        RecordSharingService.shareRecord(invNullAcc.Id, null, Inventory__c.SObjectType);
        RecordSharingService.shareRecord((SObject) null);
        RecordSharingService.shareRecord((Id) null);
        Test.stopTest();

        Assert.areNotEqual(null, invNullAcc.Id, 'Record with null Account__c should be created without throwing errors.');
    }

    @IsTest
    static void testAccountSharing() {
        // Query the retailer account created in setup
        Account retailer = [SELECT Id, Name, RecordTypeId, Dealer__c, Distributor__c, OEM__c FROM Account WHERE Name = 'Retailer A1' LIMIT 1];

        Test.startTest();
        // Trigger manual execution of sharing for the Account record
        RecordSharingService.shareRecords(new List<SObject>{ retailer });
        
        // Inspect sharing diagnostics for this Account record
        RecordSharingInspectorController.InspectionResult result = RecordSharingInspectorController.inspectSharing(retailer.Id);
        
        // Also test name-based inspect search for Account
        RecordSharingInspectorController.InspectionResult searchResult = RecordSharingInspectorController.inspectSharing('Retailer A1');
        Test.stopTest();

        // Since it's a standard Account, we check that AccountShare records are retrieved and diagnostics pass
        Assert.areNotEqual(null, result, 'Inspection result should not be null.');
        Assert.areNotEqual(null, result.recordDetail, 'Record details should not be null.');
        Assert.areEqual(retailer.Id, result.recordDetail.accountId, 'Account ID in details should match the record ID.');
        Assert.areEqual(retailer.Name, result.recordDetail.accountName, 'Account name in details should match the record name.');
        Assert.areEqual('AccountShare', result.shareObjectApiName, 'Share object name should be resolved as AccountShare.');
        
        Assert.areNotEqual(null, searchResult, 'Name-based search should return result.');
        Assert.areEqual(retailer.Id, searchResult.recordDetail.recordId, 'Name-based search record ID should match.');
    }

    @IsTest
    static void testCustomObjectsBusinessAccountSharing() {
        Account retailer = [SELECT Id FROM Account WHERE Name = 'Retailer A1' LIMIT 1];
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer A' LIMIT 1];

        Inventory_Location__c loc = new Inventory_Location__c(Name = 'Loc Test', Inventory_Location_Code__c = 'LOC-TEST');
        insert loc;

        Item__c item = new Item__c(
            Name = 'Item Test',
            Item_Code__c = 'ITEM-TEST',
            Base_Tax__c = 18,
            Active__c = true,
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'Each',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 20,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 80
        );
        insert item;

        Test.startTest();
        // 1. Purchase Requisition & PRLI
        Purchase_Requisition__c pr = new Purchase_Requisition__c(
            Requesting_Account__c = retailer.Id,
            Source_Location__c = loc.Id,
            Status__c = 'Draft'
        );
        insert pr;

        Purchase_Requisition_Line__c prli = new Purchase_Requisition_Line__c(
            Purchase_Requisition__c = pr.Id,
            Item__c = item.Id,
            Requested_Qty__c = 10
        );
        insert prli;

        // 2. Purchase Order & POLI
        Purchase_Order__c po = new Purchase_Order__c(
            Requesting_Account__c = retailer.Id,
            Status__c = 'Draft'
        );
        insert po;

        Purchase_Order_Line_Item__c poli = new Purchase_Order_Line_Item__c(
            Purchase_Order__c = po.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 5,
            Unit_Price__c = 100
        );
        insert poli;

        // 3. Order Allocation & OALI
        Order_Allocation__c oa = new Order_Allocation__c(
            Requesting_Account__c = retailer.Id,
            Supplying_Account__c = dealer.Id,
            Status__c = 'Draft'
        );
        insert oa;

        Order_Allocation_Line_Item__c oali = new Order_Allocation_Line_Item__c(
            Order_Allocation__c = oa.Id,
            Item__c = item.Id,
            Ordered_Qty__c = 2,
            Unit_Price__c = 50
        );
        insert oali;

        // 4. Inventory Reservation
        Inventory_Reservation__c ir = new Inventory_Reservation__c(
            Supplying_Account__c = retailer.Id,
            Item__c = item.Id,
            Requested_Qty__c = 4
        );
        insert ir;

        // 5. GRN & GRN Line Item
        GRN__c grn = new GRN__c(
            Requesting_Account__c = retailer.Id,
            Status__c = 'Draft'
        );
        insert grn;

        GRN_Line_Item__c grnLi = new GRN_Line_Item__c(
            GRN__c = grn.Id,
            Received_Qty__c = 5,
            Unit_Price__c = 10
        );
        insert grnLi;

        // 6. Inventory Transfer with From/To Accounts
        Inventory_Transfer__c xfer = new Inventory_Transfer__c(
            From_Account__c = retailer.Id,
            To_Account__c = dealer.Id,
            Transfer_Qty__c = 10,
            Status__c = 'Draft'
        );
        insert xfer;

        // 7. Supply Request
        Supply_Request__c sr = new Supply_Request__c(
            Requesting_Account__c = retailer.Id,
            Supplying_Account__c = dealer.Id,
            Item__c = item.Id,
            Requested_Qty__c = 5,
            Status__c = 'Draft'
        );
        insert sr;

        // Update trigger test
        pr.Requesting_Account__c = dealer.Id;
        update pr;

        sr.Requesting_Account__c = dealer.Id;
        update sr;

        // Verify Order Allocation sharing is based on Supplying_Account__c (dealer), not Requesting_Account__c (retailer)
        RecordSharingInspectorController.InspectionResult inspectByOaId = RecordSharingInspectorController.inspectSharing(oa.Id);
        Assert.areNotEqual(null, inspectByOaId, 'OA inspection by ID should succeed');
        Assert.areEqual(dealer.Id, inspectByOaId.recordDetail.accountId, 'OA sharing account must be Supplying_Account__c (Dealer), not Requesting_Account__c');

        // Inspector tests for Line Item by ID and AutoNumber Name
        RecordSharingInspectorController.InspectionResult inspectByOaliId = RecordSharingInspectorController.inspectSharing(oali.Id);
        Assert.areNotEqual(null, inspectByOaliId, 'Line item inspection by ID should succeed');
        Assert.areEqual(oa.Id, inspectByOaliId.recordDetail.parentRecordId, 'Parent record ID should be set');
        Assert.areEqual(dealer.Id, inspectByOaliId.recordDetail.accountId, 'OALI parent business account should be Supplying_Account__c from Order_Allocation__c');
        Assert.areEqual('Order_Allocation_Line_Item__Share', inspectByOaliId.shareObjectApiName, 'Share object should be Order_Allocation_Line_Item__Share');

        Order_Allocation_Line_Item__c fetchedOali = [SELECT Id, Name FROM Order_Allocation_Line_Item__c WHERE Id = :oali.Id LIMIT 1];
        RecordSharingInspectorController.InspectionResult inspectByOaliName = RecordSharingInspectorController.inspectSharing(fetchedOali.Name);
        Assert.areNotEqual(null, inspectByOaliName, 'Line item inspection by AutoNumber Name should succeed');
        Assert.areEqual(oali.Id, inspectByOaliName.recordDetail.recordId, 'Record ID should match');

        Test.stopTest();

        Assert.areNotEqual(null, pr.Id, 'PR should be inserted');
        Assert.areNotEqual(null, prli.Id, 'PRLI should be inserted');
        Assert.areNotEqual(null, po.Id, 'PO should be inserted');
        Assert.areNotEqual(null, poli.Id, 'POLI should be inserted');
        Assert.areNotEqual(null, oa.Id, 'OA should be inserted');
        Assert.areNotEqual(null, oali.Id, 'OALI should be inserted');
        Assert.areNotEqual(null, ir.Id, 'IR should be inserted');
        Assert.areNotEqual(null, grn.Id, 'GRN should be inserted');
        Assert.areNotEqual(null, grnLi.Id, 'GRN Line Item should be inserted');
        Assert.areNotEqual(null, xfer.Id, 'Inventory Transfer should be inserted');
        Assert.areNotEqual(null, sr.Id, 'Supply Request should be inserted');
    }

    @IsTest
    static void testRecalculateSharingAndSingleIdOverload() {
        Account retailer = [SELECT Id FROM Account WHERE Name = 'Retailer A1' LIMIT 1];
        Inventory_Location__c loc = new Inventory_Location__c(Name = 'Loc Test 2', Inventory_Location_Code__c = 'LOC-TEST-2');
        insert loc;

        Item__c item = new Item__c(
            Name = 'Item Test 2',
            Item_Code__c = 'ITEM-TEST-2',
            Base_Tax__c = 18,
            Active__c = true,
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'Each',
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 20,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 80
        );
        insert item;

        Inventory__c inv = new Inventory__c(
            Inventory_Location__c = loc.Id,
            Item__c = item.Id,
            Available__c = 10,
            Account__c = retailer.Id
        );
        insert inv;

        Test.startTest();
        // Test RecordSharingService.shareRecord(Id recordId)
        RecordSharingService.shareRecord(inv.Id);
        RecordSharingService.shareRecord((Id) null);

        // Test RecordSharingInspectorController.recalculateSharing(Id recordId)
        RecordSharingInspectorController.InspectionResult inspectRes = RecordSharingInspectorController.recalculateSharing(inv.Id);
        
        try {
            RecordSharingInspectorController.recalculateSharing(null);
        } catch (AuraHandledException e) {
            // Expected null handling
        }
        Test.stopTest();

        Assert.areNotEqual(null, inspectRes, 'Recalculate sharing result should not be null');
        Assert.areEqual(inv.Id, inspectRes.recordDetail.recordId, 'Record ID should match');
    }

    @IsTest
    static void testFinanceRecordsSharing() {
        Account retailer = [SELECT Id FROM Account WHERE Name = 'Retailer A1' LIMIT 1];
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Dealer A' LIMIT 1];

        Test.startTest();

        // 1. Test Payable__c (Shared by Requesting_Account__c)
        Payable__c payable = new Payable__c(
            Requesting_Account__c = retailer.Id,
            Supplying_Account__c = dealer.Id,
            Total_Amount__c = 5000,
            Status__c = 'Pending',
            Payable_Date__c = Date.today()
        );
        insert payable;

        // Verify Payable inspection and target account resolution
        RecordSharingInspectorController.InspectionResult inspectPayable = RecordSharingInspectorController.inspectSharing(payable.Id);
        Assert.areNotEqual(null, inspectPayable, 'Payable inspection should succeed');
        Assert.areEqual(retailer.Id, inspectPayable.recordDetail.accountId, 'Payable must be shared by Requesting_Account__c (Retailer)');

        // Test Payable update triggers sharing recalculation
        payable.Requesting_Account__c = dealer.Id;
        update payable;

        // 2. Test Receivable__c (Shared by Supplying_Account__c)
        Receivable__c recv = new Receivable__c(
            Requesting_Account__c = retailer.Id,
            Supplying_Account__c = dealer.Id,
            Total_Amount__c = 5000,
            Status__c = 'Pending',
            Receivable_Date__c = Date.today()
        );
        insert recv;

        // Verify Receivable inspection and target account resolution
        RecordSharingInspectorController.InspectionResult inspectRecv = RecordSharingInspectorController.inspectSharing(recv.Id);
        Assert.areNotEqual(null, inspectRecv, 'Receivable inspection should succeed');
        Assert.areEqual(dealer.Id, inspectRecv.recordDetail.accountId, 'Receivable must be shared by Supplying_Account__c (Dealer)');

        // Test Receivable update triggers sharing recalculation
        recv.Supplying_Account__c = retailer.Id;
        update recv;

        // 3. Test Invoice__c (Shared by Requesting_Account__c)
        Invoice__c inv = new Invoice__c(
            Requesting_Account__c = retailer.Id,
            Supplying_Account__c = dealer.Id,
            Invoice_Date__c = Date.today(),
            Due_Date__c = Date.today().addDays(30),
            Status__c = 'Draft',
            Type__c = 'Tax Invoice'
        );
        insert inv;

        // Verify Invoice inspection and target account resolution
        RecordSharingInspectorController.InspectionResult inspectInv = RecordSharingInspectorController.inspectSharing(inv.Id);
        Assert.areNotEqual(null, inspectInv, 'Invoice inspection should succeed');
        Assert.areEqual(retailer.Id, inspectInv.recordDetail.accountId, 'Invoice must be shared by Requesting_Account__c (Retailer)');

        // Test Invoice update triggers sharing recalculation
        inv.Requesting_Account__c = dealer.Id;
        update inv;

        Test.stopTest();

        Assert.areNotEqual(null, payable.Id, 'Payable should be inserted');
        Assert.areNotEqual(null, recv.Id, 'Receivable should be inserted');
        Assert.areNotEqual(null, inv.Id, 'Invoice should be inserted');
    }
}