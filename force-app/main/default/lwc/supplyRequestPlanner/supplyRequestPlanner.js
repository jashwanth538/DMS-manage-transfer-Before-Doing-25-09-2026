import { LightningElement, wire, track } from 'lwc';
import getPendingSupplyRequests from '@salesforce/apex/SupplyRequestPlannerController.getPendingSupplyRequests';
import confirmPlan from '@salesforce/apex/SupplyRequestPlannerController.confirmPlan';
import getStockAvailabilityDetails from '@salesforce/apex/SupplyRequestPlannerController.getStockAvailabilityDetails';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

export default class SupplyRequestPlanner extends LightningElement {
    isLoading = true;
    isSaving = false;

    // Selection
    @track selectedRequests = [];
    selectedQty = 0;
    selectedAccountCount = 0;

    // Data lists
    @track supplyRequests = [];
    @track filteredRequests = [];
    wiredResult;

    // Filter controls
    searchTerm = '';
    // selectedStatus = '';

    // Sorting
    sortedBy = 'supplyRequestName';
    sortDirection = 'asc';

    // Pagination
    currentPage = 1;
    pageSize = 10;
    showPageSizeSelector = true;

    // Popup Modal State for created OAs
    isResultModalOpen = false;
    @track createdOAs = [];

    // Stock Availability Modal State
    isStockModalOpen = false;
    isStockLoading = false;
    @track selectedStockRow = {};
    @track stockDetails = { requestInfo: {}, availableStockList: [] };

