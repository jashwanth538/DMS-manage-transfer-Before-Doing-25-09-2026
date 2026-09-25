@isTest
private class Product2SyncTest {
    
    private static Product2 createProduct(String name, String code) {
        return new Product2(
            Name = name,
            ProductCode = code,
            IsActive = true,
            Description = 'Test Description',
            Family = 'Finished Good',
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'Each',
            Base_Tax__c = 5,
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 20,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 80
        );
    }
    
    private static Item__c createItem(String name, String code) {
        return new Item__c(
            Name = name,
            Item_Code__c = code,
            Active__c = true,
            Item_Description__c = 'Test Description',
            Item_Family__c = 'Finished Good',
            Default_Supply_Method__c = 'Purchase',
            Delivery_Preparation_Time__c = 1,
            Reorder_Level__c = 10,
            Unit_Of_Measure__c = 'Each',
            Base_Tax__c = 5,
            Target_Stock_Level__c = 100,
            Stock_Low_Level_Quantity__c = 20,
            Stock_Medium_Level_Quantity__c = 50,
            Stock_High_Level_Quantity__c = 80
        );
    }
    
    @isTest
    static void testProductToItemInsert() {
        Product2 prod = createProduct('Test Product A', 'PROD-A');
        
        Test.startTest();
        insert prod;
        Test.stopTest();
        
        List<Item__c> items = [
            SELECT Id, Name, Item_Code__c, Item_Description__c, Item_Family__c, Active__c, 
                   Reorder_Level__c, Target_Stock_Level__c 
            FROM Item__c 
            WHERE Item_Code__c = 'PROD-A'
        ];
        System.assertEquals(1, items.size(), 'An item should have been created for the product');
        Item__c item = items[0];
        System.assertEquals('Test Product A', item.Name);
        System.assertEquals('Test Description', item.Item_Description__c);
        System.assertEquals('Finished Good', item.Item_Family__c);
        System.assertEquals(true, item.Active__c);
        System.assertEquals(10, item.Reorder_Level__c);
        System.assertEquals(100, item.Target_Stock_Level__c);
    }
    
    @isTest
    static void testProductToItemUpdate() {
        Product2 prod = createProduct('Test Product B', 'PROD-B');
        insert prod;
        
        // Retrieve the created Item
        Item__c itemBefore = [SELECT Id, Name, Active__c FROM Item__c WHERE Item_Code__c = 'PROD-B'];
        System.assertEquals('Test Product B', itemBefore.Name);
        
        // Update product
        prod.Name = 'Updated Product B';
        prod.Description = 'New Description B';
        prod.IsActive = false;
        
        Test.startTest();
        update prod;
        Test.stopTest();
        
        Item__c itemAfter = [SELECT Id, Name, Item_Description__c, Active__c FROM Item__c WHERE Id = :itemBefore.Id];
        System.assertEquals('Updated Product B', itemAfter.Name);
        System.assertEquals('New Description B', itemAfter.Item_Description__c);
        System.assertEquals(false, itemAfter.Active__c);
    }
    
    @isTest
    static void testItemToProductInsert() {
        Item__c item = createItem('Test Item C', 'ITEM-C');
        
        Test.startTest();
        insert item;
        Test.stopTest();
        
        List<Product2> products = [
            SELECT Id, Name, ProductCode, Description, Family, IsActive, 
                   Reorder_Level__c, Target_Stock_Level__c 
            FROM Product2 
            WHERE ProductCode = 'ITEM-C'
        ];
        System.assertEquals(1, products.size(), 'A product should have been created for the item');
        Product2 prod = products[0];
        System.assertEquals('Test Item C', prod.Name);
        System.assertEquals('Test Description', prod.Description);
        System.assertEquals('Finished Good', prod.Family);
        System.assertEquals(true, prod.IsActive);
        System.assertEquals(10, prod.Reorder_Level__c);
        System.assertEquals(100, prod.Target_Stock_Level__c);
    }
    
