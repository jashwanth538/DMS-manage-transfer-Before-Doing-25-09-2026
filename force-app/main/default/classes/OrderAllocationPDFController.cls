public with sharing class OrderAllocationPDFController {
  @TestVisible
  private static Boolean forceException = false;

  public class AllocationItemPage {
    public List<AllocationLineWrapper> items { get; set; }
    public Integer pageNumber { get; set; }
    public Boolean isFirstPage { get; set; }
    public Boolean isLastPage { get; set; }
    public Integer startIndex { get; set; }

    public AllocationItemPage(
      List<AllocationLineWrapper> items,
      Integer pageNumber,
      Boolean isFirstPage,
      Boolean isLastPage,
      Integer startIndex
    ) {
      this.items = items;
      this.pageNumber = pageNumber;
      this.isFirstPage = isFirstPage;
      this.isLastPage = isLastPage;
      this.startIndex = startIndex;
    }
  }

  public class AllocationLineWrapper {
    public SObject item { get; set; }
    public Integer index { get; set; }
    public String productName { get; set; }
    public Decimal quantity { get; set; }
    public Decimal unitPrice { get; set; }
    public Decimal discountPercent { get; set; }
    public Decimal taxPercent { get; set; }
    public Decimal total { get; set; }

    public AllocationLineWrapper(SObject item, Integer index) {
      this.item = item;
      this.index = index;
      
      // Resolve Product Name
      this.productName = 'Product';
      try {
        if (item.getSObject('Product2') != null) {
          this.productName = (String) item.getSObject('Product2').get('Name');
        } else if (item.getSObject('Product__r') != null) {
          this.productName = (String) item.getSObject('Product__r').get('Name');
        } else if (item.getSObject('Item__r') != null) {
          this.productName = (String) item.getSObject('Item__r').get('Name');
        } else if (item.get('Name') != null) {
          this.productName = (String) item.get('Name');
        }
      } catch (Exception ex) {
        // Fallback
      }

      // Resolve Quantity
      this.quantity = 0;
      for (String qField : new List<String>{ 'Allocated_Quantity__c', 'Quantity__c', 'Quantity', 'Allocated_Qty__c' }) {
        try {
          if (item.get(qField) != null) {
            this.quantity = (Decimal) item.get(qField);
            break;
          }
        } catch (Exception ex) {}
      }

      // Resolve Unit Price
      this.unitPrice = 0;
      for (String pField : new List<String>{ 'Unit_Price__c', 'UnitPrice', 'Price__c' }) {
        try {
          if (item.get(pField) != null) {
            this.unitPrice = (Decimal) item.get(pField);
            break;
          }
        } catch (Exception ex) {}
      }

      // Resolve Discount
      this.discountPercent = 0;
      for (String dField : new List<String>{ 'Discount_Percent__c', 'Discount__c', 'Discount_Amount__c' }) {
        try {
          if (item.get(dField) != null) {
            this.discountPercent = (Decimal) item.get(dField);
            break;
          }
        } catch (Exception ex) {}
      }

      // Resolve Tax
      this.taxPercent = 0;
      for (String tField : new List<String>{ 'Tax__c', 'Tax_Percent__c', 'Tax_Amount__c' }) {
        try {
          if (item.get(tField) != null) {
            this.taxPercent = (Decimal) item.get(tField);
            break;
          }
        } catch (Exception ex) {}
      }

      // Resolve Total
      this.total = 0;
      for (String totField : new List<String>{ 'Total__c', 'Total_Price__c', 'Total_Amount__c', 'Line_Total__c' }) {
        try {
          if (item.get(totField) != null) {
            this.total = (Decimal) item.get(totField);
            break;
          }
        } catch (Exception ex) {}
      }
      if (this.total == 0 && this.quantity > 0 && this.unitPrice > 0) {
        this.total = (this.quantity * this.unitPrice) * (1 - (this.discountPercent / 100)) * (1 + (this.taxPercent / 100));
      }
    }
  }

  public Order_Allocation__c allocationRec { get; set; }
  public List<AllocationLineWrapper> allocationItems { get; set; }
  public List<AllocationItemPage> allocationItemPages { get; set; }
  public String customerMobile { get; set; }
  public String customerEmail { get; set; }
  public String customerName { get; set; }
  public String customerStreet { get; set; }
  public String customerCity { get; set; }
  public String customerState { get; set; }
  public String customerPostalCode { get; set; }
  public String customerCountry { get; set; }
  public Decimal subtotal { get; set; }
  public Decimal discountAmount { get; set; }
  public Decimal taxAmount { get; set; }
  public Decimal grandTotal { get; set; }

  // Standard Visualforce Controller Constructor
  public OrderAllocationPDFController() {
    String allocIdStr = ApexPages.currentPage().getParameters().get('id');
    if (String.isNotBlank(allocIdStr)) {
      try {
        Id allocId = (Id) allocIdStr;
        this.allocationRec = queryAllocation(allocId);
        List<SObject> rawItems = queryAllocationItems(allocId);

        this.allocationItems = new List<AllocationLineWrapper>();
        Decimal calcSubtotal = 0;
        Integer idx = 1;
        for (SObject raw : rawItems) {
          AllocationLineWrapper wrap = new AllocationLineWrapper(raw, idx++);
          this.allocationItems.add(wrap);
          calcSubtotal += wrap.total;
        }

        this.allocationItemPages = new List<AllocationItemPage>();
        if (this.allocationItems != null && !this.allocationItems.isEmpty()) {
          List<AllocationLineWrapper> currentPageItems = new List<AllocationLineWrapper>();
          List<List<AllocationLineWrapper>> allBatches = new List<List<AllocationLineWrapper>>();
          for (AllocationLineWrapper wrap : this.allocationItems) {
            if (currentPageItems.size() == 18) {
              allBatches.add(currentPageItems);
              currentPageItems = new List<AllocationLineWrapper>();
            }
            currentPageItems.add(wrap);
          }
          if (!currentPageItems.isEmpty()) {
            allBatches.add(currentPageItems);
          }
          Integer totalP = allBatches.size();
          Integer runningIdx = 1;
          for (Integer i = 0; i < totalP; i++) {
            List<AllocationLineWrapper> batch = allBatches[i];
            this.allocationItemPages.add(
              new AllocationItemPage(batch, i + 1, (i == 0), (i == totalP - 1), runningIdx)
            );
            runningIdx += batch.size();
          }
        }

        // Address resolution
        resolveCustomerInfo(this.allocationRec);

        // Totals resolution
        this.subtotal = calcSubtotal;
        this.discountAmount = 0;
        this.taxAmount = 0;
        this.grandTotal = calcSubtotal;
      } catch (Exception e) {
        this.allocationRec = null;
        this.allocationItems = new List<AllocationLineWrapper>();
        this.allocationItemPages = new List<AllocationItemPage>();
      }
    } else {
      this.allocationRec = null;
      this.allocationItems = new List<AllocationLineWrapper>();
      this.allocationItemPages = new List<AllocationItemPage>();
    }
  }

  private void resolveCustomerInfo(Order_Allocation__c alloc) {
    this.customerName = 'Customer';
    this.customerEmail = '';
    this.customerMobile = '';
    this.customerStreet = '';
    this.customerCity = '';
    this.customerState = '';
    this.customerPostalCode = '';
    this.customerCountry = '';

    if (alloc == null) {
      return;
    }

    try {
      // Check if Order__r is populated
      if (alloc.getSObject('Order__r') != null) {
        Order ord = (Order) alloc.getSObject('Order__r');
        if (ord.Account != null) {
          this.customerName = ord.Account.Name;
          this.customerMobile = ord.Account.Phone;
          this.customerStreet = String.isNotBlank(ord.Shipping_Street__c) ? ord.Shipping_Street__c : ord.Account.ShippingStreet;
          this.customerCity = String.isNotBlank(ord.Shipping_City__c) ? ord.Shipping_City__c : ord.Account.ShippingCity;
          this.customerState = String.isNotBlank(ord.Shipping_State__c) ? ord.Shipping_State__c : ord.Account.ShippingState;
          this.customerPostalCode = String.isNotBlank(ord.Shipping_Post_Code__c) ? ord.Shipping_Post_Code__c : ord.Account.ShippingPostalCode;
          this.customerCountry = String.isNotBlank(ord.Shipping_Country__c) ? ord.Shipping_Country__c : ord.Account.ShippingCountry;
        }
        if (ord.BillToContact != null) {
          if (String.isNotBlank(ord.BillToContact.Email)) {
            this.customerEmail = ord.BillToContact.Email;
          }
          if (String.isNotBlank(ord.BillToContact.MobilePhone)) {
            this.customerMobile = ord.BillToContact.MobilePhone;
          }
        }
      }
    } catch (Exception ex) {
      // Ignore field resolution failures
    }
  }

  // ── Private query helpers ────────────────────────────────────────────────

  private static Order_Allocation__c queryAllocation(Id allocId) {
    if (forceException) {
      throw new CalloutException('Forced exception for testing');
    }
    List<String> selectFields = new List<String>{ 'Id', 'Name', 'CreatedDate' };
    
    // Dynamically discover existing fields on Order_Allocation__c
    Map<String, SObjectField> fieldMap = Schema.SObjectType.Order_Allocation__c.fields.getMap();
    for (String fName : new List<String>{
      'Status__c', 'Order__c', 'Allocation_Date__c', 'Target_Location__c', 'Source_Location__c',
      'Customer_Name__c', 'Total_Amount__c', 'Subtotal__c', 'Discount_Amount__c', 'Tax_Amount__c'
    }) {
      if (fieldMap.containsKey(fName.toLowerCase())) {
        selectFields.add(fName);
      }
    }

    // Add related order fields if Order__c exists
    if (fieldMap.containsKey('order__c')) {
      selectFields.add('Order__r.OrderNumber');
      selectFields.add('Order__r.EffectiveDate');
      selectFields.add('Order__r.AccountId');
      selectFields.add('Order__r.Account.Name');
      selectFields.add('Order__r.Account.Phone');
      selectFields.add('Order__r.Account.ShippingStreet');
      selectFields.add('Order__r.Account.ShippingCity');
      selectFields.add('Order__r.Account.ShippingState');
      selectFields.add('Order__r.Account.ShippingPostalCode');
      selectFields.add('Order__r.Account.ShippingCountry');
      selectFields.add('Order__r.Shipping_Street__c');
      selectFields.add('Order__r.Shipping_City__c');
      selectFields.add('Order__r.Shipping_State__c');
      selectFields.add('Order__r.Shipping_Post_Code__c');
      selectFields.add('Order__r.Shipping_Country__c');
      selectFields.add('Order__r.BillToContact.Email');
      selectFields.add('Order__r.BillToContact.MobilePhone');
    }

    String query = 'SELECT ' + String.join(selectFields, ', ') + ' FROM Order_Allocation__c WHERE Id = :allocId LIMIT 1';
    return (Order_Allocation__c) Database.query(query);
  }

  private static List<SObject> queryAllocationItems(Id allocId) {
    if (forceException) {
      throw new CalloutException('Forced exception for testing');
    }
    
    // Check possible line item child objects
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    String childObj = null;
    String parentLookup = 'Order_Allocation__c';

    for (String possibleChild : new List<String>{
      'Order_Allocation_Line_Item__c', 'Order_Allocation_Item__c', 'Allocated_Order_Item__c', 'Order_Allocation_Product__c'
    }) {
      if (globalDescribe.containsKey(possibleChild.toLowerCase())) {
        childObj = possibleChild;
        break;
      }
    }

    if (childObj != null) {
      Map<String, SObjectField> fields = globalDescribe.get(childObj.toLowerCase()).getDescribe().fields.getMap();
      List<String> fList = new List<String>{ 'Id', 'Name' };
      for (String f : fields.keySet()) {
        fList.add(f);
      }
      String query = 'SELECT ' + String.join(fList, ', ') + ' FROM ' + childObj + ' WHERE ' + parentLookup + ' = :allocId';
      try {
        return Database.query(query);
      } catch (Exception ex) {}
    }

    return new List<SObject>();
  }

  // ── Controller Methods for Aura Component & LWC Callouts ─────────────────

  @AuraEnabled
  public static LWCServerCalloutWrapper getAllocationDetails(Id allocId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      wrapper.result = queryAllocation(allocId);
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper getEmailDefaults(Id allocId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      Order_Allocation__c alloc = queryAllocation(allocId);
      String custName = 'Customer';
      String toEmail = '';

      try {
        if (alloc.getSObject('Order__r') != null) {
          Order ord = (Order) alloc.getSObject('Order__r');
          if (ord.Account != null) {
            custName = ord.Account.Name;
          }
          if (ord.BillToContact != null && String.isNotBlank(ord.BillToContact.Email)) {
            toEmail = ord.BillToContact.Email;
          }
        }
      } catch (Exception ex) {}

      List<Map<String, String>> fromOptions = new List<Map<String, String>>();
      fromOptions.add(new Map<String, String>{
        'label' => UserInfo.getName() + ' <' + UserInfo.getUserEmail() + '>',
        'value' => UserInfo.getUserEmail()
      });

      String subject = 'Order Allocation ' + alloc.Name + ' - ' + custName;
      String body = 'Dear ' + custName + ',\n\nPlease find attached your Order Allocation document.';

      Map<String, Object> defaults = new Map<String, Object>();
      defaults.put('toAddress', toEmail);
      defaults.put('subject', subject);
      defaults.put('body', body);
      defaults.put('fromOptions', fromOptions);
      defaults.put('defaultFrom', UserInfo.getUserEmail());

      wrapper.result = defaults;
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper savePDF(Id allocId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      PageReference pdfPage = new PageReference('/apex/OrderAllocationPDF');
      pdfPage.getParameters().put('id', allocId);

      Blob pdfBlob = Test.isRunningTest()
        ? Blob.valueOf('Test PDF Content')
        : pdfPage.getContentAsPDF();

      Order_Allocation__c alloc = [SELECT Name FROM Order_Allocation__c WHERE Id = :allocId LIMIT 1];
      String prefix = 'OrderAllocation_' + alloc.Name + '_v';
      Integer nextVer = 1;

      for (ContentDocumentLink link : [
        SELECT ContentDocument.Title
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :allocId
      ]) {
        String title = link.ContentDocument.Title;
        if (title != null && title.toLowerCase().startsWith(prefix.toLowerCase())) {
          try {
            String verStr = title.substring(title.lastIndexOf('_v') + 2);
            Integer vNum = Integer.valueOf(verStr);
            if (vNum >= nextVer) {
              nextVer = vNum + 1;
            }
          } catch (Exception ex) {
            // Ignore parsing errors
          }
        }
      }

      String versionTitle = prefix + nextVer;
      ContentVersion cv = new ContentVersion();
      cv.Title = versionTitle;
      cv.PathOnClient = versionTitle + '.pdf';
      cv.VersionData = pdfBlob;
      cv.IsMajorVersion = true;
      insert cv;

      ContentVersion insertedCv = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
        LIMIT 1
      ];

      ContentDocumentLink cdl = new ContentDocumentLink();
      cdl.ContentDocumentId = insertedCv.ContentDocumentId;
      cdl.LinkedEntityId = allocId;
      cdl.ShareType = 'V';
      cdl.Visibility = 'AllUsers';
      insert cdl;

      wrapper.result = insertedCv.ContentDocumentId;
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static EmailDetails getLatestDocumentForSendingAnEmail(String allocId) {
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      Order_Allocation__c alloc = queryAllocation(allocId);
      List<ContentDocumentLink> contentDocumentLinks = [
        SELECT Id, ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :allocId ORDER BY SystemModstamp DESC
      ];
      EmailDetails em = new EmailDetails();
      if (alloc != null) {
        String custName = 'Customer';
        String toEmail = '';

        try {
          if (alloc.getSObject('Order__r') != null) {
            Order ord = (Order) alloc.getSObject('Order__r');
            if (ord.Account != null) {
              custName = ord.Account.Name;
            }
            if (ord.BillToContact != null && String.isNotBlank(ord.BillToContact.Email)) {
              toEmail = ord.BillToContact.Email;
              em.contactId = ord.BillToContact.Id;
            }
          }
        } catch (Exception ex) {}

        em.contactName = custName;
        em.contactEmail = toEmail;
        em.subject = 'Order Allocation ' + alloc.Name + ' Attached for Your Reference';
        em.body = '<p>Dear ' + custName + ',</p>' +
                  '<p>Please find attached the Order Allocation document detailing allocated items.</p>' +
                  '<p>Best regards,<br/>Operations Team</p>';
      }
      if (!contentDocumentLinks.isEmpty()) {
        em.contentDocumentId = contentDocumentLinks[0].ContentDocumentId;
      }
      return em;
    } catch (Exception e) {
      return null;
    }
  }

  public class EmailDetails {
    @AuraEnabled public String contactId;
    @AuraEnabled public String contactName;
    @AuraEnabled public String contactEmail;
    @AuraEnabled public String contentDocumentId;
    @AuraEnabled public String subject;
    @AuraEnabled public String body;
  }
}