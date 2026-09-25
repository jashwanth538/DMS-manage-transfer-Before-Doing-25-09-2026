/**
 * @description Metadata Resolver that stores and dynamically retrieves sharing-related configurations
 *              for both custom business objects and standard objects (like Account) in the DMS.
 *              Allows the Apex Sharing Framework to operate generically and comply with the Open/Closed Principle.
 * @author DeepMind Antigravity
 * @date 2026-08-05
 */
public with sharing class ShareMetadataResolver {

    /**
     * @description Wrapper class encapsulating metadata descriptor properties required by the sharing engine.
     */
    public class ShareDescriptor {
        public String shareObjectApiName;
        public String parentFieldName;
        public String accessFieldName;
        public String accountLookupFieldName;
        public List<String> accountLookupFieldNames;
        public String parentLookupFieldName;
        public Schema.SObjectType parentObjectType;
        public List<String> changeTrackingFields;
        public Map<String, Object> additionalFields;
        public Boolean isRowCauseWriteable;
    }

    private static Map<Schema.SObjectType, ShareDescriptor> registry = new Map<Schema.SObjectType, ShareDescriptor>();

    static {
        // Register standard Account sharing descriptor
        ShareDescriptor accountDesc = new ShareDescriptor();
        accountDesc.shareObjectApiName = 'AccountShare';
        accountDesc.parentFieldName = 'AccountId';
        accountDesc.accessFieldName = 'AccountAccessLevel';
        accountDesc.accountLookupFieldName = 'Id';
        accountDesc.accountLookupFieldNames = new List<String>{ 'Id' };
        accountDesc.changeTrackingFields = new List<String>{ 'Dealer__c', 'Distributor__c', 'OEM__c' };
        accountDesc.additionalFields = new Map<String, Object>{
            'OpportunityAccessLevel' => 'None',
            'CaseAccessLevel' => 'None'
        };
        accountDesc.isRowCauseWriteable = false;
        registry.put(Account.SObjectType, accountDesc);

        // 1. Purchase Requisition (PR)
        ShareDescriptor prDesc = new ShareDescriptor();
        prDesc.shareObjectApiName = 'Purchase_Requisition__Share';
        prDesc.parentFieldName = 'ParentId';
        prDesc.accessFieldName = 'AccessLevel';
        prDesc.accountLookupFieldName = 'Requesting_Account__c';
        prDesc.accountLookupFieldNames = new List<String>{ 'Requesting_Account__c', 'Account__c' };
        prDesc.changeTrackingFields = new List<String>{ 'Requesting_Account__c', 'Account__c' };
        prDesc.isRowCauseWriteable = true;
        registry.put(Purchase_Requisition__c.SObjectType, prDesc);

        // 2. Purchase Requisition Line Item (PRLI)
        ShareDescriptor prliDesc = new ShareDescriptor();
        prliDesc.shareObjectApiName = 'Purchase_Requisition_Line__Share';
        prliDesc.parentFieldName = 'ParentId';
        prliDesc.accessFieldName = 'AccessLevel';
        prliDesc.parentLookupFieldName = 'Purchase_Requisition__c';
        prliDesc.parentObjectType = Purchase_Requisition__c.SObjectType;
        prliDesc.changeTrackingFields = new List<String>{ 'Purchase_Requisition__c' };
        prliDesc.isRowCauseWriteable = true;
        registry.put(Purchase_Requisition_Line__c.SObjectType, prliDesc);

        // 3. Purchase Order (PO)
        ShareDescriptor poDesc = new ShareDescriptor();
        poDesc.shareObjectApiName = 'Purchase_Order__Share';
        poDesc.parentFieldName = 'ParentId';
        poDesc.accessFieldName = 'AccessLevel';
        poDesc.accountLookupFieldName = 'Requesting_Account__c';
        poDesc.accountLookupFieldNames = new List<String>{ 'Requesting_Account__c', 'Supplying_Account__c', 'Account__c' };
        poDesc.changeTrackingFields = new List<String>{ 'Requesting_Account__c', 'Supplying_Account__c', 'Account__c' };
        poDesc.isRowCauseWriteable = true;
        registry.put(Purchase_Order__c.SObjectType, poDesc);

        // 4. Purchase Order Line Item (POLI)
        ShareDescriptor poliDesc = new ShareDescriptor();
        poliDesc.shareObjectApiName = 'Purchase_Order_Line_Item__Share';
        poliDesc.parentFieldName = 'ParentId';
        poliDesc.accessFieldName = 'AccessLevel';
        poliDesc.parentLookupFieldName = 'Purchase_Order__c';
        poliDesc.parentObjectType = Purchase_Order__c.SObjectType;
        poliDesc.changeTrackingFields = new List<String>{ 'Purchase_Order__c' };
        poliDesc.isRowCauseWriteable = true;
        registry.put(Purchase_Order_Line_Item__c.SObjectType, poliDesc);

        // 5. Order Allocation (OA)
        ShareDescriptor oaDesc = new ShareDescriptor();
        oaDesc.shareObjectApiName = 'Order_Allocation__Share';
        oaDesc.parentFieldName = 'ParentId';
        oaDesc.accessFieldName = 'AccessLevel';
        oaDesc.accountLookupFieldName = 'Supplying_Account__c';
        oaDesc.accountLookupFieldNames = new List<String>{ 'Supplying_Account__c' };
        oaDesc.changeTrackingFields = new List<String>{ 'Supplying_Account__c' };
        oaDesc.isRowCauseWriteable = true;
        registry.put(Order_Allocation__c.SObjectType, oaDesc);

        // 6. Order Allocation Line Item (OALI)
        ShareDescriptor oaliDesc = new ShareDescriptor();
        oaliDesc.shareObjectApiName = 'Order_Allocation_Line_Item__Share';
        oaliDesc.parentFieldName = 'ParentId';
        oaliDesc.accessFieldName = 'AccessLevel';
        oaliDesc.parentLookupFieldName = 'Order_Allocation__c';
        oaliDesc.parentObjectType = Order_Allocation__c.SObjectType;
        oaliDesc.changeTrackingFields = new List<String>{ 'Order_Allocation__c' };
        oaliDesc.isRowCauseWriteable = true;
        registry.put(Order_Allocation_Line_Item__c.SObjectType, oaliDesc);

        // 7. Inventory Reservation (IR)
        ShareDescriptor irDesc = new ShareDescriptor();
        irDesc.shareObjectApiName = 'Inventory_Reservation__Share';
        irDesc.parentFieldName = 'ParentId';
        irDesc.accessFieldName = 'AccessLevel';
        irDesc.accountLookupFieldName = 'Supplying_Account__c';
        irDesc.accountLookupFieldNames = new List<String>{ 'Supplying_Account__c' };
        irDesc.changeTrackingFields = new List<String>{ 'Supplying_Account__c' };
        irDesc.isRowCauseWriteable = true;
        registry.put(Inventory_Reservation__c.SObjectType, irDesc);

        // 8. Inventory
        ShareDescriptor invDesc = new ShareDescriptor();
        invDesc.shareObjectApiName = 'Inventory__Share';
        invDesc.parentFieldName = 'ParentId';
        invDesc.accessFieldName = 'AccessLevel';
        invDesc.accountLookupFieldName = 'Account__c';
        invDesc.accountLookupFieldNames = new List<String>{ 'Account__c' };
        invDesc.changeTrackingFields = new List<String>{ 'Account__c' };
        invDesc.isRowCauseWriteable = true;
        registry.put(Inventory__c.SObjectType, invDesc);

        // 9. Inventory Location
        ShareDescriptor invLocDesc = new ShareDescriptor();
        invLocDesc.shareObjectApiName = 'Inventory_Location__Share';
        invLocDesc.parentFieldName = 'ParentId';
        invLocDesc.accessFieldName = 'AccessLevel';
        invLocDesc.accountLookupFieldName = 'Account__c';
        invLocDesc.accountLookupFieldNames = new List<String>{ 'Account__c' };
        invLocDesc.changeTrackingFields = new List<String>{ 'Account__c' };
        invLocDesc.isRowCauseWriteable = true;
        registry.put(Inventory_Location__c.SObjectType, invLocDesc);

        // 10. GRN
        ShareDescriptor grnDesc = new ShareDescriptor();
        grnDesc.shareObjectApiName = 'GRN__Share';
        grnDesc.parentFieldName = 'ParentId';
        grnDesc.accessFieldName = 'AccessLevel';
        grnDesc.accountLookupFieldName = 'Requesting_Account__c';
        grnDesc.accountLookupFieldNames = new List<String>{ 'Requesting_Account__c', 'Account__c' };
        grnDesc.changeTrackingFields = new List<String>{ 'Requesting_Account__c', 'Account__c' };
        grnDesc.isRowCauseWriteable = true;
        registry.put(GRN__c.SObjectType, grnDesc);

        // 11. GRN Line Item
        ShareDescriptor grnLiDesc = new ShareDescriptor();
        grnLiDesc.shareObjectApiName = 'GRN_Line_Item__Share';
        grnLiDesc.parentFieldName = 'ParentId';
        grnLiDesc.accessFieldName = 'AccessLevel';
        grnLiDesc.parentLookupFieldName = 'GRN__c';
        grnLiDesc.parentObjectType = GRN__c.SObjectType;
        grnLiDesc.changeTrackingFields = new List<String>{ 'GRN__c' };
        grnLiDesc.isRowCauseWriteable = true;
        registry.put(GRN_Line_Item__c.SObjectType, grnLiDesc);

        // 12. Inventory Transfer
        ShareDescriptor transferDesc = new ShareDescriptor();
        transferDesc.shareObjectApiName = 'Inventory_Transfer__Share';
        transferDesc.parentFieldName = 'ParentId';
        transferDesc.accessFieldName = 'AccessLevel';
        transferDesc.accountLookupFieldName = 'From_Account__c';
        transferDesc.accountLookupFieldNames = new List<String>{ 'From_Account__c', 'To_Account__c', 'Account__c' };
        transferDesc.changeTrackingFields = new List<String>{ 'From_Account__c', 'To_Account__c', 'Account__c' };
        transferDesc.isRowCauseWriteable = true;
        registry.put(Inventory_Transfer__c.SObjectType, transferDesc);

        // 13. Supply Request (SR)
        ShareDescriptor srDesc = new ShareDescriptor();
        srDesc.shareObjectApiName = 'Supply_Request__Share';
        srDesc.parentFieldName = 'ParentId';
        srDesc.accessFieldName = 'AccessLevel';
        srDesc.accountLookupFieldName = 'Requesting_Account__c';
        srDesc.accountLookupFieldNames = new List<String>{ 'Requesting_Account__c', 'Supplying_Account__c', 'Account__c' };
        srDesc.changeTrackingFields = new List<String>{ 'Requesting_Account__c', 'Supplying_Account__c', 'Account__c' };
        srDesc.isRowCauseWriteable = true;
        registry.put(Supply_Request__c.SObjectType, srDesc);

        // 14. Item Price
        ShareDescriptor itemPriceDesc = new ShareDescriptor();
        itemPriceDesc.shareObjectApiName = 'Item_Price__Share';
        itemPriceDesc.parentFieldName = 'ParentId';
        itemPriceDesc.accessFieldName = 'AccessLevel';
        itemPriceDesc.accountLookupFieldName = 'Item_Price_Account__c';
        itemPriceDesc.accountLookupFieldNames = new List<String>{ 'Item_Price_Account__c', 'Account__c' };
        itemPriceDesc.changeTrackingFields = new List<String>{ 'Item_Price_Account__c' };
        itemPriceDesc.isRowCauseWriteable = true;
        registry.put(Item_Price__c.SObjectType, itemPriceDesc);

        // 15. Payable (Shared by Requesting Account)
        ShareDescriptor payableDesc = new ShareDescriptor();
        payableDesc.shareObjectApiName = 'Payable__Share';
        payableDesc.parentFieldName = 'ParentId';
        payableDesc.accessFieldName = 'AccessLevel';
        payableDesc.accountLookupFieldName = 'Requesting_Account__c';
        payableDesc.accountLookupFieldNames = new List<String>{ 'Requesting_Account__c' };
        payableDesc.changeTrackingFields = new List<String>{ 'Requesting_Account__c' };
        payableDesc.isRowCauseWriteable = true;
        registry.put(Payable__c.SObjectType, payableDesc);

        // 16. Receivable (Shared by Supplying Account)
        ShareDescriptor receivableDesc = new ShareDescriptor();
        receivableDesc.shareObjectApiName = 'Receivable__Share';
        receivableDesc.parentFieldName = 'ParentId';
        receivableDesc.accessFieldName = 'AccessLevel';
        receivableDesc.accountLookupFieldName = 'Supplying_Account__c';
        receivableDesc.accountLookupFieldNames = new List<String>{ 'Supplying_Account__c' };
        receivableDesc.changeTrackingFields = new List<String>{ 'Supplying_Account__c' };
        receivableDesc.isRowCauseWriteable = true;
        registry.put(Receivable__c.SObjectType, receivableDesc);

        // 17. Invoice (Shared by Requesting Account)
        ShareDescriptor invoiceDesc = new ShareDescriptor();
        invoiceDesc.shareObjectApiName = 'Invoice__Share';
        invoiceDesc.parentFieldName = 'ParentId';
        invoiceDesc.accessFieldName = 'AccessLevel';
        invoiceDesc.accountLookupFieldName = 'Requesting_Account__c';
        invoiceDesc.accountLookupFieldNames = new List<String>{ 'Requesting_Account__c' };
        invoiceDesc.changeTrackingFields = new List<String>{ 'Requesting_Account__c' };
        invoiceDesc.isRowCauseWriteable = true;
        registry.put(Invoice__c.SObjectType, invoiceDesc);
    }

    /**
     * @description Dynamic factory method to resolve the share descriptor for a given SObjectType.
     * @param sType SObjectType of the target record.
     * @return ShareDescriptor metadata details, or null if unsupported.
     */
    public static ShareDescriptor getDescriptor(Schema.SObjectType sType) {
        if (sType == null) {
            return null;
        }

        // Return registered descriptor if present
        if (registry.containsKey(sType)) {
            return registry.get(sType);
        }

        // Fallback: Resolve custom object sharing details dynamically
        String objName = sType.getDescribe().getName();
        if (objName.endsWith('__c')) {
            ShareDescriptor customDesc = new ShareDescriptor();
            customDesc.shareObjectApiName = objName.replace('__c', '__Share');
            customDesc.parentFieldName = 'ParentId';
            customDesc.accessFieldName = 'AccessLevel';
            customDesc.accountLookupFieldName = 'Requesting_Account__c';
            customDesc.accountLookupFieldNames = new List<String>{ 'Requesting_Account__c', 'Account__c' };
            customDesc.changeTrackingFields = new List<String>{ 'Requesting_Account__c', 'Account__c' };
            customDesc.additionalFields = new Map<String, Object>();
            customDesc.isRowCauseWriteable = true;
            return customDesc;
        }

        return null;
    }
}