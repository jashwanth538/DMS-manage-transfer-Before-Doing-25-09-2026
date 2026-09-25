public without sharing class InventoryTransferStatusService {
// 
//     /*
//      * ============================================================
//      * Recursion Protection
//      *
//      * Inventory Transfer
//      *      ↓
//      * OALI update
//      *      ↓
//      * OALI Trigger
//      *      ↓
//      * Order Allocation Status Service
//      * ============================================================
//      */
//     private static Boolean isProcessing = false;
// 
// 
//     /**
//      * Handles Inventory Transfer status changes.
//      *
//      * Status Flow:
//      *
//      * Requested
//      *      ↓
//      * In Transit
//      *      ↓
//      * OALI = Shipped
//      *      ↓
//      * Received
//      *      ↓
//      * OALI = Delivered
//      *      ↓
//      * OA = Delivered
//      *      when all active OALIs are Delivered
//      *
//      * Supported scenarios:
//      * - Retailer → Retailer
//      * - Retailer → Dealer
//      * - Dealer → Retailer
//      * - Dealer → Dealer
//      */
//     public static void handleStatusChange(
//         List<Inventory_Transfer__c> newRecords,
//         Map<Id, Inventory_Transfer__c> oldMap
//     ) {
// 
//         if (
//             isProcessing ||
//             newRecords == null ||
//             newRecords.isEmpty() ||
//             oldMap == null
//         ) {
//             return;
//         }
// 
// 
//         Set<Id> transferIds = new Set<Id>();
// 
// 
//         /*
//          * ============================================================
//          * STEP 1
//          * Find Inventory Transfers whose Status changed.
//          * ============================================================
//          */
//         for (Inventory_Transfer__c newTransfer : newRecords) {
// 
//             if (
//                 newTransfer == null ||
//                 newTransfer.Id == null
//             ) {
//                 continue;
//             }
// 
// 
//             Inventory_Transfer__c oldTransfer =
//                 oldMap.get(newTransfer.Id);
// 
// 
//             if (oldTransfer == null) {
//                 continue;
//             }
// 
// 
//             /*
//              * Process only when Status actually changed.
//              */
//             if (
//                 newTransfer.Status__c ==
//                 oldTransfer.Status__c
//             ) {
//                 continue;
//             }
// 
// 
//             /*
//              * Process only these status transitions:
//              *
//              * In Transit → OALI Shipped
//              * Received   → OALI Delivered
//              */
//             if (
//                 newTransfer.Status__c == 'In Transit' ||
//                 newTransfer.Status__c == 'Received'
//             ) {
// 
//                 transferIds.add(newTransfer.Id);
//             }
//         }
// 
// 
//         if (transferIds.isEmpty()) {
//             return;
//         }
// 
// 
//         isProcessing = true;
// 
// 
//         try {
// 
//             updateAllocationStatuses(transferIds);
// 
//         } catch (Exception ex) {
// 
//             System.debug(
//                 LoggingLevel.ERROR,
//                 'InventoryTransferStatusService Error: '
//                 + ex.getMessage()
//                 + ' | Line: '
//                 + ex.getLineNumber()
//             );
// 
//         } finally {
// 
//             isProcessing = false;
//         }
//     }
// 
// 
//     /**
//      * Updates the linked OALI status and
//      * recalculates the parent Sales Allocation status.
//      */
//     private static void updateAllocationStatuses(
//         Set<Id> transferIds
//     ) {
// 
//         if (
//             transferIds == null ||
//             transferIds.isEmpty()
//         ) {
//             return;
//         }
// 
// 
//         /*
//          * ============================================================
//          * STEP 2
//          * Get Inventory Transfer + linked OALI.
//          *
//          * Important:
//          * We use the direct
//          * Order_Allocation_Line_Item__c lookup.
//          *
//          * We do NOT determine the OALI using Account Type,
//          * From Account or To Account.
//          * ============================================================
//          */
//         List<Inventory_Transfer__c> transfers = [
// 
//             SELECT
//                 Id,
//                 Status__c,
//                 From_Account__c,
//                 To_Account__c,
//                 Transfer_Qty__c,
//                 Received_Qty__c,
//                 Order_Allocation_Line_Item__c,
// 
//                 Order_Allocation_Line_Item__r.Id,
//                 Order_Allocation_Line_Item__r.Status__c,
//                 Order_Allocation_Line_Item__r.Order_Allocation__c
// 
//             FROM Inventory_Transfer__c
//             WHERE Id IN :transferIds
//         ];
// 
// 
//         if (transfers.isEmpty()) {
//             return;
//         }
// 
// 
//         /*
//          * OALI records that need to be updated.
//          *
//          * Map prevents duplicate updates if multiple
//          * Inventory Transfers reference the same OALI.
//          */
//         Map<Id, Order_Allocation_Line_Item__c> oalisToUpdate =
//             new Map<Id, Order_Allocation_Line_Item__c>();
// 
// 
//         /*
//          * Parent Sales Allocation IDs
//          * that need status recalculation.
//          */
//         Set<Id> oaIdsToProcess =
//             new Set<Id>();
// 
// 
//         /*
//          * ============================================================
//          * STEP 3
//          * Process every Inventory Transfer.
//          * ============================================================
//          */
//         for (
//             Inventory_Transfer__c transfer :
//             transfers
//         ) {
// 
//             /*
//              * Inventory Transfer must have
//              * a linked OALI.
//              */
//             if (
//                 transfer.Order_Allocation_Line_Item__c == null
//             ) {
// 
//                 System.debug(
//                     LoggingLevel.WARN,
//                     'Inventory Transfer '
//                     + transfer.Id
//                     + ' has no OALI lookup.'
//                 );
// 
//                 continue;
//             }
// 
// 
//             Order_Allocation_Line_Item__c oali =
//                 transfer.Order_Allocation_Line_Item__r;
// 
// 
//             if (oali == null) {
//                 continue;
//             }
// 
// 
//             /*
//              * ========================================================
//              * IN TRANSIT
//              * ========================================================
//              *
//              * Inventory Transfer:
//              *     Requested → In Transit
//              *
//              * Result:
//              *     OALI → Shipped
//              *
//              * Delivered OALI is never moved backwards.
//              */
//             if (
//                 transfer.Status__c == 'In Transit'
//             ) {
// 
//                 if (
//                     oali.Status__c != 'Delivered' &&
//                     oali.Status__c != 'Shipped'
//                 ) {
// 
//                     oalisToUpdate.put(
//                         oali.Id,
//                         new Order_Allocation_Line_Item__c(
//                             Id = oali.Id,
//                             Status__c = 'Shipped'
//                         )
//                     );
//                 }
//             }
// 
// 
//             /*
//              * ========================================================
//              * RECEIVED
//              * ========================================================
//              *
//              * Inventory Transfer:
//              *     In Transit → Received
//              *
//              * Result:
//              *     OALI → Delivered
//              */
//             else if (
//                 transfer.Status__c == 'Received'
//             ) {
// 
//                 if (
//                     oali.Status__c != 'Delivered'
//                 ) {
// 
//                     oalisToUpdate.put(
//                         oali.Id,
//                         new Order_Allocation_Line_Item__c(
//                             Id = oali.Id,
//                             Status__c = 'Delivered'
//                         )
//                     );
//                 }
//             }
// 
// 
//             /*
//              * ========================================================
//              * STEP 4
//              * Collect parent Sales Allocation.
//              * ========================================================
//              */
//             if (
//                 oali.Order_Allocation__c != null
//             ) {
// 
//                 oaIdsToProcess.add(
//                     oali.Order_Allocation__c
//                 );
//             }
//         }
// 
// 
//         /*
//          * ============================================================
//          * STEP 5
//          * Update OALI.
//          * ============================================================
//          */
//         if (
//             !oalisToUpdate.isEmpty()
//         ) {
// 
//             List<Order_Allocation_Line_Item__c> oaliList =
//                 oalisToUpdate.values();
// 
// 
//             Database.SaveResult[] results =
//                 Database.update(
//                     oaliList,
//                     false
//                 );
// 
// 
//             for (
//                 Integer i = 0;
//                 i < results.size();
//                 i++
//             ) {
// 
//                 Database.SaveResult result =
//                     results[i];
// 
// 
//                 if (
//                     !result.isSuccess()
//                 ) {
// 
//                     for (
//                         Database.Error err :
//                         result.getErrors()
//                     ) {
// 
//                         System.debug(
//                             LoggingLevel.ERROR,
//                             'InventoryTransferStatusService - '
//                             + 'OALI Update Failed. '
//                             + 'OALI Id: '
//                             + oaliList[i].Id
//                             + ' | Error: '
//                             + err.getStatusCode()
//                             + ' | '
//                             + err.getMessage()
//                         );
//                     }
//                 }
//             }
//         }
// 
// 
//         /*
//          * ============================================================
//          * STEP 6
//          * Recalculate parent Sales Allocation status.
//          *
//          * OrderAllocationStatusService evaluates all active OALIs
//          * under the parent OA.
//          *
//          * Expected:
//          *
//          * All Delivered
//          *       ↓
//          * OA = Delivered
//          *
//          * All Shipped/Delivered
//          *       ↓
//          * OA = Shipped
//          *
//          * Ready to Ship/Shipped/Delivered
//          *       ↓
//          * OA = Ready to Ship
//          * ============================================================
//          */
//         if (
//             !oaIdsToProcess.isEmpty()
//         ) {
// 
//             OrderAllocationStatusService.processStatus(
//                 new Set<Id>(),
//                 oaIdsToProcess
//             );
//         }
//     }
}