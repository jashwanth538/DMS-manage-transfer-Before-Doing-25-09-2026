import { LightningElement, api, wire, track } from 'lwc';
import getInventoryData from '@salesforce/apex/InventoryAvailabilityController.getInventoryData';

export default class InventoryAvailability extends LightningElement {
    @api recordId;
    @api itemId;
    @api locationId;
    @api accountId;
    @api isModal = false;

    @track locationHeaders = [];
    @track tableData = [];
    @track displayedTableData = [];
    @track isLoading = true;
    @track hasError = false;
    @track isModalOpen = false;
    @track modalData = {};
    errorMessage;

    @track filteredTableData = [];

    totalRecords = 0;
    currentPage = 1;
    pageSize = 3;

    @wire(getInventoryData, { 
        orderAllocationId: '$recordId',
        itemId: '$itemId',
        locationId: '$locationId',
        accountId: '$accountId'
    })
    wiredInventory({ data, error }) {
        this.isLoading = true;

        if (data) {
            console.log('Raw Wire Data => ', JSON.stringify(data));
            // Distinct Locations for headers
            const locMap = new Map();
            data.forEach(prod => {
                if (prod.locations) {
                    prod.locations.forEach(loc => {
                        if (!locMap.has(loc.locationId)) {
                            locMap.set(loc.locationId, loc.locationName);
                        }
                    });
                }
            });
            this.locationHeaders = Array.from(locMap).map(([id, name]) => ({ id, name }));

            // Map data into table rows mapping to location columns
            let processedData = data.map((prod, index) => {
                let rowCells = this.locationHeaders.map(lh => {
                    let found = prod.locations ? prod.locations.find(l => l.locationId === lh.id) : null;
                    return {
                        id: `${prod.productId}-${lh.id}`,
                        locationId: lh.id,
                        productId: prod.productId,
                        hasData: !!found,
                        qty: found ? found.availableQty : 0,
                        fullLocData: found
                    };
                });
                return {
                    id: prod.productId || index,
                    productId: prod.productId,
                    productName: prod.productName,
                    productCode: prod.productCode,
                    productFamily: prod.productFamily,
                    cells: rowCells
                };
            });

            this.tableData = processedData;
            console.log('Processed Data => ', JSON.stringify(processedData));
            this.filteredTableData = [...processedData];

            this.totalRecords = this.filteredTableData.length;

            this.updateDisplayedRecords();

            // Auto-populate modalData directly for Modal display (Image 1)
            let targetProd = this.itemId ? processedData.find(p => p.productId === this.itemId) : processedData[0];
            if (!targetProd && processedData.length > 0) {
                targetProd = processedData[0];
            }

            if (targetProd) {
                let cellData = this.locationId ? targetProd.cells.find(c => c.locationId === this.locationId) : null;
                if (!cellData && targetProd.cells.length > 0) {
                    cellData = targetProd.cells.find(c => c.hasData) || targetProd.cells[0];
                }

                let locName = cellData ? this.locationHeaders.find(lh => lh.id === cellData.locationId)?.name : '';
                let fullLocData = cellData && cellData.fullLocData ? cellData.fullLocData : {};

                this.modalData = {
                    productName: targetProd.productName,
                    productCode: targetProd.productCode,
                    productFamily: targetProd.productFamily,
                    locationName: locName || (fullLocData.locationName || ''),
                    qty: cellData ? cellData.qty : 0,
                    onHandQty: fullLocData.onHandQty || 0,
                    reservedSaleOrderQty: fullLocData.reservedSaleOrderQty || 0,
                    reservedTransferQty: fullLocData.reservedTransferQty || 0,
                    damagedQty: fullLocData.damagedQty || 0,
                    transitInQty: fullLocData.transitInQty || 0,
                    transitOutQty: fullLocData.transitOutQty || 0
                };
            }

            this.hasError = false;
            this.isLoading = false;
        } else if (error) {
            this.hasError = true;
            this.errorMessage = error.body?.message || 'An error occurred fetching inventory data.';
            this.tableData = [];
            this.locationHeaders = [];
            this.isLoading = false;
            console.error('Error fetching inventory:', error);
        }
    }

    handleSearch(event) {
    const searchTerm = (event.detail.value || '')
        .toLowerCase()
        .trim();

    if (!searchTerm) {
        this.filteredTableData = [...this.tableData];
    } else {
        this.filteredTableData = this.tableData.filter(row => {

            const productName =
                (row.productName || '').toLowerCase();

            const productCode =
                (row.productCode || '').toLowerCase();

            const productFamily =
                (row.productFamily || '').toLowerCase();

            return (
                productName.includes(searchTerm) ||
                productCode.includes(searchTerm) ||
                productFamily.includes(searchTerm)
            );
        });
    }

    this.currentPage = 1;
    this.totalRecords = this.filteredTableData.length;

    this.updateDisplayedRecords();
}

    handleDetailsAction(event) {
        const productId = event.currentTarget.dataset.productId;
        const locationId = event.currentTarget.dataset.locationId;

        // Find data to show in modal
        const prod = this.tableData.find(p => p.productId === productId);
        const locName = this.locationHeaders.find(lh => lh.id === locationId)?.name;

        if (prod) {
            const cellData = prod.cells.find(c => c.locationId === locationId);
            const fullLocData = cellData && cellData.fullLocData ? cellData.fullLocData : {};

            this.modalData = {
                productName: prod.productName,
                productCode: prod.productCode,
                productFamily: prod.productFamily,
                locationName: locName,
                qty: cellData ? cellData.qty : 0,
                onHandQty: fullLocData.onHandQty || 0,
                reservedSaleOrderQty: fullLocData.reservedSaleOrderQty || 0,
                reservedTransferQty: fullLocData.reservedTransferQty || 0,
                damagedQty: fullLocData.damagedQty || 0,
                transitInQty: fullLocData.transitInQty || 0,
                transitOutQty: fullLocData.transitOutQty || 0
            };
        }

        this.isModalOpen = true;
    }

    closeModal() {
        this.isModalOpen = false;
        this.dispatchEvent(new CustomEvent('closemodal'));
    }

    handlePageChange(event) {
        this.currentPage = event.detail.currentPage;
        this.pageSize = event.detail.pageSize;
        console.log('Page Change => ', this.currentPage, this.pageSize);

        this.updateDisplayedRecords();
        this.scrollToHeader();
    }

    scrollToHeader() {
        const headerElement = this.template.querySelector('.inventory-container');
        if (headerElement) {
            headerElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }

    updateDisplayedRecords() {
        const start = (this.currentPage - 1) * this.pageSize;
        const end = start + this.pageSize;

        this.displayedTableData =
            this.filteredTableData.slice(start, end);
    }
    get showPagination() {
        console.log('Total Record', this.totalRecords);
    return this.totalRecords > this.pageSize;
}
}