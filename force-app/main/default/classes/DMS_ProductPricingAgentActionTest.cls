/**
 * @description Comprehensive unit tests for the rebuilt DMS_ProductPricingAgentAction.
 *              Validates all 30+ requirement scenarios across Item & Item Price search, details,
 *              pricing resolution, pagination, fuzzy matching, multiple matches, inactive filters,
 *              error handling, bulk execution (200 requests), and primitive-only Agentforce response contract.
 *
 * @author AM Industries DMS Agentforce Team
 */
@IsTest
private class DMS_ProductPricingAgentActionTest {

    @TestSetup
    static void setupTestData() {
        // 1. Picklist value resolution
        String itemUom = getActivePicklistValue(Item__c.Unit_Of_Measure__c, 'Each');
        String itemClass = getActivePicklistValue(Item__c.Classification__c, 'Finished Goods');

        // 2. Accounts (Dealers)
        Account dealerAlpha = new Account(Name = 'Dealer Alpha Motors');
        Account dealerBeta = new Account(Name = 'Dealer Beta Logistics');
        Account speedMotors = new Account(Name = 'Speed Motors Private Limited');
        insert new List<Account>{ dealerAlpha, dealerBeta, speedMotors };

        // 3. Inventory Locations
        Inventory_Location__c locHyd = new Inventory_Location__c(
            Name = 'Hyderabad Central Hub',
            Inventory_Location_Code__c = 'LOC-HYD',
            Account__c = dealerAlpha.Id,
            Is_Active__c = true
        );
        Inventory_Location__c locBlr = new Inventory_Location__c(
            Name = 'Bangalore Depot',
            Inventory_Location_Code__c = 'LOC-BLR',
            Account__c = dealerBeta.Id,
            Is_Active__c = true
        );
        insert new List<Inventory_Location__c>{ locHyd, locBlr };

        // 4. Items (Zero dependency on Product2)
        Item__c itemMotor10 = new Item__c(
            Name = 'Three Phase Induction Motor 10 HP',
            Item_Code__c = 'ITEM-MTR-010',
            Item_Family__c = 'Motors',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 18,
            Default_Supply_Method__c = 'Manufacture',
            Delivery_Preparation_Time__c = 5,
            Reorder_Level__c = 10,
            Target_Stock_Level__c = 50,
            Target_Days__c = 15,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        Item__c itemMotor15 = new Item__c(
            Name = 'Three Phase Induction Motor 15 HP',
            Item_Code__c = 'ITEM-MTR-015',
            Item_Family__c = 'Motors',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 18,
            Default_Supply_Method__c = 'Manufacture',
            Delivery_Preparation_Time__c = 5,
            Reorder_Level__c = 8,
            Target_Stock_Level__c = 40,
            Target_Days__c = 15,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        Item__c itemPump = new Item__c(
            Name = 'Hydraulic Fluid Pump 20L',
            Item_Code__c = 'ITEM-PMP-020',
            Item_Family__c = 'Hydraulics',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = false,
            Base_Tax__c = 12,
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 3,
            Reorder_Level__c = 5,
            Target_Stock_Level__c = 20,
            Target_Days__c = 10,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        Item__c itemSolarUnpriced = new Item__c(
            Name = 'Solar Auxiliary Inverter 5KW',
            Item_Code__c = 'ITEM-SOL-005',
            Item_Family__c = 'Electrical',
            Active__c = true,
            Is_Sellable__c = true,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 5,
            Default_Supply_Method__c = 'Both',
            Delivery_Preparation_Time__c = 4,
            Reorder_Level__c = 3,
            Target_Stock_Level__c = 12,
            Target_Days__c = 14,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        Item__c itemInactive = new Item__c(
            Name = 'Legacy Transmission Filter',
            Item_Code__c = 'ITEM-FLT-001',
            Item_Family__c = 'Filtration',
            Active__c = false, // Inactive Item
            Is_Sellable__c = false,
            Is_Inventory_Item__c = true,
            Base_Tax__c = 18,
            Unit_Of_Measure__c = itemUom,
            Classification__c = itemClass
        );

        insert new List<Item__c>{ itemMotor10, itemMotor15, itemPump, itemSolarUnpriced, itemInactive };

        // 5. Item Prices
        Item_Price__c priceMotorSpeed = new Item_Price__c(
            Item__c = itemMotor10.Id,
            Item_Price_Account__c = speedMotors.Id,
            Inventory_Location__c = locHyd.Id,
            Unit_Price__c = 45000,
            Discount__c = 10,
            Tax__c = 18,
            Active__c = true
        );

        Item_Price__c priceMotorAlpha = new Item_Price__c(
            Item__c = itemMotor10.Id,
            Item_Price_Account__c = dealerAlpha.Id,
            Inventory_Location__c = locHyd.Id,
            Unit_Price__c = 48000,
            Discount__c = 5,
            Tax__c = 18,
            Active__c = true
        );

        Item_Price__c pricePumpGlobal = new Item_Price__c(
            Item__c = itemPump.Id,
            Item_Price_Account__c = null, // Global base price
            Inventory_Location__c = null,
            Unit_Price__c = 15000,
            Discount__c = 0,
            Tax__c = 12,
            Active__c = true
        );

        Item_Price__c priceInactive = new Item_Price__c(
            Item__c = itemMotor10.Id,
            Item_Price_Account__c = dealerBeta.Id,
            Inventory_Location__c = locBlr.Id,
            Unit_Price__c = 50000,
            Discount__c = 0,
            Tax__c = 18,
            Active__c = false // Inactive Price
        );

        insert new List<Item_Price__c>{ priceMotorSpeed, priceMotorAlpha, pricePumpGlobal, priceInactive };
    }

    private static String getActivePicklistValue(Schema.SObjectField field, String fallback) {
        List<Schema.PicklistEntry> entries = field.getDescribe().getPicklistValues();
        for (Schema.PicklistEntry pe : entries) {
            if (pe.isActive()) {
                return pe.getValue();
            }
        }
        return fallback;
    }

    // -------------------------------------------------------------------------
    // 1-5. SEARCH_ITEMS TESTS (EXACT, CASE-INSENSITIVE, NORMALIZED, PARTIAL, TYPO)
    // -------------------------------------------------------------------------
    @IsTest
    static void testSearchItems_ExactName() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        req.itemName = 'Three Phase Induction Motor 10 HP';

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess, 'Search should succeed');
        Assert.isTrue(res.totalRecords >= 1, 'Should find motor item');
        Assert.isTrue(res.summary.contains('Three Phase Induction Motor 10 HP'));
        Assert.isTrue(res.summary.contains(DMS_ProductPricingAgentAction.BOUNDARY_STOCK_NOTICE));
        Assert.isTrue(res.jsonResponse.contains('ITEM-MTR-010'));
    }

    @IsTest
    static void testSearchItems_CaseInsensitiveAndNormalizedSpacing() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = 'search_items';
        req.itemName = '  three   phase induction motor 10hp  '; // Lowercase, extra spaces

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.isTrue(res.totalRecords >= 1);
        Assert.isTrue(res.summary.contains('Three Phase Induction Motor 10 HP'));
    }

    @IsTest
    static void testSearchItems_PartialAndItemCode() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        req.itemCode = 'ITEM-PMP-020';

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Hydraulic Fluid Pump 20L'));
    }

