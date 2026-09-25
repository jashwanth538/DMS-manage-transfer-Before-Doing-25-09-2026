import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';

import getRelatedSaleOrders from '@salesforce/apex/InventoryOverviewModalController.getRelatedSaleOrders';
import getRelatedManufacturingOrders from '@salesforce/apex/InventoryOverviewModalController.getRelatedManufacturingOrders';
import getRelatedInventoryTransfers from '@salesforce/apex/InventoryOverviewModalController.getRelatedInventoryTransfers';
import getRelatedTransitInOrders from '@salesforce/apex/InventoryOverviewModalController.getRelatedTransitInOrders';
import getRelatedTransitOutOrders from '@salesforce/apex/InventoryOverviewModalController.getRelatedTransitOutOrders';

const REQUIRED_FIELDS = [
    'Inventory__c.Name'
];

const OPTIONAL_FIELDS = [
    'Inventory__c.Item__c',
    'Inventory__c.Item__r.Name',
    'Inventory__c.Inventory_Location__c',
    'Inventory__c.Inventory_Location__r.Name',
    'Inventory__c.On_Hand_Qty__c',
    'Inventory__c.Available__c',
    'Inventory__c.Reserved_Transfer__c',
    'Inventory__c.Reserved_Sale_Order__c',
    'Inventory__c.Reserved_Manufacturing__c',
    'Inventory__c.In_Production__c',
    'Inventory__c.Reorder_Level__c',
    'Inventory__c.Target_Stock_Level__c',
    'Inventory__c.Transit_In_Quantity__c',
    'Inventory__c.Damaged__c',
    'Inventory__c.Transit_Out_Quantity__c',
    'Inventory__c.Stock_Medium_Level_Quantity__c',
    'Inventory__c.Stock_Low_Level_Quantity__c',
    'Inventory__c.Stock_High_Level_Quantity__c'
];

