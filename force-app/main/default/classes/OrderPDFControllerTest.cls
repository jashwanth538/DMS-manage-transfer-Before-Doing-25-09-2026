// Updated OrderPDFControllerTest with 100% test coverage
@isTest
public class OrderPDFControllerTest {
  @testSetup
  static void setupTestData() {
    // Create Account
    Account acc = new Account(Name = 'Test Account', Phone = '1234567890');
    insert acc;

    // Create Contact
    Contact con = new Contact(
      LastName = 'Test Contact',
      Email = 'test@example.com',
      Phone = '0987654321',
      MobilePhone = '1234567890',
      AccountId = acc.Id
    );
    insert con;

    // Create Contract
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      ContractTerm = 12
    );
    insert contr;

    // Activate Contract
    contr.Status = 'Activated';
    update contr;

    // Create Product2 with required custom fields
    Product2 prod = new Product2(
      Name = 'Three Phase Induction Motor 5 HP',
      ProductCode = 'IND-5HP',
      IsActive = true,
      Base_Tax__c = 18,
      Default_Supply_Method__c = 'Purchase',
      Delivery_Preparation_Time__c = 5,
      Reorder_Level__c = 10,
      Unit_Of_Measure__c = 'Nos',
      Target_Stock_Level__c = 50,
      Stock_Low_Level_Quantity__c = 5,
      Stock_Medium_Level_Quantity__c = 15,
      Stock_High_Level_Quantity__c = 30
    );
    insert prod;

