trigger OrderItemTrigger on OrderItem (before insert) {
    if (Trigger.isBefore && Trigger.isInsert) {
        OrderItemTriggerHandler.handleBeforeInsert(Trigger.new);
    }
}