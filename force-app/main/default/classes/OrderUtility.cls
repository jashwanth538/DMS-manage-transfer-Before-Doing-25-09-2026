public with sharing class OrderUtility {
   public static Order_Allocation__c buildOrderAllocation(Order o) {
        Order_Allocation__c allocation = new Order_Allocation__c();
        allocation.Sale_Order__c = o.Id;
        //allocation.Customer__c = o.AccountId;
        allocation.Customer_Name__c = o.Customer_Name__c;
        allocation.Bill_To_Contact__c = o.BillToContactId;
        allocation.Supplying_Account__c = o.Supplying_Account__c;
        allocation.Requesting_Account__c = o.AccountId;
        allocation.Source_Location__c = o.Source_Location__c;
        allocation.Target_Location__c = o.Target_Location__c;
        if (o.ActivatedDate != null) {
            allocation.Order_Activated_Date__c = o.ActivatedDate.date();
        }
        allocation.Order_Allocation_Date__c = System.today();
        allocation.Status__c = 'Draft';
        // allocation.Inventory_Location__c = o.Inventory_Location__c; // Commented out: Inventory_Location__c field not on Order
        allocation.Notes__c = o.Description;

        // Map Billing Address fields
        allocation.Billing_Street__c = o.Billing_Street__c;
        allocation.Billing_City__c = o.Billing_City__c;
        allocation.Billing_State__c = o.Billing_State__c;
        allocation.Billing_Post_Code__c = o.Billing_Post_Code__c;
        allocation.Billing_Country__c = o.Billing_Country__c;

        // Map Shipping Address fields
        allocation.Shipping_Street__c = o.Shipping_Street__c;
        allocation.Shipping_City__c = o.Shipping_City__c;
        allocation.Shipping_State__c = o.Shipping_State__c;
        allocation.Shipping_Post_Code__c = o.Shipping_Post_Code__c;
        allocation.Shipping_Country__c = o.Shipping_Country__c;
        
        return allocation;
    }
    
    public static Order_Allocation_Line_Item__c buildAllocationLineItem(Order o, Order_Allocation__c allocation, OrderItem oi, Map<String, Id> itemMap) {
        Order_Allocation_Line_Item__c ali = new Order_Allocation_Line_Item__c();
        ali.Order_Allocation__c = allocation.Id;
        ali.Sales_Order_Line_Item__c = oi.Id;
        // ali.Account__c = o.AccountId; // Commented out: Account__c field not on Order_Allocation_Line_Item__c
        ali.Contact__c = o.BillToContactId;
        ali.Ordered_Qty__c = oi.Quantity;
        ali.Unit_Price__c = oi.UnitPrice;
        ali.Gross_Amount__c = (oi.Quantity != null && oi.UnitPrice != null) ? (oi.Quantity * oi.UnitPrice) : 0;
        ali.Discount_Percent__c = oi.Discount_Percent__c;
        ali.Tax__c = oi.Tax__c;
        ali.Additional_Cost__c = oi.Additional_Cost__c;
        ali.Transfer_Cost__c = oi.Transfer_Cost__c;
        ali.Loading_and_Unloading_Charges__c = oi.Loading_and_Unloading_Charges__c;
        ali.Status__c = 'Draft';
        
        // Resolve the Item__c lookup using Product2.Item_Id__c matching Item__c.Product_Id__c
        if (oi.Product2 != null && String.isNotBlank(oi.Product2.Item_Id__c)) {
            String itemIdKey = oi.Product2.Item_Id__c;
            if (itemMap.containsKey(itemIdKey)) {
                ali.Item__c = itemMap.get(itemIdKey);
            }
        }
        
        return ali;
    }  
}