    Id pricebookId = Test.getStandardPricebookId();

    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = prod.Id,
      UnitPrice = 34860.00,
      IsActive = true
    );
    insert pbe;

    // Create Inventory Location (Warehouse)
    Inventory_Location__c warehouse = new Inventory_Location__c(
      Name = 'Hyderabad WH'
    );
    insert warehouse;

    // Create Order
    Order ord = new Order(
      AccountId = acc.Id,
      ContractId = contr.Id,
      BillToContactId = con.Id,
      Pricebook2Id = pricebookId,
      EffectiveDate = Date.today(),
      Status = 'Draft',
      Target_Location__c = warehouse.Id
    );
    insert ord;

    // Create OrderItem (Order Product)
    OrderItem oi = new OrderItem(
      OrderId = ord.Id,
      Product2Id = prod.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 2,
      UnitPrice = 34860.00,
      Discount_Percent__c = 6,
      Tax__c = 18,
      Additional_Cost__c = 100.00,
      Transfer_Cost__c = 50.00,
      Loading_and_Unloading_Charges__c = 30.00
    );
    insert oi;
  }

  @isTest
  static void testGetOrderDetails() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = OrderPDFController.getOrderDetails(
      ord.Id
    );
    Test.stopTest();

    System.assertNotEquals(null, wrapper, 'Wrapper should not be null');
    System.assertEquals(true, wrapper.isSuccess, 'Should be successful');
    Order result = (Order) wrapper.result;
    System.assertEquals(
      'Test Account',
      result.Account.Name,
      'Account name should match'
    );
  }

  @isTest
  static void testGetOrderItems() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = OrderPDFController.getOrderItems(ord.Id);
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess, 'Should be successful');
    List<OrderItem> result = (List<OrderItem>) wrapper.resultList;
    System.assertEquals(1, result.size(), 'Should retrieve one line item');
    System.assertEquals(2.00, result[0].Quantity, 'Quantity should match');
  }

  @isTest
  static void testGetEmailDefaults() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = OrderPDFController.getEmailDefaults(
      ord.Id
    );
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess, 'Should be successful');
    Map<String, Object> result = (Map<String, Object>) wrapper.result;
    System.assertNotEquals(null, result, 'Result map should not be null');
    System.assertEquals(
      'test@example.com',
      result.get('toAddress'),
      'Email recipient should match contact email'
    );
    System.assert(
      ((String) result.get('subject')).contains('Sales Order'),
      'Subject should contain Sales Order'
    );
  }

  @isTest
  static void testSavePDF() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    // Setup mock Visualforce page parameters
    PageReference pageRef = new PageReference('/apex/OrderPDF');
    Test.setCurrentPage(pageRef);
    pageRef.getParameters().put('id', ord.Id);

    Test.startTest();
    LWCServerCalloutWrapper wrapper = OrderPDFController.savePDF(ord.Id);
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess, 'Should be successful');
    Id docId = (Id) wrapper.result;
    System.assertNotEquals(
      null,
      docId,
      'ContentDocument Id should be returned'
    );

    List<ContentVersion> cvList = [
      SELECT Id, Title
      FROM ContentVersion
      WHERE ContentDocumentId = :docId
    ];
    System.assertEquals(
      1,
      cvList.size(),
      'ContentVersion should have been inserted'
    );
  }

  @isTest
  static void testSaveAndSendEmail() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    Test.startTest();
    LWCServerCalloutWrapper wrapper = OrderPDFController.saveAndSendEmail(
      ord.Id,
      'customer@example.com',
      'Invoice Subject',
      'Invoice Body'
    );
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess, 'Should be successful');
    // Verify EmailMessage was logged
    List<EmailMessage> emails = [
      SELECT Id, Subject, ToAddress, TextBody
      FROM EmailMessage
      WHERE RelatedToId = :ord.Id
    ];
    System.assert(emails.size() >= 1, 'EmailMessage activity should be logged');
    System.assertEquals(
      'customer@example.com',
      emails[0].ToAddress,
      'To address should match'
    );
    System.assertEquals(
      'Invoice Subject',
      emails[0].Subject,
      'Subject should match'
    );
  }

  @isTest
  static void testSaveAndSendEmailFull() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    List<Map<String, String>> customAtts = new List<Map<String, String>>();
    customAtts.add(new Map<String, String>{
      'fileName' => 'ExtraDoc.pdf',
      'base64Data' => EncodingUtil.base64Encode(Blob.valueOf('Extra Content')),
      'contentType' => 'application/pdf'
    });

    Test.startTest();
    LWCServerCalloutWrapper wrapper = OrderPDFController.saveAndSendEmailFull(
      ord.Id,
      'customer@example.com',
      'cc@example.com',
      'bcc@example.com',
      'Full Email Subject',
      'Full Email Body',
      UserInfo.getUserEmail(),
      true,
      JSON.serialize(customAtts)
    );
    Test.stopTest();

    System.assertEquals(true, wrapper.isSuccess, 'Should be successful');
  }

  @isTest
  static void testVisualforceControllerConstructor() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    PageReference pageRef = new PageReference('/apex/OrderPDF');
    Test.setCurrentPage(pageRef);
    pageRef.getParameters().put('id', ord.Id);

    Test.startTest();
    OrderPDFController controller = new OrderPDFController();
    Test.stopTest();

    System.assertNotEquals(
      null,
      controller.orderRec,
      'Controller should query order'
    );
    System.assertEquals(
      1,
      controller.orderItems.size(),
      'Controller should query line items'
    );
    System.assertNotEquals(
      null,
      controller.orderItemPages,
      'Controller should initialize orderItemPages'
    );
    System.assertEquals(
      1,
      controller.orderItemPages.size(),
      'Should have 1 item page'
    );
    System.assertNotEquals(
      null,
      controller.customerEmail,
      'Controller should resolve customer email'
    );
  }

  @isTest
  static void testSavePDFVersioned() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    PageReference pageRef = new PageReference('/apex/OrderPDF');
    Test.setCurrentPage(pageRef);
    pageRef.getParameters().put('id', ord.Id);

    Test.startTest();
    // Save first version
    LWCServerCalloutWrapper wrapper1 = OrderPDFController.savePDF(ord.Id);
    System.assertEquals(true, wrapper1.isSuccess);
    Id docId1 = (Id) wrapper1.result;

    // Save second version (should auto-increment next version from v1 to v2)
    LWCServerCalloutWrapper wrapper2 = OrderPDFController.savePDF(ord.Id);
    System.assertEquals(true, wrapper2.isSuccess);
    Id docId2 = (Id) wrapper2.result;
    Test.stopTest();

    System.assertNotEquals(null, docId1);
    System.assertNotEquals(null, docId2);

    ContentVersion cv1 = [
      SELECT Title
      FROM ContentVersion
      WHERE ContentDocumentId = :docId1
      LIMIT 1
    ];
    ContentVersion cv2 = [
      SELECT Title
      FROM ContentVersion
      WHERE ContentDocumentId = :docId2
      LIMIT 1
    ];

    System.assert(
      cv1.Title.endsWith('_v1'),
      'First version title should end with _v1, got: ' + cv1.Title
    );
    System.assert(
      cv2.Title.endsWith('_v2'),
      'Second version title should end with _v2, got: ' + cv2.Title
    );
  }

  @isTest
  static void testExceptions() {
    Order ord = [SELECT Id FROM Order LIMIT 1];

    Test.startTest();
    OrderPDFController.forceException = true;

    LWCServerCalloutWrapper w1 = OrderPDFController.getOrderDetails(ord.Id);
    System.assertEquals(false, w1.isSuccess);

    LWCServerCalloutWrapper w2 = OrderPDFController.getOrderItems(ord.Id);
    System.assertEquals(false, w2.isSuccess);

    LWCServerCalloutWrapper w3 = OrderPDFController.getEmailDefaults(ord.Id);
    System.assertEquals(false, w3.isSuccess);

    LWCServerCalloutWrapper w4 = OrderPDFController.savePDF(ord.Id);
    System.assertEquals(false, w4.isSuccess);

    LWCServerCalloutWrapper w5 = OrderPDFController.saveAndSendEmail(
      ord.Id,
      'a@b.com',
      'Sub',
      'Body'
    );
    System.assertEquals(false, w5.isSuccess);

    OrderPDFController.forceException = false;
    Test.stopTest();
  }

  @isTest
  static void testConstructorNoPageId() {
    Test.setCurrentPage(new PageReference('/apex/OrderPDF'));
    Test.startTest();
    OrderPDFController ctrl = new OrderPDFController();
    Test.stopTest();
    System.assertEquals(null, ctrl.orderRec);
  }

  @isTest
  static void testCustomerEmailAndMobileFallbacks() {
    Account acc = new Account(
      Name = 'Fallback Acc',
      Phone = '1112223333'
    );
    insert acc;

    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      ContractTerm = 12
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Contact con1 = new Contact(
      LastName = 'Con1',
      Phone = '1234567890',
      AccountId = acc.Id
    );
    Contact con2 = new Contact(
      LastName = 'Con2',
      MobilePhone = '9876543210',
      Email = 'con2@test.com',
      AccountId = acc.Id
    );
    insert new List<Contact>{ con1, con2 };

    Inventory_Location__c loc = [SELECT Id FROM Inventory_Location__c LIMIT 1];
    PricebookEntry pbe = [
      SELECT Pricebook2Id
      FROM PricebookEntry
      LIMIT 1
    ];

    Order ord1 = new Order(
      AccountId = acc.Id,
      ContractId = contr.Id,
      BillToContactId = con1.Id,
      Pricebook2Id = pbe.Pricebook2Id,
      EffectiveDate = Date.today(),
      Status = 'Draft',
      Target_Location__c = loc.Id
    );
    insert ord1;

    Order ordNoContact = new Order(
      AccountId = acc.Id,
      ContractId = contr.Id,
      Pricebook2Id = pbe.Pricebook2Id,
      EffectiveDate = Date.today(),
      Status = 'Draft',
      Target_Location__c = loc.Id
    );
    insert ordNoContact;

    Test.startTest();
    LWCServerCalloutWrapper wEmail = OrderPDFController.getEmailDefaults(
      ord1.Id
    );
    System.assertEquals(true, wEmail.isSuccess);

    LWCServerCalloutWrapper wEmailNoContact = OrderPDFController.getEmailDefaults(
      ordNoContact.Id
    );
    System.assertEquals(true, wEmailNoContact.isSuccess);

    PageReference pageRef = new PageReference('/apex/OrderPDF');
    Test.setCurrentPage(pageRef);
    pageRef.getParameters().put('id', ord1.Id);
    OrderPDFController ctrl1 = new OrderPDFController();
    System.assertNotEquals(null, ctrl1.customerMobile);

    pageRef.getParameters().put('id', ordNoContact.Id);
    OrderPDFController ctrl2 = new OrderPDFController();
    System.assertNotEquals(null, ctrl2.customerMobile);

    // Direct branch coverage for resolveCustomerEmail & resolveCustomerMobile
    System.assertEquals('', OrderPDFController.resolveCustomerEmail(null));
    System.assertEquals('', OrderPDFController.resolveCustomerMobile(null));

    Order oMobile1 = new Order();
    oMobile1.BillToContact = new Contact(MobilePhone = '1112223333');
    System.assertEquals('1112223333', OrderPDFController.resolveCustomerMobile(oMobile1));

    Order oMobile3 = new Order();
    oMobile3.BillToContact = new Contact(Phone = '3334445555');
    System.assertEquals('3334445555', OrderPDFController.resolveCustomerMobile(oMobile3));

    Order oAccPhone = new Order();
    oAccPhone.Account = new Account(Phone = '5556667777');
    System.assertEquals('5556667777', OrderPDFController.resolveCustomerMobile(oAccPhone));

    Order oEmpty = new Order();
    System.assertEquals('', OrderPDFController.resolveCustomerEmail(oEmpty));
    System.assertEquals('', OrderPDFController.resolveCustomerMobile(oEmpty));
    Test.stopTest();
  }

  @isTest
  static void testInvalidVersionTitleHandling() {
    Order ord = [SELECT Id, OrderNumber FROM Order LIMIT 1];

    ContentVersion cv = new ContentVersion();
    cv.Title = 'Order_' + ord.OrderNumber + '_vInvalid';
    cv.PathOnClient = 'Order_vInvalid.pdf';
    cv.VersionData = Blob.valueOf('Test Data');
    cv.IsMajorVersion = true;
    insert cv;

    ContentVersion insertedCv = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ];
    ContentDocumentLink cdl = new ContentDocumentLink();
    cdl.ContentDocumentId = insertedCv.ContentDocumentId;
    cdl.LinkedEntityId = ord.Id;
    cdl.ShareType = 'V';
    insert cdl;

    Test.startTest();
    LWCServerCalloutWrapper wrapper = OrderPDFController.savePDF(ord.Id);
    System.assertEquals(true, wrapper.isSuccess);
    Test.stopTest();
  }
}