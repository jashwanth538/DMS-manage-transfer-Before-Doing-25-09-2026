import { LightningElement, api, wire, track } from 'lwc';
import getSupplyPlanSummary from '@salesforce/apex/OrderAllocationPlanDetailsController.getSupplyPlanSummary';
import getLineItemSourceMap from '@salesforce/apex/OrderAllocationPlanDetailsController.getLineItemSourceMap';
import { refreshApex } from '@salesforce/apex';
import { subscribe, MessageContext } from 'lightning/messageService';
import SUPPLY_PLAN_UPDATE_MC from '@salesforce/messageChannel/SupplyPlanUpdate__c';
import SUPPLY_PLAN_ACTION_MC from '@salesforce/messageChannel/SupplyPlanAction__c';

export default class OrderAllocationPlanDetailsComponent extends LightningElement {
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
    @track planDetails = [];
    @track error;
    @track isConfirmed = false;
    @track currentPage = 1;
    pageSize = 5;
    isLoading = false;

    searchTerm = '';
    searchKey = '';

    @track sortBy = '';
    @track sortDirection = 'asc';

    get isSourceTypeSorted() { return this.sortBy === 'sourceType'; }
    get isSourceNumberSorted() { return this.sortBy === 'sourceNumber'; }
    get isStatusSorted() { return this.sortBy === 'status'; }
    get isProductSorted() { return this.sortBy === 'productName'; }
    get isSupplyMethodSorted() { return this.sortBy === 'supplyMethod'; }
    get isLineItemSorted() { return this.sortBy === 'lineItemName'; }
    get isQtySorted() { return this.sortBy === 'qty'; }

    get sortIcon() {
        return this.sortDirection === 'asc' ? 'utility:arrowup' : 'utility:arrowdown';
    }

    get pagedPlanDetails() {
        if (!this.planDetails || this.planDetails.length === 0) {
            return [];
        }
        const start = (this.currentPage - 1) * this.pageSize;
        const end = this.currentPage * this.pageSize;
        return this.planDetails.slice(start, end);
    }

    get showPagination() {
        return this.planDetails && this.planDetails.length > this.pageSize;
    }

    get totalRecords() {
        return this.planDetails ? this.planDetails.length : 0;
    }

    handlePageChange(event) {
        this.currentPage = event.detail.currentPage;
        if (event.detail.pageSize) {
            this.pageSize = event.detail.pageSize;
        }
    }

    @wire(MessageContext)
    messageContext;
    subscription = null;
    actionSubscription = null;

    getStatusBadgeClass(statusVal) {
        if (!statusVal) return 'status-badge status-warning';
        const st = String(statusVal).toLowerCase().trim();
        if (st === 'completed' || st === 'received' || st === 'issued' || st === 'fully reserved' || st === 'consumed') {
            return 'status-badge status-success';
        }
        if (st === 'requested' || st === 'approved' || st === 'in transit' || st === 'in production' || st === 'ordered' || st === 'included in pr' || st === 'included in mo' || st === 'open' || st === 'selected' || st === 'planned' || st === 'reserved' || st === 'partially reserved' || st === 'partially received' || st === 'partially issued') {
            return 'status-badge status-info';
        }
        if (st === 'draft' || st === 'not generated' || st === 'pending' || st === 'reviewed') {
            return 'status-badge status-warning';
        }
        if (st === 'cancelled' || st === 'released') {
            return 'status-badge status-danger';
        }
        return 'status-badge status-info';
    }

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
                        this.isConfirmed = true;
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

    getSourceTypeBadgeClass(sourceType) {
        if (!sourceType) return 'badge-reservation';
        const st = String(sourceType).trim();
        if (st === 'Transfer SR' || st === 'Transfer' || st.includes('Transfer')) {
            return 'badge-transfer';
        }
        if (st === 'Purchase Order' || st === 'Procurement' || st === 'PO') {
            return 'badge-procurement';
        }
        if (st === 'Purchase SR' || st === 'Supply Request' || st.includes('SR')) {
            return 'badge-supply-request';
        }
        if (st === 'Reserved' || st === 'Reservation') {
            return 'badge-reservation';
        }
        return 'badge-supply-request';
    }

