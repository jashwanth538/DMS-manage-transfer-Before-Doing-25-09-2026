trigger OrderTrigger on Order (after insert, after update) {
    new OrderTriggerHandler().run();
}