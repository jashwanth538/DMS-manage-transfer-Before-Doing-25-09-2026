public with sharing class InventoryOverviewModalController {
    
    @AuraEnabled(cacheable=true)
    public static List<SaleOrderWrapper> getRelatedSaleOrders(Id inventoryId) {
        List<SaleOrderWrapper> results = new List<SaleOrderWrapper>();
        if (inventoryId == null) {
            return results;
        }

        List<Inventory__c> invList = [SELECT Id, Item__c, Inventory_Location__c FROM Inventory__c WHERE Id = :inventoryId LIMIT 1];
        if (invList.isEmpty() || invList[0].Item__c == null) {
            return results;
        }

        Id itemId = invList[0].Item__c;
        Id locId = invList[0].Inventory_Location__c;

        // 1. Query Inventory Reservations strictly filtered by Inventory Location & Order Status != 'Dispatched'
        List<Inventory_Reservation__c> reservations;
        if (locId != null) {
            reservations = [
                SELECT Id, Name, Item__c, Item__r.Name, Inventory_Location__c, Inventory_Location__r.Name,
                       Reserved_Qty__c, Status__c, Reservation_Date__c, CreatedDate,
                       Order_Allocation_Line_Item__c, Order_Allocation_Line_Item__r.Name,
                       Order_Allocation_Line_Item__r.Item__c,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__c,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.OrderNumber,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Status,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Account.Name,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Customer__r.Name
                FROM Inventory_Reservation__c
                WHERE (Item__c = :itemId OR Order_Allocation_Line_Item__r.Item__c = :itemId)
                  AND Inventory_Location__c = :locId
                  AND (Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Status != 'Dispatched' OR Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__c = null)
                  AND Status__c != 'Dispatched'
                  AND Status__c != 'Cancelled'
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        } else {
            reservations = [
                SELECT Id, Name, Item__c, Item__r.Name, Inventory_Location__c, Inventory_Location__r.Name,
                       Reserved_Qty__c, Status__c, Reservation_Date__c, CreatedDate,
                       Order_Allocation_Line_Item__c, Order_Allocation_Line_Item__r.Name,
                       Order_Allocation_Line_Item__r.Item__c,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__c,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.OrderNumber,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Status,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Account.Name,
                       Order_Allocation_Line_Item__r.Order_Allocation__r.Customer__r.Name
                FROM Inventory_Reservation__c
                WHERE (Item__c = :itemId OR Order_Allocation_Line_Item__r.Item__c = :itemId)
                  AND (Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Status != 'Dispatched' OR Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__c = null)
                  AND Status__c != 'Dispatched'
                  AND Status__c != 'Cancelled'
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        }

        for (Inventory_Reservation__c ir : reservations) {
            SaleOrderWrapper w = new SaleOrderWrapper();
            w.reservationId = ir.Id;
            w.reservationName = ir.Name;
            w.itemName = ir.Item__r != null ? ir.Item__r.Name : '';
            w.locationName = ir.Inventory_Location__r != null ? ir.Inventory_Location__r.Name : '';
            w.reservedQty = ir.Reserved_Qty__c != null ? ir.Reserved_Qty__c : 0;
            w.status = ir.Status__c != null ? ir.Status__c : 'Reserved';
            w.reservationDate = ir.Reservation_Date__c != null ? ir.Reservation_Date__c : Date.valueOf(ir.CreatedDate);

            if (ir.Order_Allocation_Line_Item__r != null && ir.Order_Allocation_Line_Item__r.Order_Allocation__r != null) {
                w.saleOrderId = ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__c;
                w.saleOrderNumber = ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r != null
                    ? ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.OrderNumber
                    : ir.Order_Allocation_Line_Item__r.Name;

                if (ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r != null &&
                    ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Account != null) {
                    w.accountName = ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Sale_Order__r.Account.Name;
                } else if (ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Customer__r != null) {
                    w.accountName = ir.Order_Allocation_Line_Item__r.Order_Allocation__r.Customer__r.Name;
                } else {
                    w.accountName = 'N/A';
                }
            } else {
                w.saleOrderNumber = ir.Name;
                w.accountName = 'N/A';
            }
            results.add(w);
        }

        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<ManufacturingOrderWrapper> getRelatedManufacturingOrders(Id inventoryId) {
        List<ManufacturingOrderWrapper> results = new List<ManufacturingOrderWrapper>();
        if (inventoryId == null) {
            return results;
        }

        if (!Schema.getGlobalDescribe().containsKey('Manufacturing_Order__c')) {
            return results;
        }

        List<Inventory__c> invList = [SELECT Id, Item__c, Inventory_Location__c FROM Inventory__c WHERE Id = :inventoryId LIMIT 1];
        if (invList.isEmpty() || invList[0].Item__c == null) {
            return results;
        }

        Id itemId = invList[0].Item__c;
        Id locId = invList[0].Inventory_Location__c;

        String query = 'SELECT Id, Name, Item__c, Item__r.Name, Fulfillment_Warehouse__c, Fulfillment_Warehouse__r.Name, Produced_Qty__c, Planned_Qty__c, Status__c FROM Manufacturing_Order__c WHERE Item__c = :itemId';
        if (locId != null) {
            query += ' AND Fulfillment_Warehouse__c = :locId';
        }
        query += ' ORDER BY CreatedDate DESC LIMIT 100';

        List<SObject> moList = Database.query(query);

        for (SObject mo : moList) {
            ManufacturingOrderWrapper w = new ManufacturingOrderWrapper();
            w.moId = (String)mo.get('Id');
            w.moName = (String)mo.get('Name');
            
            SObject itemRef = mo.getSObject('Item__r');
            w.itemName = itemRef != null ? (String)itemRef.get('Name') : '';

            SObject whRef = mo.getSObject('Fulfillment_Warehouse__r');
            w.warehouseName = whRef != null ? (String)whRef.get('Name') : 'N/A';

            Decimal prodQty = (Decimal)mo.get('Produced_Qty__c');
            Decimal planQty = (Decimal)mo.get('Planned_Qty__c');
            w.producedQty = prodQty != null ? prodQty : (planQty != null ? planQty : 0);

            w.status = (String)mo.get('Status__c');
            if (w.status == null) {
                w.status = 'N/A';
            }
            results.add(w);
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<InventoryTransferWrapper> getRelatedInventoryTransfers(Id inventoryId) {
        List<InventoryTransferWrapper> results = new List<InventoryTransferWrapper>();
        if (inventoryId == null) {
            return results;
        }

        List<Inventory__c> invList = [SELECT Id, Item__c, Inventory_Location__c FROM Inventory__c WHERE Id = :inventoryId LIMIT 1];
        if (invList.isEmpty() || invList[0].Item__c == null) {
            return results;
        }

        Id itemId = invList[0].Item__c;
        Id locId = invList[0].Inventory_Location__c;

        List<Inventory_Transfer__c> transfers;
        if (locId != null) {
            transfers = [
                SELECT Id, Name, Item__c, Item__r.Name,
                       Source_Inventory_Location__c, Source_Inventory_Location__r.Name,
                       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name,
                       Transfer_Qty__c, Status__c, Required_Date__c
                FROM Inventory_Transfer__c
                WHERE Item__c = :itemId
                  AND (Source_Inventory_Location__c = :locId OR Destination_Inventory_Location__c = :locId)
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        } else {
            transfers = [
                SELECT Id, Name, Item__c, Item__r.Name,
                       Source_Inventory_Location__c, Source_Inventory_Location__r.Name,
                       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name,
                       Transfer_Qty__c, Status__c, Required_Date__c
                FROM Inventory_Transfer__c
                WHERE Item__c = :itemId
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        }

        for (Inventory_Transfer__c it : transfers) {
            InventoryTransferWrapper w = new InventoryTransferWrapper();
            w.transferId = it.Id;
            w.transferName = it.Name;
            w.itemName = it.Item__r != null ? it.Item__r.Name : '';
            w.sourceLocationName = it.Source_Inventory_Location__r != null ? it.Source_Inventory_Location__r.Name : 'N/A';
            w.destinationLocationName = it.Destination_Inventory_Location__r != null ? it.Destination_Inventory_Location__r.Name : 'N/A';
            w.transferQty = it.Transfer_Qty__c != null ? it.Transfer_Qty__c : 0;
            w.status = it.Status__c != null ? it.Status__c : 'N/A';
            w.requiredDate = it.Required_Date__c;
            results.add(w);
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<InventoryTransferWrapper> getRelatedTransitInOrders(Id inventoryId) {
        List<InventoryTransferWrapper> results = new List<InventoryTransferWrapper>();
        if (inventoryId == null) {
            return results;
        }

        List<Inventory__c> invList = [
            SELECT Id, Item__c, Inventory_Location__c, Transit_In_Quantity__c 
            FROM Inventory__c 
            WHERE Id = :inventoryId 
            LIMIT 1
        ];
        if (invList.isEmpty() || invList[0].Item__c == null) {
            return results;
        }

        Id itemId = invList[0].Item__c;
        Id locId = invList[0].Inventory_Location__c;

        List<Inventory_Transfer__c> transfers;
        if (locId != null) {
            transfers = [
                SELECT Id, Name, Item__c, Item__r.Name,
                       Source_Inventory_Location__c, Source_Inventory_Location__r.Name,
                       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name,
                       Transfer_Qty__c, In_Transit_Qty__c, Status__c, Required_Date__c
                FROM Inventory_Transfer__c
                WHERE Item__c = :itemId
                  AND Destination_Inventory_Location__c = :locId
                  AND Status__c NOT IN ('Received', 'Delivered', 'Completed', 'Cancelled')
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        } else {
            transfers = [
                SELECT Id, Name, Item__c, Item__r.Name,
                       Source_Inventory_Location__c, Source_Inventory_Location__r.Name,
                       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name,
                       Transfer_Qty__c, In_Transit_Qty__c, Status__c, Required_Date__c
                FROM Inventory_Transfer__c
                WHERE Item__c = :itemId
                  AND Status__c NOT IN ('Received', 'Delivered', 'Completed', 'Cancelled')
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        }

        for (Inventory_Transfer__c it : transfers) {
            InventoryTransferWrapper w = new InventoryTransferWrapper();
            w.transferId = it.Id;
            w.transferName = it.Name;
            w.itemName = it.Item__r != null ? it.Item__r.Name : '';
            w.sourceLocationName = it.Source_Inventory_Location__r != null ? it.Source_Inventory_Location__r.Name : 'N/A';
            w.destinationLocationName = it.Destination_Inventory_Location__r != null ? it.Destination_Inventory_Location__r.Name : 'N/A';
            w.transferQty = (it.In_Transit_Qty__c != null && it.In_Transit_Qty__c > 0) 
                ? it.In_Transit_Qty__c 
                : (it.Transfer_Qty__c != null ? it.Transfer_Qty__c : 0);
            w.status = it.Status__c != null ? it.Status__c : 'N/A';
            w.requiredDate = it.Required_Date__c;
            results.add(w);
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<InventoryTransferWrapper> getRelatedTransitOutOrders(Id inventoryId) {
        List<InventoryTransferWrapper> results = new List<InventoryTransferWrapper>();
        if (inventoryId == null) {
            return results;
        }

        List<Inventory__c> invList = [
            SELECT Id, Item__c, Inventory_Location__c, Transit_Out_Quantity__c 
            FROM Inventory__c 
            WHERE Id = :inventoryId 
            LIMIT 1
        ];
        if (invList.isEmpty() || invList[0].Item__c == null) {
            return results;
        }

        Id itemId = invList[0].Item__c;
        Id locId = invList[0].Inventory_Location__c;

        List<Inventory_Transfer__c> transfers;
        if (locId != null) {
            transfers = [
                SELECT Id, Name, Item__c, Item__r.Name,
                       Source_Inventory_Location__c, Source_Inventory_Location__r.Name,
                       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name,
                       Transfer_Qty__c, In_Transit_Qty__c, Status__c, Required_Date__c
                FROM Inventory_Transfer__c
                WHERE Item__c = :itemId
                  AND Source_Inventory_Location__c = :locId
                  AND Status__c NOT IN ('Received', 'Delivered', 'Completed', 'Cancelled')
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        } else {
            transfers = [
                SELECT Id, Name, Item__c, Item__r.Name,
                       Source_Inventory_Location__c, Source_Inventory_Location__r.Name,
                       Destination_Inventory_Location__c, Destination_Inventory_Location__r.Name,
                       Transfer_Qty__c, In_Transit_Qty__c, Status__c, Required_Date__c
                FROM Inventory_Transfer__c
                WHERE Item__c = :itemId
                  AND Status__c NOT IN ('Received', 'Delivered', 'Completed', 'Cancelled')
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        }

        for (Inventory_Transfer__c it : transfers) {
            InventoryTransferWrapper w = new InventoryTransferWrapper();
            w.transferId = it.Id;
            w.transferName = it.Name;
            w.itemName = it.Item__r != null ? it.Item__r.Name : '';
            w.sourceLocationName = it.Source_Inventory_Location__r != null ? it.Source_Inventory_Location__r.Name : 'N/A';
            w.destinationLocationName = it.Destination_Inventory_Location__r != null ? it.Destination_Inventory_Location__r.Name : 'N/A';
            w.transferQty = (it.In_Transit_Qty__c != null && it.In_Transit_Qty__c > 0) 
                ? it.In_Transit_Qty__c 
                : (it.Transfer_Qty__c != null ? it.Transfer_Qty__c : 0);
            w.status = it.Status__c != null ? it.Status__c : 'N/A';
            w.requiredDate = it.Required_Date__c;
            results.add(w);
        }
        return results;
    }

    public class SaleOrderWrapper {
        @AuraEnabled public String reservationId { get; set; }
        @AuraEnabled public String reservationName { get; set; }
        @AuraEnabled public String saleOrderId { get; set; }
        @AuraEnabled public String saleOrderNumber { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String itemName { get; set; }
        @AuraEnabled public String locationName { get; set; }
        @AuraEnabled public Decimal reservedQty { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date reservationDate { get; set; }
    }

    public class ManufacturingOrderWrapper {
        @AuraEnabled public String moId { get; set; }
        @AuraEnabled public String moName { get; set; }
        @AuraEnabled public String itemName { get; set; }
        @AuraEnabled public String warehouseName { get; set; }
        @AuraEnabled public Decimal producedQty { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class InventoryTransferWrapper {
        @AuraEnabled public String transferId { get; set; }
        @AuraEnabled public String transferName { get; set; }
        @AuraEnabled public String itemName { get; set; }
        @AuraEnabled public String sourceLocationName { get; set; }
        @AuraEnabled public String destinationLocationName { get; set; }
        @AuraEnabled public Decimal transferQty { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date requiredDate { get; set; }
    }
}