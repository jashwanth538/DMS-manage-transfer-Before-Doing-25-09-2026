import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPurchaseOrderDetails from '@salesforce/apex/GRNController.getPurchaseOrderDetails';
import saveGoodsReceipt from '@salesforce/apex/GRNController.saveGoodsReceipt';
import searchPurchaseOrders from '@salesforce/apex/GRNController.searchPurchaseOrders';

export default class CreateGoodsReceipt extends NavigationMixin(LightningElement) {
    @api recordId; // Prepopulated if on a PO page
    @track purchaseOrderId;

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (pageRef && pageRef.state) {
            const poId = pageRef.state.c__purchaseOrderId || pageRef.state.purchaseOrderId;
            if (poId && poId !== this.purchaseOrderId) {
                this.purchaseOrderId = poId;
                this.isLookupDisabled = true;
                this.loadPurchaseOrder(poId);
            }
        }
    }

    @track poName = '';
    @track supplyingAccountName = '';
    @track requestingAccountName = '';
    @track warehouseName = '';
    @track poStatus = '';
    @track receiptDate = '';
    @track deliveryNoteNo = '';
    @track remarks = '';
    
    @track lines = [];
    @track isLoadingItems = false;
    @track isSaveDisabled = false;
    
    @track poSearchTerm = '';
    @track searchResults = [];
    @track showDropdown = false;

    @track currentState = 'form'; // 'form', 'loading', 'success'
    @track newGrnId = '';
    @track newGrnName = '';
    @track isLookupDisabled = false;

    get isFormState() {
        return this.currentState === 'form';
    }

    get isLoadingState() {
        return this.currentState === 'loading';
    }

    get isSuccessState() {
        return this.currentState === 'success';
    }

    get showReceiveButton() {
        return this.totalReceiveQty > 0;
    }
    
    totalReceiveQty = 0;
    totalAmount = 0;

    connectedCallback() {
        // Initialize receipt date with today's date in local time YYYY-MM-DD
        const today = new Date();
        const year = today.getFullYear();
        const month = String(today.getMonth() + 1).padStart(2, '0');
        const day = String(today.getDate()).padStart(2, '0');
        this.receiptDate = `${year}-${month}-${day}`;

        // If loaded on a PO record page, pre-populate and load PO details
        if (this.recordId) {
            this.purchaseOrderId = this.recordId;
            this.isLookupDisabled = true;
            this.loadPurchaseOrder(this.recordId);
        } else {
            this.isLookupDisabled = false;
        }
    }

    get isPOFieldDisabled() {
        return this.isLookupDisabled;
    }

    get formattedTotalAmount() {
        return new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'INR'
        }).format(this.totalAmount);
    }

    handlePOSearch(event) {
        this.poSearchTerm = event.target.value;
        if (!this.poSearchTerm) {
            this.purchaseOrderId = null;
            this.resetForm();
            this.searchResults = [];
            this.showDropdown = false;
        } else {
            searchPurchaseOrders({ searchTerm: this.poSearchTerm })
                .then(response => {
                    if (response && response.isSuccess) {
                        this.searchResults = response.resultList || [];
                        this.showDropdown = true;
                    } else {
                        console.error('Error searching POs: ' + (response ? response.errorMsg : 'No response'));
                    }
                })
                .catch(error => {
                    console.error('Error searching POs', error);
                });
        }
    }

    handlePOFocus() {
        searchPurchaseOrders({ searchTerm: this.poSearchTerm })
            .then(response => {
                if (response && response.isSuccess) {
                    this.searchResults = response.resultList || [];
                    this.showDropdown = true;
                } else {
                    console.error('Error searching POs: ' + (response ? response.errorMsg : 'No response'));
                }
            })
            .catch(error => {
                console.error('Error searching POs', error);
            });
    }

    handlePOBlur() {
        setTimeout(() => {
            this.showDropdown = false;
        }, 300);
    }

    handleSelectPO(event) {
        const poId = event.currentTarget.dataset.id;
        const poName = event.currentTarget.dataset.name;
        this.purchaseOrderId = poId;
        this.poSearchTerm = poName;
        this.showDropdown = false;
        this.loadPurchaseOrder(poId);
    }

    handleReceiptDateChange(event) {
        this.receiptDate = event.target.value;
    }

    handleDeliveryNoteChange(event) {
        this.deliveryNoteNo = event.target.value;
    }

    handleRemarksChange(event) {
        this.remarks = event.target.value;
    }

    loadPurchaseOrder(poId) {
        this.isLoadingItems = true;
        getPurchaseOrderDetails({ poId: poId })
            .then(response => {
                if (response && response.isSuccess) {
                    const result = response.result;
                    const po = result.po;
                    this.poName = po.Name;
                    this.poSearchTerm = po.Name;
                    
                    this.supplyingAccountName = po.Supplying_Account__r 
                        ? po.Supplying_Account__r.Name 
                        : (po.Vendor__r ? po.Vendor__r.Name : 'N/A');
                    
                    this.requestingAccountName = po.Requesting_Account__r 
                        ? po.Requesting_Account__r.Name 
                        : (po.Account__r ? po.Account__r.Name : 'N/A');

                    this.warehouseName = po.Ship_to_Warehouse__r ? po.Ship_to_Warehouse__r.Name : 'N/A';
                    this.poStatus = po.Status__c || 'N/A';

                    if (po.Status__c === 'Closed' || po.Status__c === 'Cancelled') {
                        this.showToast('Warning', `Purchase Order ${po.Name} is ${po.Status__c} and cannot receive inventory.`, 'warning');
                    }
                    
                    // Map line items
                    this.lines = (result.lines || []).map((wrap, index) => {
                        const poli = wrap.poli;
                        const previouslyReceived = wrap.previouslyReceivedQty || 0;
                        const remaining = wrap.remainingQty != null ? wrap.remainingQty : Math.max(0, (poli.Ordered_Qty__c || 0) - previouslyReceived);
                        const defReceiveQty = remaining > 0 ? remaining : 0;
                        const unitPrice = poli.Unit_Price__c || 0;
                        
                        return {
                            rowNumber: index + 1,
                            poli: poli,
                            poLineName: poli.Name,
                            poLineUrl: `/lightning/r/Purchase_Order_Line_Item__c/${poli.Id}/view`,
                            itemName: poli.Item__r ? poli.Item__r.Name : '',
                            itemCode: poli.Item__r ? poli.Item__r.Item_Code__c : '',
                            itemUrl: poli.Item__c ? `/lightning/r/Item__c/${poli.Item__c}/view` : '#',
                            itemDescription: poli.Item__r ? poli.Item__r.Item_Description__c : '',
                            orderedQty: poli.Ordered_Qty__c || 0,
                            previouslyReceivedQty: previouslyReceived,
                            remainingQty: remaining,
                            unitPrice: unitPrice,
                            receiveQty: defReceiveQty,
                            lineAmount: defReceiveQty * unitPrice,
                            formattedUnitPrice: this.formatCurrency(unitPrice),
                            formattedLineAmount: this.formatCurrency(defReceiveQty * unitPrice),
                            isFullyReceived: remaining <= 0,
                            inputError: remaining <= 0 ? 'Fully Received' : ''
                        };
                    });
                    
                    this.recalculateTotals();
                } else {
                    const msg = response && response.errorMsg ? response.errorMsg : 'Failed to retrieve Purchase Order Details';
                    this.showToast('Error', msg, 'error');
                }
                this.isLoadingItems = false;
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
                this.isLoadingItems = false;
                this.resetForm();
            });
    }

    handleReceiveQtyChange(event) {
        const recordId = event.target.dataset.id;
        const val = event.target.value;
        
        this.lines = this.lines.map(line => {
            if (line.poli.Id === recordId) {
                let qty = parseFloat(val);
                let errorMsg = '';
                
                if (isNaN(qty)) {
                    qty = 0;
                } else if (qty < 0) {
                    errorMsg = 'Quantity cannot be negative';
                } else if (qty > line.remainingQty) {
                    errorMsg = `Cannot exceed remaining qty (${line.remainingQty})`;
                }
                
                const lineAmt = qty * line.unitPrice;
                return {
                    ...line,
                    receiveQty: qty,
                    lineAmount: lineAmt,
                    formattedLineAmount: this.formatCurrency(lineAmt),
                    inputError: errorMsg
                };
            }
            return line;
        });
        
        this.recalculateTotals();
    }

    recalculateTotals() {
        let totalQty = 0;
        let totalAmt = 0;
        
        this.lines.forEach(line => {
            if (!line.inputError || line.inputError === 'Fully Received') {
                if (line.receiveQty > 0 && line.remainingQty > 0 && line.receiveQty <= line.remainingQty) {
                    totalQty += line.receiveQty;
                    totalAmt += line.lineAmount;
                }
            }
        });
        
        this.totalReceiveQty = totalQty;
        this.totalAmount = totalAmt;
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'INR'
        }).format(value);
    }

    resetForm() {
        this.poName = '';
        this.supplyingAccountName = '';
        this.requestingAccountName = '';
        this.warehouseName = '';
        this.poStatus = '';
        this.lines = [];
        this.totalReceiveQty = 0;
        this.totalAmount = 0;
        this.currentState = 'form';
        this.newGrnId = '';
        this.newGrnName = '';
        this.remarks = '';
        this.deliveryNoteNo = '';

        const remarksArea = this.template.querySelector('.custom-textarea');
        if (remarksArea) {
            remarksArea.value = '';
        }
        const deliveryInput = this.template.querySelector('.custom-text-input');
        if (deliveryInput) {
            deliveryInput.value = '';
        }
    }

    handleCancel() {
        if (this.recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.recordId,
                    actionName: 'view'
                }
            });
        } else {
            this[NavigationMixin.Navigate]({
                type: 'standard__objectPage',
                attributes: {
                    objectApiName: 'Purchase_Order__c',
                    actionName: 'list'
                },
                state: {
                    filterName: 'Recent'
                }
            });
        }
    }

    handleViewRecord() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.newGrnId,
                actionName: 'view'
            }
        });
    }

    handleCloseSuccess() {
        this.deliveryNoteNo = '';
        this.remarks = '';
        this.poSearchTerm = '';
        this.searchResults = [];
        this.showDropdown = false;
        this.isSaveDisabled = false;
        this.isLoadingItems = false;
        this.resetForm();
        if (this.recordId) {
            this.purchaseOrderId = this.recordId;
            this.loadPurchaseOrder(this.recordId);
        } else {
            this.purchaseOrderId = null;
        }
    }

    handleReset() {
        this.deliveryNoteNo = '';
        this.remarks = '';
        this.poSearchTerm = '';
        this.searchResults = [];
        this.showDropdown = false;
        this.isSaveDisabled = false;
        this.isLoadingItems = false;
        this.purchaseOrderId = null;
        this.isLookupDisabled = false;
        this.resetForm();
    }

    handleReceiveInventory() {
        this.saveGRN('Received');
    }

    saveGRN(status) {
        const dateInput = this.template.querySelector('.custom-date-picker');
        if (dateInput && !dateInput.reportValidity()) {
            return;
        }

        if (!this.purchaseOrderId) {
            this.showToast('Warning', 'Please select a Purchase Order first.', 'warning');
            return;
        }

        // Check for line item errors (excluding fully received non-inputs)
        const hasActiveErrors = this.lines.some(line => line.inputError && line.inputError !== 'Fully Received');
        if (hasActiveErrors) {
            this.showToast('Error', 'Please resolve quantity validation errors in the PO line items table.', 'error');
            return;
        }

        if (this.totalReceiveQty <= 0) {
            this.showToast('Warning', 'Total Receive Quantity must be greater than 0.', 'warning');
            return;
        }

        this.isSaveDisabled = true;
        this.isLoadingItems = true;
        this.currentState = 'loading';

        const grnRecord = {
            sObjectType: 'GRN__c',
            Purchase_Order__c: this.purchaseOrderId,
            Receipt_Date__c: this.receiptDate,
            Delivery_Note_No__c: this.deliveryNoteNo,
            Remarks__c: this.remarks,
            Status__c: status
        };

        const grnLines = this.lines
            .filter(line => line.receiveQty > 0 && line.remainingQty > 0)
            .map(line => {
                return {
                    sObjectType: 'GRN_Line_Item__c',
                    Purchase_Order_Line_Item__c: line.poli.Id,
                    Received_Qty__c: line.receiveQty,
                    Unit_Price__c: line.unitPrice
                };
            });

        saveGoodsReceipt({ grn: grnRecord, lines: grnLines })
            .then(response => {
                if (response && response.isSuccess) {
                    const grnObj = response.result;
                    this.newGrnId = grnObj.Id;
                    this.newGrnName = grnObj.Name;
                    if (grnObj.Requesting_Account__r) {
                        this.requestingAccountName = grnObj.Requesting_Account__r.Name;
                    }
                    this.currentState = 'success';
                    this.showToast('Success', `${this.newGrnName} created successfully. Received inventory has been updated for ${this.requestingAccountName}.`, 'success');
                } else {
                    const msg = response && response.errorMsg ? response.errorMsg : 'Failed to save Goods Receipt Note';
                    this.showToast('Error', msg, 'error');
                    this.isSaveDisabled = false;
                    this.isLoadingItems = false;
                    this.currentState = 'form';
                }
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
                this.isSaveDisabled = false;
                this.isLoadingItems = false;
                this.currentState = 'form';
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        }));
    }

    getErrorMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        } else if (error && error.message) {
            return error.message;
        }
        return JSON.stringify(error);
    }
}