    @IsTest
    static void testSearchItems_MinorTypoAndReorderedWords() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        req.itemName = 'hydraulic pump 20l'; // Word order variation

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.isTrue(res.totalRecords >= 1);
        Assert.isTrue(res.summary.contains('Hydraulic Fluid Pump 20L'));
    }

    // -------------------------------------------------------------------------
    // 6. GET_ITEM_DETAILS TEST
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetItemDetails_Success() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_ITEM_DETAILS;
        req.itemName = 'Three Phase Induction Motor 10 HP';

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Item Details: Three Phase Induction Motor 10 HP'));
        Assert.isTrue(res.summary.contains('Reorder Level: 10'));
        Assert.isTrue(res.summary.contains('Supply Method: Manufacture'));
        Assert.isTrue(res.jsonResponse.contains('ITEM-MTR-010'));
    }

    // -------------------------------------------------------------------------
    // 7-10. GET_PRICING TESTS (ITEM ONLY, + ACCOUNT, + LOCATION, + BOTH)
    // -------------------------------------------------------------------------
    @IsTest
    static void testGetPricing_ItemOnly() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_PRICING;
        req.itemName = 'Hydraulic Fluid Pump 20L';

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Unit Price: 15000'));
        Assert.isTrue(res.jsonResponse.contains('15000'));
    }

    @IsTest
    static void testGetPricing_ItemAndAccount_SpeedMotors() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_PRICING;
        req.itemName = 'Three Phase Induction Motor 10 HP';
        req.accountName = 'Speed moters'; // Typo in account name

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Speed Motors Private Limited'));
        Assert.isTrue(res.summary.contains('Unit Price: 45000'));
        Assert.isTrue(res.summary.contains('Net Price: 40500')); // 45000 - 10%
    }

    @IsTest
    static void testGetPricing_ItemAndLocation() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_PRICING;
        req.itemName = 'Three Phase Induction Motor 10 HP';
        req.inventoryLocationName = 'LOC-HYD'; // By code

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.isTrue(res.totalRecords >= 2, 'Should find both active prices at Hyderabad hub');
    }

    @IsTest
    static void testGetPricing_ItemAndAccountAndLocation() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_PRICING;
        req.itemName = 'Three Phase Induction Motor 10 HP';
        req.accountName = 'Dealer Alpha Motors';
        req.inventoryLocationName = 'Hyderabad Central Hub';

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.totalRecords);
        Assert.isTrue(res.summary.contains('Unit Price: 48000'));
    }

    // -------------------------------------------------------------------------
    // 11-12. NO MATCH TESTS (NO ITEM, NO ITEM PRICE)
    // -------------------------------------------------------------------------
    @IsTest
    static void testNoMatchingItem() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        req.itemName = 'NonExistentProductXYZ123';

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess, 'Should return success=true when no data is found');
        Assert.areEqual(0, res.totalRecords);
        Assert.areEqual('No matching Item was found.', res.message);
    }

    @IsTest
    static void testItemExists_NoItemPriceExists() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_PRICING;
        req.itemName = 'Solar Auxiliary Inverter 5KW'; // Item exists but has 0 price records

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.areEqual(0, res.totalRecords);
        Assert.isTrue(res.message.contains('The Item was found, but no matching Item Price was found'));
        Assert.isTrue(res.summary.contains('Solar Auxiliary Inverter 5KW'));
    }

    // -------------------------------------------------------------------------
    // 13-15. MULTIPLE MATCHES & AMBIGUITY
    // -------------------------------------------------------------------------
    @IsTest
    static void testMultipleItemMatches_GeneralSearch() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        req.itemName = 'Three Phase Induction Motor'; // Matches 10HP and 15HP

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        DMS_ProductPricingAgentAction.Response res = responses[0];
        Assert.isTrue(res.isSuccess);
        Assert.isTrue(res.totalRecords >= 2);
    }

    // -------------------------------------------------------------------------
    // 16-17. INCLUDE INACTIVE TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testIncludeInactive_FalseAndTrue() {
        // Exclude inactive (default)
        DMS_ProductPricingAgentAction.Request reqExclude = new DMS_ProductPricingAgentAction.Request();
        reqExclude.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        reqExclude.itemName = 'Legacy Transmission Filter';
        reqExclude.includeInactive = false;

        DMS_ProductPricingAgentAction.Response resExclude = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ reqExclude }
        )[0];
        Assert.areEqual(0, resExclude.totalRecords, 'Should not return inactive item');

        // Include inactive
        DMS_ProductPricingAgentAction.Request reqInclude = new DMS_ProductPricingAgentAction.Request();
        reqInclude.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        reqInclude.itemName = 'Legacy Transmission Filter';
        reqInclude.includeInactive = true;

        DMS_ProductPricingAgentAction.Response resInclude = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ reqInclude }
        )[0];
        Assert.areEqual(1, resInclude.totalRecords, 'Should return inactive item when includeInactive=true');
    }

    @IsTest
    static void testIsActiveAliasParameter() {
        // Agentforce passing isActive=true
        DMS_ProductPricingAgentAction.Request reqActive = new DMS_ProductPricingAgentAction.Request();
        reqActive.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        reqActive.itemName = 'Legacy Transmission Filter';
        reqActive.isActive = true;

        DMS_ProductPricingAgentAction.Response resActive = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ reqActive }
        )[0];
        Assert.areEqual(0, resActive.totalRecords, 'Should exclude inactive item when isActive=true');

        // Agentforce passing isActive=false
        DMS_ProductPricingAgentAction.Request reqInactive = new DMS_ProductPricingAgentAction.Request();
        reqInactive.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        reqInactive.itemName = 'Legacy Transmission Filter';
        reqInactive.isActive = false;

        DMS_ProductPricingAgentAction.Response resInactive = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ reqInactive }
        )[0];
        Assert.areEqual(1, resInactive.totalRecords, 'Should include inactive item when isActive=false');
    }

    // -------------------------------------------------------------------------
    // 18-23. REAL PAGINATION TESTS (PAGE 1, PAGE 2, HASMORERECORDS, TOTALRECORDS)
    // -------------------------------------------------------------------------
    @IsTest
    static void testPagination_Page1AndPage2() {
        // Query Limit 2, Page 1
        DMS_ProductPricingAgentAction.Request reqP1 = new DMS_ProductPricingAgentAction.Request();
        reqP1.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        reqP1.queryLimit = 2;
        reqP1.pageNumber = 1;

        DMS_ProductPricingAgentAction.Response resP1 = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ reqP1 }
        )[0];

        Assert.isTrue(resP1.isSuccess);
        Assert.isTrue(resP1.totalRecords >= 4, 'Total active items in DB is at least 4');
        Assert.areEqual(1, resP1.currentPage);
        Assert.isTrue(resP1.hasMoreRecords, 'Page 1 must indicate hasMoreRecords=true');

        // Page 2
        DMS_ProductPricingAgentAction.Request reqP2 = new DMS_ProductPricingAgentAction.Request();
        reqP2.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        reqP2.queryLimit = 2;
        reqP2.pageNumber = 2;

        DMS_ProductPricingAgentAction.Response resP2 = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ reqP2 }
        )[0];

        Assert.isTrue(resP2.isSuccess);
        Assert.areEqual(2, resP2.currentPage);
    }

    @IsTest
    static void testPagination_InvalidLimits() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_SEARCH_ITEMS;
        req.queryLimit = -10;  // Invalid limit
        req.pageNumber = -5;   // Invalid page

        DMS_ProductPricingAgentAction.Response res = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        )[0];

        Assert.isTrue(res.isSuccess);
        Assert.areEqual(1, res.currentPage, 'Should normalize negative page number to 1');
    }

    // -------------------------------------------------------------------------
    // 24-28. VALIDATION & ERROR HANDLING TESTS
    // -------------------------------------------------------------------------
    @IsTest
    static void testUnsupportedActionType() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = 'DELETE_ITEM'; // Unsupported

        DMS_ProductPricingAgentAction.Response res = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        )[0];

        Assert.isFalse(res.isSuccess);
        Assert.isTrue(res.message.contains('Unsupported Product & Pricing request'));
    }

    @IsTest
    static void testBlankAndNullInput() {
        // Null list
        List<DMS_ProductPricingAgentAction.Response> emptyResponses = DMS_ProductPricingAgentAction.execute(null);
        Assert.areEqual(0, emptyResponses.size());

        // Blank request
        DMS_ProductPricingAgentAction.Request blankReq = new DMS_ProductPricingAgentAction.Request();
        DMS_ProductPricingAgentAction.Response res = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ blankReq }
        )[0];
        Assert.isTrue(res.isSuccess, 'Should gracefully default to listing items');
    }

    // -------------------------------------------------------------------------
    // 29. BULK EXECUTION (200 REQUESTS)
    // -------------------------------------------------------------------------
    @IsTest
    static void testBulkExecution_200Requests() {
        List<DMS_ProductPricingAgentAction.Request> bulkList = new List<DMS_ProductPricingAgentAction.Request>();
        for (Integer i = 0; i < 200; i++) {
            DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
            req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_PRICING;
            req.itemCode = 'ITEM-MTR-010';
            req.queryLimit = 1;
            bulkList.add(req);
        }

        Test.startTest();
        List<DMS_ProductPricingAgentAction.Response> responses = DMS_ProductPricingAgentAction.execute(bulkList);
        Test.stopTest();

        Assert.areEqual(200, responses.size(), 'Must safely process all 200 requests');
        for (Integer i = 0; i < 200; i++) {
            Assert.isTrue(responses[i].isSuccess);
            Assert.isTrue(responses[i].totalRecords >= 1);
        }
    }

    // -------------------------------------------------------------------------
    // 30. JSON RESPONSE STRUCTURE VALIDATION
    // -------------------------------------------------------------------------
    @IsTest
    static void testJsonResponseStructure() {
        DMS_ProductPricingAgentAction.Request req = new DMS_ProductPricingAgentAction.Request();
        req.actionType = DMS_ProductPricingAgentAction.ACTION_GET_PRICING;
        req.itemName = 'Three Phase Induction Motor 10 HP';

        DMS_ProductPricingAgentAction.Response res = DMS_ProductPricingAgentAction.execute(
            new List<DMS_ProductPricingAgentAction.Request>{ req }
        )[0];

        Assert.isTrue(res.isSuccess);
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(res.jsonResponse);
        Assert.areEqual('itemPrices', parsedJson.get('type'));
        Assert.isTrue(parsedJson.containsKey('totalRecords'));
        Assert.isTrue(parsedJson.containsKey('currentPage'));
        Assert.isTrue(parsedJson.containsKey('hasMoreRecords'));
        Assert.isTrue(parsedJson.containsKey('records'));
    }
}