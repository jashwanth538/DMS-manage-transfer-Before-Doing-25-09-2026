import { LightningElement, track, wire, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, publish, MessageContext } from 'lightning/messageService';
import SUPPLY_PLAN_UPDATE_MC from '@salesforce/messageChannel/SupplyPlanUpdate__c';
import SUPPLY_PLAN_ACTION_MC from '@salesforce/messageChannel/SupplyPlanAction__c';
import searchSupplyPlans from '@salesforce/apex/SupplyPlanController.searchSupplyPlans';
import getSupplyPlanDetails from '@salesforce/apex/SupplyPlanController.getSupplyPlanDetails';

export default class SupplyPlanSearch extends NavigationMixin(LightningElement) {
    @track searchKey = '';
    @track suggestions = [];
    @track selectedPlan = null;
    @track showSuggestions = false;
    @track isLoading = false;
    @track rawInventories = [];
    @track selectedWarehouse = 'All Warehouses';
    
    _recordId;
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.fetchPlanDetails(value);
        }
    }
    
    @track lmsCoveragePercent = null;
    @track lmsAllReviewed = false;
    @track isConfirmed = false;
    @track transferCount = 0;

    @wire(MessageContext)
    messageContext;
    subscription = null;
    actionSubscription = null;

    connectedCallback() {
        this.subscribeToMessageChannel();
        this.subscribeToActionChannel();
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

    subscribeToActionChannel() {
        if (!this.actionSubscription) {
            this.actionSubscription = subscribe(
                this.messageContext,
                SUPPLY_PLAN_ACTION_MC,
                (message) => this.handleActionMessage(message)
            );
        }
    }

    handleMessage(message) {
        if (message && message.summaryData) {
            this.lmsCoveragePercent = message.summaryData.totalCoveredPercent;
            this.lmsAllReviewed = message.summaryData.allReviewed === true;
        }
    }

    handleActionMessage(message) {
        if (message && message.actionType === 'SUBMIT_COMPLETE') {
            if (this.selectedPlan) {
                this.fetchPlanDetails(this.selectedPlan.Id);
            }
        } else if (message && message.actionType === 'SUBMIT_FAIL') {
            this.isLoading = false;
        }
    }
    
    // Wire search method to fetch suggestions as user types
    @wire(searchSupplyPlans, { searchKey: '$searchKey' })
    wiredSuggestions({ error, data }) {
        if (data) {
            if (data.isSuccess) {
                this.suggestions = (data.resultList || []).map(plan => {
                    return {
                        ...plan,
                        InventoryLocationName: plan.Target_Location__r ? plan.Target_Location__r.Name : (plan.Inventory_Location__r ? plan.Inventory_Location__r.Name : 'N/A')
                    };
                });
            } else {
                this.suggestions = [];
                console.error('Apex Error in searchSupplyPlans:', data.errorMsg);
            }
        } else if (error) {
            this.suggestions = [];
            console.error('Error fetching search suggestions:', error);
        }
    }

    get showSearchInput() {
        return !this.recordId;
    }

    get hasSuggestions() {
        return this.suggestions && this.suggestions.length > 0;
    }

    get isNotPlanSelected() {
        return !this.selectedPlan;
    }

    get isPlanConfirmed() {
        return this.selectedPlan && this.selectedPlan.Status__c && this.selectedPlan.Status__c !== 'Draft';
    }

    get isConfirmDisabled() {
        return !this.selectedPlan || !this.lmsAllReviewed || this.isLoading;
    }

    get isConfirmHidden() {
        return this.isPlanConfirmed;
    }

    get isManageTransferVisible() {
        return !!this.isPlanConfirmed && this.transferCount > 0;
    }

    get confirmPlanTooltip() {
        if (!this.selectedPlan) {
            return 'Please select a Sales Allocation first';
        }
        if (!this.lmsAllReviewed) {
            return 'Sales Allocation Planner Review is pending';
        }
        return 'Confirm this Sales Allocation plan';
    }

    get isCustomerAllocation() {
        return false;
    }

    get isSupplyingAccountRetailer() {
        return false;
    }

    get requestingAccountLabel() {
        return 'Requesting Account';
    }

    get selectedPlanStatus() {
        return this.selectedPlan && this.selectedPlan.Status__c ? this.selectedPlan.Status__c : 'Draft';
    }

    get statusBadgeClass() {
        const status = this.selectedPlanStatus.toLowerCase();
        let baseClass = 'slds-badge badge-custom ';
        if (status === 'planned') {
            return baseClass + 'badge-success';
        } else if (status === 'in progress' || status === 'active') {
            return baseClass + 'badge-warning';
        } else if (status === 'draft') {
            return baseClass + 'badge-info';
        }
        return baseClass + 'badge-neutral';
    }

    get totalLines() {
        if (this.selectedPlan && this.selectedPlan.Order_Allocation_Line_Items__r) {
            return this.selectedPlan.Order_Allocation_Line_Items__r.length;
        }
        return 0;
    }

    get totalRequiredQty() {
        if (this.selectedPlan && this.selectedPlan.Order_Allocation_Line_Items__r) {
            return this.selectedPlan.Order_Allocation_Line_Items__r.reduce((sum, item) => sum + (item.Ordered_Qty__c || 0), 0);
        }
        return 0;
    }

    get hasLineItems() {
        return this.totalLines > 0;
    }

    get lineItems() {
        if (!this.selectedPlan || !this.selectedPlan.Order_Allocation_Line_Items__r) {
            return [];
        }
        const parentStatus = this.selectedPlanStatus;
        const parentCoverage = this.coveragePercent;
        
        return this.selectedPlan.Order_Allocation_Line_Items__r.map(item => {
            const coverage = parentCoverage;
            let progressBarClass = 'slds-progress-bar__value ';
            let statusBadgeClass = 'slds-badge badge-custom ';
            
            if (coverage === 100) {
                progressBarClass += 'progress-bar-success';
                statusBadgeClass += 'badge-success';
            } else if (coverage === 75) {
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
                Quantity: item.Ordered_Qty__c || 0,
                Coverage: coverage,
                coverageStyle: `width: ${coverage}%`,
                progressBarClass: progressBarClass,
                Status: parentStatus,
                statusBadgeClass: statusBadgeClass
            };
        });
    }

    // Gauge calculations matching the layout style in the reference image
    get coveragePercent() {
        if (this.lmsCoveragePercent !== null && this.lmsCoveragePercent !== undefined) {
            const rawPct = Number(this.lmsCoveragePercent);
            return rawPct < 100 ? Math.min(99, Math.round(rawPct)) : Math.round(rawPct);
        }
        if (!this.selectedPlan) return 0;

        // Calculate dynamic coverage from line items if available
        if (this.selectedPlan.Order_Allocation_Line_Items__r && this.selectedPlan.Order_Allocation_Line_Items__r.length > 0) {
            let totalRequired = 0;
            let totalPlanned = 0;
            this.selectedPlan.Order_Allocation_Line_Items__r.forEach(item => {
                totalRequired += (item.Ordered_Qty__c || 0);
                totalPlanned += (item.Reserved_Qty_Planned__c || 0) + (item.Transfer_Qty_Planned__c || 0) + (item.Procurement_Qty_Planned__c || 0);
            });
            if (totalRequired > 0) {
                const pct = (totalPlanned / totalRequired) * 100;
                return totalPlanned < totalRequired ? Math.min(99, Math.round(pct)) : Math.round(pct);
            }
        }

        const status = this.selectedPlanStatus.toLowerCase();
        if (status === 'draft') return 25;
        if (status === 'in progress') return 75;
        return 100;
    }

    get coveragePercentText() {
        return `${this.coveragePercent}%`;
    }

    get coverageLabelText() {
        const status = this.selectedPlanStatus.toLowerCase();
        if (status === 'planned') return 'Coverage';
        return 'Progress';
    }

    get coverageDashArray() {
        const percent = this.coveragePercent;
        return `${percent}, 100`;
    }

    get circleStrokeClass() {
        const status = this.selectedPlanStatus.toLowerCase();
        if (status === 'planned') return 'circle circle-success';
        if (status === 'in progress') return 'circle circle-warning';
        return 'circle circle-info';
    }

    // Event Handlers
    handleSearchChange(event) {
        this.searchKey = event.target.value;
        this.showSuggestions = true;
    }

    handleSearchFocus() {
        this.showSuggestions = true;
    }

    handleSearchBlur() {
        // Delay closing so that click events on the suggestions are registered first
        setTimeout(() => {
            this.showSuggestions = false;
        }, 300);
    }

    handleSelectPlan(event) {
        const planId = event.currentTarget.dataset.id;
        this.fetchPlanDetails(planId);
        this.dispatchEvent(new CustomEvent('planselected', { detail: planId }));
    }

    handleClearSearch() {
        this.searchKey = '';
        this.selectedPlan = null;
        this.suggestions = [];
        this.showSuggestions = false;
        this.isConfirmed = false;
        this.lmsAllReviewed = false;
        this.transferCount = 0;
        this.dispatchEvent(new CustomEvent('planselected', { detail: null }));
    }

    handleRefresh() {
        if (this.selectedPlan) {
            this.fetchPlanDetails(this.selectedPlan.Id);
            this.showToast('Success', 'Plan details refreshed', 'success');
        }
    }

    handleSavePlan() {
        this.showToast('Info', 'Supply Plan saved successfully.', 'info');
    }

    handleConfirmPlan() {
        if (!this.selectedPlan) return;
        this.isLoading = true;
        
        publish(this.messageContext, SUPPLY_PLAN_ACTION_MC, {
            actionType: 'SUBMIT_PLAN',
            planNumber: this.selectedPlan.Name
        });
    }

    handleManageTransfer() {
        const planNumber = this.selectedPlan ? this.selectedPlan.Name : '';
        const pageRef = {
            type: 'standard__navItemPage',
            attributes: {
                apiName: 'Manage_Transfer'
            },
            state: {
                c__planNumber: planNumber
            }
        };

        this[NavigationMixin.GenerateUrl](pageRef)
            .then(url => {
                window.open(url, '_blank');
            })
            .catch(error => {
                console.error('Error generating URL for Manage Transfer page:', error);
            });
    }

    fetchPlanDetails(planId) {
        this.isLoading = true;
        this.lmsAllReviewed = false;
        this.transferCount = 0;
        
        getSupplyPlanDetails({ planIdentifier: planId })
            .then(wrapper => {
                if (wrapper && wrapper.isSuccess) {
                    const plan = wrapper.result;
                    const requestingAccId = plan.Requesting_Account__c;
                    const requestingAccName = plan.Requesting_Account__r ? plan.Requesting_Account__r.Name : '';
                    const supplyingAccId = plan.Supplying_Account__c || (plan.Target_Location__r ? plan.Target_Location__r.Account__c : null);
                    const supplyingAccName = plan.Supplying_Account__r ? plan.Supplying_Account__r.Name : (plan.Target_Location__r && plan.Target_Location__r.Account__r ? plan.Target_Location__r.Account__r.Name : '');

                    const supplyingAccType = (plan.Supplying_Account__r && plan.Supplying_Account__r.Type) || 
                                             (plan.Target_Location__r && plan.Target_Location__r.Account__r && plan.Target_Location__r.Account__r.Type) || '';
                    const supplyingAccRecordTypeName = (plan.Supplying_Account__r && plan.Supplying_Account__r.RecordType && plan.Supplying_Account__r.RecordType.Name) || '';
                    const supplyingAccRecordTypeDevName = (plan.Supplying_Account__r && plan.Supplying_Account__r.RecordType && plan.Supplying_Account__r.RecordType.DeveloperName) || '';

                    const isRetailer = (supplyingAccType && supplyingAccType.toLowerCase() === 'retailer') ||
                                       (supplyingAccRecordTypeName && supplyingAccRecordTypeName.toLowerCase() === 'retailer') ||
                                       (supplyingAccRecordTypeDevName && supplyingAccRecordTypeDevName.toLowerCase() === 'retailer') ||
                                       (supplyingAccName && supplyingAccName.toLowerCase().includes('retailer')) ||
                                       (!requestingAccId);

                    const customerName = plan.Customer_Name__c || '';

                    this.selectedPlan = {
                        ...plan,
                        Requesting_Account__c: requestingAccId,
                        RequestingAccountName: requestingAccName,
                        Supplying_Account__c: supplyingAccId,
                        SupplyingAccountName: supplyingAccName,
                        Customer_Name__c: customerName,
                        CustomerName: customerName,
                        isRetailer: isRetailer
                    };
                    this.rawInventories = wrapper.referenceCache ? wrapper.referenceCache.inventories || [] : [];
                    this.transferCount = (wrapper.referenceCache && wrapper.referenceCache.transferCount) || 0;
                    this.selectedWarehouse = 'All Warehouses';
                    this.searchKey = this.selectedPlan.Name;
                    this.showSuggestions = false;
                    this.dispatchEvent(new CustomEvent('planselected', { detail: this.selectedPlan.Id }));
                } else {
                    const errMsg = wrapper ? wrapper.errorMsg : 'Unknown error';
                    console.error('Apex Error:', errMsg);
                    this.showToast('Error', 'Could not fetch plan details: ' + errMsg, 'error');
                }
            })
            .catch(error => {
                console.error('Error fetching plan details:', error);
                this.showToast('Error', 'Could not fetch plan details: ' + (error.body ? error.body.message : error.message), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    // Navigation methods to standard records
    navigateToRecord(event) {
        event.preventDefault();
        if (this.selectedPlan && this.selectedPlan.Id) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.selectedPlan.Id,
                    actionName: 'view'
                }
            }).then(url => {
                window.open(url, '_blank');
            }).catch(() => {
                window.open('/' + this.selectedPlan.Id, '_blank');
            });
        }
    }

    navigateToCustomer(event) {
        event.preventDefault();
        if (this.selectedPlan && this.selectedPlan.Customer__c) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.selectedPlan.Customer__c,
                    actionName: 'view'
                }
            }).then(url => {
                window.open(url, '_blank');
            }).catch(() => {
                window.open('/' + this.selectedPlan.Customer__c, '_blank');
            });
        }
    }

    navigateToRequestingAccount(event) {
        event.preventDefault();
        if (this.selectedPlan && this.selectedPlan.Requesting_Account__c) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.selectedPlan.Requesting_Account__c,
                    actionName: 'view'
                }
            }).then(url => {
                window.open(url, '_blank');
            }).catch(() => {
                window.open('/' + this.selectedPlan.Requesting_Account__c, '_blank');
            });
        }
    }

    navigateToSupplyingAccount(event) {
        event.preventDefault();
        const accId = this.selectedPlan.Supplying_Account__c || (this.selectedPlan.Target_Location__r ? this.selectedPlan.Target_Location__r.Account__c : null);
        if (accId) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: accId,
                    actionName: 'view'
                }
            }).then(url => {
                window.open(url, '_blank');
            }).catch(() => {
                window.open('/' + accId, '_blank');
            });
        }
    }

    navigateToLocation(event) {
        event.preventDefault();
        if (this.selectedPlan && this.selectedPlan.Inventory_Location__c) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.selectedPlan.Inventory_Location__c,
                    actionName: 'view'
                }
            }).then(url => {
                window.open(url, '_blank');
            }).catch(() => {
                window.open('/' + this.selectedPlan.Inventory_Location__c, '_blank');
            });
        }
    }

    navigateToContact(event) {
        event.preventDefault();
        if (this.selectedPlan && this.selectedPlan.Bill_To_Contact__c) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.selectedPlan.Bill_To_Contact__c,
                    actionName: 'view'
                }
            }).then(url => {
                window.open(url, '_blank');
            }).catch(() => {
                window.open('/' + this.selectedPlan.Bill_To_Contact__c, '_blank');
            });
        }
    }

    navigateToLineItem(event) {
        event.preventDefault();
        const itemId = event.currentTarget.dataset.id;
        if (itemId) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: itemId,
                    actionName: 'view'
                }
            }).then(url => {
                window.open(url, '_blank');
            }).catch(() => {
                window.open('/' + itemId, '_blank');
            });
        }
    }

    // Inventory Availability calculations & getters
    get hasInventory() {
        return this.inventoryHeaders.length > 0;
    }

    get inventoryHeaders() {
        if (!this.selectedPlan || !this.selectedPlan.Order_Allocation_Line_Items__r) {
            return [];
        }
        const itemMap = new Map();
        this.selectedPlan.Order_Allocation_Line_Items__r.forEach(line => {
            if (line.Item__c && !itemMap.has(line.Item__c)) {
                itemMap.set(line.Item__c, line.Item__r ? line.Item__r.Name : 'Unknown Item');
            }
        });
        
        return Array.from(itemMap.entries()).map(([itemId, itemName]) => {
            return {
                id: itemId,
                label: `${itemName} (Available)`
            };
        });
    }

    get allInventoryRows() {
        if (!this.selectedPlan) {
            return [];
        }
        const headers = this.inventoryHeaders;
        const destinationId = this.selectedPlan.Inventory_Location__c;
        const destinationName = this.selectedPlan.InventoryLocationName;
        
        const locationMap = new Map();
        if (destinationId) {
            locationMap.set(destinationId, destinationName);
        }
        
        this.rawInventories.forEach(inv => {
            if (inv.Inventory_Location__c) {
                locationMap.set(inv.Inventory_Location__c, inv.Inventory_Location__r ? inv.Inventory_Location__r.Name : 'Unknown Warehouse');
            }
        });
        
        const rows = [];
        locationMap.forEach((locName, locId) => {
            let totalAvailable = 0;
            const itemAvailabilities = headers.map(header => {
                const matchedInvs = this.rawInventories.filter(inv => inv.Inventory_Location__c === locId && inv.Item__c === header.id);
                const qty = matchedInvs.reduce((sum, inv) => sum + (inv.Available_Ordered_Qty__c || 0), 0);
                totalAvailable += qty;
                return {
                    productId: header.id,
                    quantity: qty
                };
            });
            
            const isDestination = locId === destinationId;
            const displayName = isDestination ? `${locName} (Destination)` : locName;
            
            rows.push({
                locationId: locId,
                locationName: displayName,
                itemAvailabilities: itemAvailabilities,
                totalAvailable: totalAvailable,
                isDestination: isDestination
            });
        });
        
        rows.sort((a, b) => {
            if (a.isDestination) return -1;
            if (b.isDestination) return 1;
            return a.locationName.localeCompare(b.locationName);
        });
        
        const maxTotal = rows.reduce((max, r) => Math.max(max, r.totalAvailable), 0);
        
        return rows.map(r => {
            const percent = maxTotal > 0 ? (r.totalAvailable / maxTotal) * 100 : 0;
            return {
                ...r,
                progressStyle: `width: ${percent}%`,
                progressBarClass: r.totalAvailable > 0 ? 'progress-bar-blue' : 'progress-bar-empty'
            };
        });
    }

    get warehouseOptions() {
        const options = [{ label: 'All Warehouses', value: 'All Warehouses' }];
        if (!this.selectedPlan) return options;
        
        this.allInventoryRows.forEach(r => {
            options.push({
                label: r.locationName,
                value: r.locationId
            });
        });
        return options;
    }

    get inventoryRows() {
        const rows = this.allInventoryRows;
        if (this.selectedWarehouse === 'All Warehouses') {
            return rows;
        }
        return rows.filter(r => r.locationId === this.selectedWarehouse);
    }

    get inventoryTotals() {
        const headers = this.inventoryHeaders;
        const filteredRows = this.inventoryRows;
        
        let grandTotal = 0;
        const colTotals = headers.map(header => {
            const colSum = filteredRows.reduce((sum, row) => {
                const item = row.itemAvailabilities.find(avail => avail.productId === header.id);
                return sum + (item ? item.quantity : 0);
            }, 0);
            grandTotal += colSum;
            return {
                productId: header.id,
                quantity: colSum
            };
        });
        
        return {
            itemAvailabilities: colTotals,
            totalAvailable: grandTotal
        };
    }

    handleWarehouseChange(event) {
        this.selectedWarehouse = event.detail.value;
    }
}