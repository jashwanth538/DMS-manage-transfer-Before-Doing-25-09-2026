public with sharing class OrderSelector {
    public static List<Order> getOrdersWithItems(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return new List<Order>();
        }
        return [
            SELECT Id, AccountId, Customer_Name__c, BillToContactId, ActivatedDate, /* Inventory_Location__c, */ Description,
                   Supplying_Account__c,  Source_Location__c, Target_Location__c,
                   Billing_Street__c, Billing_City__c, Billing_State__c, Billing_Post_Code__c, Billing_Country__c,
                   Shipping_Street__c, Shipping_City__c, Shipping_State__c, Shipping_Post_Code__c, Shipping_Country__c,
                   (SELECT Id, Product2Id, Product2.Item_Id__c, Quantity, UnitPrice, 
                           Transfer_Cost__c, Tax__c, Discount_Percent__c, 
                           Additional_Cost__c, Loading_and_Unloading_Charges__c
                    FROM OrderItems)
            FROM Order
            WHERE Id IN :orderIds
        ];
    } 
}