public with sharing class OrderItemTriggerHandler {
    
    /**
     * Handles before insert trigger event on OrderItem.
     * Applies fallback pricing logic from Item_Price__c master when UnitPrice is not provided.
     *
     * @param newList List of new OrderItem records
     */
    public static void handleBeforeInsert(List<OrderItem> newList) {
        ItemPriceService.applyOrderItemPricing(newList);
    }
}