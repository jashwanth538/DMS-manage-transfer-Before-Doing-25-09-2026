public with sharing class Product2TriggerHandler extends BaseTriggerHandler {
    public override void beforeInsert(List<SObject> newRecords) {
        for (Product2 prod : (List<Product2>) newRecords) {
            prod.Item_Id__c = (String.isNotBlank(prod.Name) && String.isNotBlank(prod.ProductCode)) ? (prod.Name + '-' + prod.ProductCode) : '';
        }
        Product2Service.checkDuplicateProducts((List<Product2>) newRecords, null);
    }
    
    public override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {
        for (Product2 prod : (List<Product2>) newRecords) {
            prod.Item_Id__c = (String.isNotBlank(prod.Name) && String.isNotBlank(prod.ProductCode)) ? (prod.Name + '-' + prod.ProductCode) : '';
        }
        Product2Service.checkDuplicateProducts((List<Product2>) newRecords, (Map<Id, Product2>) oldMap);
    }

    public override void afterInsert(List<SObject> newRecords, Map<Id, SObject> newMap) {
        Product2Service.syncProductsToItems((List<Product2>) newRecords, null);
    }
    
    public override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {
        Product2Service.syncProductsToItems((List<Product2>) newRecords, (Map<Id, Product2>) oldMap);
    }
}