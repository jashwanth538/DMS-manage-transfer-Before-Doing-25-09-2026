import { LightningElement, api, wire, track } from 'lwc';
import { publish, MessageContext } from 'lightning/messageService';
import searchAndFilterMessageChannel from '@salesforce/messageChannel/searchAndFilterMessage__c';

export default class GenericSearchAndFilterPanel extends LightningElement {
    // Component Header Title
    @api panelTitle;

    // Search Box Properties
    @api searchLabel = 'Search';
    @api searchPlaceholder = 'Search...';
    
    // Search Column Selector Properties
    @api searchColumns = []; // Array of { label, value }
    @api searchColumnLabel = 'Search Column';
    @api searchColumnPlaceholder = 'Select column...';

    // Filtering Dropdown Properties
    @api filterColumn = '';
    @api filterLabel = 'Filter By';
    @api filterPlaceholder = 'Select filter...';
    @api filterOptions = []; // Array of { label, value }

    // LMS Enable toggle and debounce duration
    @api debounceDelay = 300;
    @api enableLms = false;

    // Internal tracked state properties that map to external input values
    @track _searchText = '';
    @track _selectedSearchColumn = '';
    @track _selectedFilterValue = '';

    // LMS context wire
    @wire(MessageContext)
    messageContext;

    // Search query getter and setter
    @api
    get searchText() {
        return this._searchText;
    }
    set searchText(value) {
        this._searchText = value || '';
    }

    // Selected search column getter and setter
    @api
    get selectedSearchColumn() {
        return this._selectedSearchColumn;
    }
    set selectedSearchColumn(value) {
        this._selectedSearchColumn = value || '';
    }

    // Selected filter value getter and setter
    @api
    get selectedFilterValue() {
        return this._selectedFilterValue;
    }
    set selectedFilterValue(value) {
        this._selectedFilterValue = value || '';
    }

    // Debounce timer ID
    delayTimeout;

    // Checks if search columns have been populated
    get hasSearchColumns() {
        return this.searchColumns && this.searchColumns.length > 0;
    }

    // Checks if filter options have been populated
    get hasFilterOptions() {
        return this.filterOptions && this.filterOptions.length > 0;
    }

    // Compute dynamic width styling classes for the search field
    get searchFieldClass() {
        const hasCols = this.hasSearchColumns;
        const hasFilters = this.hasFilterOptions;
        let sizeClass = 'slds-medium-size_10-of-12';
        if (hasCols && hasFilters) {
            sizeClass = 'slds-medium-size_4-of-12';
        } else if (hasCols) {
            sizeClass = 'slds-medium-size_6-of-12';
        } else if (hasFilters) {
            sizeClass = 'slds-medium-size_5-of-12';
        }
        return `slds-col slds-size_1-of-1 ${sizeClass} slds-m-bottom_small`;
    }

    // Compute dynamic width styling classes for the filter combobox field
    get filterFieldClass() {
        const hasCols = this.hasSearchColumns;
        let sizeClass = 'slds-medium-size_5-of-12';
        if (hasCols) {
            sizeClass = 'slds-medium-size_3-of-12';
        }
        return `slds-col slds-size_1-of-1 ${sizeClass} slds-m-bottom_small`;
    }

    // Reset button field container style
    get resetFieldClass() {
        return 'slds-col slds-size_1-of-1 slds-medium-size_2-of-12 slds-m-bottom_small slds-text-align_right action-btn-col';
    }

    // Handle typing in the search text field
    handleSearchChange(event) {
        this._searchText = event.target.value;
        window.clearTimeout(this.delayTimeout);
        this.delayTimeout = setTimeout(() => {
            this.dispatchSearchChange();
        }, this.debounceDelay);
    }

    // Handle selecting a column to narrow down search
    handleSearchColumnChange(event) {
        this._selectedSearchColumn = event.detail.value;
        this.dispatchSearchChange();
    }

    // Handle changing the select value on filter dropdown
    handleFilterChange(event) {
        this._selectedFilterValue = event.detail.value;
        this.dispatchFilterChange();
    }

    // Dispatch the custom event and publish to LMS channel if enabled
    dispatchSearchChange() {
        const searchDetail = {
            searchText: this._searchText,
            searchColumn: this._selectedSearchColumn
        };

        this.dispatchEvent(new CustomEvent('searchchange', {
            detail: searchDetail
        }));

        if (this.enableLms) {
            this.publishLMS();
        }
    }

    // Dispatch custom event for filter change and publish to LMS channel if enabled
    dispatchFilterChange() {
        const filterDetail = {
            filterColumn: this.filterColumn,
            filterValue: this._selectedFilterValue
        };

        this.dispatchEvent(new CustomEvent('filterchange', {
            detail: filterDetail
        }));

        if (this.enableLms) {
            this.publishLMS();
        }
    }

    // Reset handler to clear all inputs
    handleReset() {
        this._searchText = '';
        this._selectedSearchColumn = '';
        this._selectedFilterValue = '';

        this.dispatchEvent(new CustomEvent('reset'));

        if (this.enableLms) {
            this.publishLMS();
        }
    }

    // Publish helper for LMS messaging
    publishLMS() {
        const payload = {
            searchText: this._searchText,
            searchColumn: this._selectedSearchColumn,
            filterColumn: this.filterColumn,
            filterValue: this._selectedFilterValue,
            sourceComponent: 'genericSearchAndFilterPanel'
        };
        publish(this.messageContext, searchAndFilterMessageChannel, payload);
    }
}