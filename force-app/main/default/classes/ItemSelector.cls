public with sharing class ItemSelector {
    public static Map<Id, Item__c> getItemsByIds(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) {
            return new Map<Id, Item__c>();
        }
        return new Map<Id, Item__c>([
            SELECT Id, Reorder_Level__c, Target_Stock_Level__c, Default_Supply_Method__c,
            Stock_Low_Level_Quantity__c, Stock_Medium_Level_Quantity__c, Stock_High_Level_Quantity__c
            FROM Item__c 
            WHERE Id IN :ids
        ]);
    }

    public static List<Item__c> getItemsByProductIds(Set<String> productIds) {
        if (productIds == null || productIds.isEmpty()) {
            return new List<Item__c>();
        }
        return [
            SELECT Id, Product_Id__c 
            FROM Item__c 
            WHERE Product_Id__c IN :productIds
        ];
    }

    public static List<Item__c> getItemsByProductUniqueIds(Set<String> productIds) {
        if (productIds == null || productIds.isEmpty()) {
            return new List<Item__c>();
        }
        return [
            SELECT Id, Product_Unique_Id__c 
            FROM Item__c 
            WHERE Product_Unique_Id__c IN :productIds
        ];
    }

    public static Map<Id, Item__c> getItemsByProductIds(Set<Id> productIds) {
        if (productIds == null || productIds.isEmpty()) {
            return new Map<Id, Item__c>();
        }
        Map<Id, Item__c> productToItemMap = new Map<Id, Item__c>();
        for (Item__c item : [
            SELECT Id, Related_Product__c 
            FROM Item__c 
            WHERE Related_Product__c IN :productIds
        ]) {
            productToItemMap.put(item.Related_Product__c, item);
        }
        return productToItemMap;
    }
}