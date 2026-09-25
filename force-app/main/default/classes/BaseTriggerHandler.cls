public abstract class BaseTriggerHandler {
    public virtual void beforeInsert(List<SObject> newRecords) {}
    public virtual void afterInsert(List<SObject> newRecords, Map<Id, SObject> newMap) {}
    
    public virtual void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {}
    public virtual void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap, Map<Id, SObject> newMap) {}
    
    public virtual void beforeDelete(List<SObject> oldRecords, Map<Id, SObject> oldMap) {}
    public virtual void afterDelete(Map<Id, SObject> oldMap) {}
    
    public virtual void afterUndelete(List<SObject> newRecords, Map<Id, SObject> newMap) {}

    public void run() {
        if (Trigger.isBefore) {
            if (Trigger.isInsert) {
                beforeInsert(Trigger.new);
            } else if (Trigger.isUpdate) {
                beforeUpdate(Trigger.new, Trigger.oldMap, Trigger.newMap);
            } else if (Trigger.isDelete) {
                beforeDelete(Trigger.old, Trigger.oldMap);
            }
        } else if (Trigger.isAfter) {
            if (Trigger.isInsert) {
                afterInsert(Trigger.new, Trigger.newMap);
            } else if (Trigger.isUpdate) {
                afterUpdate(Trigger.new, Trigger.oldMap, Trigger.newMap);
            } else if (Trigger.isDelete) {
                afterDelete(Trigger.oldMap);
            } else if (Trigger.isUndelete) {
                afterUndelete(Trigger.new, Trigger.newMap);
            }
        }
    }
}