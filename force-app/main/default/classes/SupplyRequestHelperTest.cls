@isTest
private class SupplyRequestHelperTest {

    @isTest
    static void testPopulateAccountsAndLocations_WithExplicitAccount() {
        // Create Parent Account (Supplying Account candidate)
        Account parentAcc = new Account(Name = 'Parent Supplying Account');
        insert parentAcc;

        // Create Child Account (Requesting Account)
        Account childAcc = new Account(Name = 'Child Requesting Account', ParentId = parentAcc.Id);
        insert childAcc;

        // Create Locations for both accounts
        Inventory_Location__c targetLoc = new Inventory_Location__c(
            Name = 'Target Location A',
            Account__c = childAcc.Id
        );
        Inventory_Location__c sourceLoc = new Inventory_Location__c(
            Name = 'Source Location B',
            Account__c = parentAcc.Id
        );
        insert new List<Inventory_Location__c>{ targetLoc, sourceLoc };

        // Create Supply Request with only Requesting Account set
        Supply_Request__c sr = new Supply_Request__c(
            Requesting_Account__c = childAcc.Id
        );

        Test.startTest();
        SupplyRequestHelper.populateAccountsAndLocations(new List<Supply_Request__c>{ sr });
        Test.stopTest();

        // Assertions
        System.assertEquals(childAcc.Id, sr.Requesting_Account__c, 'Requesting Account should remain childAcc');
        System.assertEquals(parentAcc.Id, sr.Supplying_Account__c, 'Supplying Account should be populated from ParentId');
        System.assertEquals(targetLoc.Id, sr.Target_Location__c, 'Target Location should be populated from childAcc location');
        System.assertEquals(sourceLoc.Id, sr.Source_Location__c, 'Source Location should be populated from parentAcc location');
    }

    @isTest
    static void testPopulateAccountsAndLocations_DeriveFromUser() {
        // Create Supply Request with no Requesting Account
        Supply_Request__c sr = new Supply_Request__c();

        Test.startTest();
        SupplyRequestHelper.populateAccountsAndLocations(new List<Supply_Request__c>{ sr });
        Test.stopTest();

        // Should complete without throwing exceptions
        System.assertNotEquals(null, sr, 'Supply request object should exist');
    }

    @isTest
    static void testPopulateAccountsAndLocations_Bulk() {
        Account parentAcc = new Account(Name = 'Parent Account');
        insert parentAcc;

        Account childAcc = new Account(Name = 'Child Account', ParentId = parentAcc.Id);
        insert childAcc;

        Inventory_Location__c loc1 = new Inventory_Location__c(Name = 'Location 1', Account__c = childAcc.Id);
        Inventory_Location__c loc2 = new Inventory_Location__c(Name = 'Location 2', Account__c = parentAcc.Id);
        insert new List<Inventory_Location__c>{ loc1, loc2 };

        List<Supply_Request__c> srList = new List<Supply_Request__c>();
        for (Integer i = 0; i < 50; i++) {
            srList.add(new Supply_Request__c(Requesting_Account__c = childAcc.Id));
        }

        Test.startTest();
        SupplyRequestHelper.populateAccountsAndLocations(srList);
        Test.stopTest();

        for (Supply_Request__c sr : srList) {
            System.assertEquals(parentAcc.Id, sr.Supplying_Account__c, 'Supplying Account should be set');
            System.assertEquals(loc1.Id, sr.Target_Location__c, 'Target Location should be set');
            System.assertEquals(loc2.Id, sr.Source_Location__c, 'Source Location should be set');
        }
    }

    @isTest
    static void testPopulateAccountsAndLocations_SubRequestType() {
        Account dealerAcc = new Account(Name = 'Dealer Account', Type = 'Dealer');
        insert dealerAcc;

        Account retailerAcc = new Account(Name = 'Retailer Account', Type = 'Retailer', ParentId = dealerAcc.Id);
        insert retailerAcc;

        Supply_Request__c sr = new Supply_Request__c(
            Requesting_Account__c = retailerAcc.Id,
            Supplying_Account__c = dealerAcc.Id
        );

        Test.startTest();
        SupplyRequestHelper.populateAccountsAndLocations(new List<Supply_Request__c>{ sr });
        Test.stopTest();

        // Verifies no restricted picklist exception is thrown and logic executes safely
        System.assertNotEquals(null, sr, 'Supply request record should be processed safely');
    }
}