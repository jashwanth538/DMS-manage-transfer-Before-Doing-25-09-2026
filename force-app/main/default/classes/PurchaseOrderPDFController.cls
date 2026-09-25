public with sharing class PurchaseOrderPDFController {
  @TestVisible
  private static Boolean forceException = false;

  public class POItemPage {
    public List<POLineWrapper> items { get; set; }
    public Integer pageNumber { get; set; }
    public Boolean isFirstPage { get; set; }
    public Boolean isLastPage { get; set; }
    public Integer startIndex { get; set; }

    public POItemPage(List<POLineWrapper> items, Integer pageNumber, Boolean isFirstPage, Boolean isLastPage, Integer startIndex) {
      this.items = items;
      this.pageNumber = pageNumber;
      this.isFirstPage = isFirstPage;
      this.isLastPage = isLastPage;
      this.startIndex = startIndex;
    }
  }

  public Purchase_Order__c poRec { get; set; }
  public List<POLineWrapper> poItems { get; set; }
  public List<POItemPage> poItemPages { get; set; }
  public String vendorEmail { get; set; }
  public String vendorMobile { get; set; }
  public String vendorStreet { get; set; }
  public String vendorCity { get; set; }
  public String vendorState { get; set; }
  public String vendorPostalCode { get; set; }
  public String vendorCountry { get; set; }
  public Decimal subtotal { get; set; }
  public Decimal taxAmount { get; set; }
  public Decimal discountAmount { get; set; }
  public Decimal grandTotal { get; set; }

  public class POLineWrapper {
    public Purchase_Order_Line_Item__c item { get; set; }
    public Integer index { get; set; }
    public Decimal total { get; set; }

    public POLineWrapper(Purchase_Order_Line_Item__c item, Integer index) {
      this.item = item;
      this.index = index;
      Decimal qty = item.Ordered_Qty__c != null ? item.Ordered_Qty__c : 0;
      Decimal price = item.Unit_Price__c != null ? item.Unit_Price__c : 0;
      this.total = qty * price;
    }
  }

  // Standard Visualforce Controller Constructor
  public PurchaseOrderPDFController() {
    String poIdStr = ApexPages.currentPage().getParameters().get('id');
    if (poIdStr != null) {
      Id poId = (Id) poIdStr;
      this.poRec = queryPurchaseOrder(poId);

      List<Purchase_Order_Line_Item__c> rawItems = queryPurchaseOrderItems(
        poId
      );
      this.poItems = new List<POLineWrapper>();

      // Calculate default subtotal first from items for fallback
      Decimal calculatedSubtotal = 0;
      Integer idx = 1;
      for (Purchase_Order_Line_Item__c raw : rawItems) {
        POLineWrapper wrap = new POLineWrapper(raw, idx++);
        this.poItems.add(wrap);
        calculatedSubtotal += wrap.total;
      }

      this.poItemPages = new List<POItemPage>();
      if (this.poItems != null && !this.poItems.isEmpty()) {
        List<POLineWrapper> currentPageItems = new List<POLineWrapper>();
        List<List<POLineWrapper>> allBatches = new List<List<POLineWrapper>>();
        for (POLineWrapper wrap : this.poItems) {
          if (currentPageItems.size() == 18) {
            allBatches.add(currentPageItems);
            currentPageItems = new List<POLineWrapper>();
          }
          currentPageItems.add(wrap);
        }
        if (!currentPageItems.isEmpty()) {
          allBatches.add(currentPageItems);
        }
        Integer totalP = allBatches.size();
        Integer runningIdx = 1;
        for (Integer i = 0; i < totalP; i++) {
          List<POLineWrapper> batch = allBatches[i];
          this.poItemPages.add(new POItemPage(batch, i + 1, (i == 0), (i == totalP - 1), runningIdx));
          runningIdx += batch.size();
        }
      }

      // Populate properties using custom fields from Purchase_Order__c if they are not null;
      // otherwise, fall back to calculated/default values.
      this.subtotal = (this.poRec != null && this.poRec.Sub_Total__c != null)
        ? this.poRec.Sub_Total__c
        : calculatedSubtotal;
      this.discountAmount = (this.poRec != null && this.poRec.Discount_Amount__c != null)
        ? this.poRec.Discount_Amount__c
        : 0;
      this.taxAmount = (this.poRec != null && this.poRec.Tax_Amount__c != null)
        ? this.poRec.Tax_Amount__c
        : 0;
      this.grandTotal = (this.poRec != null && this.poRec.Total_Amount__c != null)
        ? this.poRec.Total_Amount__c
        : (this.subtotal - this.discountAmount + this.taxAmount);

      this.vendorEmail = resolveVendorEmail(this.poRec);
      this.vendorMobile = resolveVendorMobile(this.poRec);
      if (this.poRec != null && this.poRec.Supplying_Account__r != null) {
        this.vendorStreet = this.poRec.Supplying_Account__r.BillingStreet;
        this.vendorCity = this.poRec.Supplying_Account__r.BillingCity;
        this.vendorState = this.poRec.Supplying_Account__r.BillingState;
        this.vendorPostalCode = this.poRec.Supplying_Account__r.BillingPostalCode;
        this.vendorCountry = this.poRec.Supplying_Account__r.BillingCountry;
      }

      // Deduplicate address fields if street contains city, state, postal code, or country
      if (this.vendorStreet != null) {
        String streetLower = this.vendorStreet.toLowerCase();
        if (
          this.vendorStreet.contains('\n') || this.vendorStreet.contains('\r')
        ) {
          this.vendorCity = '';
          this.vendorState = '';
          this.vendorPostalCode = '';
          this.vendorCountry = '';
        } else {
          if (this.vendorCity != null && this.vendorCity != '') {
            String cityLower = this.vendorCity.toLowerCase();
            if (streetLower.contains(cityLower)) {
              this.vendorCity = '';
            }
          }
          if (this.vendorState != null && this.vendorState != '') {
            String stateLower = this.vendorState.toLowerCase();
            if (streetLower.contains(stateLower)) {
              this.vendorState = '';
            }
          }
          if (this.vendorPostalCode != null && this.vendorPostalCode != '') {
            String zipLower = this.vendorPostalCode.toLowerCase();
            if (streetLower.contains(zipLower)) {
              this.vendorPostalCode = '';
            }
          }
          if (this.vendorCountry != null && this.vendorCountry != '') {
            String countryLower = this.vendorCountry.toLowerCase();
            if (streetLower.contains(countryLower)) {
              this.vendorCountry = '';
            }
          }
        }
      }
    }
  }

  // ── Private query helpers ────────────────────────────────────────────────

  private static Purchase_Order__c queryPurchaseOrder(Id poId) {
    return [
      SELECT
        Id,
        Name,
        PO_Date__c,
        Expected_Date__c,
        Status__c,
        Customer_Name__c,
        Supplying_Account__c,
        Supplying_Account__r.Name,
        Supplying_Account__r.Phone,
        Supplying_Account__r.BillingStreet,
        Supplying_Account__r.BillingCity,
        Supplying_Account__r.BillingState,
        Supplying_Account__r.BillingPostalCode,
        Supplying_Account__r.BillingCountry,
        Requesting_Account__c,
        Requesting_Account__r.Name,
        Target_Location__c,
        Target_Location__r.Name,
        Source_Location__c,
        Source_Location__r.Name,
        Sub_Total__c,
        Discount_Amount__c,
        Tax_Amount__c,
        Total_Amount__c
      FROM Purchase_Order__c
      WHERE Id = :poId
      LIMIT 1
    ];
  }

  private static List<Purchase_Order_Line_Item__c> queryPurchaseOrderItems(
    Id poId
  ) {
    return [
      SELECT
        Id,
        Item__c,
        Item__r.Name,
        Ordered_Qty__c,
        Received_Qty__c,
        Previously_Received_Quantity__c,
        Unit_Price__c,
        POLI_Total__c,
        Tax__c,
        Discount__c
      FROM Purchase_Order_Line_Item__c
      WHERE Purchase_Order__c = :poId
      ORDER BY Item__r.Name ASC
    ];
  }

  private static String resolveVendorEmail(Purchase_Order__c po) {
    if (po == null) {
      return '';
    }
    if (po.Supplying_Account__c != null) {
      List<Contact> contacts = [
        SELECT Email
        FROM Contact
        WHERE AccountId = :po.Supplying_Account__c AND Email != NULL
        ORDER BY CreatedDate ASC
        LIMIT 1
      ];
      if (!contacts.isEmpty() && String.isNotBlank(contacts[0].Email)) {
        return contacts[0].Email;
      }
    }
    return '';
  }

  private static String resolveVendorMobile(Purchase_Order__c po) {
    if (po == null) {
      return '';
    }
    if (po.Supplying_Account__c != null) {
      List<Contact> contacts = [
        SELECT MobilePhone, Phone
        FROM Contact
        WHERE
          AccountId = :po.Supplying_Account__c
          AND (MobilePhone != NULL
          OR Phone != NULL)
        ORDER BY CreatedDate ASC
        LIMIT 1
      ];
      if (!contacts.isEmpty()) {
        return contacts[0].MobilePhone != null
          ? contacts[0].MobilePhone
          : contacts[0].Phone;
      }
      if (po.Supplying_Account__r != null && String.isNotBlank(po.Supplying_Account__r.Phone)) {
        return po.Supplying_Account__r.Phone;
      }
    }
    return '';
  }

  // ── AuraEnabled methods (all return LWCServerCalloutWrapper) ─────────────

  @AuraEnabled(cacheable=true)
  public static LWCServerCalloutWrapper getPurchaseOrderDetails(Id poId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      wrapper.result = queryPurchaseOrder(poId);
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled(cacheable=true)
  public static LWCServerCalloutWrapper getPurchaseOrderItems(Id poId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      wrapper.resultList = queryPurchaseOrderItems(poId);
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper getEmailDefaults(Id poId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      Purchase_Order__c po = queryPurchaseOrder(poId);
      String vendorName = (po != null && po.Supplying_Account__r != null && String.isNotBlank(po.Supplying_Account__r.Name))
        ? po.Supplying_Account__r.Name
        : 'Vendor';
      String toEmail = resolveVendorEmail(po);

      List<Map<String, String>> fromOptions = new List<Map<String, String>>();
      fromOptions.add(new Map<String, String>{
        'label' => UserInfo.getName() + ' <' + UserInfo.getUserEmail() + '>',
        'value' => UserInfo.getUserEmail()
      });

      for (OrgWideEmailAddress owea : [SELECT Id, Address, DisplayName FROM OrgWideEmailAddress LIMIT 10]) {
        if (owea.Address != UserInfo.getUserEmail()) {
          fromOptions.add(new Map<String, String>{
            'label' => owea.DisplayName + ' <' + owea.Address + '>',
            'value' => owea.Address
          });
        }
      }

      String dateStr = System.now().format('dd/MM/yyyy, h:mm a');
      if (po != null && po.PO_Date__c != null) {
        dateStr = Datetime.newInstance(po.PO_Date__c.year(), po.PO_Date__c.month(), po.PO_Date__c.day()).format('dd/MM/yyyy');
      }

      String logoUrl = '/resource/AM_Industries_Logo';

      String bodyHtml = '<div style="max-width: 600px; margin: 0 auto; background-color: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; overflow: hidden; font-family: \'Segoe UI\', Arial, sans-serif; color: #334155; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);">' +
        '<table style="width: 100%; border-collapse: collapse; border-bottom: 1px solid #f1f5f9; background-color: #ffffff;">' +
        '<tr>' +
        '<td style="padding: 20px 24px; text-align: left; vertical-align: middle; width: 40%;">' +
        '<img src="' + logoUrl + '" alt="AM Industries Logo" style="max-height: 50px; width: auto; height: auto; border: 0; display: inline-block;" />' +
        '</td>' +
        '<td style="padding: 20px 24px; text-align: right; vertical-align: middle; width: 60%;">' +
        '<span style="font-size: 22px; font-weight: 800; color: #2d259c; letter-spacing: 0.5px; text-transform: uppercase; font-family: Arial, sans-serif;">AM INDUSTRIES</span>' +
        '</td>' +
        '</tr>' +
        '</table>' +
        '<div style="padding: 32px;">' +
        '<h2 style="margin: 0 0 20px 0; font-size: 22px; font-weight: 700; color: #2d259c; line-height: 1.3;">Purchase Order Attached for Your Reference!</h2>' +
        '<p style="margin: 0 0 16px 0; font-size: 15px; color: #334155;">Dear ' + vendorName + ',</p>' +
        '<p style="margin: 0 0 24px 0; font-size: 15px; line-height: 1.6; color: #475569;">Please find attached the Purchase Order detailing the products we require. Kindly review the Purchase Order and confirm your acceptance.</p>' +
        '<div style="background-color: #f8f7ff; border-left: 4px solid #ff2b6d; border-radius: 0 8px 8px 0; padding: 20px 24px; margin-bottom: 24px;">' +
        '<p style="margin: 0 0 8px 0; font-size: 14px; color: #1e1b4b;"><strong style="color: #1e1b4b;">Reference ID:</strong> ' + (po != null ? po.Name : '') + '</p>' +
        '<p style="margin: 0; font-size: 14px; color: #1e1b4b;"><strong style="color: #1e1b4b;">PO Date:</strong> ' + dateStr + '</p>' +
        '</div>' +
        '<p style="margin: 0 0 28px 0; font-size: 15px; line-height: 1.6; color: #475569;">If you have any questions or need clarification, please feel free to reach out to us by replying to this email.</p>' +
        '<div style="text-align: center; margin: 32px 0 28px 0;">' +
        '<a href="https://www.arrayminds.com" target="_blank" style="background-color: #ff2b6d; color: #ffffff; padding: 14px 36px; border-radius: 30px; font-weight: 700; font-size: 15px; text-decoration: none; display: inline-block; box-shadow: 0 4px 12px rgba(255, 43, 109, 0.35);">Visit Our Website</a>' +
        '</div>' +
        '<div style="border-top: 1px solid #f1f5f9; margin-top: 32px; padding-top: 24px; text-align: center;">' +
        '<p style="font-size: 11px; font-weight: 700; color: #94a3b8; letter-spacing: 1.5px; text-transform: uppercase; margin: 0 0 12px 0;">STAY CONNECTED</p>' +
        '<p style="font-size: 14px; font-weight: 600; color: #2d259c; margin: 0;">' +
        '<a href="https://www.facebook.com/people/Array-Minds/pfbid02VdbZyKacMccE7P729XkQdCdM3Zq4GwLNV7raikYvmMaMhzNBFJqxsWSKzztcduF3l/" target="_blank" style="color: #2d259c; text-decoration: none;">Facebook</a>&nbsp;&nbsp;<span style="color: #cbd5e1;">|</span>&nbsp;&nbsp;' +
        '<a href="https://x.com/amindustries" target="_blank" style="color: #2d259c; text-decoration: none;">X</a>&nbsp;&nbsp;<span style="color: #cbd5e1;">|</span>&nbsp;&nbsp;' +
        '<a href="https://www.linkedin.com/company/am-industries/about/" target="_blank" style="color: #2d259c; text-decoration: none;">LinkedIn</a>&nbsp;&nbsp;<span style="color: #cbd5e1;">|</span>&nbsp;&nbsp;' +
        '<a href="https://www.youtube.com/@AMIndustries-he8hm" target="_blank" style="color: #2d259c; text-decoration: none;">YouTube</a>' +
        '</p>' +
        '</div>' +
        '</div>' +
        '<div style="background-color: #1e1b4b; height: 12px; width: 100%;"></div>' +
        '</div>';

      Map<String, Object> defaults = new Map<String, Object>();
      defaults.put('orderNumber', po != null ? po.Name : '');
      defaults.put('toAddress', toEmail);
      defaults.put('subject', 'Purchase Order Attached for Your Reference');
      defaults.put('body', bodyHtml);
      defaults.put('bodyHtml', bodyHtml);
      defaults.put('fromOptions', fromOptions);
      defaults.put('defaultFrom', fromOptions.isEmpty() ? UserInfo.getUserEmail() : fromOptions[0].get('value'));
      defaults.put('defaultFromDisplay', fromOptions.isEmpty() ? UserInfo.getName() + ' <' + UserInfo.getUserEmail() + '>' : fromOptions[0].get('label'));

      wrapper.result = defaults;
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper savePDF(Id poId) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      PageReference pdfPage = new PageReference('/apex/PurchaseOrderPDF');
      pdfPage.getParameters().put('id', poId);

      Blob pdfBlob = Test.isRunningTest()
        ? Blob.valueOf('Test PDF Content')
        : pdfPage.getContentAsPDF();

      Purchase_Order__c po = [
        SELECT Name
        FROM Purchase_Order__c
        WHERE Id = :poId
        LIMIT 1
      ];
      String prefix = 'PurchaseOrder_' + po.Name + '_v';
      Integer nextVer = 1;

      for (ContentDocumentLink link : [
        SELECT ContentDocument.Title
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :poId
      ]) {
        String title = link.ContentDocument.Title;
        if (
          title != null && title.toLowerCase().startsWith(prefix.toLowerCase())
        ) {
          try {
            String verStr = title.substring(prefix.length());
            if (verStr.contains('.')) {
              verStr = verStr.substring(0, verStr.indexOf('.'));
            }
            Integer ver = Integer.valueOf(verStr);
            if (ver >= nextVer)
              nextVer = ver + 1;
          } catch (Exception ex) {
            /* skip */
          }
        }
      }

      String fileTitle = 'PurchaseOrder_' + po.Name + '_v' + nextVer;

      ContentVersion cv = new ContentVersion();
      cv.Title = fileTitle;
      cv.PathOnClient = fileTitle + '.pdf';
      cv.VersionData = pdfBlob;
      cv.IsMajorVersion = true;
      insert cv;

      ContentVersion inserted = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
        LIMIT 1
      ];

      ContentDocumentLink cdl = new ContentDocumentLink();
      cdl.ContentDocumentId = inserted.ContentDocumentId;
      cdl.LinkedEntityId = poId;
      cdl.ShareType = 'V';
      cdl.Visibility = 'AllUsers';
      insert cdl;

      wrapper.result = inserted.ContentDocumentId;
      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper saveAndSendEmail(
    Id poId,
    String toAddress,
    String subject,
    String body
  ) {
    return saveAndSendEmailFull(poId, toAddress, null, null, subject, body, null, true, null);
  }

  @AuraEnabled
  public static LWCServerCalloutWrapper saveAndSendEmailFull(
    Id poId,
    String toAddress,
    String ccAddress,
    String bccAddress,
    String subject,
    String body,
    String fromAddress,
    Boolean includePdfAttachment,
    String customAttachmentsJson
  ) {
    LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      List<Messaging.EmailFileAttachment> attachments = new List<Messaging.EmailFileAttachment>();
      Id docId = null;

      Boolean shouldIncludePdf = (includePdfAttachment == null || includePdfAttachment == true);
      if (shouldIncludePdf) {
        LWCServerCalloutWrapper pdfResult = savePDF(poId);
        if (!pdfResult.isSuccess) {
          return pdfResult;
        }
        docId = (Id) pdfResult.result;

        ContentVersion cv = [
          SELECT Id, VersionData, Title, FileExtension
          FROM ContentVersion
          WHERE ContentDocumentId = :docId
          LIMIT 1
        ];

        Messaging.EmailFileAttachment attachment = new Messaging.EmailFileAttachment();
        attachment.setFileName(cv.Title + '.' + cv.FileExtension);
        attachment.setBody(cv.VersionData);
        attachment.setContentType('application/pdf');
        attachments.add(attachment);
      }

      // Add custom attachments if present
      if (String.isNotBlank(customAttachmentsJson)) {
        List<Object> rawList = (List<Object>) JSON.deserializeUntyped(customAttachmentsJson);
        for (Object itemObj : rawList) {
          Map<String, Object> item = (Map<String, Object>) itemObj;
          String fileName = (String) item.get('fileName');
          String base64Data = (String) item.get('base64Data');
          String contentType = (String) item.get('contentType');
          if (String.isNotBlank(fileName) && String.isNotBlank(base64Data)) {
            Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
            att.setFileName(fileName);
            att.setBody(EncodingUtil.base64Decode(base64Data));
            if (String.isNotBlank(contentType)) {
              att.setContentType(contentType);
            }
            attachments.add(att);
          }
        }
      }

      // Send email via Messaging service
      Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();

      // TO addresses parsing
      List<String> toList = new List<String>();
      if (String.isNotBlank(toAddress)) {
        for (String addr : toAddress.split('[,;\\s]+')) {
          String cleanAddr = addr.trim();
          if (String.isNotBlank(cleanAddr) && cleanAddr.contains('@')) {
            toList.add(cleanAddr);
          }
        }
      }

      // CC addresses parsing
      List<String> ccList = new List<String>();
      if (String.isNotBlank(ccAddress)) {
        for (String addr : ccAddress.split('[,;\\s]+')) {
          String cleanAddr = addr.trim();
          if (String.isNotBlank(cleanAddr) && cleanAddr.contains('@')) {
            ccList.add(cleanAddr);
          }
        }
      }

      // BCC addresses parsing
      List<String> bccList = new List<String>();
      if (String.isNotBlank(bccAddress)) {
        for (String addr : bccAddress.split('[,;\\s]+')) {
          String cleanAddr = addr.trim();
          if (String.isNotBlank(cleanAddr) && cleanAddr.contains('@')) {
            bccList.add(cleanAddr);
          }
        }
      }

      if (!toList.isEmpty()) {
        email.setToAddresses(toList);
      }
      if (!ccList.isEmpty()) {
        email.setCcAddresses(ccList);
      }
      if (!bccList.isEmpty()) {
        email.setBccAddresses(bccList);
      }

      email.setSaveAsActivity(false);

      // Org-Wide Email / Sender setup
      if (String.isNotBlank(fromAddress)) {
        List<OrgWideEmailAddress> owea = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :fromAddress LIMIT 1];
        if (!owea.isEmpty()) {
          email.setOrgWideEmailAddressId(owea[0].Id);
        } else {
          email.setReplyTo(fromAddress);
        }
      } else {
        List<OrgWideEmailAddress> owea = [SELECT Id FROM OrgWideEmailAddress LIMIT 1];
        if (!owea.isEmpty()) {
          email.setOrgWideEmailAddressId(owea[0].Id);
        }
      }

      email.setSubject(subject);
      String htmlContent = body;
      if (String.isNotBlank(htmlContent) && !htmlContent.toLowerCase().contains('<p>') && !htmlContent.toLowerCase().contains('<br')) {
        htmlContent = '<p>' + htmlContent.replace('\n\n', '</p><p>').replace('\n', '<br/>') + '</p>';
      }
      email.setHtmlBody(htmlContent != null ? htmlContent : '');
      email.setPlainTextBody(body != null ? body.replaceAll('<[^>]*>', '\n') : '');
      email.setWhatId(poId);

      if (!attachments.isEmpty()) {
        email.setFileAttachments(attachments);
      }

      Messaging.SendEmailResult[] results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }, false);
      if (!results.isEmpty() && !results[0].isSuccess()) {
        String errStr = '';
        for (Messaging.SendEmailError err : results[0].getErrors()) {
          errStr += err.getMessage() + '; ';
        }
        wrapper.isSuccess = false;
        wrapper.errorMsg = 'Email bounce/delivery failure: ' + errStr;
        return wrapper;
      }

      // Explicitly log EmailMessage activity on the Purchase Order record for the Activity Timeline
      EmailMessage emailMsg = new EmailMessage();
      emailMsg.RelatedToId = poId;
      emailMsg.Subject = subject;
      emailMsg.HtmlBody = (htmlContent != null) ? htmlContent : '';
      emailMsg.TextBody = (body != null) ? body.replaceAll('<[^>]*>', '\n') : '';
      emailMsg.ToAddress = !toList.isEmpty() ? String.join(toList, '; ') : toAddress;
      if (!ccList.isEmpty()) {
        emailMsg.CcAddress = String.join(ccList, '; ');
      }
      if (!bccList.isEmpty()) {
        emailMsg.BccAddress = String.join(bccList, '; ');
      }
      emailMsg.FromAddress = String.isNotBlank(fromAddress) ? fromAddress : UserInfo.getUserEmail();
      emailMsg.FromName = UserInfo.getName();
      emailMsg.Status = '3'; // Sent
      emailMsg.MessageDate = System.now();
      insert emailMsg;

      // Link PDF attachment to the EmailMessage activity
      if (docId != null) {
        try {
          ContentDocumentLink cdlEmail = new ContentDocumentLink();
          cdlEmail.ContentDocumentId = docId;
          cdlEmail.LinkedEntityId = emailMsg.Id;
          cdlEmail.ShareType = 'V';
          cdlEmail.Visibility = 'AllUsers';
          insert cdlEmail;
        } catch (Exception exLink) {
          /* skip if link error or already linked */
        }
      }

      wrapper.isSuccess = true;
    } catch (Exception e) {
      wrapper.isSuccess = false;
      wrapper.errorMsg = e.getMessage();
    }
    return wrapper;
  }

  @AuraEnabled
  public static EmailDetails getLatestDocumentForSendingAnEmail(String poId) {
    try {
      if (forceException) {
        throw new CalloutException('Forced exception for testing');
      }
      List<Purchase_Order__c> poList = [
        SELECT Id, Name, Supplying_Account__c, Supplying_Account__r.Name
        FROM Purchase_Order__c WHERE Id = :poId
      ];
      List<ContentDocumentLink> contentDocumentLinks = [
        SELECT Id, ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :poId ORDER BY SystemModstamp DESC
      ];
      EmailDetails em = new EmailDetails();
      if (!poList.isEmpty()) {
        Purchase_Order__c po = poList[0];
        String vendorEmail = resolveVendorEmail(po);
        String vendorName = (po.Supplying_Account__r != null && String.isNotBlank(po.Supplying_Account__r.Name))
          ? po.Supplying_Account__r.Name
          : 'Vendor';
        em.contactName = vendorName;
        em.contactEmail = vendorEmail;
        if (po.Supplying_Account__c != null) {
          List<Contact> contacts = [
            SELECT Id FROM Contact WHERE AccountId = :po.Supplying_Account__c AND Email != NULL ORDER BY CreatedDate ASC LIMIT 1
          ];
          if (!contacts.isEmpty()) {
            em.contactId = contacts[0].Id;
          }
        }
        em.subject = 'Purchase Order ' + po.Name + (String.isNotBlank(vendorName) ? ' - ' + vendorName : '');
        em.body = '<p>Dear ' + vendorName + ',</p>' +
                  '<p>Thank you for your interest in our company.</p>' +
                  '<p>Please find attached the Purchase Order containing the details of the products and services we will provide.</p>' +
                  '<p>Kindly review the Purchase Order and confirm your acceptance by replying to this email. Once we receive your confirmation, we will proceed with the order and share the confirmation details.</p>' +
                  '<p>If you have any questions or need any clarification, please feel free to contact us. We are happy to assist you.</p>' +
                  '<p>We look forward to working with you.</p>' +
                  '<p>Best Regards,</p>' +
                  '<p>Procurement Team.</p>';
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