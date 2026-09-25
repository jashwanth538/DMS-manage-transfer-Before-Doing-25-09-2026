@isTest
public class PurchaseOrderPDFControllerTest {
  @testSetup
  static void setupTestData() {
    // 1. Vendor 1
    Account vendor1 = new Account(
      Name = 'ABC Traders',
      Phone = '1234567890',
      BillingStreet = '123 Custom St',
      BillingCity = 'Hyderabad',
      BillingState = 'Telangana',
      BillingPostalCode = '500081',
      BillingCountry = 'India'
    );
    insert vendor1;

    Contact con1 = new Contact(
      LastName = 'Test Contact',
      Email = 'test@example.com',
      Phone = '0987654321',
      MobilePhone = '1234567890',
      AccountId = vendor1.Id
    );
    insert con1;

    // 2. Vendor 2
    Account vendor2 = new Account(
      Name = 'Standard Address Vendor',
      BillingStreet = '456 Standard St',
      BillingCity = 'Bangalore',
      BillingState = 'Karnataka',
      BillingPostalCode = '560001',
      BillingCountry = 'India',
      Phone = '9876543210'
    );
    insert vendor2;

    Contact con2 = new Contact(
      LastName = 'MobilePhone Contact',
      MobilePhone = '9988776655',
      AccountId = vendor2.Id
    );
    insert con2;

    // 3. Vendor 3 with Multiline Address
    Account vendor3 = new Account(
      Name = 'Multiline Address Vendor',
      BillingStreet = 'Building 4\nSector 5\nIndustrial Area',
      BillingCity = 'Pune',
      BillingState = 'Maharashtra',
      BillingPostalCode = '411001',
      BillingCountry = 'India'
    );
    insert vendor3;

    // 4. Vendor 4 with Inline Address
    Account vendor4 = new Account(
      Name = 'Inline Address Vendor',
      BillingStreet = '123 Main St, chennai, tamil nadu, 600001, india',
      BillingCity = 'Chennai',
      BillingState = 'Tamil Nadu',
      BillingPostalCode = '600001',
      BillingCountry = 'India',
      Phone = '8877665544'
    );
    insert vendor4;

    // 5. Empty Vendor (no contacts, no address)
    Account emptyVendor = new Account(
      Name = 'Empty Vendor',
      BillingState = 'Telangana'
    );
    insert emptyVendor;

    // Warehouse Location
    Inventory_Location__c warehouse = new Inventory_Location__c(
      Name = 'Hyderabad WH'
    );
    insert warehouse;

    // Item
    Item__c item = new Item__c(Name = 'ITEM-A', Base_Tax__c = 18.0);
    insert item;

    // Purchase Order 1: Standard with Vendor1
    Purchase_Order__c po1 = new Purchase_Order__c(
      Supplying_Account__c = vendor1.Id,
      Target_Location__c = warehouse.Id,
      PO_Date__c = Date.today(),
      Expected_Date__c = Date.today().addDays(5),
      Status__c = 'Draft'
    );
    insert po1;

    Purchase_Order_Line_Item__c poli1 = new Purchase_Order_Line_Item__c(
      Purchase_Order__c = po1.Id,
      Item__c = item.Id,
      Ordered_Qty__c = 10,
      Unit_Price__c = 100
    );
    insert poli1;

    // Purchase Order 2: Empty Vendor and Null PO_Date__c
    Purchase_Order__c po2 = new Purchase_Order__c(
      Supplying_Account__c = emptyVendor.Id,
      Status__c = 'Draft'
    );
    insert po2;

    // Purchase Order 3: 25 Line Items for Pagination Testing
    Purchase_Order__c po3 = new Purchase_Order__c(
      Supplying_Account__c = vendor1.Id,
      PO_Date__c = Date.today(),
      Status__c = 'Draft'
    );
    insert po3;

    List<Purchase_Order_Line_Item__c> manyItems = new List<Purchase_Order_Line_Item__c>();
    for (Integer i = 0; i < 25; i++) {
      manyItems.add(new Purchase_Order_Line_Item__c(
        Purchase_Order__c = po3.Id,
        Item__c = item.Id,
        Ordered_Qty__c = 1,
        Unit_Price__c = 10
      ));
    }
    insert manyItems;

    // Purchase Order 4: Multiline Address Vendor
    Purchase_Order__c po4 = new Purchase_Order__c(
      Supplying_Account__c = vendor3.Id,
      Status__c = 'Draft'
    );
    insert po4;

    // Purchase Order 5: Inline Address Vendor
    Purchase_Order__c po5 = new Purchase_Order__c(
      Supplying_Account__c = vendor4.Id,
      Status__c = 'Draft'
    );
    insert po5;

    // Purchase Order 6: Standard Address Vendor
    Purchase_Order__c po6 = new Purchase_Order__c(
      Supplying_Account__c = vendor2.Id,
      Status__c = 'Draft'
    );
    insert po6;
  }

