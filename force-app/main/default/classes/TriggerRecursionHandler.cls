public with sharing class TriggerRecursionHandler {
    private static Set<String> executedActions = new Set<String>();

    public static Boolean hasRun(String actionName) {
        return executedActions.contains(actionName);
    }

    public static void markRun(String actionName) {
        executedActions.add(actionName);
    }
    
    public static void reset(String actionName) {
        executedActions.remove(actionName);
    }
}