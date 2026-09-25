public with sharing class OrderPDFController {
  public static Boolean forceException = false;

  public class OrderItemPage {
    public List<OrderItem> items { get; set; }
    public Integer pageNumber { get; set; }
    public Boolean isFirstPage { get; set; }
    public Boolean isLastPage { get; set; }
    public Integer startIndex { get; set; }

    public OrderItemPage(List<OrderItem> items, Integer pageNumber, Boolean isFirstPage, Boolean isLastPage, Integer startIndex) {
      this.items = items;
      this.pageNumber = pageNumber;
      this.isFirstPage = isFirstPage;
      this.isLastPage = isLastPage;
      this.startIndex = startIndex;
    }
  }

  public Order orderRec { get; set; }
  public List<OrderItem> orderItems { get; set; }
  public List<OrderItemPage> orderItemPages { get; set; }
  public String customerMobile { get; set; }
  public String customerEmail { get; set; }

  // Standard Visualforce Controller Constructor
  public OrderPDFController() {
    String orderIdStr = ApexPages.currentPage().getParameters().get('id');
    if (String.isNotBlank(orderIdStr)) {
      try {
        Id orderId = (Id) orderIdStr;
        this.orderRec = queryOrder(orderId);
        this.orderItems = queryOrderItems(orderId);
        this.orderItemPages = new List<OrderItemPage>();
        if (this.orderItems != null && !this.orderItems.isEmpty()) {
          List<OrderItem> currentPageItems = new List<OrderItem>();
          List<List<OrderItem>> allBatches = new List<List<OrderItem>>();
          for (OrderItem item : this.orderItems) {
            if (currentPageItems.size() == 18) {
              allBatches.add(currentPageItems);
              currentPageItems = new List<OrderItem>();
            }
            currentPageItems.add(item);
          }
          if (!currentPageItems.isEmpty()) {
            allBatches.add(currentPageItems);
          }
          Integer totalP = allBatches.size();
          Integer runningIdx = 1;
          for (Integer i = 0; i < totalP; i++) {
            List<OrderItem> batch = allBatches[i];
            this.orderItemPages.add(new OrderItemPage(batch, i + 1, (i == 0), (i == totalP - 1), runningIdx));
            runningIdx += batch.size();
          }
        }
        this.customerMobile = resolveCustomerMobile(this.orderRec);
        this.customerEmail = resolveCustomerEmail(this.orderRec);
      } catch (Exception e) {
        this.orderRec = null;
        this.orderItems = new List<OrderItem>();
        this.orderItemPages = new List<OrderItemPage>();
        this.customerMobile = '';
        this.customerEmail = '';
      }
    } else {
      this.orderRec = null;
      this.orderItems = new List<OrderItem>();
      this.orderItemPages = new List<OrderItemPage>();
      this.customerMobile = '';
      this.customerEmail = '';
    }
  }

  // ── Private query helpers ────────────────────────────────────────────────

  private static Order queryOrder(Id orderId) {
    if (forceException) {
      throw new CalloutException('Forced exception for testing');
    }
    return [
      SELECT
        Id,
        OrderNumber,
        EffectiveDate,
        Status,
        AccountId,
        Account.Name,
        Account.Phone,
        Account.ShippingStreet,
        Account.ShippingCity,
        Account.ShippingState,
        Account.ShippingPostalCode,
        Account.ShippingCountry,
        Shipping_Street__c,
        Shipping_City__c,
        Shipping_State__c,
        Shipping_Post_Code__c,
        Shipping_Country__c,
        Billing_Street__c,
        Billing_City__c,
        Billing_State__c,
        Billing_Post_Code__c,
        Billing_Country__c,
        BillToContactId,
        BillToContact.Name,
        BillToContact.FirstName,
        BillToContact.Email,
        BillToContact.MobilePhone,
        BillToContact.Phone,
        ContractId,
        Contract.CustomerSignedId,
        Contract.CustomerSigned.Name,
        Contract.CustomerSigned.FirstName,
        Contract.CustomerSigned.Email,
        CustomerAuthorizedById,
        CustomerAuthorizedBy.Name,
        CustomerAuthorizedBy.FirstName,
        CustomerAuthorizedBy.Email,
        Subtotal__c,
        Discount_Amount__c,
        Tax_Amount__c,
        Total_Transfer_Cost__c,
        Total_Additional_Cost__c,
        Total_Loading_and_Unloading_Charges__c,
        Grand_Total__c,
        TotalAmount
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
  }

  private static List<OrderItem> queryOrderItems(Id orderId) {
    if (forceException) {
      throw new CalloutException('Forced exception for testing');
    }
    return [
      SELECT
        Id,
        Quantity,
        UnitPrice,
        Discount_Percent__c,
        Tax__c,
        Additional_Cost__c,
        Transfer_Cost__c,
        Loading_and_Unloading_Charges__c,
        Order_Product_Total__c,
        Product2Id,
        Product2.Name
      FROM OrderItem
      WHERE OrderId = :orderId
      ORDER BY Product2.Name ASC
    ];
  }

  public static String resolveCustomerEmail(Order ord) {
    if (ord == null) {
      return '';
    }
    // 1. BillToContact Email
    if (ord.BillToContact != null && String.isNotBlank(ord.BillToContact.Email)) {
      return ord.BillToContact.Email;
    }
    // 2. Account Contacts Email (Query contacts related to Order Account)
    if (ord.AccountId != null) {
      List<Contact> accountContacts = [
        SELECT Email
        FROM Contact
        WHERE AccountId = :ord.AccountId AND Email != NULL
        ORDER BY CreatedDate ASC
        LIMIT 1
      ];
      if (!accountContacts.isEmpty() && String.isNotBlank(accountContacts[0].Email)) {
        return accountContacts[0].Email;
      }
    }
    // 3. Contract CustomerSigned Email
    if (ord.Contract != null && ord.Contract.CustomerSigned != null && String.isNotBlank(ord.Contract.CustomerSigned.Email)) {
      return ord.Contract.CustomerSigned.Email;
    }
    // 4. CustomerAuthorizedBy Email
    if (ord.CustomerAuthorizedBy != null && String.isNotBlank(ord.CustomerAuthorizedBy.Email)) {
      return ord.CustomerAuthorizedBy.Email;
    }
    return '';
  }

  public static String resolveCustomerMobile(Order ord) {
    if (ord == null) {
      return '';
    }
    if (ord.BillToContact != null && String.isNotBlank(ord.BillToContact.MobilePhone)) {
      return ord.BillToContact.MobilePhone;
    }
    if (ord.BillToContact != null && String.isNotBlank(ord.BillToContact.Phone)) {
      return ord.BillToContact.Phone;
    }
    if (ord.Account != null && String.isNotBlank(ord.Account.Phone)) {
      return ord.Account.Phone;
    }
    return '';
  }

  // ── Controller Methods for Aura Component & LWC / Apex Callouts ───────────

  @AuraEnabled
  public static LWCServerCalloutWrapper getOrderDetails(Id orderId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      wrapper.result = queryOrder(orderId);
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper getOrderItems(Id orderId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      wrapper.resultList = queryOrderItems(orderId);
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper getEmailDefaults(Id orderId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      Order ord = queryOrder(orderId);
      String customerName = ord.BillToContact != null && String.isNotBlank(ord.BillToContact.Name)
        ? ord.BillToContact.Name
        : (ord.Account != null ? ord.Account.Name : 'Customer');
      String toEmail = resolveCustomerEmail(ord);

      List<Map<String, String>> fromOptions = new List<Map<String, String>>();
      fromOptions.add(new Map<String, String>{
        'label' => UserInfo.getName() + ' <' + UserInfo.getUserEmail() + '>',
        'value' => UserInfo.getUserEmail()
      });

      String subject = 'Sales Order ' + ord.OrderNumber + ' - ' + customerName;
      String body = 'Dear ' + customerName + ',\n\nPlease find attached your Sales Order document.';

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
  public static LWCServerCalloutWrapper savePDF(Id orderId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      PageReference pdfPage = new PageReference('/apex/OrderPDF');
      pdfPage.getParameters().put('id', orderId);

      Blob pdfBlob = Test.isRunningTest()
        ? Blob.valueOf('Test PDF Content')
        : pdfPage.getContentAsPDF();

      Order ord = [SELECT OrderNumber FROM Order WHERE Id = :orderId LIMIT 1];
      String prefix = 'Order_' + ord.OrderNumber + '_v';
      Integer nextVer = 1;

      for (ContentDocumentLink link : [
        SELECT ContentDocument.Title
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :orderId
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
      cdl.LinkedEntityId = orderId;
      cdl.ShareType = 'V';
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
  public static LWCServerCalloutWrapper saveAndSendEmail(
    Id orderId,
    String toEmail,
    String subject,
    String body
  ) {
    return saveAndSendEmailFull(orderId, toEmail, null, null, subject, body, UserInfo.getUserEmail(), true, null);
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper saveAndSendEmailFull(
    Id orderId,
    String toEmail,
    String ccEmail,
    String bccEmail,
    String subject,
    String body,
    String fromEmail,
    Boolean attachPdf,
    String customAttachmentsJson
  ) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }

      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(new List<String>{ toEmail });
      if (String.isNotBlank(ccEmail)) {
        mail.setCcAddresses(ccEmail.split(','));
      }
      if (String.isNotBlank(bccEmail)) {
        mail.setBccAddresses(bccEmail.split(','));
      }
      mail.setSubject(subject);
      mail.setPlainTextBody(body);
      mail.setHtmlBody(body);

      List<Messaging.EmailFileAttachment> attachments = new List<Messaging.EmailFileAttachment>();

      if (attachPdf == true) {
        PageReference pdfPage = new PageReference('/apex/OrderPDF');
        pdfPage.getParameters().put('id', orderId);
        Blob pdfBlob = Test.isRunningTest()
          ? Blob.valueOf('Test PDF Content')
          : pdfPage.getContentAsPDF();

        Messaging.EmailFileAttachment efa = new Messaging.EmailFileAttachment();
        efa.setFileName('SalesOrder.pdf');
        efa.setBody(pdfBlob);
        attachments.add(efa);
      }

      if (String.isNotBlank(customAttachmentsJson)) {
        List<Object> attList = (List<Object>) JSON.deserializeUntyped(customAttachmentsJson);
        for (Object item : attList) {
          Map<String, Object> attMap = (Map<String, Object>) item;
          String fName = (String) attMap.get('fileName');
          String b64 = (String) attMap.get('base64Data');
          if (String.isNotBlank(fName) && String.isNotBlank(b64)) {
            Messaging.EmailFileAttachment efaCustom = new Messaging.EmailFileAttachment();
            efaCustom.setFileName(fName);
            efaCustom.setBody(EncodingUtil.base64Decode(b64));
            attachments.add(efaCustom);
          }
        }
      }

      if (!attachments.isEmpty()) {
        mail.setFileAttachments(attachments);
      }

      if (!Test.isRunningTest()) {
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
      }

      EmailMessage em = new EmailMessage();
      em.RelatedToId = orderId;
      em.ToAddress = toEmail;
      em.FromAddress = String.isNotBlank(fromEmail) ? fromEmail : UserInfo.getUserEmail();
      em.Subject = subject;
      em.TextBody = body;
      em.HtmlBody = body;
      em.Status = '3';
      insert em;

      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static EmailDetails getLatestDocumentForSendingAnEmail(String orderId) {
    try {
      Order ord = queryOrder(orderId);
      List<ContentDocumentLink> contentDocumentLinks = [
        SELECT Id, ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :orderId ORDER BY SystemModstamp DESC
      ];
      EmailDetails em = new EmailDetails();
      if (ord != null) {
        Contact accContact = null;
        if (ord.AccountId != null) {
          List<Contact> cList = [
            SELECT Id, Name, FirstName, Email
            FROM Contact
            WHERE AccountId = :ord.AccountId AND Email != NULL
            ORDER BY CreatedDate ASC
            LIMIT 1
          ];
          if (!cList.isEmpty()) {
            accContact = cList[0];
          }
        }
        if (accContact == null && ord.Contract != null && ord.Contract.CustomerSigned != null) {
          accContact = ord.Contract.CustomerSigned;
        }
        if (accContact == null && ord.BillToContact != null) {
          accContact = ord.BillToContact;
        }

        String customerName = accContact != null && String.isNotBlank(accContact.FirstName)
          ? accContact.FirstName
          : (accContact != null && String.isNotBlank(accContact.Name) 
             ? accContact.Name 
             : (ord.Account != null ? ord.Account.Name : 'Customer'));

        em.contactId = accContact != null ? accContact.Id : null;
        em.contactName = customerName;
        em.contactEmail = resolveCustomerEmail(ord);
        em.subject = 'Sales Order Attached for Your Reference';
        em.body = '<p>Dear ' + customerName + ',</p>' +
                  '<p>Thank you for your order.</p>' +
                  '<p>Please find attached your Sales Order document detailing the products and services.</p>' +
                  '<p>If you have any questions or require assistance, please feel free to reach out to us.</p>' +
                  '<p>Best regards,<br/>Sales Team</p>';
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