    async enrichDetails(rawDetails) {
        if (!rawDetails || rawDetails.length === 0) {
            return [];
        }

        const lineItemIds = [...new Set(rawDetails.map(d => d.lineItemId).filter(id => !!id))];
        let sourceMap = {};
        if (lineItemIds.length > 0) {
            try {
                sourceMap = await getLineItemSourceMap({ lineItemIds });
            } catch (err) {
                console.error('Error fetching source map for line items:', err);
            }
        }

        const enriched = [];
        const seenSrLineItems = new Set();
        const seenRecordKeys = new Set();

        rawDetails.forEach((detail) => {
            let displaySourceType = detail.requestType || detail.sourceType;

            const key = `${detail.lineItemId}_${detail.sourceType}`;
            let dbInfo = null;

            if (detail.sourceId) {
                // If sourceId is already present from backend, match directly by sourceId
                dbInfo = sourceMap ? sourceMap[`${detail.lineItemId}_PO_${detail.sourceId}`] : null;
            }

            if (!dbInfo && detail.requestType === 'Transfer SR') {
                dbInfo = sourceMap ? (sourceMap[`${detail.lineItemId}_Transfer SR`] || sourceMap[`${detail.lineItemId}_Transfer`]) : null;
            } else if (!dbInfo && detail.requestType === 'Purchase SR') {
                dbInfo = sourceMap ? (sourceMap[`${detail.lineItemId}_Purchase SR`] || sourceMap[`${detail.lineItemId}_Supply Request`]) : null;
            } else if (!dbInfo && detail.sourceType === 'Purchase Order') {
                // If it's a Transfer PO vs Procurement PO (checked via reason/warehouse or qty)
                if (detail.reason && detail.reason.includes('Transfer')) {
                    dbInfo = sourceMap ? sourceMap[`${detail.lineItemId}_Transfer PO`] : null;
                } else {
                    dbInfo = sourceMap ? sourceMap[`${detail.lineItemId}_Procurement PO`] : null;
                }
                if (!dbInfo) {
                    dbInfo = sourceMap ? sourceMap[`${detail.lineItemId}_Purchase Order`] : null;
                }
            }

            if (!dbInfo && sourceMap && sourceMap[key]) {
                dbInfo = sourceMap[key];
            }

            let sourceNumber = detail.sourceNumber;
            let sourceId = detail.sourceId;
            let statusVal = detail.status;
            let reason = detail.reason;

            if (dbInfo && (!sourceNumber || sourceNumber === 'Not Generated' || !sourceId)) {
                if (dbInfo.sourceNumber) sourceNumber = dbInfo.sourceNumber;
                if (dbInfo.sourceId) sourceId = dbInfo.sourceId;
                if (dbInfo.status) statusVal = dbInfo.status;
                if (dbInfo.requestType) {
                    displaySourceType = dbInfo.requestType;
                }
                reason = undefined;
            }

            if (!sourceNumber || sourceNumber === '-') {
                sourceNumber = 'Not Generated';
            }

            if (!statusVal) {
                statusVal = 'Draft';
            }

            // Strictly normalize displaySourceType based on user requirement:
            // INVT / Inventory Transfer records should show 'Inventory Transfer'
            // SR records show 'Transfer SR' or 'Purchase SR'
            // PO records show 'Purchase Order'
            if (sourceNumber && sourceNumber.startsWith('INVT -')) {
                displaySourceType = 'Inventory Transfer';
            } else if (sourceNumber && sourceNumber.startsWith('PO -')) {
                displaySourceType = 'Purchase Order';
            } else if (sourceNumber && sourceNumber.startsWith('SR -')) {
                if (detail.requestType === 'Transfer SR' || 
                    displaySourceType === 'Transfer SR' || 
                    displaySourceType === 'Transfer' || 
                    detail.sourceType === 'Transfer' || 
                    detail.sourceType === 'Transfer SR' || 
                    (dbInfo && dbInfo.requestType === 'Transfer SR')) {
                    displaySourceType = 'Transfer SR';
                } else {
                    displaySourceType = 'Purchase SR';
                }
            } else {
                if (displaySourceType === 'Procurement' || displaySourceType === 'Purchase' || displaySourceType === 'Purchase Order' || displaySourceType === 'PO') {
                    displaySourceType = 'Purchase Order';
                } else if (displaySourceType === 'Inventory Transfer' || (dbInfo && dbInfo.requestType === 'Inventory Transfer')) {
                    displaySourceType = 'Inventory Transfer';
                } else if (displaySourceType === 'Transfer' || displaySourceType === 'Transfer SR') {
                    displaySourceType = 'Transfer SR';
                } else if (displaySourceType === 'Reserved' || displaySourceType === 'Reservation') {
                    displaySourceType = 'Reservation';
                }
            }

            const isNotGenerated = sourceNumber === 'Not Generated' || !sourceId;
            if (isNotGenerated && !reason) {
                reason = `Source record (${displaySourceType}) has not been generated in Salesforce yet.`;
            }

            // Deduplicate rows if the same database record was already added for this line item
            if (sourceId && seenRecordKeys.has(`${detail.lineItemId}_${sourceId}`)) {
                return;
            }
            if (sourceId) {
                seenRecordKeys.add(`${detail.lineItemId}_${sourceId}`);
            }

            const badgeClass = this.getSourceTypeBadgeClass(displaySourceType);

            enriched.push({
                ...detail,
                sourceType: displaySourceType,
                uniqueKey: `${detail.lineItemId || ''}-${sourceId || displaySourceType}-${enriched.length}`,
                badgeClass: badgeClass,
                sourceNumber: sourceNumber,
                sourceId: sourceId,
                status: statusVal,
                statusBadgeClass: this.getStatusBadgeClass(statusVal),
                supplyMethod: detail.supplyMethod || (dbInfo && dbInfo.supplyMethod ? dbInfo.supplyMethod : 'Purchase'),
                lineItemUrl: detail.lineItemId ? '/' + detail.lineItemId : '',
                sourceUrl: sourceId ? '/' + sourceId : '',
                isNotGenerated: isNotGenerated,
                isNotGeneratedStyle: isNotGenerated ? 'color: #64748b; font-style: italic; font-size: 0.85rem;' : '',
                reason: reason
            });

            if (displaySourceType === 'Supply Request' || displaySourceType === 'Transfer SR' || displaySourceType === 'Purchase SR' || (dbInfo && dbInfo.requestType)) {
                seenSrLineItems.add(detail.lineItemId);
                if (displaySourceType === 'Purchase SR' || (dbInfo && dbInfo.requestType === 'Purchase SR')) {
                    seenSrLineItems.add(detail.lineItemId + '_PurchaseSR');
                }
                if (displaySourceType === 'Transfer SR' || (dbInfo && dbInfo.requestType === 'Transfer SR')) {
                    seenSrLineItems.add(detail.lineItemId + '_TransferSR');
                }
            }

            // Also show the Purchase Supply Request row if this line item has a Purchase SR and it wasn't already added
            if (detail.lineItemId && (detail.sourceType === 'Purchase Order' || detail.sourceType === 'Procurement')) {
                const srInfo = sourceMap ? (sourceMap[`${detail.lineItemId}_Purchase SR`] || sourceMap[`${detail.lineItemId}_Supply Request`]) : null;
                if (srInfo && !seenSrLineItems.has(detail.lineItemId + '_PurchaseSR') && (!srInfo.sourceId || !seenRecordKeys.has(`${detail.lineItemId}_${srInfo.sourceId}`))) {
                    seenSrLineItems.add(detail.lineItemId + '_PurchaseSR');
                    if (srInfo.sourceId) seenRecordKeys.add(`${detail.lineItemId}_${srInfo.sourceId}`);
                    const srDisplayType = srInfo.requestType || 'Purchase SR';
                    const srBadgeClass = this.getSourceTypeBadgeClass(srDisplayType);

                    enriched.push({
                        ...detail,
                        sourceType: srDisplayType,
                        uniqueKey: `${detail.lineItemId}-${srDisplayType}-${enriched.length}`,
                        badgeClass: srBadgeClass,
                        sourceNumber: srInfo.sourceNumber || 'Not Generated',
                        sourceId: srInfo.sourceId || null,
                        status: srInfo.status || 'Open',
                        statusBadgeClass: this.getStatusBadgeClass(srInfo.status || 'Open'),
                        supplyMethod: srInfo.supplyMethod || 'Purchase',
                        lineItemUrl: detail.lineItemId ? '/' + detail.lineItemId : '',
                        sourceUrl: srInfo.sourceId ? '/' + srInfo.sourceId : '',
                        isNotGenerated: !srInfo.sourceId,
                        isNotGeneratedStyle: !srInfo.sourceId ? 'color: #64748b; font-style: italic; font-size: 0.85rem;' : '',
                        reason: !srInfo.sourceId ? 'Supply Request record not generated yet' : undefined
                    });
                }
            }

            // Also show Transfer SR row if this line item has a Transfer SR that wasn't already added
            if (detail.lineItemId && (detail.sourceType === 'Transfer' || detail.sourceType === 'Transfer SR')) {
                const srInfo = sourceMap ? sourceMap[`${detail.lineItemId}_Transfer SR`] : null;
                if (srInfo && !seenSrLineItems.has(detail.lineItemId + '_TransferSR') && (!srInfo.sourceId || !seenRecordKeys.has(`${detail.lineItemId}_${srInfo.sourceId}`))) {
                    seenSrLineItems.add(detail.lineItemId + '_TransferSR');
                    if (srInfo.sourceId) seenRecordKeys.add(`${detail.lineItemId}_${srInfo.sourceId}`);
                    const srDisplayType = srInfo.requestType || 'Transfer SR';
                    const srBadgeClass = this.getSourceTypeBadgeClass(srDisplayType);

                    enriched.push({
                        ...detail,
                        sourceType: srDisplayType,
                        uniqueKey: `${detail.lineItemId}-${srDisplayType}-${enriched.length}`,
                        badgeClass: srBadgeClass,
                        sourceNumber: srInfo.sourceNumber || 'Not Generated',
                        sourceId: srInfo.sourceId || null,
                        status: srInfo.status || 'Open',
                        statusBadgeClass: this.getStatusBadgeClass(srInfo.status || 'Open'),
                        supplyMethod: srInfo.supplyMethod || 'Purchase',
                        lineItemUrl: detail.lineItemId ? '/' + detail.lineItemId : '',
                        sourceUrl: srInfo.sourceId ? '/' + srInfo.sourceId : '',
                        isNotGenerated: !srInfo.sourceId,
                        isNotGeneratedStyle: !srInfo.sourceId ? 'color: #64748b; font-style: italic; font-size: 0.85rem;' : '',
                        reason: !srInfo.sourceId ? 'Transfer Supply Request record not generated yet' : undefined
                    });
                }
            }

            // Also check if there are additional Purchase Orders for this line item not yet rendered
            if (detail.lineItemId && sourceMap && sourceMap[`${detail.lineItemId}_POs`]) {
                const allItemPos = sourceMap[`${detail.lineItemId}_POs`];
                if (Array.isArray(allItemPos)) {
                    allItemPos.forEach((poInfo) => {
                        if (poInfo && poInfo.sourceId && !seenRecordKeys.has(`${detail.lineItemId}_${poInfo.sourceId}`)) {
                            seenRecordKeys.add(`${detail.lineItemId}_${poInfo.sourceId}`);
                            const poBadgeClass = this.getSourceTypeBadgeClass('Purchase Order');

                            enriched.push({
                                ...detail,
                                sourceType: 'Purchase Order',
                                uniqueKey: `${detail.lineItemId}-PO-${poInfo.sourceId}-${enriched.length}`,
                                badgeClass: poBadgeClass,
                                sourceNumber: poInfo.sourceNumber || 'Not Generated',
                                sourceId: poInfo.sourceId,
                                qty: poInfo.qty || detail.qty,
                                status: poInfo.status || 'Draft',
                                statusBadgeClass: this.getStatusBadgeClass(poInfo.status || 'Draft'),
                                supplyMethod: poInfo.supplyMethod || 'Purchase',
                                lineItemUrl: detail.lineItemId ? '/' + detail.lineItemId : '',
                                sourceUrl: '/' + poInfo.sourceId,
                                isNotGenerated: false,
                                isNotGeneratedStyle: '',
                                reason: undefined
                            });
                        }
                    });
                }
            }
        });

        return enriched.map((item, idx) => ({ ...item, index: idx + 1 }));
    }

