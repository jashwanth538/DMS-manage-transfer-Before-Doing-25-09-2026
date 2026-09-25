public without sharing class OrderAllocationStatusInvocable {

    public class Request {

        @InvocableVariable(
            label='OALI Record ID'
            description='ID of Order Allocation Line Item'
        )
        public Id oaliId;

        @InvocableVariable(
            label='OA Record ID'
            description='ID of Order Allocation'
        )
        public Id oaId;
    }

    @InvocableMethod(
        label='Process OALI and OA Status'
        description='Updates OALI to Ready to Ship when Remaining Qty is zero and updates OA when all OALI are Ready to Ship.'
    )
    public static void processRecords(List<Request> requests) {

        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> oaliIds = new Set<Id>();
        Set<Id> oaIds = new Set<Id>();

        /*
         * STEP 0
         * Collect OALI and OA IDs from the Invocable requests.
         */
        for (Request req : requests) {

            if (req == null) {
                continue;
            }

            if (req.oaliId != null) {

                if (
                    req.oaliId.getSObjectType() ==
                    Order_Allocation_Line_Item__c.SObjectType
                ) {
                    oaliIds.add(req.oaliId);

                } else if (
                    req.oaliId.getSObjectType() ==
                    Order_Allocation__c.SObjectType
                ) {
                    oaIds.add(req.oaliId);
                }
            }

            if (req.oaId != null) {

                if (
                    req.oaId.getSObjectType() ==
                    Order_Allocation__c.SObjectType
                ) {
                    oaIds.add(req.oaId);

                } else if (
                    req.oaId.getSObjectType() ==
                    Order_Allocation_Line_Item__c.SObjectType
                ) {
                    oaliIds.add(req.oaId);
                }
            }
        }

        if (oaliIds.isEmpty() && oaIds.isEmpty()) {

            System.debug(
                'OrderAllocationStatusInvocable: No valid OALI or OA IDs provided.'
            );

            return;
        }

        /*
         * STEP 1
         * Get OALI records with quantity fields.
         */
        List<Order_Allocation_Line_Item__c> oaliList =
            new List<Order_Allocation_Line_Item__c>();

        if (!oaliIds.isEmpty()) {

            oaliList = [
                SELECT
                    Id,
                    Status__c,
                    Ordered_Qty__c,
                    Reserved_Quantity__c,
                    Transfer_Qty_Received__c,
                    Procurement_Qty_Received__c,
                    Remaining_Qty__c,
                    Ready_to_Ship_Date__c,
                    Order_Allocation__c,
                    Order_Allocation__r.Status__c
                FROM Order_Allocation_Line_Item__c
                WHERE Id IN :oaliIds
            ];
        }

        /*
         * Add parent OA IDs from OALI records.
         */
        for (Order_Allocation_Line_Item__c oali : oaliList) {

            if (oali.Order_Allocation__c != null) {
                oaIds.add(oali.Order_Allocation__c);
            }
        }

        /*
         * STEP 2
         * Update OALI:
         *
         * Planned / Confirmed / Draft / Awaiting Inventory
         * +
         * Remaining Qty <= 0
         * =
         * Ready to Ship
         */
        List<Order_Allocation_Line_Item__c> oaliToUpdate =
            new List<Order_Allocation_Line_Item__c>();

        Set<String> terminalOaliStatuses =
            new Set<String>{
                'Ready to Ship',
                'Shipped',
                'Delivered',
                'Closed',
                'Cancelled'
            };

        Set<String> validConfirmedStatuses =
            new Set<String>{
                'Confirmed Planning',
                'Confirmed Planned',
                'Confirmed',
                'Planned',
                'Draft',
                'Awaiting Inventory'
            };

        for (Order_Allocation_Line_Item__c oali : oaliList) {

            /*
             * Ignore OALIs already at a later/terminal status.
             */
            if (terminalOaliStatuses.contains(oali.Status__c)) {
                continue;
            }

            /*
             * Only process planned/confirmed/draft statuses.
             */
            Boolean isConfirmedPlanned =
                validConfirmedStatuses.contains(oali.Status__c);

            if (!isConfirmedPlanned) {
                continue;
            }

            Decimal ordered =
                oali.Ordered_Qty__c != null
                ? oali.Ordered_Qty__c
                : 0;

            Decimal reserved =
                oali.Reserved_Quantity__c != null
                ? oali.Reserved_Quantity__c
                : 0;

            Decimal transferRecv =
                oali.Transfer_Qty_Received__c != null
                ? oali.Transfer_Qty_Received__c
                : 0;

            Decimal procRecv =
                oali.Procurement_Qty_Received__c != null
                ? oali.Procurement_Qty_Received__c
                : 0;

            Decimal calculatedRemaining =
                ordered -
                (reserved + transferRecv + procRecv);

            Boolean isFulfilled =
                (
                    oali.Remaining_Qty__c != null &&
                    oali.Remaining_Qty__c <= 0
                )
                ||
                (
                    ordered > 0 &&
                    calculatedRemaining <= 0
                );

            if (isFulfilled) {

                Order_Allocation_Line_Item__c updateOali =
                    new Order_Allocation_Line_Item__c(
                        Id = oali.Id,
                        Status__c = 'Ready to Ship',
                        Ready_to_Ship_Date__c = System.now()
                    );

                oaliToUpdate.add(updateOali);
            }
        }

        /*
         * Update OALI records.
         */
        if (!oaliToUpdate.isEmpty()) {

            Database.SaveResult[] oaliResults =
                Database.update(oaliToUpdate, false);

            for (Database.SaveResult result : oaliResults) {

                if (!result.isSuccess()) {

                    for (Database.Error error : result.getErrors()) {

                        System.debug(
                            'OALI Update Error: ' +
                            error.getStatusCode() +
                            ' - ' +
                            error.getMessage()
                        );
                    }
                }
            }
        }

        /*
         * STEP 3
         * Get ALL active OALIs for the parent OA.
         *
         * Cancelled OALIs are excluded.
         */
        if (oaIds.isEmpty()) {
            return;
        }

        List<Order_Allocation_Line_Item__c> allActiveOaliList = [
            SELECT
                Id,
                Status__c,
                Order_Allocation__c
            FROM Order_Allocation_Line_Item__c
            WHERE Order_Allocation__c IN :oaIds
            AND Status__c != 'Cancelled'
        ];

        /*
         * Counters for each parent OA.
         */
        Map<Id, Integer> totalActiveCountMap =
            new Map<Id, Integer>();

        Map<Id, Integer> readyToShipCountMap =
            new Map<Id, Integer>();

        Map<Id, Integer> shippedCountMap =
            new Map<Id, Integer>();

        Map<Id, Integer> deliveredCountMap =
            new Map<Id, Integer>();

        for (Id oaId : oaIds) {

            totalActiveCountMap.put(oaId, 0);
            readyToShipCountMap.put(oaId, 0);
            shippedCountMap.put(oaId, 0);
            deliveredCountMap.put(oaId, 0);
        }

        /*
         * Count OALI statuses.
         */
        for (
            Order_Allocation_Line_Item__c oali :
            allActiveOaliList
        ) {

            Id oaId = oali.Order_Allocation__c;

            totalActiveCountMap.put(
                oaId,
                totalActiveCountMap.get(oaId) + 1
            );

            if (oali.Status__c == 'Ready to Ship') {

                readyToShipCountMap.put(
                    oaId,
                    readyToShipCountMap.get(oaId) + 1
                );

            } else if (oali.Status__c == 'Shipped') {

                shippedCountMap.put(
                    oaId,
                    shippedCountMap.get(oaId) + 1
                );

            } else if (oali.Status__c == 'Delivered') {

                deliveredCountMap.put(
                    oaId,
                    deliveredCountMap.get(oaId) + 1
                );
            }
        }

        /*
         * STEP 4
         * Get parent Order Allocations.
         */
        List<Order_Allocation__c> oaList = [
            SELECT
                Id,
                Status__c,
                Shipped_Date__c,
                Ready_to_Ship_Date__c
            FROM Order_Allocation__c
            WHERE Id IN :oaIds
        ];

        List<Order_Allocation__c> oaToUpdate =
            new List<Order_Allocation__c>();

        /*
         * STEP 5
         * Parent OA Status Logic.
         *
         * Status rollup hierarchy:
         * 1. If ALL active OALIs are 'Delivered' -> Parent OA becomes 'Delivered'.
         * 2. If ALL active OALIs are 'Shipped' or 'Delivered' -> Parent OA becomes 'Shipped'.
         * 3. If ALL active OALIs are 'Ready to Ship', 'Shipped', or 'Delivered' -> Parent OA becomes 'Ready to Ship'.
         */
        Set<String> oaTerminalStatuses = new Set<String>{
            'Closed',
            'Cancelled'
        };

        for (Order_Allocation__c oa : oaList) {

            Integer totalActive =
                totalActiveCountMap.get(oa.Id);

            Integer readyCount =
                readyToShipCountMap.get(oa.Id);

            Integer shippedCount =
                shippedCountMap.get(oa.Id);

            Integer deliveredCount =
                deliveredCountMap.get(oa.Id);

            System.debug(
                'Processing OA [' +
                oa.Id +
                '] Current Status: ' +
                oa.Status__c +
                ' | Total Active OALIs: ' +
                totalActive +
                ' | Ready: ' +
                readyCount +
                ' | Shipped: ' +
                shippedCount +
                ' | Delivered: ' +
                deliveredCount
            );

            if (totalActive == null || totalActive == 0) {
                continue;
            }

            if (oaTerminalStatuses.contains(oa.Status__c)) {
                continue;
            }

            String targetStatus = null;

            if (deliveredCount == totalActive) {
                targetStatus = 'Delivered';
            } else if ((shippedCount + deliveredCount) == totalActive) {
                targetStatus = 'Shipped';
            } else if ((readyCount + shippedCount + deliveredCount) == totalActive) {
                targetStatus = 'Ready to Ship';
            }

            if (targetStatus == null) {
                System.debug(
                    'OA [' +
                    oa.Id +
                    '] NOT updated. OALIs are not all Ready to Ship / Shipped / Delivered.'
                );
                continue;
            }

            Boolean shouldUpdate = false;

            if (targetStatus == 'Delivered' && oa.Status__c != 'Delivered') {
                shouldUpdate = true;
            } else if (
                targetStatus == 'Shipped' &&
                oa.Status__c != 'Shipped' &&
                oa.Status__c != 'Delivered'
            ) {
                shouldUpdate = true;
            } else if (
                targetStatus == 'Ready to Ship' &&
                oa.Status__c != 'Ready to Ship' &&
                oa.Status__c != 'Shipped' &&
                oa.Status__c != 'Delivered'
            ) {
                shouldUpdate = true;
            }

            if (shouldUpdate) {
                Order_Allocation__c updateOA =
                    new Order_Allocation__c(
                        Id = oa.Id,
                        Status__c = targetStatus
                    );

                if (
                    targetStatus == 'Ready to Ship' ||
                    targetStatus == 'Shipped' ||
                    targetStatus == 'Delivered'
                ) {
                    if (oa.Ready_to_Ship_Date__c == null) {
                        updateOA.Ready_to_Ship_Date__c = Date.today();
                    }
                }

                if (
                    targetStatus == 'Shipped' ||
                    targetStatus == 'Delivered'
                ) {
                    if (oa.Shipped_Date__c == null) {
                        updateOA.Shipped_Date__c = Date.today();
                    }
                }

                oaToUpdate.add(updateOA);

                System.debug(
                    'OA [' +
                    oa.Id +
                    '] status updated from ' +
                    oa.Status__c +
                    ' to ' +
                    targetStatus
                );

            } else {
                System.debug(
                    'OA [' +
                    oa.Id +
                    '] status update not needed. Current Status=' +
                    oa.Status__c +
                    ' | Target Status=' +
                    targetStatus
                );
            }
        }

        /*
         * STEP 6
         * Update Parent OAs.
         */
        if (!oaToUpdate.isEmpty()) {

            Database.SaveResult[] oaResults =
                Database.update(oaToUpdate, false);

            for (Database.SaveResult result : oaResults) {

                if (!result.isSuccess()) {

                    for (Database.Error error : result.getErrors()) {

                        System.debug(
                            LoggingLevel.ERROR,
                            'OA Update Error: ' +
                            error.getStatusCode() +
                            ' - ' +
                            error.getMessage()
                        );
                    }

                } else {

                    System.debug(
                        LoggingLevel.INFO,
                        'OA Status successfully updated: ' +
                        result.getId()
                    );
                }
            }
        }
    }
}