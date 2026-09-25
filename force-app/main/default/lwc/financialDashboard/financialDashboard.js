import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getUserAccountContext from '@salesforce/apex/FinancialDashboardController.getUserAccountContext';
import getDashboardData     from '@salesforce/apex/FinancialDashboardController.getDashboardData';

// ─── Constants ─────────────────────────────────────────────────────────────
const PAGE_SIZE       = 50;
const DUE_SOON_DAYS   = 7;
const TODAY           = new Date(); TODAY.setHours(0, 0, 0, 0);
const DUE_SOON_CUTOFF = new Date(TODAY); DUE_SOON_CUTOFF.setDate(TODAY.getDate() + DUE_SOON_DAYS);

const SORT_OPTIONS = [
    { label: 'Due Date (Asc)',          value: 'dueDate_asc'          },
    { label: 'Due Date (Desc)',         value: 'dueDate_desc'         },
    { label: 'Amount (High → Low)',     value: 'totalAmount_desc'     },
    { label: 'Amount (Low → High)',     value: 'totalAmount_asc'      },
    { label: 'Outstanding (High → Low)',value: 'outstanding_desc'     },
    { label: 'Status',                  value: 'status_asc'           },
];

const STATUS_FILTERS = [
    { label: 'All',           value: 'all'           },
    { label: 'Unpaid',        value: 'Unpaid'        },
    { label: 'Partially Paid',value: 'Partially Paid'},
    { label: 'Paid',          value: 'Paid'          },
    { label: 'Overdue',       value: 'Overdue'       },
    { label: 'Cancelled',     value: 'Cancelled'     },
];

const INV_STATUS_FILTERS = [
    { label: 'All',           value: 'all'           },
    { label: 'Draft',         value: 'Draft'         },
    { label: 'Approved',      value: 'Approved'      },
    { label: 'Issued',        value: 'Issued'        },
    { label: 'Partially Paid',value: 'Partially Paid'},
    { label: 'Paid',          value: 'Paid'          },
    { label: 'Overdue',       value: 'Overdue'       },
];

// ─── Status badge mapping ───────────────────────────────────────────────────
const STATUS_BADGE_MAP = {
    'Unpaid':         'fd-badge fd-badge--unpaid',
    'Partially Paid': 'fd-badge fd-badge--partial',
    'Paid':           'fd-badge fd-badge--paid',
    'Overdue':        'fd-badge fd-badge--overdue',
    'Cancelled':      'fd-badge fd-badge--cancelled',
    'Disputed':       'fd-badge fd-badge--disputed',
    'Draft':          'fd-badge fd-badge--draft',
    'Approved':       'fd-badge fd-badge--approved',
    'Issued':         'fd-badge fd-badge--issued',
};

// ─── Due-date logic ─────────────────────────────────────────────────────────
function getDueInfo(dueDateStr, outstanding) {
    const bal = outstanding != null ? outstanding : 0;

    if (bal <= 0) {
        return { label: 'Paid', cssClass: 'fd-badge fd-badge--paid' };
    }

    if (!dueDateStr) {
        return { label: 'No Due Date', cssClass: 'fd-badge fd-badge--neutral' };
    }

    const due = new Date(dueDateStr); due.setHours(0, 0, 0, 0);
    const today = new Date(); today.setHours(0, 0, 0, 0);

    const diffMs   = due - today;
    const diffDays = Math.round(diffMs / (1000 * 60 * 60 * 24));

    if (diffDays < 0) {
        const overdueDays = Math.abs(diffDays);
        return {
            label:    `⚠ Overdue by ${overdueDays} day${overdueDays !== 1 ? 's' : ''}`,
            cssClass: 'fd-badge fd-badge--overdue'
        };
    } else if (diffDays === 0) {
        return { label: 'Due Today',    cssClass: 'fd-badge fd-badge--due-today' };
    } else if (diffDays === 1) {
        return { label: 'Due Tomorrow', cssClass: 'fd-badge fd-badge--due-soon' };
    } else if (diffDays <= DUE_SOON_DAYS) {
        return { label: `Due in ${diffDays} days`, cssClass: 'fd-badge fd-badge--due-soon' };
    } else {
        return { label: '', cssClass: '' };
    }
}