    @isTest
    static void testItemToProductUpdate() {
        Item__c item = createItem('Test Item D', 'ITEM-D');
        insert item;
        
        Product2 prodBefore = [SELECT Id, Name, IsActive FROM Product2 WHERE ProductCode = 'ITEM-D'];
        System.assertEquals('Test Item D', prodBefore.Name);
        
        item.Name = 'Updated Item D';
        item.Item_Description__c = 'New Description D';
        item.Active__c = false;
        
        Test.startTest();
        update item;
        Test.stopTest();
        
        Product2 prodAfter = [SELECT Id, Name, Description, IsActive FROM Product2 WHERE Id = :prodBefore.Id];
        System.assertEquals('Updated Item D', prodAfter.Name);
        System.assertEquals('New Description D', prodAfter.Description);
        System.assertEquals(false, prodAfter.IsActive);
    }
    
    @isTest
    static void testBulkSync() {
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 50; i++) {
            products.add(createProduct('Bulk Prod ' + i, 'BULK-' + i));
        }
        
        Test.startTest();
        insert products;
        Test.stopTest();
        
        List<Item__c> items = [SELECT Id FROM Item__c WHERE Item_Code__c LIKE 'BULK-%'];
        System.assertEquals(50, items.size());
    }

    @isTest
    static void testDuplicatePreventionInBatchProducts() {
        List<Product2> products = new List<Product2>();
        products.add(createProduct('Prod X', 'DUPLICATE-KEY'));
        products.add(createProduct('Prod X', 'DUPLICATE-KEY'));
        
        try {
            insert products;
            System.assert(false, 'Should fail to insert duplicate products in a batch due to composite uniqueness');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('A Product with this Name and Product Code combination already exists.'), 'Error message should contain custom text. Got: ' + e.getMessage());
        }
    }

    @isTest
    static void testDuplicatePreventionInBatchItems() {
        List<Item__c> itemsD = new List<Item__c>();
        itemsD.add(createItem('Item X', 'DUPLICATE-KEY2'));
        itemsD.add(createItem('Item X', 'DUPLICATE-KEY2'));
        
        try {
            insert itemsD;
            System.assert(false, 'Should fail to insert duplicate items in a batch due to composite uniqueness');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('An Item with this Name and Item Code combination already exists.'), 'Error message should contain custom text. Got: ' + e.getMessage());
        }
    }

    @isTest
    static void testDuplicatePreventionOnProductId() {
        // Create Product
        Product2 prod = createProduct('Product Unique Test', 'P-UNIQUE');
        insert prod;
        
        // Item is automatically created by sync with Product_Id__c = 'Product Unique Test-P-UNIQUE'
        List<Item__c> items = [SELECT Id, Product_Id__c FROM Item__c WHERE Product_Id__c = 'Product Unique Test-P-UNIQUE'];
        System.assertEquals(1, items.size());
        
        // Try to insert another Item with same Name and Code combination
        Item__c duplicateItem = createItem('Product Unique Test', 'P-UNIQUE');
        
        try {
            insert duplicateItem;
            System.assert(false, 'DML should have failed because of duplicate Name and Code combination');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('An Item with this Name and Item Code combination already exists.'), 'Error message should contain custom text. Got: ' + e.getMessage());
        }
    }

    @isTest
    static void testDuplicatePreventionOnItemId() {
        // Create Item
        Item__c item = createItem('Item Unique Test', 'I-UNIQUE');
        insert item;
        
        // Product is automatically created by sync with Item_Id__c = 'Item Unique Test-I-UNIQUE'
        List<Product2> products = [SELECT Id, Item_Id__c FROM Product2 WHERE Item_Id__c = 'Item Unique Test-I-UNIQUE'];
        System.assertEquals(1, products.size());
        
        // Try to insert another Product with same Name and Code combination
        Product2 duplicateProduct = createProduct('Item Unique Test', 'I-UNIQUE');
        
        try {
            insert duplicateProduct;
            System.assert(false, 'DML should have failed because of duplicate Name and Code combination');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('A Product with this Name and Product Code combination already exists.'), 'Error message should contain custom text. Got: ' + e.getMessage());
        }
    }
}