    @wire(getPendingSupplyRequests)
    wiredRequests(result) {
        this.wiredResult = result;
        const { data, error } = result;
        this.isLoading = false;

        if (data) {

            // console.log(JSON.stringify(data));

            // data.forEach(r => {
            //     console.log(
            //         r.supplyRequestName,
            //         'Status =',
            //         '"' + r.status + '"'
            //     );
            // });
            this.supplyRequests = data;
            this.applyFilters();
        } else if (error) {
            console.error('Error fetching supply requests:', error);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error loading Supply Requests',
                    message: error?.body?.message || 'An error occurred while fetching records.',
                    variant: 'error'
                })
            );
        }
    }

    async handleRefresh() {
        this.isLoading = true;
        try {
            await refreshApex(this.wiredResult);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Refreshed',
                    message: 'Supply requests updated successfully.',
                    variant: 'success'
                })
            );
        } catch (error) {
            console.error('Error refreshing data:', error);
        } finally {
            this.isLoading = false;
        }
    }

    // --- Pagination Handler ---
    handlePageChange(event) {
        if (event.detail) {
            this.currentPage = event.detail.currentPage || 1;
            this.pageSize = event.detail.pageSize || this.pageSize;
        }
    }

    // --- Paged Data for Custom Table ---
    get pagedRequests() {
        if (!this.filteredRequests || this.filteredRequests.length === 0) {
            return [];
        }
        const startIndex = (this.currentPage - 1) * this.pageSize;
        const endIndex = startIndex + this.pageSize;
        const slice = this.filteredRequests.slice(startIndex, endIndex);

        return slice.map(item => {
            const isSelected = this.selectedRequests.includes(item.supplyRequestId);
            const reqQty = Number(item.requestedQty) || 0;
            const locQty = this.getLocationAvailableQty(item);
            const otherInfo = this.getOtherRetailerInfo(item);
            const retQty = otherInfo.qty;

            let coverageStatus = 'In Stock';
            let coverageClass = 'coverage-badge badge-green';
            if (locQty >= reqQty && reqQty > 0) {
                coverageStatus = 'Fully Covered at Location';
                coverageClass = 'coverage-badge badge-green';
            } else if (locQty > 0) {
                coverageStatus = 'Partially Covered at Location';
                coverageClass = 'coverage-badge badge-amber';
            } else if (retQty > 0) {
                coverageStatus = 'Available at Other Retailers';
                coverageClass = 'coverage-badge badge-blue';
            } else {
                coverageStatus = 'Stock Awaiting / Low Stock';
                coverageClass = 'coverage-badge badge-red';
            }

            const locName = item.currentLocationName 
                || item.locationName 
                || item.supplyingAccountName 
                || item.location 
                || '';

            return {
                ...item,
                isSelected: isSelected,
                rowClass: isSelected ? 'row-selected' : '',
                statusBadgeClass: this.getStatusBadgeClass(item.status),
                formattedQty: this.formatDecimal(item.requestedQty),
                formattedDate: this.formatDate(item.requiredDate),
                currentLocationName: locName,
                otherRetailerName: otherInfo.name,
                currentLocationAvailableQty: locQty,
                otherRetailerAvailableQty: retQty,
                formattedLocationQty: this.formatDecimal(locQty),
                formattedRetailerQty: this.formatDecimal(retQty),
                stockCoverageStatus: coverageStatus,
                coverageClass: coverageClass
            };
        });
    }

    get isAllPageSelected() {
        if (!this.pagedRequests || this.pagedRequests.length === 0) return false;
        return this.pagedRequests.every(item => this.selectedRequests.includes(item.supplyRequestId));
    }

    formatDate(dateStr) {
        if (!dateStr) return '—';
        try {
            const parts = dateStr.split('-');
            if (parts.length === 3) {
                const year = parts[0];
                const month = parts[1];
                const day = parts[2];
                const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                const monthIdx = parseInt(month, 10) - 1;
                return `${monthNames[monthIdx] || month} ${day}, ${year}`;
            }
            return dateStr;
        } catch {
            return dateStr;
        }
    }

    getStatusBadgeClass(status) {
        switch (status) {
            case 'Open':
                return 'status-badge badge-open';
            case 'Included In OA':
                return 'status-badge badge-oa';
            case 'Included In MO':
                return 'status-badge badge-mo';
            case 'Ordered':
                return 'status-badge badge-ordered';
            case 'In Production':
                return 'status-badge badge-prod';
            case 'Partially Received':
                return 'status-badge badge-partial';
            case 'Received':
                return 'status-badge badge-received';
            case 'Partially Issued':
                return 'status-badge badge-partial-issued';
            case 'Issued':
                return 'status-badge badge-issued';
            case 'Completed':
                return 'status-badge badge-completed';
            case 'Cancelled':
                return 'status-badge badge-cancelled';
            default:
                return 'status-badge badge-default';
        }
    }

    // --- Dynamic Stock & Decimal Formatting Helpers ---
    formatDecimal(val) {
        if (val == null || val === '' || isNaN(val)) return '0';
        const num = Number(val);
        return num.toLocaleString(undefined, {
            minimumFractionDigits: 0,
            maximumFractionDigits: 2
        });
    }

    getLocationAvailableQty(item) {
        if (!item) return 0;
        
        // 1. Explicit check of known field aliases
        const knownFields = [
            'availableStock', 'availableQty', 'availableQuantity', 'available',
            'currentLocationAvailableQty', 'locationAvailableQty', 'quantityAvailable',
            'availableStockQty', 'onHand', 'quantityOnHand', 'stockQty', 'onHandQty',
            'currentLocationQty', 'locationQty', 'inventoryQty', 'inventoryAvailable', 'stock'
        ];

        for (const field of knownFields) {
            if (item[field] != null && !isNaN(item[field])) {
                return Number(item[field]);
            }
        }

        // 2. Dynamic scan of object keys for any key containing 'avail' or 'stock'
        for (const key of Object.keys(item)) {
            const lowerKey = key.toLowerCase();
            if ((lowerKey.includes('avail') || lowerKey.includes('stock') || lowerKey.includes('hand')) 
                && !lowerKey.includes('request') && !lowerKey.includes('other')) {
                const val = item[key];
                if (val != null && !isNaN(val)) {
                    return Number(val);
                }
            }
        }

        return 0;
    }

    getOtherRetailerInfo(item) {
        if (!item) return { name: '', qty: 0 };

        // 1. Dynamic key scan for explicit other retailer fields on item
        let explicitName = '';
        let explicitQty = null;

        for (const key of Object.keys(item)) {
            const lowerKey = key.toLowerCase();
            if (lowerKey.includes('other') && lowerKey.includes('retailer')) {
                if (typeof item[key] === 'string' && !explicitName) {
                    explicitName = item[key];
                } else if (!isNaN(item[key]) && explicitQty == null) {
                    explicitQty = Number(item[key]);
                }
            }
        }

        if (explicitName || explicitQty != null) {
            return {
                name: explicitName || '',
                qty: explicitQty || 0
            };
        }

        // 2. Dynamic aggregation across supplyRequests dataset for other retailer accounts having the same item
        if (this.supplyRequests && this.supplyRequests.length > 0) {
            const targetProd = (item.itemName || '').toLowerCase().trim();
            const targetProdId = item.itemId;
            const currentAcc = (item.requestingAccountName || item.accountName || '').toLowerCase().trim();
            const currentAccId = item.requestingAccountId;
            const supplyingAcc = (item.supplyingAccountName || item.currentLocationName || '').toLowerCase().trim();

            const otherRecords = this.supplyRequests.filter(r => {
                const rProd = (r.itemName || '').toLowerCase().trim();
                const rAcc = (r.requestingAccountName || r.accountName || '').toLowerCase().trim();

                // Flexible match product
                const isSameProduct = (targetProdId && r.itemId) 
                    ? (r.itemId === targetProdId) 
                    : (targetProd && rProd ? (rProd.includes(targetProd) || targetProd.includes(rProd)) : false);

                // Exclude current requesting account and supplying location account
                const isDifferentAccount = (currentAccId && r.requestingAccountId)
                    ? (r.requestingAccountId !== currentAccId)
                    : (rAcc ? (!rAcc.includes(currentAcc) && !currentAcc.includes(rAcc)) : true);

                const isNotSupplyingLoc = supplyingAcc ? (!rAcc.includes(supplyingAcc) && !supplyingAcc.includes(rAcc)) : true;

                return isSameProduct && isDifferentAccount && isNotSupplyingLoc;
            });

            if (otherRecords.length > 0) {
                const accountNames = Array.from(new Set(otherRecords.map(r => r.requestingAccountName || r.accountName).filter(Boolean)));
                const nameStr = accountNames.join(', ');
                const totalQty = otherRecords.reduce((sum, r) => {
                    const avail = this.getLocationAvailableQty(r) || Number(r.requestedQty) || 0;
                    return sum + avail;
                }, 0);

                return {
                    name: nameStr,
                    qty: totalQty
                };
            }
        }

        return {
            name: '',
            qty: 0
        };
    }

    // --- Custom Table Selection Handlers ---
    handleSelectAllPage(event) {
        const isChecked = event.target.checked;
        const pageIds = this.pagedRequests.map(r => r.supplyRequestId);
        let updated = [...this.selectedRequests];

        if (isChecked) {
            pageIds.forEach(id => {
                if (!updated.includes(id)) {
                    updated.push(id);
                }
            });
        } else {
            updated = updated.filter(id => !pageIds.includes(id));
        }

        this.selectedRequests = updated;
        this.recalculateSelectionTotals();
    }

    handleRowCheckboxChange(event) {
        const srId = event.target.dataset.id;
        const isChecked = event.target.checked;

        if (isChecked) {
            if (!this.selectedRequests.includes(srId)) {
                this.selectedRequests = [...this.selectedRequests, srId];
            }
        } else {
            this.selectedRequests = this.selectedRequests.filter(id => id !== srId);
        }

        this.recalculateSelectionTotals();
    }

    handleClearSelection() {
        this.selectedRequests = [];
        this.selectedQty = 0;
        this.selectedAccountCount = 0;
    }

    recalculateSelectionTotals() {
        const selectedItems = this.supplyRequests.filter(r => this.selectedRequests.includes(r.supplyRequestId));
        this.selectedQty = selectedItems.reduce((sum, r) => sum + (Number(r.requestedQty) || 0), 0);
        const uniqueAccounts = new Set(selectedItems.map(r => r.requestingAccountId || r.requestingAccountName).filter(Boolean));
        this.selectedAccountCount = uniqueAccounts.size;
    }

    get hasSelection() {
        return this.selectedRequests.length > 0;
    }

    get selectedRequestCount() {
        return this.selectedRequests.length;
    }

    get formattedSelectedQty() {
        return this.selectedQty.toLocaleString();
    }

    get totalRequestsCount() {
        return (this.supplyRequests || []).length;
    }

    get filteredCount() {
        return (this.filteredRequests || []).length;
    }

    get hasRecords() {
        return this.filteredRequests && this.filteredRequests.length > 0;
    }

    // --- Confirm Plan & Popup Logic ---
    async confirmPlan() {
        if (this.selectedRequests.length === 0) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'No Selection',
                    message: 'Please select at least one Supply Request to plan.',
                    variant: 'warning'
                })
            );
            return;
        }

        this.isSaving = true;
        this.isLoading = true;

        try {
            const results = await confirmPlan({
                supplyRequestIds: this.selectedRequests
            });

            this.createdOAs = (results || []).map(oa => ({
                ...oa,
                formattedTotalQty: (oa.totalQty != null ? Number(oa.totalQty).toLocaleString() : '0'),
                plannerUrl: `/lightning/n/Sales_Allocation_Planner?c__recordId=${oa.id}&c__planNumber=${encodeURIComponent(oa.name || '')}`
            }));

            this.isResultModalOpen = true;

            this.selectedRequests = [];
            this.selectedQty = 0;
            this.selectedAccountCount = 0;

            await refreshApex(this.wiredResult);
        } catch (error) {
            console.error('Error creating Order Allocation:', error);
            let errMsg = 'Unknown Error occurred.';
            if (error && error.body && error.body.message) {
                errMsg = error.body.message;
            } else if (error && error.message) {
                errMsg = error.message;
            } else if (typeof error === 'string') {
                errMsg = error;
            }
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error creating Order Allocation',
                    message: errMsg,
                    variant: 'error'
                })
            );
        } finally {
            this.isSaving = false;
            this.isLoading = false;
        }
    }

    handleOpenPlanner(event) {
        const url = event.currentTarget.dataset.url;
        if (url) {
            window.open(url, '_blank');
        }
    }

    handleOpenAllPlanners() {
        (this.createdOAs || []).forEach(oa => {
            if (oa.plannerUrl) {
                window.open(oa.plannerUrl, '_blank');
            }
        });
    }

    handleCloseModal() {
        this.isResultModalOpen = false;
        this.createdOAs = [];
    }

    // --- Stock Availability Modal Handlers ---
    async handleOpenStockModal(event) {
        const srId = event.currentTarget.dataset.id;
        if (!srId) return;

        this.isStockModalOpen = true;
        this.isStockLoading = true;
        this.selectedStockRow = (this.pagedRequests || []).find(r => r.supplyRequestId === srId) 
                             || (this.supplyRequests || []).find(r => r.supplyRequestId === srId) || {};

        try {
            const data = await getStockAvailabilityDetails({ supplyRequestId: srId });
            if (data && data.requestInfo) {
                const reqInfo = {
                    ...data.requestInfo,
                    formattedRequestedQty: this.formatDecimal(data.requestInfo.requestedQty),
                    formattedRequiredDate: this.formatDate(data.requestInfo.requiredDate)
                };

                const stockList = (data.availableStockList || []).map(item => ({
                    ...item,
                    formattedAvailableQty: this.formatDecimal(item.availableQty),
                    formattedOnHandQty: this.formatDecimal(item.onHandQty),
                    formattedReservedQty: this.formatDecimal(item.reservedQty),
                    formattedInTransitQty: this.formatDecimal(item.inTransitQty),
                    stockStatusBadgeClass: this.getStockStatusBadgeClass(item.stockStatus)
                }));

                this.stockDetails = {
                    requestInfo: reqInfo,
                    availableStockList: stockList
                };
            }
        } catch (error) {
            console.error('Error fetching stock availability details:', error);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error loading Stock Details',
                    message: error?.body?.message || 'Failed to fetch stock availability.',
                    variant: 'error'
                })
            );
        } finally {
            this.isStockLoading = false;
        }
    }

    handleCloseStockModal() {
        this.isStockModalOpen = false;
        this.isStockLoading = false;
        this.selectedStockRow = {};
        this.stockDetails = { requestInfo: {}, availableStockList: [] };
    }

    getStockStatusBadgeClass(status) {
        switch (status) {
            case 'In Stock':
                return 'stock-status-pill pill-in-stock';
            case 'Low Stock':
                return 'stock-status-pill pill-low-stock';
            case 'Out of Stock':
                return 'stock-status-pill pill-out-of-stock';
            default:
                return 'stock-status-pill pill-default';
        }
    }

    get hasAvailableStockList() {
        return this.stockDetails && this.stockDetails.availableStockList && this.stockDetails.availableStockList.length > 0;
    }

    get createdOACount() {
        return (this.createdOAs || []).length;
    }

    get hasMultipleOAs() {
        return (this.createdOAs || []).length > 1;
    }

    // --- KPI Counts ---
    get openCount() {
        return (this.supplyRequests || []).filter(r => r.status === 'Open').length;
    }

    get oaCount() {
        return (this.supplyRequests || []).filter(r => r.status === 'Included In OA').length;
    }

    get partiallyReceivedCount() {
        return (this.supplyRequests || []).filter(r => r.status === 'Partially Received').length;
    }

    get receivedCount() {
        return (this.supplyRequests || []).filter(r => r.status === 'Received').length;
    }

    get cancelledCount() {
        return (this.supplyRequests || []).filter(r => r.status === 'Cancelled').length;
    }

    get completedCount() {
        return (this.supplyRequests || []).filter(r => r.status === 'Completed').length;
    }

    // --- KPI Card Active States ---
    get isOpenActive() { return this.selectedStatus === 'Open'; }
    get isOaActive() { return this.selectedStatus === 'Included In OA'; }
    get isPartialActive() { return this.selectedStatus === 'Partially Received'; }
    get isReceivedActive() { return this.selectedStatus === 'Received'; }
    get isCancelledActive() { return this.selectedStatus === 'Cancelled'; }
    get isCompletedActive() { return this.selectedStatus === 'Completed'; }

    get openCardClass() { return `kpi-card card-orange ${this.isOpenActive ? 'is-active' : ''}`; }
    get oaCardClass() { return `kpi-card card-green ${this.isOaActive ? 'is-active' : ''}`; }
    get partialCardClass() { return `kpi-card card-blue ${this.isPartialActive ? 'is-active' : ''}`; }
    get receivedCardClass() { return `kpi-card card-teal ${this.isReceivedActive ? 'is-active' : ''}`; }
    get cancelledCardClass() { return `kpi-card card-red ${this.isCancelledActive ? 'is-active' : ''}`; }
    get completedCardClass() { return `kpi-card card-purple ${this.isCompletedActive ? 'is-active' : ''}`; }

    handleKpiClick(event) {
        const targetStatus = event.currentTarget.dataset.status;
        if (this.selectedStatus === targetStatus) {
            this.selectedStatus = ''; // Toggle off
        } else {
            this.selectedStatus = targetStatus;
        }
        this.currentPage = 1;
        this.applyFilters();
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value ? event.target.value.toLowerCase().trim() : '';
        this.currentPage = 1;
        this.applyFilters();
    }

    // handleStatusChange(event) {
    //     this.selectedStatus = event.detail.value;
    //     console.log('Selected Status = "' + this.selectedStatus + '"');
    //     this.currentPage = 1;
    //     this.applyFilters();
    // }

    // --- Custom Sorting ---
    handleSortColumn(event) {
        const fieldName = event.currentTarget.dataset.field;
        if (this.sortedBy === fieldName) {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortedBy = fieldName;
            this.sortDirection = 'asc';
        }
        this.sortData(this.sortedBy, this.sortDirection);
    }

    get isSupplyRequestSorted() { return this.sortedBy === 'supplyRequestName'; }
    get isProductSorted() { return this.sortedBy === 'itemName'; }
    get isAccountSorted() { return this.sortedBy === 'requestingAccountName'; }
    get isQtySorted() { return this.sortedBy === 'requestedQty'; }
    get isDateSorted() { return this.sortedBy === 'requiredDate'; }
    get isStatusSorted() { return this.sortedBy === 'status'; }

    get sortIconSupplyRequest() { return this.isSupplyRequestSorted ? (this.sortDirection === 'asc' ? '▲' : '▼') : '↕'; }
    get sortIconProduct() { return this.isProductSorted ? (this.sortDirection === 'asc' ? '▲' : '▼') : '↕'; }
    get sortIconAccount() { return this.isAccountSorted ? (this.sortDirection === 'asc' ? '▲' : '▼') : '↕'; }
    get sortIconQty() { return this.isQtySorted ? (this.sortDirection === 'asc' ? '▲' : '▼') : '↕'; }
    get sortIconDate() { return this.isDateSorted ? (this.sortDirection === 'asc' ? '▲' : '▼') : '↕'; }
    get sortIconStatus() { return this.isStatusSorted ? (this.sortDirection === 'asc' ? '▲' : '▼') : '↕'; }

    sortData(fieldName, direction) {
        let parseData = [...this.filteredRequests];
        let keyValue = (a) => {
            return a[fieldName] !== undefined && a[fieldName] !== null ? a[fieldName] : '';
        };
        let isReverse = direction === 'asc' ? 1 : -1;
        parseData.sort((x, y) => {
            let valX = keyValue(x);
            let valY = keyValue(y);
            if (typeof valX === 'string') {
                return isReverse * valX.localeCompare(valY);
            }
            return isReverse * ((valX > valY) - (valY > valX));
        });
        this.filteredRequests = parseData;
    }

    applyFilters() {

    let data = [...this.supplyRequests];

    // Global Search
    if (this.searchTerm) {

        const search = this.searchTerm.toLowerCase();

        data = data.filter(r =>

            (r.supplyRequestName || '').toLowerCase().includes(search) ||

            (r.requestingAccountName || '').toLowerCase().includes(search) ||

            (r.itemName || '').toLowerCase().includes(search)

        );
    }

    // Status Filter
    // if (this.selectedStatus) {

    //     data = data.filter(r => r.status === this.selectedStatus);

    // }

    this.filteredRequests = data;
}

    handleClearFilters() {

    this.searchTerm = '';

    // this.selectedStatus = '';

    this.applyFilters();
}

    get hasActiveFilters() {
        return Boolean(this.searchTerm);
    }

    // get accountOptions() {
    //     if (!this.supplyRequests || this.supplyRequests.length === 0) {
    //         return [{ label: 'All Accounts', value: '' }];
    //     }
    //     const map = new Map();
    //     this.supplyRequests.forEach(r => {
    //         if (r.requestingAccountId && r.requestingAccountName) {
    //             map.set(r.requestingAccountId, r.requestingAccountName);
    //         }
    //     });
    //     const options = Array.from(map.entries())
    //         .sort((a, b) => a[1].localeCompare(b[1]))
    //         .map(([id, name]) => ({ label: name, value: id }));
    //     return [{ label: 'All Accounts', value: '' }, ...options];
    // }

    // get itemOptions() {
    //     if (!this.supplyRequests || this.supplyRequests.length === 0) {
    //         return [{ label: 'All Products', value: '' }];
    //     }
    //     const map = new Map();
    //     this.supplyRequests.forEach(r => {
    //         if (r.itemId && r.itemName) {
    //             map.set(r.itemId, r.itemName);
    //         }
    //     });
    //     const options = Array.from(map.entries())
    //         .sort((a, b) => a[1].localeCompare(b[1]))
    //         .map(([id, name]) => ({ label: name, value: id }));
    //     return [{ label: 'All Products', value: '' }, ...options];
    // }

//     statusOptions = [
//     { label: 'All Statuses', value: '' },
//     { label: 'Open', value: 'Open' },
//     { label: 'Included In OA', value: 'Included In OA' },
//     { label: 'Partially Received', value: 'Partially Received' },
//     { label: 'Received', value: 'Received' },
//     { label: 'Completed', value: 'Completed' },
//     { label: 'Cancelled', value: 'Cancelled' }
// ];
}