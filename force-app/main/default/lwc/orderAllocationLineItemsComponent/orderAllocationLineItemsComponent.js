import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { subscribe, MessageContext } from 'lightning/messageService';
import SUPPLY_PLAN_UPDATE_MC from '@salesforce/messageChannel/SupplyPlanUpdate__c';
import SUPPLY_PLAN_ACTION_MC from '@salesforce/messageChannel/SupplyPlanAction__c';
import getOrderAllocationDetails from '@salesforce/apex/OrderAllocationLineItemsComponents.getOrderAllocationDetails';
import { refreshApex } from '@salesforce/apex';

export default class OrderAllocationLineItemsComponent extends NavigationMixin(LightningElement) {
    @api recordId;
    @track orderAllocation = null;
    @track error = null;
    @track isLoading = true;
    @track lmsCoveragePercent = null;
    @track lmsLineItemCoverages = {};
    
    @track searchKey = '';
    
    // Pagination
    @track pageSize = 10;
    @track currentPage = 1;

    @wire(MessageContext)
    messageContext;
    subscription = null;
    actionSubscription = null;

    connectedCallback() {
        this.subscribeToMessageChannel();
        this.subscribeToActionChannel();
        this.injectCustomStyles();
    }

    subscribeToActionChannel() {
        if (!this.actionSubscription) {
            this.actionSubscription = subscribe(
                this.messageContext,
                SUPPLY_PLAN_ACTION_MC,
                (message) => {
                    if (message && (message.actionType === 'SUBMIT_COMPLETE' || message.actionType === 'CONFIRM_COMPLETE')) {
                        if (this.wiredOrderAllocationResult) {
                            refreshApex(this.wiredOrderAllocationResult);
                        }
                    }
                }
            );
        }
    }

    subscribeToMessageChannel() {
        if (!this.subscription) {
            this.subscription = subscribe(
                this.messageContext,
                SUPPLY_PLAN_UPDATE_MC,
                (message) => this.handleMessage(message)
            );
        }
    }

    handleMessage(message) {
        if (message && message.summaryData) {
            this.lmsCoveragePercent = message.summaryData.totalCoveredPercent;
            if (message.summaryData.lineItemCoverages) {
                this.lmsLineItemCoverages = message.summaryData.lineItemCoverages;
            }
        }
    }

    wiredOrderAllocationResult;

    @wire(getOrderAllocationDetails, { recordId: '$recordId' })
    wiredOrderAllocation(result) {
        this.wiredOrderAllocationResult = result;
        const { error, data } = result;
        if (data) {
            this.orderAllocation = data;
            this.error = null;
            this.isLoading = false;
        } else if (error) {
            this.error = error;
            this.orderAllocation = null;
            this.isLoading = false;
            console.error('Error fetching sales allocation details:', error);
        }
    }

    get totalLines() {
        return this.allLineItems.length;
    }

    get hasLineItems() {
        return this.orderAllocation && 
               this.orderAllocation.Order_Allocation_Line_Items__r && 
               this.orderAllocation.Order_Allocation_Line_Items__r.length > 0;
    }

    get orderAllocationStatus() {
        return this.orderAllocation && this.orderAllocation.Status__c ? this.orderAllocation.Status__c : 'Draft';
    }

    get isPlanPlanned() {
        if (!this.orderAllocationStatus) return false;
        const status = this.orderAllocationStatus.toLowerCase();
        return status !== 'draft';
    }

    get tableClass() {
        return this.isPlanPlanned 
            ? 'slds-table slds-table_cell-buffer slds-table_bordered table-custom planned-table' 
            : 'slds-table slds-table_cell-buffer slds-table_bordered table-custom';
    }

    get tableColspan() {
        return this.isPlanPlanned ? 5 : 2;
    }

    get coveragePercent() {
        if (this.lmsCoveragePercent !== null && this.lmsCoveragePercent !== undefined) {
            return Number(this.lmsCoveragePercent);
        }
        const status = this.orderAllocationStatus.toLowerCase();
        if (status === 'draft') return 25;
        if (status === 'in progress') return 75;
        return 100;
    }

    handleSearchChange(event) {
        this.searchKey = event.detail.searchText || '';
        this.currentPage = 1;
    }

    async handleSearchReset() {
        this.isLoading = true;
        this.searchKey = '';
        this.currentPage = 1;
        
        // Reset horizontal scroll to the left
        const scrollableContainer = this.template.querySelector('.slds-scrollable_x');
        if (scrollableContainer) {
            scrollableContainer.scrollLeft = 0;
        }

        if (this.wiredOrderAllocationResult) {
            try {
                await refreshApex(this.wiredOrderAllocationResult);
            } catch (error) {
                console.error('Error refreshing sales allocation details:', error);
            } finally {
                this.isLoading = false;
            }
        } else {
            this.isLoading = false;
        }
    }

