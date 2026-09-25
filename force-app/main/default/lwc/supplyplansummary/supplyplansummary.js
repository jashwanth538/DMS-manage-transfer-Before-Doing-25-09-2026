import { LightningElement, api, wire, track } from 'lwc';
import getSupplyPlanSummary from '@salesforce/apex/SupplyPlanController.getSupplyPlanSummary';
import { refreshApex } from '@salesforce/apex';
import { subscribe, MessageContext } from 'lightning/messageService';
import SUPPLY_PLAN_UPDATE_MC from '@salesforce/messageChannel/SupplyPlanUpdate__c';
import SUPPLY_PLAN_ACTION_MC from '@salesforce/messageChannel/SupplyPlanAction__c';

export default class Supplyplansummary extends LightningElement {
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
    @track planDetails;
    @track error;
    isLoading = false;

    searchTerm = '';
    searchKey = '';

    // Midpoints and visibility for labels inside donut segments
    @track reservedTextX = '0';
    @track reservedTextY = '0';
    @track reservedTextTransform = '';
    @track showReservedText = false;

    @track transferTextX = '0';
    @track transferTextY = '0';
    @track transferTextTransform = '';
    @track showTransferText = false;

    @track procurementTextX = '0';
    @track procurementTextY = '0';
    @track procurementTextTransform = '';
    @track showProcurementText = false;

    get reservedLabel() {
        return 'Reserved';
    }

    get transferLabel() {
        return 'Transfer';
    }

    get reservedPercentFormatted() {
        return this.summaryData ? Number(this.summaryData.reservedPercent).toFixed(2).replace(/\.00$/, '') : '0';
    }

    get transferPercentFormatted() {
        return this.summaryData ? Number(this.summaryData.transferPercent).toFixed(2).replace(/\.00$/, '') : '0';
    }

    get procurementPercentFormatted() {
        return this.summaryData ? Number(this.summaryData.procurementPercent).toFixed(2).replace(/\.00$/, '') : '0';
    }

    get totalCoveredPercentFormatted() {
        return this.summaryData ? Number(this.summaryData.totalCoveredPercent).toFixed(2).replace(/\.00$/, '') : '0';
    }

    get remainingQtyFormatted() {
        if (!this.summaryData) return '0';
        const remaining = Math.max(0, (this.summaryData.totalRequired || 0) - (this.summaryData.totalCovered || 0));
        return this.formatIndianNumber(remaining);
    }

    get remainingPercentFormatted() {
        if (!this.summaryData) return '0';
        const remainingPct = Math.max(0, 100 - (Number(this.summaryData.totalCoveredPercent) || 0));
        return remainingPct.toFixed(2).replace(/\.00$/, '');
    }

    get totalRequiredFormatted() {
        return this.summaryData ? this.formatIndianNumber(this.summaryData.totalRequired) : '0';
    }

    get donutValStyle() {
        const text = this.totalRequiredFormatted;
        const len = text.length;
        let fontSize = 7.2;
        if (len > 5) {
            fontSize = Math.max(3.0, Math.min(7.2, 40 / len));
        }
        return `font-size: ${fontSize.toFixed(2)}px;`;
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
        if (val >= 10000000) { // 1 Crore
            return (val / 10000000).toFixed(2).replace(/\.?0+$/, '') + ' Cr';
        }
        if (val >= 100000) { // 1 Lakh
            return (val / 100000).toFixed(2).replace(/\.?0+$/, '') + ' Lakh';
        }
        return val.toLocaleString('en-IN');
    }

    // Chart Data
    reservedDashArray = '0, 100';
    transferDashArray = '0, 100';
    transferDashOffset = '0';
    procurementDashArray = '0, 100';
    procurementDashOffset = '0';

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

