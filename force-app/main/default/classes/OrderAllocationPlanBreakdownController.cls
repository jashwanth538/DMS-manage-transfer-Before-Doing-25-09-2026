public with sharing class OrderAllocationPlanBreakdownController {
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSupplyPlanSummary(String searchTerm) {
        return SupplyPlanController.getSupplyPlanSummary(searchTerm);
    }
}