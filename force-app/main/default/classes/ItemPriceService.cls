/**
 * @description Enterprise-grade, bulkified service for resolving and defaulting Item Prices,
 *              Discount Percentages, and Tax Percentages from Item_Price__c master records for:
 *              - Order Line Items (OLI)
 *              - Order Allocation Line Items (OALI)
 *              - Purchase Order Line Items (POLI)
 * 
 * Business Rules:
 * 1. Never overwrite an existing transaction Unit Price, Discount %, or Tax %.
 * 2. If Unit Price is null/blank, resolve from active Item_Price__c using:
 *    - Item_Price_Account__c (Supplying / Selling Account)
 *    - Item__c (Item record)
 *    - Inventory_Location__c (Source Inventory Location)
 *    - Active__c = TRUE
 * 3. Also default Discount % and Tax % from Item_Price__c if not already populated on the line item.
 * 4. Validate against duplicates and missing prices:
 *    - If no active price exists -> "Active Item Price is not configured for this Account, Item, and Inventory Location."
 *    - If multiple active prices exist -> "Multiple active Item Price records exist for this Account, Item, and Inventory Location."
 */
public with sharing class ItemPriceService {

    public class PriceResolutionResult {
        public Decimal unitPrice;
        public Decimal discountPercent;
        public Decimal taxPercent;
        public Boolean isSuccess;
        public String errorMessage;

        public PriceResolutionResult(Decimal unitPrice, Decimal discountPercent, Decimal taxPercent) {
            this.unitPrice = unitPrice;
            this.discountPercent = discountPercent;
            this.taxPercent = taxPercent;
            this.isSuccess = true;
            this.errorMessage = null;
        }

        public PriceResolutionResult(String errorMessage) {
            this.unitPrice = null;
            this.discountPercent = null;
            this.taxPercent = null;
            this.isSuccess = false;
            this.errorMessage = errorMessage;
        }
    }

    /**
     * @description Applies fallback pricing, discount %, and tax % to Order_Allocation_Line_Item__c records in before-insert trigger.
     *              Preserves existing prices and resolves missing values from parent Order_Allocation__c
     *              Supplying Account and Source Location.
     */
    public static void applyOALIPricing(List<Order_Allocation_Line_Item__c> oaliList) {
        if (oaliList == null || oaliList.isEmpty()) {
            return;
        }

        // 1. Identify OALIs that require price/discount/tax resolution
        List<Order_Allocation_Line_Item__c> oalisNeedingPrice = new List<Order_Allocation_Line_Item__c>();
        Set<Id> parentOaIds = new Set<Id>();

        for (Order_Allocation_Line_Item__c oali : oaliList) {
            if (oali.Unit_Price__c == null || oali.Discount_Percent__c == null || oali.Tax__c == null) {
                oalisNeedingPrice.add(oali);
                if (oali.Order_Allocation__c != null) {
                    parentOaIds.add(oali.Order_Allocation__c);
                }
            }
        }

        if (oalisNeedingPrice.isEmpty()) {
            return;
        }

        // 2. Query parent Order_Allocation__c records in bulk
        Map<Id, Order_Allocation__c> parentOaMap = new Map<Id, Order_Allocation__c>();
        if (!parentOaIds.isEmpty()) {
            parentOaMap = new Map<Id, Order_Allocation__c>([
                SELECT Id, Supplying_Account__c, Source_Location__c
                FROM Order_Allocation__c
                WHERE Id IN :parentOaIds
            ]);
        }

        // 3. Collect account, item, and location IDs
        Set<Id> accountIds = new Set<Id>();
        Set<Id> itemIds = new Set<Id>();
        Set<Id> locationIds = new Set<Id>();

        for (Order_Allocation_Line_Item__c oali : oalisNeedingPrice) {
            Order_Allocation__c parentOa = oali.Order_Allocation__c != null ? parentOaMap.get(oali.Order_Allocation__c) : null;
            Id supplyingAccId = parentOa != null ? parentOa.Supplying_Account__c : null;
            Id sourceLocId = parentOa != null ? parentOa.Source_Location__c : null;
            Id itemId = oali.Item__c;

            if (supplyingAccId != null) accountIds.add(supplyingAccId);
            if (itemId != null) itemIds.add(itemId);
            if (sourceLocId != null) locationIds.add(sourceLocId);
        }

        // 4. Resolve prices in bulk
        Map<String, PriceResolutionResult> priceMap = getPricesBulk(accountIds, itemIds, locationIds);

        // 5. Apply resolved prices, discount, tax or add validation errors
        for (Order_Allocation_Line_Item__c oali : oalisNeedingPrice) {
            Order_Allocation__c parentOa = oali.Order_Allocation__c != null ? parentOaMap.get(oali.Order_Allocation__c) : null;
            Id supplyingAccId = parentOa != null ? parentOa.Supplying_Account__c : null;
            Id sourceLocId = parentOa != null ? parentOa.Source_Location__c : null;
            Id itemId = oali.Item__c;

            if (supplyingAccId == null || sourceLocId == null || itemId == null) {
                if (oali.Unit_Price__c == null) {
                    oali.addError('Active Item Price is not configured for this Account, Item, and Inventory Location.');
                }
                continue;
            }

            String lookupKey = buildKey(supplyingAccId, itemId, sourceLocId);
            PriceResolutionResult result = priceMap.get(lookupKey);

            if (result == null || !result.isSuccess) {
                if (oali.Unit_Price__c == null) {
                    String errorMsg = (result != null && result.errorMessage != null)
                        ? result.errorMessage
                        : 'Active Item Price is not configured for this Account, Item, and Inventory Location.';
                    oali.addError(errorMsg);
                }
            } else {
                if (oali.Unit_Price__c == null) {
                    oali.Unit_Price__c = result.unitPrice;
                }
                if (oali.Discount_Percent__c == null && result.discountPercent != null) {
                    oali.Discount_Percent__c = result.discountPercent;
                }
                if (oali.Tax__c == null && result.taxPercent != null) {
                    oali.Tax__c = result.taxPercent;
                }
            }
        }
    }

    /**
     * @description Applies fallback pricing, discount %, and tax % to Purchase_Order_Line_Item__c records in before-insert trigger.
     *              Resolves missing values from parent Purchase_Order__c Supplying Account and Source Location.
     */
    public static void applyPOLIPricing(List<Purchase_Order_Line_Item__c> poliList) {
        if (poliList == null || poliList.isEmpty()) {
            return;
        }

        // 1. Identify POLIs that require price/discount/tax resolution
        List<Purchase_Order_Line_Item__c> polisNeedingPrice = new List<Purchase_Order_Line_Item__c>();
        Set<Id> parentPoIds = new Set<Id>();

        for (Purchase_Order_Line_Item__c poli : poliList) {
            if (poli.Unit_Price__c == null || poli.Discount__c == null || poli.Tax__c == null) {
                polisNeedingPrice.add(poli);
                if (poli.Purchase_Order__c != null) {
                    parentPoIds.add(poli.Purchase_Order__c);
                }
            }
        }

        if (polisNeedingPrice.isEmpty()) {
            return;
        }

        // 2. Query parent Purchase_Order__c records in bulk
        Map<Id, Purchase_Order__c> parentPoMap = new Map<Id, Purchase_Order__c>();
        if (!parentPoIds.isEmpty()) {
            parentPoMap = new Map<Id, Purchase_Order__c>([
                SELECT Id, Supplying_Account__c, Source_Location__c
                FROM Purchase_Order__c
                WHERE Id IN :parentPoIds
            ]);
        }

        // 3. Collect account, item, and location IDs
        Set<Id> accountIds = new Set<Id>();
        Set<Id> itemIds = new Set<Id>();
        Set<Id> locationIds = new Set<Id>();

        for (Purchase_Order_Line_Item__c poli : polisNeedingPrice) {
            Purchase_Order__c parentPo = poli.Purchase_Order__c != null ? parentPoMap.get(poli.Purchase_Order__c) : null;
            Id supplyingAccId = parentPo != null ? parentPo.Supplying_Account__c : null;
            Id sourceLocId = parentPo != null ? parentPo.Source_Location__c : null;
            Id itemId = poli.Item__c;

            if (supplyingAccId != null) accountIds.add(supplyingAccId);
            if (itemId != null) itemIds.add(itemId);
            if (sourceLocId != null) locationIds.add(sourceLocId);
        }

        // 4. Resolve prices in bulk
        Map<String, PriceResolutionResult> priceMap = getPricesBulk(accountIds, itemIds, locationIds);

        // 5. Apply resolved values or add validation errors
        for (Purchase_Order_Line_Item__c poli : polisNeedingPrice) {
            Purchase_Order__c parentPo = poli.Purchase_Order__c != null ? parentPoMap.get(poli.Purchase_Order__c) : null;
            Id supplyingAccId = parentPo != null ? parentPo.Supplying_Account__c : null;
            Id sourceLocId = parentPo != null ? parentPo.Source_Location__c : null;
            Id itemId = poli.Item__c;

            if (supplyingAccId == null || sourceLocId == null || itemId == null) {
                if (poli.Unit_Price__c == null) {
                    poli.addError('Active Item Price is not configured for this Account, Item, and Inventory Location.');
                }
                continue;
            }

            String lookupKey = buildKey(supplyingAccId, itemId, sourceLocId);
            PriceResolutionResult result = priceMap.get(lookupKey);

            if (result == null || !result.isSuccess) {
                if (poli.Unit_Price__c == null) {
                    String errorMsg = (result != null && result.errorMessage != null)
                        ? result.errorMessage
                        : 'Active Item Price is not configured for this Account, Item, and Inventory Location.';
                    poli.addError(errorMsg);
                }
            } else {
                if (poli.Unit_Price__c == null) {
                    poli.Unit_Price__c = result.unitPrice;
                }
                if (poli.Discount__c == null && result.discountPercent != null) {
                    poli.Discount__c = result.discountPercent;
                }
                if (poli.Tax__c == null && result.taxPercent != null) {
                    poli.Tax__c = result.taxPercent;
                }
            }
        }
    }

    /**
     * @description Applies fallback pricing to standard OrderItem records in before-insert trigger.
     */
    public static void applyOrderItemPricing(List<OrderItem> orderItemList) {
        if (orderItemList == null || orderItemList.isEmpty()) {
            return;
        }

        // 1. Identify OrderItems that require price resolution
        List<OrderItem> itemsNeedingPrice = new List<OrderItem>();
        Set<Id> orderIds = new Set<Id>();
        Set<Id> pbeIds = new Set<Id>();

        for (OrderItem oi : orderItemList) {
            if (oi.UnitPrice == null || oi.UnitPrice <= 0) {
                itemsNeedingPrice.add(oi);
                if (oi.OrderId != null) orderIds.add(oi.OrderId);
                if (oi.PricebookEntryId != null) pbeIds.add(oi.PricebookEntryId);
            }
        }

        if (itemsNeedingPrice.isEmpty()) {
            return;
        }

        // 2. Query parent Order records to get Account
        Map<Id, Order> orderMap = new Map<Id, Order>();
        if (!orderIds.isEmpty()) {
            orderMap = new Map<Id, Order>([
                SELECT Id, AccountId
                FROM Order
                WHERE Id IN :orderIds
            ]);
        }

        Set<Id> accountIds = new Set<Id>();
        for (Order ord : orderMap.values()) {
            if (ord.AccountId != null) accountIds.add(ord.AccountId);
        }

        Map<Id, Id> accToLocationMap = new Map<Id, Id>();
        if (!accountIds.isEmpty()) {
            for (Inventory_Location__c loc : [
                SELECT Id, Account__c 
                FROM Inventory_Location__c 
                WHERE Account__c IN :accountIds AND Is_Active__c = true
                ORDER BY CreatedDate ASC
            ]) {
                if (!accToLocationMap.containsKey(loc.Account__c)) {
                    accToLocationMap.put(loc.Account__c, loc.Id);
                }
            }
        }

        Set<Id> itemIds = new Set<Id>();
        Set<Id> locationIds = new Set<Id>(accToLocationMap.values());

        Map<Id, Id> oiToItemMap = new Map<Id, Id>();
        for (OrderItem oi : itemsNeedingPrice) {
            Id itemId = null;
            try {
                itemId = (Id) oi.get('Item__c');
            } catch (Exception e) {
                // Fallback
            }
            if (itemId != null) {
                oiToItemMap.put(oi.Id != null ? oi.Id : (Id)oi.PricebookEntryId, itemId);
                itemIds.add(itemId);
            }
        }

        Map<String, PriceResolutionResult> priceMap = getPricesBulk(accountIds, itemIds, locationIds);

        for (OrderItem oi : itemsNeedingPrice) {
            Order ord = oi.OrderId != null ? orderMap.get(oi.OrderId) : null;
            Id accId = ord != null ? ord.AccountId : null;
            Id locId = accId != null ? accToLocationMap.get(accId) : null;
            Id itemId = oiToItemMap.get(oi.Id != null ? oi.Id : (Id)oi.PricebookEntryId);

            if (accId == null || locId == null || itemId == null) {
                oi.addError('Active Item Price is not configured for this Account, Item, and Inventory Location.');
                continue;
            }

            String lookupKey = buildKey(accId, itemId, locId);
            PriceResolutionResult result = priceMap.get(lookupKey);

            if (result == null || !result.isSuccess) {
                String errorMsg = (result != null && result.errorMessage != null)
                    ? result.errorMessage
                    : 'Active Item Price is not configured for this Account, Item, and Inventory Location.';
                oi.addError(errorMsg);
            } else {
                oi.UnitPrice = result.unitPrice;
            }
        }
    }

    /**
     * @description Direct single price resolution helper for on-demand use.
     */
    public static Decimal resolvePrice(Id accountId, Id itemId, Id locationId) {
        PriceResolutionResult res = resolveFullPricing(accountId, itemId, locationId);
        return res.unitPrice;
    }

    /**
     * @description Direct single full pricing resolution helper returning price, discount %, and tax %.
     */
    public static PriceResolutionResult resolveFullPricing(Id accountId, Id itemId, Id locationId) {
        if (accountId == null || itemId == null || locationId == null) {
            throw new AuraHandledException('Active Item Price is not configured for this Account, Item, and Inventory Location.');
        }

        Map<String, PriceResolutionResult> resultMap = getPricesBulk(
            new Set<Id>{ accountId },
            new Set<Id>{ itemId },
            new Set<Id>{ locationId }
        );

        String lookupKey = buildKey(accountId, itemId, locationId);
        PriceResolutionResult result = resultMap.get(lookupKey);

        if (result == null || !result.isSuccess) {
            String msg = (result != null && result.errorMessage != null)
                ? result.errorMessage
                : 'Active Item Price is not configured for this Account, Item, and Inventory Location.';
            throw new AuraHandledException(msg);
        }

        return result;
    }

    /**
     * @description Bulk queries Item_Price__c master records and groups them by Account+Item+Location.
     *              Detects and flags duplicate active prices and missing prices.
     */
    public static Map<String, PriceResolutionResult> getPricesBulk(
        Set<Id> accountIds, 
        Set<Id> itemIds, 
        Set<Id> locationIds
    ) {
        Map<String, PriceResolutionResult> resultMap = new Map<String, PriceResolutionResult>();

        if (accountIds.isEmpty() || itemIds.isEmpty() || locationIds.isEmpty()) {
            return resultMap;
        }

        // Query active prices matching the criteria including Discount__c and Tax__c
        List<Item_Price__c> activePrices = [
            SELECT Id, Item_Price_Account__c, Item__c, Inventory_Location__c, Unit_Price__c, Discount__c, Tax__c, Active__c
            FROM Item_Price__c
            WHERE Item_Price_Account__c IN :accountIds
              AND Item__c IN :itemIds
              AND Inventory_Location__c IN :locationIds
              AND Active__c = true
        ];

        Map<String, List<Item_Price__c>> groupedPrices = new Map<String, List<Item_Price__c>>();

        for (Item_Price__c ip : activePrices) {
            String key = buildKey(ip.Item_Price_Account__c, ip.Item__c, ip.Inventory_Location__c);
            if (!groupedPrices.containsKey(key)) {
                groupedPrices.put(key, new List<Item_Price__c>());
            }
            groupedPrices.get(key).add(ip);
        }

        for (String key : groupedPrices.keySet()) {
            List<Item_Price__c> prices = groupedPrices.get(key);
            if (prices.size() > 1) {
                resultMap.put(key, new PriceResolutionResult('Multiple active Item Price records exist for this Account, Item, and Inventory Location.'));
            } else if (prices.size() == 1) {
                Item_Price__c p = prices[0];
                resultMap.put(key, new PriceResolutionResult(p.Unit_Price__c, p.Discount__c, p.Tax__c));
            }
        }

        return resultMap;
    }

    /**
     * @description Builds a standard lookup key from Account, Item, and Inventory Location IDs.
     */
    public static String buildKey(Id accountId, Id itemId, Id locationId) {
        return (accountId != null ? String.valueOf(accountId) : '') + '_' +
               (itemId != null ? String.valueOf(itemId) : '') + '_' +
               (locationId != null ? String.valueOf(locationId) : '');
    }
}