@isTest
public class Product2TriggerTest {
    @isTest
    static void testProduct2Trigger() {
        Product2 prod = new Product2(
            Name = 'Test Product ABC',
            ProductCode = 'TEST-ABC',
            IsActive = true
        );
        
        Test.startTest();
        insert prod;
        
        prod.Description = 'Updated description';
        update prod;
        Test.stopTest();
        
        List<Item__c> items = [SELECT Id, Name, Item_Code__c FROM Item__c WHERE Item_Code__c = 'TEST-ABC'];
        System.assertEquals(1, items.size(), 'Should sync product insert to item');
    }
}