    get allLineItems() {
        if (!this.orderAllocation || !this.orderAllocation.Order_Allocation_Line_Items__r) {
            return [];
        }
        const parentStatus = this.orderAllocationStatus;
        
        let items = [...this.orderAllocation.Order_Allocation_Line_Items__r];
        items.sort((a, b) => {
            if (a.Name && b.Name) {
                return a.Name.localeCompare(b.Name, undefined, { numeric: true, sensitivity: 'base' });
            }
            return 0;
        });

        if (this.searchKey && this.searchKey.trim()) {
            const key = this.searchKey.toLowerCase().trim();
            items = items.filter(item => {
                const name = item.Name ? item.Name.toLowerCase() : '';
                const itemName = item.Item__r && item.Item__r.Name ? item.Item__r.Name.toLowerCase() : '';
                return name.includes(key) || itemName.includes(key);
            });
        }

        return items.map(item => {
            const lmsData = this.lmsLineItemCoverages[item.Id];
            const hasLmsCoverages = Object.keys(this.lmsLineItemCoverages).length > 0;
            const coverage = lmsData 
                ? lmsData.coverage 
                : (hasLmsCoverages 
                    ? 0 
                    : (this.lmsCoveragePercent !== null ? this.lmsCoveragePercent : 0));
            const status = item.Status__c || (lmsData ? lmsData.status : parentStatus) || 'Draft';

            let progressBarClass = 'slds-progress-bar__value ';
            let statusBadgeClass = 'slds-badge badge-custom ';
            
            if (coverage >= 100) {
                progressBarClass += 'progress-bar-success';
                statusBadgeClass += 'badge-success';
            } else if (coverage >= 75) {
                progressBarClass += 'progress-bar-warning';
                statusBadgeClass += 'badge-warning';
            } else {
                progressBarClass += 'progress-bar-info';
                statusBadgeClass += 'badge-info';
            }
            
            return {
                Id: item.Id,
                Name: item.Name,
                ItemName: item.Item__r ? item.Item__r.Name : '-',
                url: '/' + item.Id,
                Quantity: item.Ordered_Qty__c || 0,
                Coverage: coverage,
                coverageStyle: `width: ${Math.min(100, coverage)}%`,
                progressBarClass: progressBarClass,
                Status: status,
                statusBadgeClass: statusBadgeClass,
                ReservedQtyReceived: item.Reserved_Quantity__c || 0,
                ReservedQtyPlanned: item.Reserved_Qty_Planned__c || 0,
                TransferQtyReceived: item.Transfer_Qty_Received__c || 0,
                TransferQtyPlanned: item.Transfer_Qty_Planned__c || 0,
                // Procurement Received and Planned quantities
                SupplyRequestQtyReceived: (item.Procurement_Qty_Received__c != null) ? item.Procurement_Qty_Received__c : (item.Supply_Request_Qty_Received__c || 0),
                SupplyRequestQtyPlanned: (item.Procurement_Qty_Planned__c != null) ? item.Procurement_Qty_Planned__c : (item.Supply_Request_Qty_Planned__c || 0)
            };
        });
    }

    // Pagination Getters
    get totalPages() {
        return Math.ceil(this.allLineItems.length / this.pageSize) || 1;
    }

    get showPagination() {
        return this.totalPages > 1;
    }

    get pagedLineItems() {
        const start = (this.currentPage - 1) * this.pageSize;
        const end = start + this.pageSize;
        return this.allLineItems.slice(start, end);
    }

    handlePageChange(event) {
        this.currentPage = event.detail.currentPage;
        this.pageSize = event.detail.pageSize;
    }

    navigateToLineItem(event) {
        event.preventDefault();
        const itemId = event.currentTarget.dataset.id;
        if (!itemId) return;
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: {
                recordId: itemId,
                actionName: 'view'
            }
        }).then((url) => {
            window.open(url, '_blank');
        }).catch(() => {
            window.open('/' + itemId, '_blank');
        });
    }

    injectCustomStyles() {
        const style = document.createElement('style');
        style.innerText = `
            .generic-search-panel-mini .search-filter-panel {
                background: transparent !important;
                border: none !important;
                box-shadow: none !important;
                padding: 8px 0 !important;
            }
            .generic-search-panel-mini .reset-btn-custom {
                font-size: 0 !important;
                width: 32px !important;
                min-width: 32px !important;
                height: 32px !important;
                padding: 0 !important;
                border-radius: 50% !important;
                display: inline-flex !important;
                align-items: center !important;
                justify-content: center !important;
                border: 1px solid #cbd5e1 !important;
                background-color: #ffffff !important;
                box-shadow: 0 1px 2px rgba(0,0,0,0.05) !important;
                margin-top: 20px !important;
            }
            .generic-search-panel-mini .reset-btn-custom:hover {
                background-color: #f8fafc !important;
                border-color: #94a3b8 !important;
            }
            .generic-search-panel-mini .reset-btn-custom lightning-icon {
                margin: 0 !important;
            }
            .generic-search-panel-mini .search-input-field {
                margin-bottom: 0 !important;
            }
        `;
        document.head.appendChild(style);
    }
}