    handleMessage(message) {
        if (message && message.summaryData) {
            const data = message.summaryData;
            this.summaryData = data;
            this.planDetails = data.planDetails;
            this.calculateChartSegments(data);
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
                // Round data for display
                this.summaryData = {
                    ...data,
                    reservedPercent: data.reservedPercent != null ? Number(data.reservedPercent).toFixed(2) : 0,
                    transferPercent: data.transferPercent != null ? Number(data.transferPercent).toFixed(2) : 0,
                    procurementPercent: data.procurementPercent != null ? Number(data.procurementPercent).toFixed(2) : 0,
                    totalCoveredPercent: data.totalCoveredPercent != null ? Number(data.totalCoveredPercent).toFixed(2) : 0
                };
                if (data.planDetails) {
                    this.planDetails = data.planDetails.map((detail, index) => {
                        let badgeClass = 'badge-reservation';
                        if (detail.sourceType === 'Transfer') badgeClass = 'badge-transfer';
                        if (detail.sourceType === 'Procurement') badgeClass = 'badge-procurement';
                        
                        return {
                            ...detail,
                            index: index + 1,
                            badgeClass: badgeClass,
                            lineItemUrl: '/' + detail.lineItemId
                        };
                    });
                }
                this.calculateChartSegments(data);
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

    calculateChartSegments(data) {
        // Handle case where total is 0
        if (!data.totalRequired || data.totalRequired === 0) {
            this.showReservedText = false;
            this.showTransferText = false;
            this.showProcurementText = false;
            return;
        }

        const reservedQty = Number(data.reservedQty) || 0;
        const transferQty = Number(data.transferQty) || 0;
        const procurementQty = Number(data.procurementQty) || 0;
        const totalRequired = Number(data.totalRequired) || 0;
        const totalCovered = Number(data.totalCovered) || 0;

        const maxVal = Math.max(totalRequired, totalCovered);
        
        if (maxVal === 0) {
            this.showReservedText = false;
            this.showTransferText = false;
            this.showProcurementText = false;
            return;
        }

        const reservedSize = (reservedQty / maxVal) * 100;
        const transferSize = (transferQty / maxVal) * 100;
        const procurementSize = (procurementQty / maxVal) * 100;

        // SVG stroke-dasharray works as "length, gap".
        this.reservedDashArray = `${reservedSize}, ${100 - reservedSize}`;
        
        // Offset for transfer is the negative length of reserved
        this.transferDashArray = `${transferSize}, ${100 - transferSize}`;
        this.transferDashOffset = `-${reservedSize}`;

        // Offset for procurement is negative length of reserved + transfer
        this.procurementDashArray = `${procurementSize}, ${100 - procurementSize}`;
        this.procurementDashOffset = `-${reservedSize + transferSize}`;

        // Calculate segment percentage text locations
        const radius = 15.9155;

        // Reserved
        this.showReservedText = reservedSize > 5;
        if (this.showReservedText) {
            const midReserved = reservedSize / 2;
            const angleReserved = (midReserved / 100) * 2 * Math.PI - Math.PI / 2;
            this.reservedTextX = (20 + radius * Math.cos(angleReserved)).toFixed(2);
            this.reservedTextY = (20 + radius * Math.sin(angleReserved)).toFixed(2);
            let rotReserved = (angleReserved * 180 / Math.PI) + 90;
            rotReserved = (rotReserved % 360 + 360) % 360;
            if (rotReserved > 90 && rotReserved < 270) {
                rotReserved -= 180;
            }
            this.reservedTextTransform = `rotate(${rotReserved.toFixed(2)} ${this.reservedTextX} ${this.reservedTextY})`;
        }

        // Transfer
        this.showTransferText = transferSize > 5;
        if (this.showTransferText) {
            const midTransfer = reservedSize + (transferSize / 2);
            const angleTransfer = (midTransfer / 100) * 2 * Math.PI - Math.PI / 2;
            this.transferTextX = (20 + radius * Math.cos(angleTransfer)).toFixed(2);
            this.transferTextY = (20 + radius * Math.sin(angleTransfer)).toFixed(2);
            let rotTransfer = (angleTransfer * 180 / Math.PI) + 90;
            rotTransfer = (rotTransfer % 360 + 360) % 360;
            if (rotTransfer > 90 && rotTransfer < 270) {
                rotTransfer -= 180;
            }
            this.transferTextTransform = `rotate(${rotTransfer.toFixed(2)} ${this.transferTextX} ${this.transferTextY})`;
        }

        // Procurement
        this.showProcurementText = procurementSize > 5;
        if (this.showProcurementText) {
            const midProcurement = reservedSize + transferSize + (procurementSize / 2);
            const angleProcurement = (midProcurement / 100) * 2 * Math.PI - Math.PI / 2;
            this.procurementTextX = (20 + radius * Math.cos(angleProcurement)).toFixed(2);
            this.procurementTextY = (20 + radius * Math.sin(angleProcurement)).toFixed(2);
            let rotProcurement = (angleProcurement * 180 / Math.PI) + 90;
            rotProcurement = (rotProcurement % 360 + 360) % 360;
            if (rotProcurement > 90 && rotProcurement < 270) {
                rotProcurement -= 180;
            }
            this.procurementTextTransform = `rotate(${rotProcurement.toFixed(2)} ${this.procurementTextX} ${this.procurementTextY})`;
        }
    }
}