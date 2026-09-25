trigger OrderAllocationLineItemTrigger on Order_Allocation_Line_Item__c (before insert, after update) {
    if (Trigger.isBefore && Trigger.isInsert) {
        OrderAllocationLineItemTriggerHandler.handleBeforeInsert(Trigger.new);
    } else if (Trigger.isAfter && Trigger.isUpdate) {
        OrderAllocationLineItemTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}