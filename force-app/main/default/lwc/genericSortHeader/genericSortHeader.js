import { LightningElement, api } from 'lwc';

export default class GenericSortHeader extends LightningElement {
    @api label = '';
    @api columnName = '';
    @api currentSortBy = '';
    @api currentSortDirection = 'asc';

    get isSorted() {
        return this.currentSortBy === this.columnName;
    }

    get isAsc() {
        return this.isSorted && this.currentSortDirection === 'asc';
    }

    get isDesc() {
        return this.isSorted && this.currentSortDirection === 'desc';
    }

    get sortIconName() {
        if (!this.isSorted) {
            return 'utility:sort';
        }
        return this.isAsc ? 'utility:arrowup' : 'utility:arrowdown';
    }

    get headerClass() {
        return this.isSorted ? 'sort-header-container sorted' : 'sort-header-container';
    }

    handleSortClick(event) {
        event.preventDefault();
        let nextDirection = 'asc';
        if (this.isSorted) {
            nextDirection = this.currentSortDirection === 'asc' ? 'desc' : 'asc';
        }

        this.dispatchEvent(
            new CustomEvent('sort', {
                detail: {
                    columnName: this.columnName,
                    sortDirection: nextDirection,
                    sortBy: this.columnName
                },
                bubbles: true,
                composed: true
            })
        );
    }
}