function sfDateToISO(sfDate) {
    if (!sfDate) return null;
    // Salesforce dates are YYYY-MM-DD strings; convert to ISO for lightning-formatted-date-time
    return sfDate + 'T00:00:00.000Z';
}

// ─── Sort comparator factory ────────────────────────────────────────────────
function buildComparator(sortValue) {
    const [field, dir] = sortValue.split('_');
    const asc = dir === 'asc';
    return (a, b) => {
        let va, vb;
        if (field === 'dueDate') {
            va = a.dueDate ? new Date(a.dueDate) : new Date(8640000000000000);
            vb = b.dueDate ? new Date(b.dueDate) : new Date(8640000000000000);
        } else if (field === 'totalAmount') {
            va = a.totalAmount || 0;
            vb = b.totalAmount || 0;
        } else if (field === 'outstanding') {
            va = a.outstandingBalance != null ? a.outstandingBalance : (a.balanceDue || 0);
            vb = b.outstandingBalance != null ? b.outstandingBalance : (b.balanceDue || 0);
        } else if (field === 'status') {
            va = a.status || '';
            vb = b.status || '';
        } else {
            va = 0; vb = 0;
        }
        if (va < vb) return asc ? -1 : 1;
        if (va > vb) return asc ? 1 : -1;
        return 0;
    };
}

// ─── Enrich payable row ─────────────────────────────────────────────────────
function enrichPayable(r) {
    const dueInfo = getDueInfo(r.dueDate, r.outstandingBalance);
    return {
        ...r,
        payableDateISO:     sfDateToISO(r.payableDate),
        dueDateISO:         sfDateToISO(r.dueDate),
        statusBadgeClass:   STATUS_BADGE_MAP[r.status] || 'fd-badge fd-badge--neutral',
        dueLabel:           dueInfo.label,
        dueBadgeClass:      dueInfo.cssClass,
        rowClass:           dueInfo.cssClass.includes('overdue') ? 'fd-row fd-row--overdue' : 'fd-row',
    };
}

// ─── Enrich receivable row ──────────────────────────────────────────────────
function enrichReceivable(r) {
    const dueInfo = getDueInfo(r.dueDate, r.outstandingBalance);
    return {
        ...r,
        receivableDateISO:  sfDateToISO(r.receivableDate),
        dueDateISO:         sfDateToISO(r.dueDate),
        statusBadgeClass:   STATUS_BADGE_MAP[r.status] || 'fd-badge fd-badge--neutral',
        dueLabel:           dueInfo.label,
        dueBadgeClass:      dueInfo.cssClass,
        rowClass:           dueInfo.cssClass.includes('overdue') ? 'fd-row fd-row--overdue' : 'fd-row',
    };
}

