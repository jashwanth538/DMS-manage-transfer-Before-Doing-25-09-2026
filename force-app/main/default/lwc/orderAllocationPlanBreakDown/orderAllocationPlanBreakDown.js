import { LightningElement, api, wire, track } from 'lwc';
import getSupplyPlanSummary from '@salesforce/apex/OrderAllocationPlanBreakdownController.getSupplyPlanSummary';
import { refreshApex } from '@salesforce/apex';
import { subscribe, MessageContext } from 'lightning/messageService';
import SUPPLY_PLAN_UPDATE_MC from '@salesforce/messageChannel/SupplyPlanUpdate__c';
import SUPPLY_PLAN_ACTION_MC from '@salesforce/messageChannel/SupplyPlanAction__c';

export default class OrderAllocationPlanBreakDown extends LightningElement {
    _recordId;
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.searchKey = value;
        if (value) {
            this.isLoading = true;
        }
    }
    @track summaryData;
    @track error;
    isLoading = false;

    searchTerm = '';
    searchKey = '';

    @wire(MessageContext)
    messageContext;
    subscription = null;
    actionSubscription = null;

    connectedCallback() {
        if (this.recordId) {
            this.searchKey = this.recordId;
            this.isLoading = true;
        }
        this.subscribeToMessageChannel();
        this.subscribeToActionChannel();
    }

    subscribeToActionChannel() {
        if (!this.actionSubscription) {
            this.actionSubscription = subscribe(
                this.messageContext,
                SUPPLY_PLAN_ACTION_MC,
                (message) => {
                    if (message && (message.actionType === 'SUBMIT_COMPLETE' || message.actionType === 'CONFIRM_COMPLETE')) {
                        this.isLoading = true;
                        if (this.wiredSummaryResult) {
                            refreshApex(this.wiredSummaryResult)
                                .finally(() => {
                                    this.isLoading = false;
                                });
                        } else {
                            this.isLoading = false;
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

    get reservedQtyFormatted() {
        return this.summaryData ? this.formatIndianNumber(this.summaryData.reservedQty) : '0';
    }

    get transferQtyFormatted() {
        return this.summaryData ? this.formatIndianNumber(this.summaryData.transferQty) : '0';
    }

    get procurementQtyFormatted() {
        return this.summaryData ? this.formatIndianNumber(this.summaryData.procurementQty) : '0';
    }

    get totalCoveredFormatted() {
        return this.summaryData ? this.formatIndianNumber(this.summaryData.totalCovered) : '0';
    }

    formatIndianNumber(num) {
        if (num === null || num === undefined || isNaN(num)) return '0';
        const val = Number(num);
        if (val >= 10000000) {
            return (val / 10000000).toFixed(2).replace(/\.?0+$/, '') + ' Cr';
        }
        if (val >= 100000) {
            return (val / 100000).toFixed(2).replace(/\.?0+$/, '') + ' Lakh';
        }
        return val.toLocaleString('en-IN');
    }

    handleMessage(message) {
        if (message && message.summaryData) {
            const data = message.summaryData;
            this.summaryData = {
                ...data,
                reservedPercent: data.reservedPercent != null ? Number(data.reservedPercent).toFixed(2) : 0,
                transferPercent: data.transferPercent != null ? Number(data.transferPercent).toFixed(2) : 0,
                procurementPercent: data.procurementPercent != null ? Number(data.procurementPercent).toFixed(2) : 0,
                totalCoveredPercent: data.totalCoveredPercent != null ? Number(data.totalCoveredPercent).toFixed(2) : 0
            };
            this.error = undefined;
            this.isLoading = false;
        }
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleSearchClick() {
        if (this.searchTerm) {
            this.searchKey = this.searchTerm;
            this.isLoading = true;
        }
    }

    wiredSummaryResult;

    @wire(getSupplyPlanSummary, { searchTerm: '$searchKey' })
    wiredSummary(result) {
        this.wiredSummaryResult = result;
        const { error, data } = result;
        this.isLoading = false;
        if (data) {
            if (data.isFound) {
                this.summaryData = {
                    ...data,
                    reservedPercent: data.reservedPercent != null ? Number(data.reservedPercent).toFixed(2) : 0,
                    transferPercent: data.transferPercent != null ? Number(data.transferPercent).toFixed(2) : 0,
                    procurementPercent: data.procurementPercent != null ? Number(data.procurementPercent).toFixed(2) : 0,
                    totalCoveredPercent: data.totalCoveredPercent != null ? Number(data.totalCoveredPercent).toFixed(2) : 0
                };
                this.error = undefined;
            } else {
                if (!this.summaryData) {
                    this.error = 'Supply Plan not found or has no data.';
                }
            }
        } else if (error) {
            if (!this.summaryData) {
                this.error = error.body ? error.body.message : error.message;
            }
        }
    }
}