    async handleMessage(message) {
        if (message && message.summaryData) {
            const rawDetails = message.summaryData.planDetails || [];
            this.planDetails = await this.enrichDetails(rawDetails);
            this.sortBy = '';
            this.sortDirection = 'asc';
            if (message.summaryData.status && message.summaryData.status !== 'Draft') {
                this.isConfirmed = true;
            } else {
                this.isConfirmed = false;
            }
            this.currentPage = 1;
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
    async wiredSummary(result) {
        this.wiredSummaryResult = result;
        const { error, data } = result;
        this.isLoading = false;
        if (data) {
            if (data.isFound) {
                const status = data.status || data.Status__c;
                if (status && status !== 'Draft') {
                    this.isConfirmed = true;
                } else {
                    this.isConfirmed = false;
                }
                if (data.planDetails) {
                    this.planDetails = await this.enrichDetails(data.planDetails);
                } else {
                    this.planDetails = [];
                }
                this.sortBy = '';
                this.sortDirection = 'asc';
                this.currentPage = 1;
                this.error = undefined;
            } else {
                if (!this.planDetails || this.planDetails.length === 0) {
                    this.planDetails = [];
                    this.currentPage = 1;
                    this.error = 'Supply Plan not found or has no data.';
                }
            }
        } else if (error) {
            if (!this.planDetails || this.planDetails.length === 0) {
                this.error = error.body ? error.body.message : error.message;
                this.planDetails = [];
            }
        }
    }

    handleSort(event) {
        const field = event.currentTarget.dataset.field;
        if (!field) return;

        if (this.sortBy === field) {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortBy = field;
            this.sortDirection = 'asc';
        }

        this.sortData(field, this.sortDirection);
    }

    sortData(fieldname, direction) {
        let parseData = JSON.parse(JSON.stringify(this.planDetails));
        let isAscending = direction === 'asc';
        
        parseData.sort((a, b) => {
            let valA = a[fieldname];
            let valB = b[fieldname];

            if (valA === undefined || valA === null) valA = '';
            if (valB === undefined || valB === null) valB = '';

            if (typeof valA === 'number' && typeof valB === 'number') {
                return isAscending ? valA - valB : valB - valA;
            }

            let strA = String(valA).toLowerCase();
            let strB = String(valB).toLowerCase();

            if (strA < strB) return isAscending ? -1 : 1;
            if (strA > strB) return isAscending ? 1 : -1;
            return 0;
        });

        this.planDetails = parseData;
        this.updateIndexes();
        this.currentPage = 1;
    }

    updateIndexes() {
        this.planDetails = this.planDetails.map((detail, idx) => {
            return {
                ...detail,
                index: idx + 1
            };
        });
    }
}