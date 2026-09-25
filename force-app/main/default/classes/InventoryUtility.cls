public with sharing class InventoryUtility {
    public static String generateReplenishmentKey(Id itemId, Id locationId, String requestType) {
        return String.valueOf(itemId) + '_' + String.valueOf(locationId) + '_' + requestType;
    }

    public static String generateReplenishmentKey(Id itemId, Id locationId, Id accountId, String requestType) {
        return String.valueOf(itemId) + '_' + String.valueOf(locationId) + '_' + String.valueOf(accountId) + '_' + requestType;
    }
}