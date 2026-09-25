trigger Product2Trigger on Product2 (before insert, before update, after insert, after update) {
    new Product2TriggerHandler().run();
}