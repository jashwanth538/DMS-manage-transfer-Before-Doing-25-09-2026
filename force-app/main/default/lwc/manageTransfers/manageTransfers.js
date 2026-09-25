import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { CurrentPageReference } from 'lightning/navigation';
import { subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import searchAndFilterMessageChannel from '@salesforce/messageChannel/searchAndFilterMessage__c';
import getLocations from '@salesforce/apex/InventoryTransferPending.getLocations';
import getPendingTransfers from '@salesforce/apex/InventoryTransferPending.getPendingTransfers';
import getApprovedTransfers from '@salesforce/apex/InventroyAcceptingPannel.getApprovedTransfers';
import getDashboardTransfers from '@salesforce/apex/InventoryTransferPending.getDashboardTransfers';


export default class ManageTransfers extends LightningElement {
    @track searchTerm = '';
    @track inputValue = '';
    @track selectedLocationId = 'All';
    @track locationOptions = [{ label: 'All Locations', value: 'All' }];
    @track selectedRequestType = 'All';
    requestTypeOptions = [
        { label: 'All Request Types', value: 'All' },
        { label: 'Customer Demand', value: 'Customer Demand' },
        { label: 'Transfer SR', value: 'Transfer SR' },
        { label: 'Purchase SR', value: 'Purchase SR' },
        { label: 'Forecast Demand', value: 'Forecast Demand' },
        { label: 'Manual Request', value: 'Manual Request' },
        { label: 'Stock Replenishment', value: 'Stock Replenishment' }
        // { label: 'Manufacturing', value: 'Manufacturing' }
    ];

    pendingTransfers = [];
    approvedTransfers = [];
    allTransfers = [];

    wiredPendingResult;
    wiredApprovedResult;
    wiredDashboardResult;
    dashboardTransfers = [];
    urlPlanNumber = '';

    @wire(MessageContext)
    messageContext;
    searchSubscription = null;

    @wire(getLocations)
    wiredLocations({ data, error }) {
        if (data) {
            this.locationOptions = [
                { label: 'All Locations', value: 'All' },
                ...data.map(loc => ({
                    label: loc.Name,
                    value: loc.Id
                }))
            ];
        } else if (error) {
            console.error('Error loading locations in parent controller:', error);
        }
    }

    @wire(getPendingTransfers)
    wiredPending(result) {
        this.wiredPendingResult = result;
        const { data, error } = result;
        if (data) {
            this.pendingTransfers = data;
            this.combineTransfers();
        } else if (error) {
            console.error('[ManageTransfers] Error loading pending transfers:', error?.body?.message || error?.message || error, error);
        }
    }

    @wire(getApprovedTransfers)
    wiredApproved(result) {
        this.wiredApprovedResult = result;
        const { data, error } = result;
        if (data) {
            this.approvedTransfers = data;
            this.combineTransfers();
        } else if (error) {
            console.error('[ManageTransfers] Error loading approved transfers:', error?.body?.message || error?.message || error, error);
        }
    }

    @wire(getDashboardTransfers)
    wiredDashboard(result) {
        this.wiredDashboardResult = result;
        const { data, error } = result;
        if (data) {
            this.dashboardTransfers = data;
        } else if (error) {
            console.error('[ManageTransfers] Error loading dashboard transfers:', error?.body?.message || error?.message || error, error);
        }
    }

    get metrics() {
        if (!this.dashboardTransfers) {
            return {
                pendingCount: 0,
                inTransitCount: 0,
                totalQtyOutTransit: 0,
                totalQtyInTransit: 0,
            };
        }

        const locId = this.selectedLocationId;
        const hasLoc = locId && locId !== 'All';
        const reqType = this.selectedRequestType;
        const hasReqType = reqType && reqType !== 'All';
        const searchKey = this.searchTerm ? this.searchTerm.toLowerCase().trim() : '';

        let pendingCount = 0;
        let inTransitCount = 0;
        let totalQtyOutTransit = 0;
        let totalQtyInTransit = 0;

        const matchesSearch = (item, locNameField) => {
            if (!searchKey) return true;
            
            const nameMatch = item.Name && item.Name.toLowerCase().includes(searchKey);
            const itemMatch = item.Item__r && item.Item__r.Name && item.Item__r.Name.toLowerCase().includes(searchKey);
            const codeMatch = item.Item__r && item.Item__r.Item_Code__c && item.Item__r.Item_Code__c.toLowerCase().includes(searchKey);
            const allocNameMatch = item.Order_Allocation_Line_Item__r && item.Order_Allocation_Line_Item__r.Order_Allocation__r && item.Order_Allocation_Line_Item__r.Order_Allocation__r.Name && item.Order_Allocation_Line_Item__r.Order_Allocation__r.Name.toLowerCase().includes(searchKey);
            const allocLineMatch = item.Order_Allocation_Line_Item__r && item.Order_Allocation_Line_Item__r.Name && item.Order_Allocation_Line_Item__r.Name.toLowerCase().includes(searchKey);
            
            const locName = item[locNameField] && item[locNameField].Name;
            const locMatch = locName && locName.toLowerCase().includes(searchKey);

            return nameMatch || itemMatch || codeMatch || allocNameMatch || allocLineMatch || locMatch;
        };

        this.dashboardTransfers.forEach(item => {
            // Check request type filter
            const reqTypeMatch = !hasReqType || item.Request_Type__c === reqType;
            if (!reqTypeMatch) return;
            // 1. Pending Count (Status: 'Requested', Location: Source)
            if (item.Status__c === 'Requested') {
                const locMatch = !hasLoc || item.Source_Inventory_Location__c === locId;
                if (locMatch && matchesSearch(item, 'Source_Inventory_Location__r')) {
                    pendingCount++;
                }
            }
            // 2. In-Transit Count & Total Qty In-Transit (Status: 'In Transit', Location: Destination)
            else if (item.Status__c === 'In Transit') {
                const destLocMatch = !hasLoc || item.Destination_Inventory_Location__c === locId;
                if (destLocMatch && matchesSearch(item, 'Destination_Inventory_Location__r')) {
                    inTransitCount++;
                    if (item.Transfer_Qty__c) {
                        totalQtyInTransit += item.Transfer_Qty__c;
                    }
                }

                // 3. Total Qty Out-Transit (Status: 'In Transit', Location: Source)
                const sourceLocMatch = !hasLoc || item.Source_Inventory_Location__c === locId;
                if (sourceLocMatch && matchesSearch(item, 'Source_Inventory_Location__r')) {
                    if (item.Transfer_Qty__c) {
                        totalQtyOutTransit += item.Transfer_Qty__c;
                    }
                }
            }
        });

        return {
            pendingCount,
            inTransitCount,
            totalQtyOutTransit,
            totalQtyInTransit,
        };
    }

    get isClearDisabled() {
        return (!this.searchTerm || this.searchTerm.trim() === '') && this.selectedLocationId === 'All' && this.selectedRequestType === 'All';
    }

    @wire(CurrentPageReference)
    getStateParameters(pageRef) {
        if (pageRef && pageRef.state) {
            const planNum = pageRef.state.c__planNumber || pageRef.state.planNumber;
            if (planNum) {
                this.urlPlanNumber = planNum;
                this.searchTerm = planNum;
                this.inputValue = planNum;
                this.resolvePlanNumberToName(planNum);
            }
        }
    }

    combineTransfers() {
        const pending = this.pendingTransfers || [];
        const approved = this.approvedTransfers || [];
        this.allTransfers = [...pending, ...approved];
        if (this.urlPlanNumber) {
            this.resolvePlanNumberToName(this.urlPlanNumber);
        }
    }

    resolvePlanNumberToName(planNum) {
        if (!planNum) return;
        if (this.allTransfers && this.allTransfers.length > 0) {
            const matchingRecord = this.allTransfers.find(record => {
                const oa = record.Order_Allocation_Line_Item__r?.Order_Allocation__r;
                if (!oa) return false;
                const oaId = oa.Id || record.Order_Allocation_Line_Item__r?.Order_Allocation__c;
                return (oaId && oaId.toLowerCase() === planNum.toLowerCase()) ||
                    (oa.Name && oa.Name.toLowerCase() === planNum.toLowerCase());
            });
            if (matchingRecord) {
                const oaName = matchingRecord.Order_Allocation_Line_Item__r.Order_Allocation__r.Name;
                if (oaName) {
                    this.searchTerm = oaName;
                    this.inputValue = oaName;
                }
            }
        }
    }

    connectedCallback() {
        this.subscribeToSearchChannel();
        this.injectCustomStyles();
    }

    disconnectedCallback() {
        this.unsubscribeFromSearchChannel();
    }

    _stylesInjected = false;
    injectCustomStyles() {
        if (this._stylesInjected) return;
        this._stylesInjected = true;
        const style = document.createElement('style');
        style.setAttribute('data-manage-transfers', 'true');
        style.textContent = `
            /* Scoped to child search panel only – prevents text wrapping in buttons */
            c-generic-search-and-filter-panel .reset-btn-custom {
                white-space: nowrap !important;
                display: inline-flex !important;
                align-items: center !important;
                justify-content: center !important;
                height: 36px !important;
                padding: 0 1.25rem !important;
                margin-top: 0 !important;
            }
            c-generic-search-and-filter-panel .slds-grid {
                display: flex !important;
                flex-direction: row !important;
                align-items: flex-end !important;
                flex-wrap: nowrap !important;
                gap: 12px !important;
                width: 100% !important;
            }
            c-generic-search-and-filter-panel .slds-grid > div:has(.search-input-field) {
                flex: 1 1 auto !important;
                width: auto !important;
                max-width: none !important;
            }
            c-generic-search-and-filter-panel .slds-grid > div:has(.filter-combobox) {
                flex: 0 0 240px !important;
                width: 240px !important;
            }
            c-generic-search-and-filter-panel .action-btn-col {
                flex: 0 0 auto !important;
                display: flex !important;
                align-items: flex-end !important;
                width: auto !important;
            }
        `;
        document.head.appendChild(style);
    }

    subscribeToSearchChannel() {
        if (!this.searchSubscription) {
            this.searchSubscription = subscribe(
                this.messageContext,
                searchAndFilterMessageChannel,
                (message) => this.handleSearchMessage(message)
            );
        }
    }

    unsubscribeFromSearchChannel() {
        if (this.searchSubscription) {
            unsubscribe(this.searchSubscription);
            this.searchSubscription = null;
        }
    }

    handleSearchMessage(message) {
        if (message && message.sourceComponent === 'genericSearchAndFilterPanel') {
            this.searchTerm = message.searchText || '';
            this.inputValue = message.searchText || '';
            this.urlPlanNumber = '';
            this.selectedLocationId = message.filterValue || 'All';
        }
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.inputValue = event.target.value;
        this.urlPlanNumber = '';
    }

    handleLocationChange(event) {
        this.selectedLocationId = event.target.value;
    }

    handleRequestTypeChange(event) {
        this.selectedRequestType = event.target.value;
    }

    handleClearFilters() {
        this.searchTerm = '';
        this.inputValue = '';
        this.urlPlanNumber = '';
        this.selectedLocationId = 'All';
        this.selectedRequestType = 'All';
        
        const searchInput = this.template.querySelector('.search-input');
        if (searchInput) {
            searchInput.value = '';
        }
    }

    handleTransferInitiated() {
        const acceptingPannel = this.template.querySelector('c-inventory-transfer-accpecting-pannel');
        if (acceptingPannel) {
            acceptingPannel.refreshData();
        }
        refreshApex(this.wiredPendingResult);
        refreshApex(this.wiredApprovedResult);
        if (this.wiredDashboardResult) {
            refreshApex(this.wiredDashboardResult);
        }
    }

    handleTransferAccepted() {
        const pendingPannel = this.template.querySelector('c-inventory-transfer-pending-pannel');
        if (pendingPannel) {
            pendingPannel.refreshData();
        }
        refreshApex(this.wiredPendingResult);
        refreshApex(this.wiredApprovedResult);
        if (this.wiredDashboardResult) {
            refreshApex(this.wiredDashboardResult);
        }
    }

    handlePendingRefreshed() {
        refreshApex(this.wiredPendingResult);
        if (this.wiredDashboardResult) {
            refreshApex(this.wiredDashboardResult);
        }
    }

    handleAcceptingRefreshed() {
        refreshApex(this.wiredApprovedResult);
        if (this.wiredDashboardResult) {
            refreshApex(this.wiredDashboardResult);
        }
    }
}