// ─── Enrich invoice row ─────────────────────────────────────────────────────
function enrichInvoice(r) {
    const dueInfo = getDueInfo(r.dueDate, r.balanceDue);
    return {
        ...r,
        invoiceDateISO:     sfDateToISO(r.invoiceDate),
        dueDateISO:         sfDateToISO(r.dueDate),
        statusBadgeClass:   STATUS_BADGE_MAP[r.status] || 'fd-badge fd-badge--neutral',
        dueLabel:           dueInfo.label,
        dueBadgeClass:      dueInfo.cssClass,
        rowClass:           dueInfo.cssClass.includes('overdue') ? 'fd-row fd-row--overdue' : 'fd-row',
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// LWC Component
// ═══════════════════════════════════════════════════════════════════════════
export default class FinancialDashboard extends NavigationMixin(LightningElement) {

    // ── State ───────────────────────────────────────────────────────────
    @track userAccountId   = null;
    @track userAccountName = null;
    @track noAccountError  = false;

    @track isLoadingContext    = true;
    @track isLoadingPayables   = false;
    @track isLoadingReceivables= false;
    @track isLoadingInvoices   = false;

    @track globalError       = null;
    @track payablesError     = null;
    @track receivablesError  = null;
    @track invoicesError     = null;

    @track summary = {
        myValuation: 0,
        myOutstanding: 0,
        networkValuation: 0,
        networkOutstanding: 0,
        totalPayables: 0,
        totalReceivables: 0,
        totalInvoiceCount: 0,
        overduePayables: 0,
        overdueReceivables: 0,
        dueSoonPayables: 0,
        dueSoonReceivables: 0,
        outstandingPayables: 0,
        outstandingReceivables: 0
    };

    // Raw data from Apex
    @track _payables    = [];
    @track _receivables = [];
    @track _invoices    = [];

    // Active tab
    @track activeTab = 'payables';

    // Valuation section visibility toggle
    @track showValuation = false;

    // Filter states
    @track payableSearch    = '';
    @track receivableSearch = '';
    @track invoiceSearch    = '';

    @track payableStatusFilter    = 'all';
    @track receivableStatusFilter = 'all';
    @track invoiceStatusFilter    = 'all';

    // Sort states
    @track payableSort    = 'dueDate_asc';
    @track receivableSort = 'dueDate_asc';
    @track invoiceSort    = 'dueDate_asc';

    // Pagination
    @track payablesOffset    = 0;
    @track receivablesOffset = 0;
    @track invoicesOffset    = 0;

    // Account search & type filter (global across Enterprise View)
    @track accountSearch     = '';
    @track accountTypeFilter = 'all';   // 'all' | 'Distributor' | 'Dealer' | 'Retailer'

    // ── Lifecycle ───────────────────────────────────────────────────────
    connectedCallback() {
        this._loadUserContext();
    }

    async _loadUserContext() {
        this.isLoadingContext = true;
        this.globalError = null;
        try {
            const ctx = await getUserAccountContext();
            if (ctx && ctx.accountId) {
                this.userAccountId   = ctx.accountId;
                this.userAccountName = ctx.accountName;
                await this._loadDashboardData();
            } else {
                this.noAccountError = true;
            }
        } catch (e) {
            this.globalError = 'Unable to load your account context. Please try again.';
        } finally {
            this.isLoadingContext = false;
        }
    }

    async _loadDashboardData() {
        this.isLoadingPayables    = true;
        this.isLoadingReceivables = true;
        this.isLoadingInvoices    = true;
        this.payablesError        = null;
        this.receivablesError     = null;
        this.invoicesError        = null;

        try {
            const data = await getDashboardData({
                accountId: this.userAccountId,
                pageSize:  PAGE_SIZE,
                offset:    0
            });
            this._payables    = (data.payables    || []).map(enrichPayable);
            this._receivables = (data.receivables || []).map(enrichReceivable);
            this._invoices    = (data.invoices    || []).map(enrichInvoice);
            this.summary      = data.summary || this.summary;
            // Reset offsets on full refresh
            this.payablesOffset    = 0;
            this.receivablesOffset = 0;
            this.invoicesOffset    = 0;
        } catch (e) {
            this.globalError = 'Unable to load financial records. Please try again.';
        } finally {
            this.isLoadingPayables    = false;
            this.isLoadingReceivables = false;
            this.isLoadingInvoices    = false;
        }
    }

    // ── Computed properties ─────────────────────────────────────────────
    get hasAccount() {
        return !!this.userAccountId;
    }

    get totalDueSoon() {
        const p = this.summary.dueSoonPayables    || 0;
        const r = this.summary.dueSoonReceivables || 0;
        return p + r;
    }

    // Valuation Panel & Button Getters
    get valuationButtonLabel() {
        return this.showValuation ? 'Hide Valuation' : 'Valuation';
    }

    get valuationButtonIcon() {
        return this.showValuation ? 'utility:chevrondown' : 'utility:chart';
    }

    get valuationButtonClass() {
        return `fd-btn-valuation ${this.showValuation ? 'fd-btn-valuation--active' : ''}`;
    }

    get grossFinancialAmount() {
        return (this.summary.totalPayables || 0) + (this.summary.totalReceivables || 0);
    }

    get settledAmount() {
        const payablesSettled = (this.summary.totalPayables || 0) - (this.summary.outstandingPayables || 0);
        const receivablesSettled = (this.summary.totalReceivables || 0) - (this.summary.outstandingReceivables || 0);
        return Math.max(0, payablesSettled + receivablesSettled);
    }

    handleToggleValuation() {
        this.showValuation = !this.showValuation;
    }

    // Tab visibility
    get isPayablesTab()    { return this.activeTab === 'payables';    }
    get isReceivablesTab() { return this.activeTab === 'receivables'; }
    get isInvoicesTab()    { return this.activeTab === 'invoices';    }

    // Tab CSS classes
    get payablesTabClass()    { return `fd-tab ${this.activeTab === 'payables'    ? 'fd-tab--active' : ''}`; }
    get receivablesTabClass() { return `fd-tab ${this.activeTab === 'receivables' ? 'fd-tab--active' : ''}`; }
    get invoicesTabClass()    { return `fd-tab ${this.activeTab === 'invoices'    ? 'fd-tab--active' : ''}`; }

    // Sort options
    get sortOptions() { return SORT_OPTIONS; }

    // Status filters (with dynamic CSS per section)
    get statusFilters() {
        return STATUS_FILTERS.map(f => ({
            ...f,
            cssClass:    `fd-filter-btn ${this.payableStatusFilter    === f.value ? 'fd-filter-btn--active' : ''}`,
            cssClassRec: `fd-filter-btn ${this.receivableStatusFilter === f.value ? 'fd-filter-btn--active' : ''}`,
        }));
    }

    get invoiceStatusFilters() {
        return INV_STATUS_FILTERS.map(f => ({
            ...f,
            cssClassInv: `fd-filter-btn ${this.invoiceStatusFilter === f.value ? 'fd-filter-btn--active' : ''}`,
        }));
    }

    // ── Filtered + sorted data ──────────────────────────────────────────
    get filteredPayables() {
        let data = this._filterRecords(this._payables, this.payableSearch, this.payableStatusFilter, ['payableNumber','supplyingAccountName','requestingAccountName','invoiceNumber']);
        data = this._applyGlobalFilters(data, ['supplyingAccountName','requestingAccountName']);
        return this._sortRecords(data, this.payableSort);
    }

    get filteredReceivables() {
        let data = this._filterRecords(this._receivables, this.receivableSearch, this.receivableStatusFilter, ['receivableNumber','requestingAccountName','supplyingAccountName','customerName','invoiceNumber']);
        data = this._applyGlobalFilters(data, ['requestingAccountName','supplyingAccountName','customerName']);
        return this._sortRecords(data, this.receivableSort);
    }

    get filteredInvoices() {
        let data = this._filterRecords(this._invoices, this.invoiceSearch, this.invoiceStatusFilter, ['invoiceNumber','requestingAccountName','supplyingAccountName']);
        data = this._applyGlobalFilters(data, ['requestingAccountName','supplyingAccountName']);
        return this._sortRecords(data, this.invoiceSort);
    }

    _filterRecords(records, search, statusFilter, searchFields) {
        let data = records || [];
        if (statusFilter && statusFilter !== 'all') {
            data = data.filter(r => r.status === statusFilter);
        }
        if (search && search.trim()) {
            const term = search.trim().toLowerCase();
            data = data.filter(r =>
                searchFields.some(f => r[f] && r[f].toLowerCase().includes(term))
            );
        }
        return data;
    }

    // Apply global account search + account type filter
    _applyGlobalFilters(records, accountFields) {
        let data = records || [];
        // Global account name search
        if (this.accountSearch && this.accountSearch.trim()) {
            const term = this.accountSearch.trim().toLowerCase();
            data = data.filter(r =>
                accountFields.some(f => r[f] && r[f].toLowerCase().includes(term))
            );
        }
        // Account type filter (uses accountType field if available, else checks accountTypePrimary)
        if (this.accountTypeFilter && this.accountTypeFilter !== 'all') {
            const type = this.accountTypeFilter.toLowerCase();
            data = data.filter(r => {
                // Check dedicated accountType fields first, then fall back to name matching
                const primaryType  = (r.supplyingAccountType  || r.requestingAccountType || r.accountType || '').toLowerCase();
                const secondaryType= (r.requestingAccountType || '').toLowerCase();
                if (primaryType) return primaryType === type || secondaryType === type;
                // Fallback: check account names contain the type keyword
                return accountFields.some(f => r[f] && r[f].toLowerCase().includes(type));
            });
        }
        return data;
    }


    _sortRecords(records, sortValue) {
        return [...records].sort(buildComparator(sortValue));
    }

    // ── Counts for tab badges ───────────────────────────────────────────
    get payablesCount()    { return this._payables.length    || null; }
    get receivablesCount() { return this._receivables.length || null; }
    get invoicesCount()    { return this._invoices.length    || null; }

    // ── Empty / table visibility ────────────────────────────────────────
    get showPayablesTable()   { return !this.isLoadingPayables    && !this.payablesError    && this.filteredPayables.length    > 0; }
    get showPayablesEmpty()   { return !this.isLoadingPayables    && !this.payablesError    && this.filteredPayables.length    === 0; }
    get showReceivablesTable(){ return !this.isLoadingReceivables && !this.receivablesError && this.filteredReceivables.length > 0; }
    get showReceivablesEmpty(){ return !this.isLoadingReceivables && !this.receivablesError && this.filteredReceivables.length === 0; }
    get showInvoicesTable()   { return !this.isLoadingInvoices    && !this.invoicesError    && this.filteredInvoices.length    > 0; }
    get showInvoicesEmpty()   { return !this.isLoadingInvoices    && !this.invoicesError    && this.filteredInvoices.length    === 0; }

    // ── Pagination ──────────────────────────────────────────────────────
    get showPayablesPagination()    { return this._payables.length    >= PAGE_SIZE; }
    get showReceivablesPagination() { return this._receivables.length >= PAGE_SIZE; }
    get showInvoicesPagination()    { return this._invoices.length    >= PAGE_SIZE; }

    get isPrevDisabled()        { return this.payablesOffset    === 0; }
    get isPayablesNextDisabled(){ return this._payables.length    < PAGE_SIZE; }
    get isRecPrevDisabled()     { return this.receivablesOffset === 0; }
    get isRecNextDisabled()     { return this._receivables.length < PAGE_SIZE; }
    get isInvPrevDisabled()     { return this.invoicesOffset    === 0; }
    get isInvNextDisabled()     { return this._invoices.length    < PAGE_SIZE; }

    get payablesPaginationLabel()    { return `${this.payablesOffset + 1} – ${this.payablesOffset + this._payables.length}`; }
    get receivablesPaginationLabel() { return `${this.receivablesOffset + 1} – ${this.receivablesOffset + this._receivables.length}`; }
    get invoicesPaginationLabel()    { return `${this.invoicesOffset + 1} – ${this.invoicesOffset + this._invoices.length}`; }

    // ── Event Handlers ──────────────────────────────────────────────────

    handleTabChange(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    handleRefresh() {
        this._loadDashboardData();
    }

    handlePayableSearch(event)    { this.payableSearch    = event.target.value; }
    handleReceivableSearch(event) { this.receivableSearch = event.target.value; }
    handleInvoiceSearch(event)    { this.invoiceSearch    = event.target.value; }

    handlePayableSort(event)    { this.payableSort    = event.detail.value; }
    handleReceivableSort(event) { this.receivableSort = event.detail.value; }
    handleInvoiceSort(event)    { this.invoiceSort    = event.detail.value; }

    handleStatusFilter(event) {
        const section = event.currentTarget.dataset.section;
        const filter  = event.currentTarget.dataset.filter;
        if (section === 'payable')    this.payableStatusFilter    = filter;
        if (section === 'receivable') this.receivableStatusFilter = filter;
        if (section === 'invoice')    this.invoiceStatusFilter    = filter;
    }

    // ── Account Type Toggle & Account Search ────────────────────────────
    handleAccountTypeFilter(event) {
        this.accountTypeFilter = event.currentTarget.dataset.type || 'all';
    }

    handleAccountSearch(event) {
        this.accountSearch = event.target.value;
    }

    handleClearAccountSearch() {
        this.accountSearch = '';
    }

    // Account type toggle button CSS getters
    get acctTypeAllClass()         { return this._acctTypePillClass('all'); }
    get acctTypeDistributorClass() { return this._acctTypePillClass('Distributor'); }
    get acctTypeDealerClass()      { return this._acctTypePillClass('Dealer'); }
    get acctTypeRetailerClass()    { return this._acctTypePillClass('Retailer'); }

    _acctTypePillClass(type) {
        const base = 'fd-acct-type-btn';
        return this.accountTypeFilter === type ? `${base} fd-acct-type-btn--active` : base;
    }

    get accountTypeFilterLabel() {
        return (this.accountTypeFilter && this.accountTypeFilter !== 'all')
            ? this.accountTypeFilter
            : '';
    }

    // ── Navigation ──────────────────────────────────────────────────────

    handleNavClick(event) {
        event.stopPropagation();
        const recordId  = event.currentTarget.dataset.recordId;
        const objectAPI = event.currentTarget.dataset.object;
        this._navigateToRecord(recordId, objectAPI);
    }

    handleRowClick(event) {
        const recordId  = event.currentTarget.dataset.recordId;
        const objectAPI = event.currentTarget.dataset.object;
        if (recordId) this._navigateToRecord(recordId, objectAPI);
    }

    _navigateToRecord(recordId, objectApiName) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId:     recordId,
                objectApiName:objectApiName,
                actionName:   'view'
            }
        });
    }

    // ── Pagination handlers ─────────────────────────────────────────────

    async handlePayablesPrev() {
        if (this.payablesOffset >= PAGE_SIZE) {
            this.payablesOffset -= PAGE_SIZE;
            await this._reloadPayables();
        }
    }

    async handlePayablesNext() {
        this.payablesOffset += PAGE_SIZE;
        await this._reloadPayables();
    }

    async handleReceivablesPrev() {
        if (this.receivablesOffset >= PAGE_SIZE) {
            this.receivablesOffset -= PAGE_SIZE;
            await this._reloadReceivables();
        }
    }

    async handleReceivablesNext() {
        this.receivablesOffset += PAGE_SIZE;
        await this._reloadReceivables();
    }

    async handleInvoicesPrev() {
        if (this.invoicesOffset >= PAGE_SIZE) {
            this.invoicesOffset -= PAGE_SIZE;
            await this._reloadInvoices();
        }
    }

    async handleInvoicesNext() {
        this.invoicesOffset += PAGE_SIZE;
        await this._reloadInvoices();
    }

    async _reloadPayables() {
        this.isLoadingPayables = true;
        this.payablesError = null;
        try {
            const data = await getDashboardData({
                accountId: this.userAccountId,
                pageSize:  PAGE_SIZE,
                offset:    this.payablesOffset
            });
            this._payables = (data.payables || []).map(enrichPayable);
        } catch (e) {
            this.payablesError = 'Failed to load payables.';
        } finally {
            this.isLoadingPayables = false;
        }
    }

    async _reloadReceivables() {
        this.isLoadingReceivables = true;
        this.receivablesError = null;
        try {
            const data = await getDashboardData({
                accountId: this.userAccountId,
                pageSize:  PAGE_SIZE,
                offset:    this.receivablesOffset
            });
            this._receivables = (data.receivables || []).map(enrichReceivable);
        } catch (e) {
            this.receivablesError = 'Failed to load receivables.';
        } finally {
            this.isLoadingReceivables = false;
        }
    }

    async _reloadInvoices() {
        this.isLoadingInvoices = true;
        this.invoicesError = null;
        try {
            const data = await getDashboardData({
                accountId: this.userAccountId,
                pageSize:  PAGE_SIZE,
                offset:    this.invoicesOffset
            });
            this._invoices = (data.invoices || []).map(enrichInvoice);
        } catch (e) {
            this.invoicesError = 'Failed to load invoices.';
        } finally {
            this.isLoadingInvoices = false;
        }
    }
}