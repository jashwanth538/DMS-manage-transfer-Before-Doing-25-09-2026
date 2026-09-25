public with sharing class Product2Utility {
    public static void mapProductToItem(Product2 prod, Item__c item) {
        item.Name = prod.Name;
        item.Item_Code__c = prod.ProductCode;
        item.Item_Description__c = prod.Description;
        item.Item_Family__c = prod.Family;
        item.Active__c = prod.IsActive;
        item.Unit_Of_Measure__c = prod.Unit_Of_Measure__c;
        item.Default_Supply_Method__c = prod.Default_Supply_Method__c;
        item.Base_Tax__c = prod.Base_Tax__c;
        item.Delivery_Preparation_Time__c = prod.Delivery_Preparation_Time__c;
        item.Reorder_Level__c = prod.Reorder_Level__c;
        item.Target_Stock_Level__c = prod.Target_Stock_Level__c;
        item.Stock_Low_Level_Quantity__c = prod.Stock_Low_Level_Quantity__c;
        item.Stock_Medium_Level_Quantity__c = prod.Stock_Medium_Level_Quantity__c;
        item.Stock_High_Level_Quantity__c = prod.Stock_High_Level_Quantity__c;
        item.Classification__c = prod.Classification__c;
        item.Is_Sellable__c = prod.Is_Sellable__c;
        item.Is_Inventory_Item__c = prod.Is_Inventory_Item__c;
        item.Service_Type__c = prod.Service_Type__c;
        item.Target_Days__c = prod.Target_Days__c;
        item.Quantity_Unit_Of_Measure__c = prod.QuantityUnitOfMeasure;
        item.Product_Id__c = prod.Item_Id__c;
    }

    public static void mapItemToProduct(Item__c item, Product2 prod) {
        prod.Name = item.Name;
        prod.ProductCode = item.Item_Code__c;
        prod.Description = item.Item_Description__c;
        prod.Family = item.Item_Family__c;
        prod.IsActive = item.Active__c;
        prod.Unit_Of_Measure__c = item.Unit_Of_Measure__c;
        prod.Default_Supply_Method__c = item.Default_Supply_Method__c;
        prod.Base_Tax__c = item.Base_Tax__c;
        prod.Delivery_Preparation_Time__c = item.Delivery_Preparation_Time__c;
        prod.Reorder_Level__c = item.Reorder_Level__c;
        prod.Target_Stock_Level__c = item.Target_Stock_Level__c;
        prod.Stock_Low_Level_Quantity__c = item.Stock_Low_Level_Quantity__c;
        prod.Stock_Medium_Level_Quantity__c = item.Stock_Medium_Level_Quantity__c;
        prod.Stock_High_Level_Quantity__c = item.Stock_High_Level_Quantity__c;
        prod.Classification__c = item.Classification__c;
        prod.Is_Sellable__c = item.Is_Sellable__c;
        prod.Is_Inventory_Item__c = item.Is_Inventory_Item__c;
        prod.Service_Type__c = item.Service_Type__c;
        prod.Target_Days__c = item.Target_Days__c;
        prod.QuantityUnitOfMeasure = item.Quantity_Unit_Of_Measure__c;
        prod.Item_Id__c = item.Product_Id__c;
    }
}