public without sharing class GRNController {
    /*
    @AuraEnabled(cacheable=true)
    public static LWCServerCalloutWrapper searchPurchaseOrders(String searchTerm) {
        LWCServerCalloutWrapper wrapper = new LWCServerCalloutWrapper();
        try {
            String key = String.isBlank(searchTerm) ? '%' : '%' + searchTerm.trim() + '%';
            wrapper.resultList = [
                SELECT Id, Name, Status__c,
                       Requesting_Account__c, Requesting_Account__r.Name,
                       Supplying_Account__c, Supplying_Account__r.Name,
                       Source_Location__c, Source_Location__r.Name,
                       Target_Location__c, Target_Location__r.Name
                FROM Purchase_Order__c 
                WHERE Name LIKE :key
                  AND Status__c NOT IN ('Closed', 'Cancelled', 'Fully Received', 'Received')
                ORDER BY Name 
                LIMIT 10
            ];
            wrapper.isSuccess = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in searchPurchaseOrders: ' + e.getMessage() + '\n' + e.getStackTraceString());
            AuraHandledException ahe = new AuraHandledException('Error searching Purchase Orders: ' + e.getMessage());
            ahe.setMessage('Error searching Purchase Orders: ' + e.getMessage());
            throw ahe;
        }
        return wrapper;
    }
    
    public class PODetailWrapper {
        @AuraEnabled public Purchase_Order__c po { get; set; }
        @AuraEnabled public List<POLineWrapper> lines { get; set; }
    }
    
    public class POLineWrapper {
        @AuraEnabled public Purchase_Order_Line_Item__c poli { get; set; }
        @AuraEnabled public Decimal previouslyReceivedQty { get; set; }
        @AuraEnabled public Decimal remainingQty { get; set; }
    }
    
    @AuraEnabled(cacheable=false)
    public static LWCServerCalloutWrapper getPurchaseOrderDetails(Id poId) {
        LWCServerCalloutWrapper calloutWrapper = new LWCServerCalloutWrapper();
        try {
            PODetailWrapper wrapper = new PODetailWrapper();
            
            wrapper.po = [
                SELECT Id, Name, Target_Location__c, Target_Location__r.Name,
                       Source_Location__c, Source_Location__r.Name,
                       PO_Date__c, Expected_Date__c, Status__c,
                       Requesting_Account__c, Requesting_Account__r.Name,
                       Supplying_Account__c, Supplying_Account__r.Name
                FROM Purchase_Order__c
                WHERE Id = :poId
                LIMIT 1
            ];
            
            List<Purchase_Order_Line_Item__c> lines = [
                SELECT Id, Name, Purchase_Order__c, Item__c, Item__r.Name, Item__r.Item_Code__c, 
                       Item__r.Item_Description__c, Ordered_Qty__c, Unit_Price__c, Status__c, Previously_Received_Quantity__c
                FROM Purchase_Order_Line_Item__c
                WHERE Purchase_Order__c = :poId
            ];
            
            Map<Id, Decimal> prevReceivedMap = new Map<Id, Decimal>();
            for (AggregateResult ar : [
                SELECT Purchase_Order_Line_Item__c, SUM(Received_Qty__c) totalRec
                FROM GRN_Line_Item__c
                WHERE Purchase_Order_Line_Item__r.Purchase_Order__c = :poId
                  AND GRN__r.Status__c = 'Received'
                GROUP BY Purchase_Order_Line_Item__c
            ]) {
                prevReceivedMap.put((Id)ar.get('Purchase_Order_Line_Item__c'), (Decimal)ar.get('totalRec'));
            }
            
            wrapper.lines = new List<POLineWrapper>();
            for (Purchase_Order_Line_Item__c line : lines) {
                POLineWrapper lw = new POLineWrapper();
                lw.poli = line;
                Decimal prevRec = prevReceivedMap.containsKey(line.Id) ? prevReceivedMap.get(line.Id) : (line.Previously_Received_Quantity__c != null ? line.Previously_Received_Quantity__c : 0);
                lw.previouslyReceivedQty = prevRec;
                Decimal ordQty = line.Ordered_Qty__c != null ? line.Ordered_Qty__c : 0;
                lw.remainingQty = Math.max(0, ordQty - prevRec);
                wrapper.lines.add(lw);
            }
            
            calloutWrapper.result = wrapper;
            calloutWrapper.isSuccess = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in getPurchaseOrderDetails: ' + e.getMessage() + '\n' + e.getStackTraceString());
            AuraHandledException ahe = new AuraHandledException('Error loading Purchase Order: ' + e.getMessage());
            ahe.setMessage('Error loading Purchase Order: ' + e.getMessage());
            throw ahe;
        }
        return calloutWrapper;
    }
    
    @AuraEnabled
    public static LWCServerCalloutWrapper saveGoodsReceipt(GRN__c grn, List<GRN_Line_Item__c> lines) {
        LWCServerCalloutWrapper calloutWrapper = new LWCServerCalloutWrapper();
        try {
            if (grn == null) {
                throw createAuraException('Goods Receipt Note details cannot be empty.');
            }

            if (grn.Purchase_Order__c == null) {
                throw createAuraException('Purchase Order reference is required for GRN receive.');
            }
            
            Purchase_Order__c po = [
                SELECT Id, Target_Location__c, Target_Location__r.Account__c,
                       Source_Location__c, Source_Location__r.Account__c,
                       Requesting_Account__c, Supplying_Account__c, Status__c
                FROM Purchase_Order__c 
                WHERE Id = :grn.Purchase_Order__c
                LIMIT 1
            ];

            // Resolve Target Location (Speed Motors Warehouse / Requesting Location)
            Id targetLocId = po.Target_Location__c;
            if (targetLocId == null && po.Requesting_Account__c != null) {
                List<Inventory_Location__c> reqLocs = [
                    SELECT Id FROM Inventory_Location__c 
                    WHERE Account__c = :po.Requesting_Account__c AND Is_Active__c = true 
                    ORDER BY CreatedDate ASC LIMIT 1
                ];
                if (!reqLocs.isEmpty()) {
                    targetLocId = reqLocs[0].Id;
                }
            }

            // Resolve Source Location (Kumar Traders Location / Supplying Location)
            Id sourceLocId = po.Source_Location__c;
            if (sourceLocId == null && po.Supplying_Account__c != null) {
                List<Inventory_Location__c> suppLocs = [
                    SELECT Id FROM Inventory_Location__c 
                    WHERE Account__c = :po.Supplying_Account__c AND Is_Active__c = true 
                    ORDER BY CreatedDate ASC LIMIT 1
                ];
                if (!suppLocs.isEmpty()) {
                    sourceLocId = suppLocs[0].Id;
                }
            }

            grn.Inventory_Location__c = targetLocId != null ? targetLocId : sourceLocId;
            
            if (po.Requesting_Account__c != null) {
                grn.Requesting_Account__c = po.Requesting_Account__c;
            }
            if (po.Supplying_Account__c != null) {
                grn.Supplying_Account__c = po.Supplying_Account__c;
            }
            
            insert grn;
            
            if (lines != null && !lines.isEmpty()) {
                for (GRN_Line_Item__c line : lines) {
                    line.GRN__c = grn.Id;
                }
                insert lines;
            }
            
            if (grn.Status__c == 'Received' || String.isBlank(grn.Status__c)) {
                grn.Status__c = 'Received';
                processInventoryAndAllocations(grn, lines, po, targetLocId, sourceLocId);
            }
            
            GRN__c insertedGrn = [SELECT Id, Name, Requesting_Account__r.Name FROM GRN__c WHERE Id = :grn.Id LIMIT 1];
            calloutWrapper.result = insertedGrn;
            calloutWrapper.isSuccess = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in saveGoodsReceipt: ' + e.getMessage() + '\n' + e.getStackTraceString());
            String errorMsg = e.getMessage();
            calloutWrapper.isSuccess = false;
            calloutWrapper.errorMsg = errorMsg;
            AuraHandledException ahe = new AuraHandledException(errorMsg);
            ahe.setMessage(errorMsg);
            throw ahe;
        }
        return calloutWrapper;
    }
    
    private static void processInventoryAndAllocations(
        GRN__c grn, 
        List<GRN_Line_Item__c> lines, 
        Purchase_Order__c po, 
        Id targetLocId, 
        Id sourceLocId
    ) {
        if (targetLocId == null && sourceLocId == null) {
            throw createAuraException('The Purchase Order must specify Target or Source Location to receive inventory.');
        }

        if (targetLocId == null) {
            targetLocId = sourceLocId;
        } else if (sourceLocId == null) {
            sourceLocId = targetLocId;
        }

        Set<Id> poliIds = new Set<Id>();
        if (lines != null) {
            for (GRN_Line_Item__c gli : lines) {
                if (gli.Purchase_Order_Line_Item__c != null) {
                    poliIds.add(gli.Purchase_Order_Line_Item__c);
                }
            }
        }

        Map<Id, Purchase_Order_Line_Item__c> poliMap = new Map<Id, Purchase_Order_Line_Item__c>([
            SELECT Id, Item__c, Ordered_Qty__c, Status__c, Purchase_Order__c, Previously_Received_Quantity__c
            FROM Purchase_Order_Line_Item__c
            WHERE Id IN :poliIds
        ]);

        // 1. Accumulate received quantities per item & validate
        Map<Id, Decimal> itemToRecQtyMap = new Map<Id, Decimal>();
        for (GRN_Line_Item__c gli : lines) {
            if (gli.Purchase_Order_Line_Item__c != null && gli.Received_Qty__c != null) {
                if (gli.Received_Qty__c <= 0) {
                    throw createAuraException('GRN received quantity must be greater than zero.');
                }
                Purchase_Order_Line_Item__c poli = poliMap.get(gli.Purchase_Order_Line_Item__c);
                if (poli != null && poli.Item__c != null) {
                    Decimal current = itemToRecQtyMap.containsKey(poli.Item__c) ? itemToRecQtyMap.get(poli.Item__c) : 0;
                    itemToRecQtyMap.put(poli.Item__c, current + gli.Received_Qty__c);
                }
            }
        }

        if (itemToRecQtyMap.isEmpty()) {
            throw createAuraException('No valid received line items found to process.');
        }

        Set<Id> itemIds = itemToRecQtyMap.keySet();

        Id reqAccId = po.Requesting_Account__c;
        Id suppAccId = po.Supplying_Account__c;

        // 2. Query Target (Speed Motors) and Source (Kumar Traders) Inventory records by Location or Account
        List<Inventory__c> existingInventories = [
            SELECT Id, Item__c, Inventory_Location__c, Account__c, Available__c, On_Hand_Qty__c, Transit_In_Quantity__c, Transit_Out_Quantity__c
            FROM Inventory__c
            WHERE Item__c IN :itemIds 
              AND (
                  (Inventory_Location__c != null AND Inventory_Location__c IN (:targetLocId, :sourceLocId))
                  OR (Account__c != null AND Account__c IN (:reqAccId, :suppAccId))
              )
        ];

        Map<String, Inventory__c> invByLocMap = new Map<String, Inventory__c>();
        Map<String, Inventory__c> invByAccMap = new Map<String, Inventory__c>();
        for (Inventory__c inv : existingInventories) {
            if (inv.Inventory_Location__c != null) {
                invByLocMap.put(inv.Inventory_Location__c + '_' + inv.Item__c, inv);
            }
            if (inv.Account__c != null) {
                invByAccMap.put(inv.Account__c + '_' + inv.Item__c, inv);
            }
        }

        List<Inventory__c> invsToUpsert = new List<Inventory__c>();

        for (Id itemId : itemIds) {
            Decimal qtyToReceive = itemToRecQtyMap.get(itemId);

            // 1. TARGET INVENTORY (Target Account + Target Location + Item): Transit_Out ↓
            String targetLocKey = targetLocId + '_' + itemId;
            String targetAccKey = reqAccId + '_' + itemId;
            Inventory__c targetInv = targetLocId != null ? invByLocMap.get(targetLocKey) : null;
            if (targetInv == null && reqAccId != null) {
                targetInv = invByAccMap.get(targetAccKey);
            }
            if (targetInv == null) {
                targetInv = new Inventory__c(
                    Item__c = itemId,
                    Inventory_Location__c = targetLocId,
                    Account__c = reqAccId,
                    Available__c = 0,
                    Transit_Out_Quantity__c = 0,
                    Transit_In_Quantity__c = 0
                );
                if (targetLocId != null) invByLocMap.put(targetLocKey, targetInv);
                if (reqAccId != null) invByAccMap.put(targetAccKey, targetInv);
            }

            Decimal targetTransitOut = targetInv.Transit_Out_Quantity__c != null ? targetInv.Transit_Out_Quantity__c : 0;
            targetInv.Transit_Out_Quantity__c = Math.max(0, targetTransitOut - qtyToReceive);
            invsToUpsert.add(targetInv);

            // 2. SOURCE INVENTORY (Source Account + Source Location + Item): Transit_In ↓, Available ↑
            String sourceLocKey = sourceLocId + '_' + itemId;
            String sourceAccKey = suppAccId + '_' + itemId;
            Inventory__c sourceInv = sourceLocId != null ? invByLocMap.get(sourceLocKey) : null;
            if (sourceInv == null && suppAccId != null) {
                sourceInv = invByAccMap.get(sourceAccKey);
            }
            if (sourceInv == null && (sourceLocId != null || suppAccId != null)) {
                sourceInv = new Inventory__c(
                    Item__c = itemId,
                    Inventory_Location__c = sourceLocId,
                    Account__c = suppAccId,
                    Available__c = 0,
                    Transit_In_Quantity__c = 0,
                    Transit_Out_Quantity__c = 0
                );
                if (sourceLocId != null) invByLocMap.put(sourceLocKey, sourceInv);
                if (suppAccId != null) invByAccMap.put(sourceAccKey, sourceInv);
            }

            if (sourceInv != null) {
                Decimal sourceTransitIn = sourceInv.Transit_In_Quantity__c != null ? sourceInv.Transit_In_Quantity__c : 0;
                sourceInv.Transit_In_Quantity__c = Math.max(0, sourceTransitIn - qtyToReceive);
                sourceInv.Available__c = (sourceInv.Available__c != null ? sourceInv.Available__c : 0) + qtyToReceive;
                if (sourceInv != targetInv) {
                    invsToUpsert.add(sourceInv);
                }
            }
        }

        if (!invsToUpsert.isEmpty()) {
            upsert invsToUpsert;
        }

        // 3. Update PO Line Items and PO Status
        List<Purchase_Order_Line_Item__c> allPoLines = [
            SELECT Id, Ordered_Qty__c, Status__c, Purchase_Order__c, Previously_Received_Quantity__c, Received_Qty__c
            FROM Purchase_Order_Line_Item__c
            WHERE Purchase_Order__c = :po.Id
        ];

        Map<Id, Decimal> lineNewRecQtyMap = new Map<Id, Decimal>();
        for (GRN_Line_Item__c gli : lines) {
            if (gli.Purchase_Order_Line_Item__c != null && gli.Received_Qty__c != null) {
                Decimal current = lineNewRecQtyMap.containsKey(gli.Purchase_Order_Line_Item__c) 
                    ? lineNewRecQtyMap.get(gli.Purchase_Order_Line_Item__c) : 0;
                lineNewRecQtyMap.put(gli.Purchase_Order_Line_Item__c, current + gli.Received_Qty__c);
            }
        }

        Boolean allFullyReceived = true;
        Boolean anyReceived = false;
        List<Purchase_Order_Line_Item__c> poliToUpdate = new List<Purchase_Order_Line_Item__c>();

        for (Purchase_Order_Line_Item__c poli : allPoLines) {
            Decimal totalRec = poli.Received_Qty__c != null ? poli.Received_Qty__c : (poli.Previously_Received_Quantity__c != null ? poli.Previously_Received_Quantity__c : 0);
            poli.Previously_Received_Quantity__c = totalRec;

            Decimal ordQty = (poli.Ordered_Qty__c == null ? 0 : poli.Ordered_Qty__c);

            if (totalRec >= ordQty && ordQty > 0) {
                poli.Status__c = 'Fully Received';
            } else if (totalRec > 0) {
                poli.Status__c = 'Partially Received';
            }

            if (poli.Status__c == 'Fully Received') {
                anyReceived = true;
            } else {
                allFullyReceived = false;
                if (poli.Status__c == 'Partially Received') {
                    anyReceived = true;
                }
            }

            poliToUpdate.add(poli);
        }

        if (!poliToUpdate.isEmpty()) {
            update poliToUpdate;
        }

        // Update PO status (PO Status picklist uses 'Received', not 'Fully Received')
        String newPoStatus = po.Status__c;
        if (allFullyReceived) {
            newPoStatus = 'Received';
        } else if (anyReceived) {
            newPoStatus = 'Partially Received';
        }

        if (newPoStatus != po.Status__c) {
            po.Status__c = newPoStatus;
            update po;
        }

        // 4. Update GRN status to Received
        grn.Status__c = 'Received';
        update grn;

        // 5. Update Purchase_Order_Allocation__c (POA) and linked Supply Request(s) (Supply_Request__c)
        List<Purchase_Order_Allocation__c> poas = [
            SELECT Id, Allocated_Qty__c, Received_Qty__c, Supply_Request__c, Supply_Request__r.Item__c, Supply_Request__r.Requested_Qty__c, Supply_Request__r.Status__c
            FROM Purchase_Order_Allocation__c
            WHERE Purchase_Order__c = :po.Id
        ];

        if (!poas.isEmpty()) {
            Map<Id, Decimal> itemToRemainingNewRecMap = new Map<Id, Decimal>(itemToRecQtyMap);

            List<Purchase_Order_Allocation__c> poasToUpdate = new List<Purchase_Order_Allocation__c>();
            Map<Id, Decimal> srTotalReceivedMap = new Map<Id, Decimal>();

            for (Purchase_Order_Allocation__c poa : poas) {
                Id poaItem = (poa.Supply_Request__r != null && poa.Supply_Request__r.Item__c != null) 
                    ? poa.Supply_Request__r.Item__c 
                    : null;
                
                Decimal allocQty = poa.Allocated_Qty__c != null ? poa.Allocated_Qty__c : 0;
                Decimal currPoaRec = poa.Received_Qty__c != null ? poa.Received_Qty__c : 0;
                Decimal remainingAlloc = Math.max(0, allocQty - currPoaRec);

                Decimal unallocatedRec = 0;
                if (poaItem != null && itemToRemainingNewRecMap.containsKey(poaItem)) {
                    unallocatedRec = itemToRemainingNewRecMap.get(poaItem);
                } else if (!itemToRemainingNewRecMap.isEmpty()) {
                    unallocatedRec = itemToRemainingNewRecMap.values()[0];
                }

                Decimal addQty = Math.min(remainingAlloc > 0 ? remainingAlloc : unallocatedRec, unallocatedRec);
                Decimal newPoaRec = currPoaRec + addQty;
                poa.Received_Qty__c = newPoaRec;
                poasToUpdate.add(poa);

                if (poaItem != null && itemToRemainingNewRecMap.containsKey(poaItem)) {
                    itemToRemainingNewRecMap.put(poaItem, Math.max(0, unallocatedRec - addQty));
                }

                if (poa.Supply_Request__c != null) {
                    Decimal srTotal = srTotalReceivedMap.containsKey(poa.Supply_Request__c) ? srTotalReceivedMap.get(poa.Supply_Request__c) : 0;
                    srTotalReceivedMap.put(poa.Supply_Request__c, srTotal + newPoaRec);
                }
            }

            if (!poasToUpdate.isEmpty()) {
                update poasToUpdate;
            }

            if (!srTotalReceivedMap.isEmpty()) {
                List<Supply_Request__c> srsToUpdate = [
                    SELECT Id, Requested_Qty__c, Status__c, Received_Qty__c
                    FROM Supply_Request__c
                    WHERE Id IN :srTotalReceivedMap.keySet()
                ];

                List<Supply_Request__c> updatedSRs = new List<Supply_Request__c>();
                for (Supply_Request__c sr : srsToUpdate) {
                    Decimal reqQty = sr.Requested_Qty__c != null ? sr.Requested_Qty__c : 0;
                    Decimal totalSrRec = srTotalReceivedMap.get(sr.Id);
                    sr.Received_Qty__c = totalSrRec;
                    if (totalSrRec >= reqQty && reqQty > 0) {
                        sr.Status__c = 'Completed';
                    } else if (totalSrRec > 0) {
                        sr.Status__c = 'Partially Received';
                    }
                    updatedSRs.add(sr);
                }
                if (!updatedSRs.isEmpty()) {
                    update updatedSRs;
                }
            }
        }
    }

    private static AuraHandledException createAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    } */
}