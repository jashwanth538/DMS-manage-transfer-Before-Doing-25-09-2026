trigger ItemTrigger on Item__c (before insert, before update, after insert, after update) {
    new ItemTriggerHandler().run();
}