export default class InventoryOverviewCard extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    wiredRecordResult;
    record;
    error;
    isLoading = true;

    // Modal States
    isModalOpen = false;
    modalTitle = '';
    modalIcon = 'standard:orders';
    activeModalType = '';
    isModalLoading = false;
    modalData = [];

    @wire(getRecord, { recordId: '$recordId', fields: REQUIRED_FIELDS, optionalFields: OPTIONAL_FIELDS })
    wiredRecord(result) {
        this.wiredRecordResult = result;
        const { error, data } = result;
        this.isLoading = false;
        if (data) {
            this.record = data;
            this.error = undefined;
        } else if (error) {
            console.error('Error loading inventory record:', JSON.stringify(error));
            this.error = error;
            this.record = undefined;
        }
    }

    get errorMessage() {
        if (!this.error) return '';
        if (this.error.body && Array.isArray(this.error.body)) {
            return this.error.body.map(e => e.message).join(', ');
        } else if (this.error.body && typeof this.error.body === 'object' && this.error.body.message) {
            return this.error.body.message;
        } else if (typeof this.error === 'string') {
            return this.error;
        }
        return JSON.stringify(this.error);
    }

    // Getters for individual fields
    get recordName() {
        return getFieldValue(this.record, 'Inventory__c.Name') || 'Inventory Record';
    }

    get itemId() {
        return getFieldValue(this.record, 'Inventory__c.Item__c') || null;
    }

    get itemName() {
        return getFieldValue(this.record, 'Inventory__c.Item__r.Name') || 'N/A';
    }

    get locationId() {
        return getFieldValue(this.record, 'Inventory__c.Inventory_Location__c') || null;
    }

    get locationName() {
        return getFieldValue(this.record, 'Inventory__c.Inventory_Location__r.Name') || 'N/A';
    }

    get onHandQty() {
        return getFieldValue(this.record, 'Inventory__c.On_Hand_Qty__c') ?? 0;
    }

    get availableQty() {
        return getFieldValue(this.record, 'Inventory__c.Available__c') ?? 0;
    }

    get reservedTransfer() {
        return getFieldValue(this.record, 'Inventory__c.Reserved_Transfer__c') ?? 0;
    }

    get reservedSaleOrder() {
        return getFieldValue(this.record, 'Inventory__c.Reserved_Sale_Order__c') ?? 0;
    }

    get reservedMfg() {
        return getFieldValue(this.record, 'Inventory__c.Reserved_Manufacturing__c') ?? 0;
    }

    get inProduction() {
        return getFieldValue(this.record, 'Inventory__c.In_Production__c') ?? 0;
    }

    get reorderLevel() {
        return getFieldValue(this.record, 'Inventory__c.Reorder_Level__c') ?? 0;
    }

    get targetStockLevel() {
        return getFieldValue(this.record, 'Inventory__c.Target_Stock_Level__c') ?? 0;
    }

    get transitInQty() {
        return getFieldValue(this.record, 'Inventory__c.Transit_In_Quantity__c') ?? 0;
    }

    get damagedQty() {
        return getFieldValue(this.record, 'Inventory__c.Damaged__c') ?? 0;
    }

    get transitOutQty() {
        return getFieldValue(this.record, 'Inventory__c.Transit_Out_Quantity__c') ?? 0;
    }

    get stockMediumLevel() {
        return getFieldValue(this.record, 'Inventory__c.Stock_Medium_Level_Quantity__c') ?? 0;
    }

    get stockLowLevel() {
        return getFieldValue(this.record, 'Inventory__c.Stock_Low_Level_Quantity__c') ?? 0;
    }

    get stockHighLevel() {
        return getFieldValue(this.record, 'Inventory__c.Stock_High_Level_Quantity__c') ?? 0;
    }

    // Calculated getters
    get totalReserved() {
        return this.reservedSaleOrder;
    }

    get pipelineNetInflow() {
        return this.transitInQty - this.transitOutQty;
    }

    get stockHealthPercent() {
        const target = this.targetStockLevel;
        const available = this.availableQty;
        if (target > 0) {
            const pct = Math.round((available / target) * 100);
            return Math.max(0, Math.min(pct, 100));
        }
        if (this.reorderLevel > 0) {
            const pct = Math.round((available / (this.reorderLevel * 2)) * 100);
            return Math.max(0, Math.min(pct, 100));
        }
        return available > 0 ? 100 : 0;
    }

    get progressStyle() {
        return `width: ${this.stockHealthPercent}%;`;
    }

    get stockStatus() {
        const avail = this.availableQty;
        const reorder = this.reorderLevel;
        const low = this.stockLowLevel;

        if (avail <= 0) {
            return {
                label: 'Out of Stock',
                class: 'badge-out-of-stock',
                icon: 'utility:error'
            };
        } else if (low > 0 && avail <= low) {
            return {
                label: 'Critical Low',
                class: 'badge-critical',
                icon: 'utility:error'
            };
        } else if (reorder > 0 && avail <= reorder) {
            return {
                label: 'Reorder Needed',
                class: 'badge-warning',
                icon: 'utility:alert'
            };
        }
        return {
            label: 'Optimal Stock',
            class: 'badge-success',
            icon: 'utility:success'
        };
    }

    get hasDamagedStock() {
        return this.damagedQty > 0;
    }

    get damagedBoxClass() {
        return this.hasDamagedStock ? 'field-box accent-bg-damaged' : 'field-box';
    }

    get damagedValueClass() {
        return this.hasDamagedStock ? 'field-value metric-number text-danger' : 'field-value metric-number';
    }

    // Modal Type Getters
    get isSaleOrderModal() {
        return this.activeModalType === 'saleOrder';
    }

    get isManufacturingModal() {
        return this.activeModalType === 'manufacturing';
    }

    get isTransferModal() {
        return this.activeModalType === 'transfer' || this.activeModalType === 'transitIn' || this.activeModalType === 'transitOut';
    }

    get hasModalData() {
        return this.modalData && this.modalData.length > 0;
    }

    // Navigation Handlers
    handleItemClick(event) {
        event.preventDefault();
        if (this.itemId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.itemId,
                    actionName: 'view'
                }
            });
        }
    }

    handleLocationClick(event) {
        event.preventDefault();
        if (this.locationId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.locationId,
                    actionName: 'view'
                }
            });
        }
    }

    handleRecordNavigate(event) {
        event.preventDefault();
        const recId = event.currentTarget.dataset.id;
        if (recId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: recId,
                    actionName: 'view'
                }
            });
        }
    }

    // Modal Handlers
    handleOpenSaleOrdersModal() {
        this.activeModalType = 'saleOrder';
        this.modalTitle = 'Reserved Sale Orders';
        this.modalIcon = 'standard:orders';
        this.isModalOpen = true;
        this.fetchModalData();
    }

    handleOpenManufacturingModal() {
        this.activeModalType = 'manufacturing';
        this.modalTitle = 'Reserved Manufacturing Orders';
        this.modalIcon = 'standard:approval';
        this.isModalOpen = true;
        this.fetchModalData();
    }

    handleOpenTransfersModal() {
        this.activeModalType = 'transfer';
        this.modalTitle = 'Reserved Inventory Transfers';
        this.modalIcon = 'standard:shipment';
        this.isModalOpen = true;
        this.fetchModalData();
    }

    handleOpenTransitInModal() {
        this.activeModalType = 'transitIn';
        this.modalTitle = 'Transit In Orders';
        this.modalIcon = 'standard:shipment';
        this.isModalOpen = true;
        this.fetchModalData();
    }

    handleOpenTransitOutModal() {
        this.activeModalType = 'transitOut';
        this.modalTitle = 'Transit Out Orders';
        this.modalIcon = 'standard:shipment';
        this.isModalOpen = true;
        this.fetchModalData();
    }

    handleCloseModal() {
        this.isModalOpen = false;
        this.modalData = [];
    }

    fetchModalData() {
        this.isModalLoading = true;
        this.modalData = [];

        if (this.activeModalType === 'saleOrder') {
            getRelatedSaleOrders({ inventoryId: this.recordId })
                .then((data) => {
                    this.modalData = data || [];
                })
                .catch((err) => {
                    console.error('Error fetching related Sale Orders:', err);
                })
                .finally(() => {
                    this.isModalLoading = false;
                });
        } else if (this.activeModalType === 'manufacturing') {
            getRelatedManufacturingOrders({ inventoryId: this.recordId })
                .then((data) => {
                    this.modalData = data || [];
                })
                .catch((err) => {
                    console.error('Error fetching related Manufacturing Orders:', err);
                })
                .finally(() => {
                    this.isModalLoading = false;
                });
        } else if (this.activeModalType === 'transfer') {
            getRelatedInventoryTransfers({ inventoryId: this.recordId })
                .then((data) => {
                    this.modalData = data || [];
                })
                .catch((err) => {
                    console.error('Error fetching related Inventory Transfers:', err);
                })
                .finally(() => {
                    this.isModalLoading = false;
                });
        } else if (this.activeModalType === 'transitIn') {
            getRelatedTransitInOrders({ inventoryId: this.recordId })
                .then((data) => {
                    this.modalData = data || [];
                })
                .catch((err) => {
                    console.error('Error fetching Transit In Orders:', err);
                })
                .finally(() => {
                    this.isModalLoading = false;
                });
        } else if (this.activeModalType === 'transitOut') {
            getRelatedTransitOutOrders({ inventoryId: this.recordId })
                .then((data) => {
                    this.modalData = data || [];
                })
                .catch((err) => {
                    console.error('Error fetching Transit Out Orders:', err);
                })
                .finally(() => {
                    this.isModalLoading = false;
                });
        }
    }

    handleRefresh() {
        this.isLoading = true;
        notifyRecordUpdateAvailable([{ recordId: this.recordId }])
            .finally(() => {
                this.isLoading = false;
            });
    }
}