  @isTest
  static void testGetPurchaseOrderDetails() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = PurchaseOrderPDFController.getPurchaseOrderDetails(po.Id);
    LWCServerCalloutWrapper errorWrapper = PurchaseOrderPDFController.getPurchaseOrderDetails(null);
    Test.stopTest();

    System.assertNotEquals(null, wrapper);
    System.assertEquals(true, wrapper.isSuccess);
    System.assertEquals(false, errorWrapper.isSuccess);
  }

  @isTest
  static void testGetPurchaseOrderItems() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = PurchaseOrderPDFController.getPurchaseOrderItems(po.Id);
    LWCServerCalloutWrapper errorWrapper = PurchaseOrderPDFController.getPurchaseOrderItems(null);
    Test.stopTest();

    System.assertNotEquals(null, wrapper);
    System.assertEquals(true, wrapper.isSuccess);
    System.assertEquals(true, errorWrapper.isSuccess);
    System.assertEquals(0, errorWrapper.resultList.size());
  }

  @isTest
  static void testGetEmailDefaults() {
    Purchase_Order__c po1 = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];
    Purchase_Order__c po2 = [SELECT Id FROM Purchase_Order__c WHERE Supplying_Account__r.Name = 'Empty Vendor' LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper1 = PurchaseOrderPDFController.getEmailDefaults(po1.Id);
    LWCServerCalloutWrapper wrapper2 = PurchaseOrderPDFController.getEmailDefaults(po2.Id);
    LWCServerCalloutWrapper errorWrapper = PurchaseOrderPDFController.getEmailDefaults(null);
    Test.stopTest();

    System.assertEquals(true, wrapper1.isSuccess);
    System.assertEquals(true, wrapper2.isSuccess);
    System.assertEquals(false, errorWrapper.isSuccess);
  }

  @isTest
  static void testSavePDFAndVersioning() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];

    Test.startTest();
    // Save version 1
    LWCServerCalloutWrapper wrapper1 = PurchaseOrderPDFController.savePDF(po.Id);
    // Save version 2
    LWCServerCalloutWrapper wrapper2 = PurchaseOrderPDFController.savePDF(po.Id);
    // Trigger catch block
    PurchaseOrderPDFController.forceException = true;
    LWCServerCalloutWrapper errorWrapper = PurchaseOrderPDFController.savePDF(po.Id);
    PurchaseOrderPDFController.forceException = false;
    Test.stopTest();

    System.assertEquals(true, wrapper1.isSuccess);
    System.assertEquals(true, wrapper2.isSuccess);
    System.assertNotEquals(null, wrapper1.result);
    System.assertEquals(false, errorWrapper.isSuccess);

    PurchaseOrderPDFController.EmailDetails details = 
      PurchaseOrderPDFController.getLatestDocumentForSendingAnEmail(String.valueOf(po.Id));
    PurchaseOrderPDFController.forceException = true;
    PurchaseOrderPDFController.EmailDetails emptyDetails = 
      PurchaseOrderPDFController.getLatestDocumentForSendingAnEmail(String.valueOf(po.Id));
    PurchaseOrderPDFController.forceException = false;

    System.assertNotEquals(null, details);
    System.assertEquals('ABC Traders', details.contactName);
    System.assertEquals('test@example.com', details.contactEmail);
    System.assertNotEquals(null, details.contentDocumentId);
    System.assertEquals(null, emptyDetails);
  }

  @isTest
  static void testSaveAndSendEmail() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = PurchaseOrderPDFController.saveAndSendEmail(
      po.Id,
      'vendor@example.com',
      'Subject Test',
      'Body Test'
    );
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess);
  }

  @isTest
  static void testSaveAndSendEmailFull_WithAttachments() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];

    List<Map<String, String>> customAtts = new List<Map<String, String>>();
    customAtts.add(new Map<String, String>{
      'fileName' => 'VendorDoc.pdf',
      'base64Data' => EncodingUtil.base64Encode(Blob.valueOf('Vendor Content')),
      'contentType' => 'application/pdf'
    });

    Test.startTest();
    LWCServerCalloutWrapper wrapper = PurchaseOrderPDFController.saveAndSendEmailFull(
      po.Id,
      'vendor1@example.com, vendor2@example.com; vendor3@example.com',
      'cc1@example.com, cc2@example.com',
      'bcc1@example.com, bcc2@example.com',
      'PO Email Subject',
      'Plain Body Without HTML Tags',
      UserInfo.getUserEmail(),
      true,
      JSON.serialize(customAtts)
    );
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess);
  }

  @isTest
  static void testSaveAndSendEmailFull_NoPdfAndBlankSender() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = PurchaseOrderPDFController.saveAndSendEmailFull(
      po.Id,
      'vendor@example.com',
      null,
      null,
      'PO Subject',
      '<p>HTML Body</p>',
      null,
      false,
      null
    );
    // Trigger catch block
    PurchaseOrderPDFController.forceException = true;
    LWCServerCalloutWrapper errorWrapper = PurchaseOrderPDFController.saveAndSendEmailFull(
      po.Id, null, null, null, null, null, null, true, null
    );
    PurchaseOrderPDFController.forceException = false;
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess);
    System.assertEquals(false, errorWrapper.isSuccess);
  }

  @isTest
  static void testVisualforceController_Standard() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Target_Location__c != null LIMIT 1];

    Test.startTest();
    PageReference pageRef = new PageReference('/apex/PurchaseOrderPDF');
    pageRef.getParameters().put('id', po.Id);
    Test.setCurrentPage(pageRef);

    PurchaseOrderPDFController controller = new PurchaseOrderPDFController();
    Test.stopTest();

    System.assertNotEquals(null, controller.poRec);
    System.assertEquals(1, controller.poItems.size());
    System.assertNotEquals(null, controller.subtotal);
    System.assertNotEquals(null, controller.grandTotal);
    System.assertEquals(1000, controller.subtotal);
    System.assertEquals('test@example.com', controller.vendorEmail);
    System.assertEquals('1234567890', controller.vendorMobile);
    System.assertEquals('123 Custom St', controller.vendorStreet);
    System.assertEquals('Hyderabad', controller.vendorCity);
  }

  @isTest
  static void testVisualforceController_Pagination() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Supplying_Account__r.Name = 'ABC Traders' AND Target_Location__c = null LIMIT 1];

    Test.startTest();
    PageReference pageRef = new PageReference('/apex/PurchaseOrderPDF');
    pageRef.getParameters().put('id', po.Id);
    Test.setCurrentPage(pageRef);

    PurchaseOrderPDFController controller = new PurchaseOrderPDFController();
    Test.stopTest();

    System.assertEquals(25, controller.poItems.size());
    System.assertEquals(2, controller.poItemPages.size());
    System.assertEquals(18, controller.poItemPages[0].items.size());
    System.assertEquals(7, controller.poItemPages[1].items.size());
  }

  @isTest
  static void testVisualforceController_StandardAddressFallback() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Supplying_Account__r.Name = 'Standard Address Vendor' LIMIT 1];

    Test.startTest();
    PageReference pageRef = new PageReference('/apex/PurchaseOrderPDF');
    pageRef.getParameters().put('id', po.Id);
    Test.setCurrentPage(pageRef);

    PurchaseOrderPDFController controller = new PurchaseOrderPDFController();
    Test.stopTest();

    System.assertEquals('456 Standard St', controller.vendorStreet);
    System.assertEquals('Bangalore', controller.vendorCity);
    System.assertEquals('Karnataka', controller.vendorState);
    System.assertEquals('560001', controller.vendorPostalCode);
    System.assertEquals('India', controller.vendorCountry);
    System.assertEquals('9988776655', controller.vendorMobile);
  }

  @isTest
  static void testVisualforceController_MultilineAddress() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Supplying_Account__r.Name = 'Multiline Address Vendor' LIMIT 1];

    Test.startTest();
    PageReference pageRef = new PageReference('/apex/PurchaseOrderPDF');
    pageRef.getParameters().put('id', po.Id);
    Test.setCurrentPage(pageRef);

    PurchaseOrderPDFController controller = new PurchaseOrderPDFController();
    Test.stopTest();

    System.assertEquals('Pune', controller.vendorCity);
    System.assertEquals('Maharashtra', controller.vendorState);
    System.assertEquals('411001', controller.vendorPostalCode);
    System.assertEquals('India', controller.vendorCountry);
  }

  @isTest
  static void testVisualforceController_InlineAddressDeduplication() {
    Purchase_Order__c po = [SELECT Id FROM Purchase_Order__c WHERE Supplying_Account__r.Name = 'Inline Address Vendor' LIMIT 1];

    Test.startTest();
    PageReference pageRef = new PageReference('/apex/PurchaseOrderPDF');
    pageRef.getParameters().put('id', po.Id);
    Test.setCurrentPage(pageRef);

    PurchaseOrderPDFController controller = new PurchaseOrderPDFController();
    Test.stopTest();

    System.assertEquals('', controller.vendorCity);
    System.assertEquals('', controller.vendorState);
    System.assertEquals('', controller.vendorPostalCode);
    System.assertEquals('', controller.vendorCountry);
    System.assertEquals('8877665544', controller.vendorMobile);
  }

  @isTest
  static void testVisualforceController_NoPageParamAndHelpers() {
    Test.startTest();
    PurchaseOrderPDFController controller = new PurchaseOrderPDFController();

    Purchase_Order_Line_Item__c poliNull = new Purchase_Order_Line_Item__c();
    PurchaseOrderPDFController.POLineWrapper wrapNull = 
      new PurchaseOrderPDFController.POLineWrapper(poliNull, 1);
    Test.stopTest();

    System.assertEquals(null, controller.poRec);
    System.assertEquals(0, wrapNull.total);
  }
}