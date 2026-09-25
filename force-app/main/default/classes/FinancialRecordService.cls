public without sharing class FinancialRecordService {

    /**
     * Generates financial records (Payable, Invoice, Invoice Line Items, Receivable)
     * for the provided Purchase Order IDs.
     * Prevents duplicate record creation if financial records already exist for a PO.
     */
    public static void generateFinancialRecordsForPOs(Set<Id> poIds) {
        if (poIds == null || poIds.isEmpty()) {
            return;
        }

        // 1. Duplicate Prevention: Identify POs that already have financial records
        Set<Id> existingPoIds = new Set<Id>();
        
        for (Payable__c p : [
            SELECT Purchase_Order__c 
            FROM Payable__c 
            WHERE Purchase_Order__c IN :poIds
        ]) {
            if (p.Purchase_Order__c != null) {
                existingPoIds.add(p.Purchase_Order__c);
            }
        }
        
        for (Invoice__c inv : [
            SELECT Purchase_Order__c 
            FROM Invoice__c 
            WHERE Purchase_Order__c IN :poIds
        ]) {
            if (inv.Purchase_Order__c != null) {
                existingPoIds.add(inv.Purchase_Order__c);
            }
        }
        
        for (Receivable__c r : [
            SELECT Purchase_Order__c 
            FROM Receivable__c 
            WHERE Purchase_Order__c IN :poIds
        ]) {
            if (r.Purchase_Order__c != null) {
                existingPoIds.add(r.Purchase_Order__c);
            }
        }

        Set<Id> validPoIds = new Set<Id>();
        for (Id poId : poIds) {
            if (!existingPoIds.contains(poId)) {
                validPoIds.add(poId);
            }
        }

        if (validPoIds.isEmpty()) {
            return;
        }

        // 2. Query Purchase Orders and their Line Items
        List<Purchase_Order__c> poList = [
            SELECT Id, Name, Supplying_Account__c, Requesting_Account__c, Reference_Account__c,
                   PO_Date__c, Expected_Date__c, Sales_Allocation__c, Sub_Total__c, Total_Amount__c,
                   Tax_Amount__c, Discount_Amount__c, Status__c,
                   (SELECT Id, Item__c, Ordered_Qty__c, Unit_Price__c, Discount__c, Discount_Amount__c,
                           Tax__c, Tax_Amount__c, Gross_Amount__c, POLI_Total__c, Sales_Allocation_Line_Item__c
                    FROM Purchase_Order_Line_Item__r)
            FROM Purchase_Order__c
            WHERE Id IN :validPoIds
        ];

        if (poList.isEmpty()) {
            return;
        }

        // 3. Prepare Invoices
        List<Invoice__c> invoicesToInsert = new List<Invoice__c>();
        Map<Id, Invoice__c> poIdToInvoiceMap = new Map<Id, Invoice__c>();

        for (Purchase_Order__c po : poList) {
            Date invDate = po.PO_Date__c != null ? po.PO_Date__c : Date.today();
            Date dueDate = po.Expected_Date__c != null ? po.Expected_Date__c : invDate.addDays(30);

            Decimal subtotal = 0;
            Decimal taxAmount = 0;
            Decimal discountAmount = 0;

            if (po.Purchase_Order_Line_Item__r != null) {
                for (Purchase_Order_Line_Item__c poli : po.Purchase_Order_Line_Item__r) {
                    Decimal qty = poli.Ordered_Qty__c != null ? poli.Ordered_Qty__c : 0;
                    Decimal price = poli.Unit_Price__c != null ? poli.Unit_Price__c : 0;
                    Decimal gross = qty * price;

                    Decimal disc = 0;
                    if (poli.Discount_Amount__c != null) {
                        disc = poli.Discount_Amount__c;
                    } else if (poli.Discount__c != null && poli.Discount__c > 0) {
                        disc = (gross * poli.Discount__c) / 100;
                    }

                    Decimal taxRate = poli.Tax__c != null ? poli.Tax__c : 0;
                    Decimal tax = 0;
                    if (poli.Tax_Amount__c != null) {
                        tax = poli.Tax_Amount__c;
                    } else {
                        tax = ((gross - disc) * taxRate) / 100;
                    }

                    subtotal += gross;
                    discountAmount += disc;
                    taxAmount += tax;
                }
            }

            Invoice__c inv = new Invoice__c(
                Supplying_Account__c = po.Supplying_Account__c,
                Requesting_Account__c = po.Requesting_Account__c,
                Purchase_Order__c = po.Id,
                Invoice_Date__c = invDate,
                Due_Date__c = dueDate,
                Type__c = 'Accounts Payable',
                Status__c = 'Approved',
                Payment_Terms__c = 'Net 30',
                Subtotal__c = subtotal,
                Tax_Amount__c = taxAmount,
                Discount_Amount__c = discountAmount
            );

            invoicesToInsert.add(inv);
            poIdToInvoiceMap.put(po.Id, inv);
        }

        if (!invoicesToInsert.isEmpty()) {
            insert invoicesToInsert;
        }

        // 4. Prepare Invoice Line Items
        List<Invoice_Line_Item__c> ilisToInsert = new List<Invoice_Line_Item__c>();
        for (Purchase_Order__c po : poList) {
            Invoice__c parentInvoice = poIdToInvoiceMap.get(po.Id);
            if (parentInvoice != null && parentInvoice.Id != null && po.Purchase_Order_Line_Item__r != null) {
                for (Purchase_Order_Line_Item__c poli : po.Purchase_Order_Line_Item__r) {
                    Decimal qty = poli.Ordered_Qty__c != null ? poli.Ordered_Qty__c : 0;
                    Decimal price = poli.Unit_Price__c != null ? poli.Unit_Price__c : 0;
                    Decimal gross = qty * price;

                    Decimal disc = 0;
                    if (poli.Discount_Amount__c != null) {
                        disc = poli.Discount_Amount__c;
                    } else if (poli.Discount__c != null && poli.Discount__c > 0) {
                        disc = (gross * poli.Discount__c) / 100;
                    }

                    Invoice_Line_Item__c ili = new Invoice_Line_Item__c(
                        Invoice__c = parentInvoice.Id,
                        Item__c = poli.Item__c,
                        Purchase_Order_Line_Item__c = poli.Id,
                        Quantity__c = qty,
                        Unit_Price__c = price,
                        Discount_Amount__c = disc,
                        Tax_Rate__c = poli.Tax__c != null ? poli.Tax__c : 0,
                        Description__c = 'Invoice Line for Purchase Order Item'
                    );
                    ilisToInsert.add(ili);
                }
            }
        }

        if (!ilisToInsert.isEmpty()) {
            insert ilisToInsert;
        }

        // 5. Prepare Payables and Receivables
        List<Payable__c> payablesToInsert = new List<Payable__c>();
        List<Receivable__c> receivablesToInsert = new List<Receivable__c>();

        for (Purchase_Order__c po : poList) {
            Invoice__c parentInvoice = poIdToInvoiceMap.get(po.Id);
            Id invId = parentInvoice != null ? parentInvoice.Id : null;

            Date poDate = po.PO_Date__c != null ? po.PO_Date__c : Date.today();
            Date dueDate = po.Expected_Date__c != null ? po.Expected_Date__c : poDate.addDays(30);

            Decimal totalAmt = 0;
            if (parentInvoice != null && parentInvoice.Subtotal__c != null) {
                totalAmt = parentInvoice.Subtotal__c + (parentInvoice.Tax_Amount__c != null ? parentInvoice.Tax_Amount__c : 0) - (parentInvoice.Discount_Amount__c != null ? parentInvoice.Discount_Amount__c : 0);
            } else if (po.Total_Amount__c != null) {
                totalAmt = po.Total_Amount__c;
            }

            Payable__c payable = new Payable__c(
                Supplying_Account__c = po.Supplying_Account__c,
                Requesting_Account__c = po.Requesting_Account__c,
                Purchase_Order__c = po.Id,
                Invoice__c = invId,
                Payable_Date__c = poDate,
                Due_Date__c = dueDate,
                Total_Amount__c = totalAmt,
                Amount_Paid__c = 0,
                Status__c = 'Unpaid',
                Payment_Status__c = 'Pending Approval',
                Payment_Terms__c = 'Net 30'
            );
            payablesToInsert.add(payable);

            Receivable__c receivable = new Receivable__c(
                Supplying_Account__c = po.Supplying_Account__c,
                Requesting_Account__c = po.Requesting_Account__c,
                Purchase_Order__c = po.Id,
                Invoice__c = invId,
                Receivable_Date__c = poDate,
                Due_Date__c = dueDate,
                Total_Amount__c = totalAmt,
                Amount_Received__c = 0,
                Status__c = 'Unpaid',
                Collection_Status__c = 'Current',
                Payment_Terms__c = 'Net 30'
            );
            receivablesToInsert.add(receivable);
        }

        if (!payablesToInsert.isEmpty()) {
            insert payablesToInsert;
        }

        if (!receivablesToInsert.isEmpty()) {
            insert receivablesToInsert;
        }
    }
}