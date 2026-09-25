public with sharing class OrderService {
    
    public static void handleAfterInsert(List<Order> newOrders) {
        Set<Id> activatedOrderIds = new Set<Id>();
        for (Order o : newOrders) {
            if (o.Status == 'Activated') {
                activatedOrderIds.add(o.Id);
            }
        }
        createOrderAllocations(activatedOrderIds);
    }
    
    public static void handleAfterUpdate(List<Order> newOrders, Map<Id, Order> oldMap) {
        Set<Id> activatedOrderIds = new Set<Id>();
        for (Order o : newOrders) {
            Order oldOrder = oldMap.get(o.Id);
            if (o.Status == 'Activated' && (oldOrder == null || oldOrder.Status != 'Activated')) {
                activatedOrderIds.add(o.Id);
            }
        }
        createOrderAllocations(activatedOrderIds);
    }
    
    private static void createOrderAllocations(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return;
        }
        
        if (TriggerRecursionHandler.hasRun('CreateOrderAllocations')) {
            return;
        }
        TriggerRecursionHandler.markRun('CreateOrderAllocations');
        
        // Use Selector Layer
        List<Order> orders = OrderSelector.getOrdersWithItems(orderIds);
        
        // Extract Product2.Item_Id__c from order items to resolve Item__c records
        Set<String> productIds = new Set<String>();
        for (Order o : orders) {
            for (OrderItem oi : o.OrderItems) {
                if (oi.Product2 != null && String.isNotBlank(oi.Product2.Item_Id__c)) {
                    productIds.add(oi.Product2.Item_Id__c);
                }
            }
        }
        
        // Query Item__c records using inline SOQL instead of missing ItemSelector class
        Map<String, Id> itemMap = new Map<String, Id>();
        if (!productIds.isEmpty()) {
            for (Item__c item : [SELECT Id, Product_Id__c FROM Item__c WHERE Product_Id__c IN :productIds]) {
                if (String.isNotBlank(item.Product_Id__c)) {
                    itemMap.put(item.Product_Id__c, item.Id);
                }
            }
        }
        
        // Prepare Order Allocation headers
        List<Order_Allocation__c> allocationsToInsert = new List<Order_Allocation__c>();
        Map<Id, Order_Allocation__c> orderToAllocationMap = new Map<Id, Order_Allocation__c>();
        
        for (Order o : orders) {
            Order_Allocation__c allocation = OrderUtility.buildOrderAllocation(o);
            allocationsToInsert.add(allocation);
            orderToAllocationMap.put(o.Id, allocation);
        }
        
        if (!allocationsToInsert.isEmpty()) {
            insert allocationsToInsert;
        }
        
        // Prepare Order Allocation Line Items
        List<Order_Allocation_Line_Item__c> lineItemsToInsert = new List<Order_Allocation_Line_Item__c>();
        
        for (Order o : orders) {
            Order_Allocation__c allocation = orderToAllocationMap.get(o.Id);
            if (allocation == null || allocation.Id == null) {
                continue;
            }
            
            for (OrderItem oi : o.OrderItems) {
                Order_Allocation_Line_Item__c ali = OrderUtility.buildAllocationLineItem(o, allocation, oi, itemMap);
                lineItemsToInsert.add(ali);
            }
        }
        
        if (!lineItemsToInsert.isEmpty()) {
            insert lineItemsToInsert;
        }
    }
}