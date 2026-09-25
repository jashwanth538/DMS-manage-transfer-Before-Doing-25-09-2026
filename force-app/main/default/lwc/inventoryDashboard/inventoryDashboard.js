import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getDashboardInitData from '@salesforce/apex/InventoryDashboardController.getDashboardInitData';
import searchInventories from '@salesforce/apex/InventoryDashboardController.searchInventories';
import updateInventoryStock from '@salesforce/apex/InventoryDashboardController.updateInventoryStock';

import getRelatedSaleOrders from '@salesforce/apex/InventoryOverviewModalController.getRelatedSaleOrders';
import getRelatedInventoryTransfers from '@salesforce/apex/InventoryOverviewModalController.getRelatedInventoryTransfers';
import getRelatedTransitInOrders from '@salesforce/apex/InventoryOverviewModalController.getRelatedTransitInOrders';
import getRelatedTransitOutOrders from '@salesforce/apex/InventoryOverviewModalController.getRelatedTransitOutOrders';

export default class InventoryDashboard extends NavigationMixin(LightningElement) {

    // ============================================================
    // Search & Filter Properties
    // ============================================================

    @track searchKey = '';
    @track selectedSearchColumn = 'Item';
    @track selectedLocationId = '';
    @track locationSearchInputTerm = '';
    @track isLocationDropdownOpen = false;
    @track selectedStatusFilter = '';
    @track locationSearchKey = '';

    // ============================================================
    // Hierarchy & Navigation State
    // ============================================================

    @track selectedAccountType = 'all'; // 'all', 'OEM', 'Distributor', 'Dealer', 'Retailer'
    @track selectedAccountId = '';
    @track accountSearchTerm = '';
    @track isAccountDropdownOpen = false;
    @track availableTabs = [{ tabId: 'all', label: 'All', count: 0 }];
    @track hierarchyAccounts = [];
    @track userEnterpriseType = 'Standard';
    @track userDirectAccountIds = [];


    // ============================================================
    // Master Data
    // ============================================================

    @track locations = [];
    @track items = [];
    @track rawInventories = [];


    // ============================================================
    // UI State
    // ============================================================

    @track isLoading = false;


    @track itemPriceMap = {};
    @track showValuationMetrics = false;

    // ============================================================
    // KPI Statistics
    // ============================================================

    @track kpiStats = {
        totalOnHand: 0,
        totalAvailable: 0,
        totalReservedSaleOrder: 0,
        totalDamaged: 0,
        totalTransitIn: 0,
        totalTransitOut: 0,
        totalValuationOnHand: 0,
        totalValuationAvailable: 0,
        formattedTotalValuation: '$0.00',
        healthScore: 100,
        healthLabel: 'Optimal',
        healthClass: 'health-badge-optimal',
        // Current User Direct Valuation & Health
        userTotalOnHand: 0,
        userTotalValuationOnHand: 0,
        formattedUserValuation: '$0.00',
        userHealthScore: 100,
        userHealthLabel: 'Optimal',
        userHealthClass: 'health-badge-optimal',
        userTrackedItemsCount: 0
    };


    // ============================================================
    // Sorting
    // ============================================================

    @track sortBy = 'Item__r.Name';
    @track sortDirection = 'asc';


    // ============================================================
    // Pagination
    // ============================================================

    @track pageNumber = 1;
    @track pageSize = 5;


    // ============================================================
    // Stock Adjustment Modal
    // ============================================================

    @track isAdjustModalOpen = false;
    @track isModalSaving = false;
    @track editRecord = {};


    // ============================================================
    // Detail Modal
    // ============================================================

    @track isDetailModalOpen = false;
    @track isDetailModalLoading = false;
    @track detailModalType = '';
    @track detailModalTitle = '';
    @track detailModalItemName = '';
    @track detailModalLocationName = '';
    @track detailModalData = [];

    // ============================================================
    // Row Valuation Modal
    // ============================================================

    @track isValuationModalOpen = false;
    @track valuationRecord = {};


    // ============================================================
    // Search Debounce
    // ============================================================

    delayTimeout;
    requestId = 0;


    // ============================================================
    // Detail Modal Getters
    // ============================================================

    get isSaleOrderDetailModal() {
        return this.detailModalType === 'saleOrder';
    }


    get isTransferDetailModal() {
        return (
            this.detailModalType === 'transfer' ||
            this.detailModalType === 'transitIn' ||
            this.detailModalType === 'transitOut'
        );
    }


    get hasDetailModalData() {
        return (
            this.detailModalData &&
            this.detailModalData.length > 0
        );
    }


    get valuationToggleBtnClass() {
        return `action-btn ${this.showValuationMetrics ? 'valuation-btn-active' : ''}`;
    }

    get valuationToggleLabel() {
        return this.showValuationMetrics ? 'Hide Valuation' : 'Valuation & Health';
    }

    // ============================================================
    // Active Filters
    // ============================================================

    get hasActiveFilters() {
        return !!(
            (this.searchKey && this.searchKey.trim()) ||
            this.selectedLocationId ||
            (this.locationSearchKey && this.locationSearchKey.trim()) ||
            this.selectedStatusFilter ||
            this.selectedAccountId ||
            (this.selectedAccountType && this.selectedAccountType !== 'all')
        );
    }

    // ============================================================
    // Hierarchy Tabs & Account Filter Getters
    // ============================================================

    get isRetailer() {
        return this.userEnterpriseType === 'Retailer';
    }

    get showNetworkValuationMetrics() {
        // Retailers don't have downstream partners or network locations, so hide network cards for them
        return this.showEnterpriseView;
    }

    get valuationCardColumnClass() {
        // If network metrics are shown (4 cards), size 1-of-4 on large screens. If only 2 cards (Retailer), size 1-of-2 on large screens.
        return this.showNetworkValuationMetrics
            ? 'slds-col slds-size_1-of-1 slds-small-size_1-of-2 slds-medium-size_1-of-2 slds-large-size_1-of-4 slds-m-bottom_small'
            : 'slds-col slds-size_1-of-1 slds-small-size_1-of-2 slds-medium-size_1-of-2 slds-large-size_1-of-2 slds-m-bottom_small';
    }

    get valuationCardTitle() {
        return this.showNetworkValuationMetrics ? 'My Valuation (On Hand)' : 'Total Inventory Valuation (On Hand)';
    }

    get stockHealthCardTitle() {
        return this.showNetworkValuationMetrics ? 'My Stock Health' : 'Stock Health';
    }

    get showEnterpriseView() {
        // If the logged in user is a Retailer, hide Enterprise View
        if (this.userEnterpriseType === 'Retailer') {
            return false;
        }
        // If there are no category tabs beyond 'All', or only 1 account in total, hide Enterprise View
        const nonAllTabs = (this.availableTabs || []).filter(t => t.tabId !== 'all');
        if (nonAllTabs.length === 0) {
            return false;
        }
        if (!this.hierarchyAccounts || this.hierarchyAccounts.length <= 1) {
            return false;
        }
        return true;
    }

    get renderedTabs() {
        return (this.availableTabs || []).map(tab => ({
            ...tab,
            isActive: this.selectedAccountType === tab.tabId,
            tabClass: this.selectedAccountType === tab.tabId ? 'active-tab-pill' : 'tab-pill'
        }));
    }

    get showAccountDropdown() {
        return this.accountOptions.length > 1;
    }

    get filteredHierarchyAccounts() {
        if (!this.hierarchyAccounts || this.hierarchyAccounts.length === 0) {
            return [];
        }
        if (!this.selectedAccountType || this.selectedAccountType === 'all') {
            return this.hierarchyAccounts;
        }
        return this.hierarchyAccounts.filter(acc => acc.recordTypeDeveloperName === this.selectedAccountType);
    }

    get searchableAccountList() {
        let list = this.filteredHierarchyAccounts;
        if (this.accountSearchTerm && this.accountSearchTerm.trim()) {
            const term = this.accountSearchTerm.toLowerCase().trim();
            list = list.filter(acc => {
                const nameMatch = acc.name && acc.name.toLowerCase().includes(term);
                const typeMatch = acc.recordTypeName && acc.recordTypeName.toLowerCase().includes(term);
                return nameMatch || typeMatch;
            });
        }
        return list.map(acc => ({
            ...acc,
            isSelected: acc.id === this.selectedAccountId,
            itemClass: `slds-media slds-listbox__option slds-listbox__option_plain slds-media_small ${acc.id === this.selectedAccountId ? 'slds-is-selected active-account-item' : 'account-option-item'}`
        }));
    }

    get accountOptions() {
        const typeLabel = this.selectedAccountType === 'all' 
            ? 'All Accounts' 
            : `All ${this.selectedAccountType}s`;

        const options = [
            { label: typeLabel, value: '' }
        ];

        this.filteredHierarchyAccounts.forEach(acc => {
            const typeSuffix = acc.recordTypeName ? ` (${acc.recordTypeName})` : '';
            options.push({
                label: `${acc.name}${typeSuffix}`,
                value: acc.id
            });
        });

        return options;
    }

    get selectedAccountLabel() {
        if (!this.selectedAccountId) {
            return this.selectedAccountType === 'all' ? 'All Accounts' : `All ${this.selectedAccountType}s`;
        }
        const acc = this.hierarchyAccounts.find(a => a.id === this.selectedAccountId);
        return acc ? acc.name : (this.selectedAccountType === 'all' ? 'All Accounts' : `All ${this.selectedAccountType}s`);
    }

    get accountSearchPlaceholder() {
        if (this.selectedAccountId) {
            return this.selectedAccountLabel;
        }
        return this.selectedAccountType === 'all' ? 'Search All Accounts...' : `Search ${this.selectedAccountType}s...`;
    }

    // ============================================================
    // Location Options (Hierarchy Filtered)
    // ============================================================

    get filteredLocations() {
        if (!this.locations || this.locations.length === 0) {
            return [];
        }

        let locs = this.locations;

        // If specific account selected
        if (this.selectedAccountId) {
            locs = locs.filter(loc => loc.Account__c === this.selectedAccountId);
        } else if (this.selectedAccountType && this.selectedAccountType !== 'all') {
            // Filter by all accounts belonging to the selected account type
            const allowedAccIds = new Set(this.filteredHierarchyAccounts.map(a => a.id));
            locs = locs.filter(loc => loc.Account__c && allowedAccIds.has(loc.Account__c));
        }

        return locs;
    }

    get searchableLocationList() {
        let locs = this.filteredLocations;
        if (this.locationSearchInputTerm && this.locationSearchInputTerm.trim()) {
            const term = this.locationSearchInputTerm.toLowerCase().trim();
            locs = locs.filter(loc => {
                const nameMatch = loc.Name && loc.Name.toLowerCase().includes(term);
                const codeMatch = loc.Inventory_Location_Code__c && loc.Inventory_Location_Code__c.toLowerCase().includes(term);
                const accMatch = loc.Account__r && loc.Account__r.Name && loc.Account__r.Name.toLowerCase().includes(term);
                return nameMatch || codeMatch || accMatch;
            });
        }
        return locs.map(loc => {
            const accPrefix = loc.Account__r && loc.Account__r.Name ? `${loc.Account__r.Name} - ` : '';
            return {
                ...loc,
                displayName: `${accPrefix}${loc.Name}`,
                code: loc.Inventory_Location_Code__c || 'No Code',
                isSelected: loc.Id === this.selectedLocationId,
                itemClass: `slds-media slds-listbox__option slds-listbox__option_plain slds-media_small ${loc.Id === this.selectedLocationId ? 'slds-is-selected active-account-item' : 'account-option-item'}`
            };
        });
    }

    get selectedLocationLabel() {
        if (!this.selectedLocationId) {
            return 'All Locations';
        }
        const loc = this.locations.find(l => l.Id === this.selectedLocationId);
        if (loc) {
            const accPrefix = loc.Account__r && loc.Account__r.Name ? `${loc.Account__r.Name} - ` : '';
            return `${accPrefix}${loc.Name} (${loc.Inventory_Location_Code__c || 'No Code'})`;
        }
        return 'Selected Location';
    }

    get locationSearchPlaceholder() {
        if (this.selectedLocationId) {
            return this.selectedLocationLabel;
        }
        return 'Search Locations...';
    }

    get locationOptions() {
        return [
            {
                label: 'All Locations',
                value: ''
            },
            ...this.filteredLocations.map(loc => {
                const accPrefix = loc.Account__r && loc.Account__r.Name ? `${loc.Account__r.Name} - ` : '';
                return {
                    label: `${accPrefix}${loc.Name} (${loc.Inventory_Location_Code__c || 'No Code'})`,
                    value: loc.Id
                };
            })
        ];
    }


    // ============================================================
    // Status Options
    // ============================================================

    get statusOptions() {
        return [
            {
                label: 'All Stock Levels',
                value: ''
            },
            {
                label: 'Low Stock (< Reorder Level)',
                value: 'low'
            },
            {
                label: 'Out of Stock (0)',
                value: 'out'
            },
            {
                label: 'Damaged Stock (> 0)',
                value: 'damaged'
            }
        ];
    }


    // ============================================================
    // Alert Level Options
    // ============================================================

    get alertLevelOptions() {
        return [
            {
                label: 'All Levels',
                value: ''
            },
            {
                label: 'Low',
                value: 'low'
            },
            {
                label: 'Medium',
                value: 'medium'
            },
            {
                label: 'High',
                value: 'high'
            }
        ];
    }


    // ============================================================
    // Search Column Options
    // ============================================================

    get searchColumns() {
        return [
            {
                label: 'All Columns',
                value: ''
            },
            {
                label: 'Item Name/Code',
                value: 'Item'
            },
            {
                label: 'Location Name/Code',
                value: 'Location'
            }
        ];
    }


    // ============================================================
    // Table Columns
    // ============================================================

    get columns() {
        return [
            {
                label: 'Stock Ref',
                fieldName: 'Name',
                sortable: true,
                headerClass: 'table-header font-weight-semibold'
            },
            {
                label: 'Item Details',
                fieldName: 'Item__r.Name',
                sortable: true,
                headerClass: 'table-header font-weight-semibold'
            },
            {
                label: 'Location',
                fieldName: 'Inventory_Location__r.Name',
                sortable: true,
                headerClass: 'table-header font-weight-semibold'
            },
            {
                label: 'Available',
                fieldName: 'Available__c',
                sortable: true,
                headerClass: 'table-header font-weight-semibold slds-text-align_right'
            },
            {
                label: 'On Hand',
                fieldName: 'On_Hand_Qty__c',
                sortable: true,
                headerClass: 'table-header font-weight-semibold slds-text-align_right'
            },
            {
                label: 'Reserved - Sale Order',
                fieldName: 'Reserved_Sale_Order__c',
                sortable: true,
                headerClass: 'table-header font-weight-semibold slds-text-align_right'
            },
            {
                label: 'Damaged',
                fieldName: 'Damaged__c',
                sortable: true,
                headerClass: 'table-header font-weight-semibold slds-text-align_right'
            },
            {
                label: 'Transit (In/Out)',
                fieldName: 'Transit',
                sortable: false,
                headerClass: 'table-header font-weight-semibold slds-text-align_center'
            },
            {
                label: 'Status',
                fieldName: 'Status',
                sortable: false,
                headerClass: 'table-header font-weight-semibold slds-text-align_center'
            },
            {
                label: 'Actions',
                fieldName: 'Actions',
                sortable: false,
                headerClass: 'table-header font-weight-semibold slds-text-align_center'
            }
        ];
    }


    // ============================================================
    // Lifecycle
    // ============================================================

    connectedCallback() {
        this.fetchInitialData();
        this.queryInventories();
    }


    // ============================================================
    // Initial Data
    // ============================================================

    fetchInitialData() {

        getDashboardInitData()

            .then(result => {

                console.log(
                    '@@@@' + JSON.stringify(result)
                );

                if (result && result.isSuccess) {

                    this.locations =
                        result.referenceCache &&
                        result.referenceCache.locations
                            ? result.referenceCache.locations
                            : [];

                    this.items =
                        result.referenceCache &&
                        result.referenceCache.items
                            ? result.referenceCache.items
                            : [];

                    const hierarchyContext =
                        result.referenceCache &&
                        result.referenceCache.hierarchyContext
                            ? result.referenceCache.hierarchyContext
                            : null;

                    if (hierarchyContext) {
                        this.userEnterpriseType = hierarchyContext.userType || 'Standard';
                        this.availableTabs = hierarchyContext.availableTabs || [{ tabId: 'all', label: 'All', count: 0 }];
                        this.hierarchyAccounts = hierarchyContext.accounts || [];
                        this.userDirectAccountIds = hierarchyContext.directAccountIds || [];
                    }

                    const stats =
                        result.referenceCache
                            ? result.referenceCache.stats
                            : null;

                    if (
                        stats &&
                        !this.hasActiveFilters &&
                        (
                            !this.rawInventories ||
                            this.rawInventories.length === 0
                        )
                    ) {

                        this.kpiStats = {
                            totalOnHand:
                                stats.totalOnHand || 0,

                            totalAvailable:
                                stats.totalAvailable || 0,

                            totalReservedSaleOrder:
                                stats.totalReservedSaleOrder || 0,

                            totalDamaged:
                                stats.totalDamaged || 0,

                            totalTransitIn:
                                stats.totalTransitIn || 0,

                            totalTransitOut:
                                stats.totalTransitOut || 0
                        };
                    }

                } else {

                    this.showToast(
                        'Error',
                        'Failed to retrieve init data: ' +
                        (
                            result
                                ? result.errorMsg
                                : 'Unknown error'
                        ),
                        'error'
                    );
                }

            })

            .catch(error => {

                console.error(
                    'Error fetching init data',
                    error
                );

                this.showToast(
                    'Error',
                    'Error retrieving layout parameters: ' +
                    (
                        error.body
                            ? error.body.message
                            : error.message
                    ),
                    'error'
                );

            });
    }


    // ============================================================
    // Query Inventories
    // ============================================================

    queryInventories() {

        this.isLoading = true;

        const currentRequestId =
            ++this.requestId;

        searchInventories({

            searchKey:
                this.searchKey,

            locationId:
                this.selectedLocationId,

            statusFilter:
                this.selectedStatusFilter,

            searchColumn:
                this.selectedSearchColumn,

            locationSearchKey:
                this.locationSearchKey,

            accountId:
                this.selectedAccountId,

            accountType:
                this.selectedAccountType

        })

            .then(result => {

                if (
                    currentRequestId !==
                    this.requestId
                ) {
                    return;
                }

                if (
                    result &&
                    result.isSuccess
                ) {

                    this.rawInventories =
                        result.resultList || [];

                    if (result.referenceCache && result.referenceCache.itemPriceMap) {
                        this.itemPriceMap = result.referenceCache.itemPriceMap;
                    }

                    this.pageNumber = 1;

                    this.calculateDynamicKPIs();

                } else {

                    this.showToast(
                        'Error',
                        'Failed searching inventory: ' +
                        (
                            result
                                ? result.errorMsg
                                : 'Unknown error'
                        ),
                        'error'
                    );
                }

            })

            .catch(error => {

                if (
                    currentRequestId !==
                    this.requestId
                ) {
                    return;
                }

                console.error(
                    'Error querying inventories',
                    error
                );

                this.showToast(
                    'Error',
                    'Error querying inventory records: ' +
                    (
                        error.body
                            ? error.body.message
                            : error.message
                    ),
                    'error'
                );

            })

            .finally(() => {

                if (
                    currentRequestId ===
                    this.requestId
                ) {
                    this.isLoading = false;
                }

            });
    }


    // ============================================================
    // Calculate KPIs
    // ============================================================

    calculateDynamicKPIs() {
        let totalOnHand = 0;
        let totalAvailable = 0;
        let totalReservedSaleOrder = 0;
        let totalDamaged = 0;
        let totalTransitIn = 0;
        let totalTransitOut = 0;
        let totalValuationOnHand = 0;
        let totalValuationAvailable = 0;
        let healthyItemCount = 0;
        let totalTrackedItems = this.rawInventories.length;

        // Current User Direct Stock & Valuation
        const directAccountSet = new Set(this.userDirectAccountIds || []);
        let userTotalOnHand = 0;
        let userTotalValuationOnHand = 0;
        let userHealthyItemCount = 0;
        let userTrackedItemsCount = 0;

        this.rawInventories.forEach(rec => {
            const onHand = rec.On_Hand_Qty__c || 0;
            const available = rec.Available__c || 0;
            const reserved = rec.Reserved_Sale_Order__c || 0;
            const damaged = rec.Damaged__c || 0;
            const transitIn = rec.Transit_In_Quantity__c || 0;
            const transitOut = rec.Transit_Out_Quantity__c || 0;

            totalOnHand += onHand;
            totalAvailable += available;
            totalReservedSaleOrder += reserved;
            totalDamaged += damaged;
            totalTransitIn += transitIn;
            totalTransitOut += transitOut;

            // Determine if this inventory record belongs directly to current user's mapped accounts
            const recAccId = rec.Account__c || (rec.Inventory_Location__r && rec.Inventory_Location__r.Account__c);
            const isUserDirectRec = directAccountSet.size === 0 || (recAccId && directAccountSet.has(recAccId));

            // Lookup unit price
            let unitPrice = 0;
            if (rec.Item__c && this.itemPriceMap) {
                const accKey = recAccId ? `${rec.Item__c}_${recAccId}` : null;
                if (accKey && this.itemPriceMap[accKey] !== undefined) {
                    unitPrice = this.itemPriceMap[accKey];
                } else if (this.itemPriceMap[rec.Item__c] !== undefined) {
                    unitPrice = this.itemPriceMap[rec.Item__c];
                }
            }

            const recValuationOnHand = (onHand * unitPrice);
            totalValuationOnHand += recValuationOnHand;
            totalValuationAvailable += (available * unitPrice);

            // Health determination: SKU is healthy if available > low threshold (or reorder level)
            const lowLimit = (rec.Item__r && rec.Item__r.Stock_Low_Level_Quantity__c !== undefined)
                ? rec.Item__r.Stock_Low_Level_Quantity__c
                : (rec.Reorder_Level__c || 10);

            const isHealthy = (available > lowLimit);
            if (isHealthy) {
                healthyItemCount++;
            }

            // User-specific aggregation
            if (isUserDirectRec) {
                userTrackedItemsCount++;
                userTotalOnHand += onHand;
                userTotalValuationOnHand += recValuationOnHand;
                if (isHealthy) {
                    userHealthyItemCount++;
                }
            }
        });

        // Network health
        const healthScore = totalTrackedItems > 0 
            ? Math.round((healthyItemCount / totalTrackedItems) * 100) 
            : 100;

        let healthLabel = 'Optimal';
        let healthClass = 'health-badge-optimal';

        if (healthScore < 50) {
            healthLabel = 'Critical Shortage';
            healthClass = 'health-badge-critical';
        } else if (healthScore < 80) {
            healthLabel = 'Low Stock Risk';
            healthClass = 'health-badge-warning';
        }

        const formattedTotalValuation = new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'INR',
            maximumFractionDigits: 0
        }).format(totalValuationOnHand);

        // User health & valuation
        const userHealthScore = userTrackedItemsCount > 0
            ? Math.round((userHealthyItemCount / userTrackedItemsCount) * 100)
            : 100;

        let userHealthLabel = 'Optimal';
        let userHealthClass = 'health-badge-optimal';

        if (userHealthScore < 50) {
            userHealthLabel = 'Critical Shortage';
            userHealthClass = 'health-badge-critical';
        } else if (userHealthScore < 80) {
            userHealthLabel = 'Low Stock Risk';
            userHealthClass = 'health-badge-warning';
        }

        const formattedUserValuation = new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'INR',
            maximumFractionDigits: 0
        }).format(userTotalValuationOnHand);

        this.kpiStats = {
            totalOnHand,
            totalAvailable,
            totalReservedSaleOrder,
            totalDamaged,
            totalTransitIn,
            totalTransitOut,
            totalValuationOnHand,
            totalValuationAvailable,
            formattedTotalValuation,
            healthScore,
            healthLabel,
            healthClass,
            // User Direct metrics
            userTotalOnHand,
            userTotalValuationOnHand,
            formattedUserValuation,
            userHealthScore,
            userHealthLabel,
            userHealthClass,
            userTrackedItemsCount
        };
    }

    handleToggleValuationMetrics() {
        this.showValuationMetrics = !this.showValuationMetrics;
    }


    // ============================================================
    // Process Inventory Records
    // ============================================================

    get processedInventories() {

        return this.rawInventories.map(rec => {

            const available =
                rec.Available__c || 0;

            const damaged =
                rec.Damaged__c || 0;

            const lowLimit =
                rec.Item__r &&
                rec.Item__r.Stock_Low_Level_Quantity__c !== undefined
                    ? rec.Item__r.Stock_Low_Level_Quantity__c
                    : 10;

            const medLimit =
                rec.Item__r &&
                rec.Item__r.Stock_Medium_Level_Quantity__c !== undefined
                    ? rec.Item__r.Stock_Medium_Level_Quantity__c
                    : 30;

            let availableClass =
                'available-qty font-weight-bold ';

            if (available > medLimit) {

                availableClass +=
                    'text-green';

            } else if (available > lowLimit) {

                availableClass +=
                    'text-orange';

            } else {

                availableClass +=
                    'text-red';
            }

            const damagedClass =
                damaged > 0
                    ? 'text-red font-weight-semibold'
                    : 'text-slate-400';

            let statusLabel =
                'High Stock';

            let statusClass =
                'slds-badge badge-custom badge-success';

            if (available <= 0) {

                statusLabel =
                    'Out of Stock';

                statusClass =
                    'slds-badge badge-custom badge-error';

            } else if (available <= lowLimit) {

                statusLabel =
                    'Low Stock';

                statusClass =
                    'slds-badge badge-custom badge-error';

            } else if (available <= medLimit) {

                statusLabel =
                    'Medium Stock';

                statusClass =
                    'slds-badge badge-custom badge-warning';
            }

            let unitPrice = 0;
            if (rec.Item__c && this.itemPriceMap) {
                const accKey = rec.Account__c ? `${rec.Item__c}_${rec.Account__c}` : null;
                if (accKey && this.itemPriceMap[accKey] !== undefined) {
                    unitPrice = this.itemPriceMap[accKey];
                } else if (this.itemPriceMap[rec.Item__c] !== undefined) {
                    unitPrice = this.itemPriceMap[rec.Item__c];
                }
            }

            const onHandQty = rec.On_Hand_Qty__c || 0;
            const totalValuation = onHandQty * unitPrice;

            return {
                Id: rec.Id,
                Name: rec.Name,
                itemName: rec.Item__r ? rec.Item__r.Name : 'Unknown Item',
                itemCode: rec.Item__r ? (rec.Item__r.Item_Code__c || 'N/A') : 'N/A',
                locationName: rec.Inventory_Location__r ? rec.Inventory_Location__r.Name : 'Unknown Location',
                locationCode: rec.Inventory_Location__r ? (rec.Inventory_Location__r.Inventory_Location_Code__c || 'N/A') : 'N/A',
                onHandQty: onHandQty,
                availableQty: available,
                reservedSaleOrderQty: rec.Reserved_Sale_Order__c || 0,
                damagedQty: damaged,
                transitInQty: rec.Transit_In_Quantity__c || 0,
                transitOutQty: rec.Transit_Out_Quantity__c || 0,
                unitPrice: unitPrice,
                totalValuation: totalValuation,
                formattedUnitPrice: new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' }).format(unitPrice),
                formattedTotalValuation: new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(totalValuation),
                availableClass: availableClass,
                damagedClass: damagedClass,
                statusLabel: statusLabel,
                statusClass: statusClass
            };
        });
    }


    get hasRecords() {

        return (
            this.rawInventories &&
            this.rawInventories.length > 0
        );

    }


    // ============================================================
    // Search Handlers
    // ============================================================

    handleItemSearchChange(event) {

        this.searchKey =
            event.target.value || '';

        window.clearTimeout(
            this.delayTimeout
        );

        this.delayTimeout =
            window.setTimeout(() => {

                this.queryInventories();

            }, 300);
    }


    handleLocationChange(event) {

        this.selectedLocationId =
            event.detail.value;

        this.queryInventories();
    }


    handleLocationSearchChange(event) {

        this.locationSearchKey =
            event.target.value || '';

        window.clearTimeout(
            this.delayTimeout
        );

        this.delayTimeout =
            window.setTimeout(() => {

                this.queryInventories();

            }, 300);
    }


    handleStatusFilterChange(event) {

        this.selectedStatusFilter =
            event.detail.value;

        this.queryInventories();
    }


    // ============================================================
    // Hierarchy Navigation Event Handlers
    // ============================================================

    handleTabClick(event) {
        const tabId = event.currentTarget.dataset.id;
        if (this.selectedAccountType === tabId) {
            return;
        }
        this.selectedAccountType = tabId;
        this.selectedAccountId = ''; // reset specific account selection when switching tabs
        this.accountSearchTerm = '';
        this.selectedLocationId = ''; // reset location when switching tab
        this.queryInventories();
    }

    handleAccountChange(event) {
        this.selectedAccountId = event.detail.value;
        this.accountSearchTerm = '';
        this.selectedLocationId = ''; // reset location selection when changing account
        this.queryInventories();
    }

    handleAccountSearchInput(event) {
        this.accountSearchTerm = event.target.value || '';
        this.isAccountDropdownOpen = true;
    }

    handleAccountSearchFocus() {
        this.isAccountDropdownOpen = true;
    }

    handleAccountSearchBlur() {
        // Delay closing so that click selection on dropdown option register
        window.setTimeout(() => {
            this.isAccountDropdownOpen = false;
        }, 250);
    }

    handleSelectAccount(event) {
        const accId = event.currentTarget.dataset.id || '';
        this.selectedAccountId = accId;
        this.accountSearchTerm = '';
        this.isAccountDropdownOpen = false;
        this.selectedLocationId = ''; // reset location when switching account
        this.queryInventories();
    }

    handleClearAccountSelection(event) {
        if (event) {
            event.stopPropagation();
        }
        this.selectedAccountId = '';
        this.accountSearchTerm = '';
        this.isAccountDropdownOpen = false;
        this.selectedLocationId = '';
        this.queryInventories();
    }

    handleResetFilters() {

        this.searchKey = '';

        this.selectedSearchColumn =
            'Item';

        this.selectedLocationId = '';

        this.locationSearchKey = '';

        this.selectedStatusFilter = '';

        this.selectedAccountType = 'all';

        this.selectedAccountId = '';

        this.accountSearchTerm = '';

        this.isAccountDropdownOpen = false;

        this.queryInventories();

        this.fetchInitialData();
    }


    handleRefreshData() {

        this.queryInventories();

        this.fetchInitialData();

        this.showToast(
            'Success',
            'Data synchronized with Salesforce database',
            'success'
        );
    }


    // ============================================================
    // Navigation
    // ============================================================

    navigateToRecord(event) {

        event.preventDefault();

        const recordId =
            event.currentTarget.dataset.id;

        if (!recordId) {
            return;
        }

        this[NavigationMixin.Navigate]({

            type:
                'standard__recordPage',

            attributes: {

                recordId:
                    recordId,

                actionName:
                    'view'
            }
        });
    }


    // ============================================================
    // Sorting
    // ============================================================

    handleSort(event) {
        const { columnName, sortDirection } = event.detail || {};
        const field = columnName || (event.currentTarget && event.currentTarget.dataset ? event.currentTarget.dataset.field : null);

        if (!field) {
            return;
        }

        if (sortDirection) {
            this.sortDirection = sortDirection;
            this.sortBy = field;
        } else {
            this.sortDirection =
                this.sortBy === field && this.sortDirection === 'asc'
                    ? 'desc'
                    : 'asc';
            this.sortBy = field;
        }

        this.sortData(
            this.sortBy,
            this.sortDirection
        );
    }


    handleHeaderSort(event) {

        const field =
            event.currentTarget.dataset.field;

        this.sortDirection =
            this.sortBy === field &&
            this.sortDirection === 'asc'
                ? 'desc'
                : 'asc';

        this.sortBy =
            field;

        this.sortData(
            field,
            this.sortDirection
        );
    }



    sortData(
        fieldname,
        direction
    ) {

        const parseFieldName =
            rec => {

                if (
                    fieldname ===
                    'Item__r.Name'
                ) {

                    return rec.Item__r
                        ? rec.Item__r.Name
                        : '';

                }

                if (
                    fieldname ===
                    'Inventory_Location__r.Name'
                ) {

                    return rec.Inventory_Location__r
                        ? rec.Inventory_Location__r.Name
                        : '';

                }

                return (
                    rec[fieldname] !== undefined &&
                    rec[fieldname] !== null
                )
                    ? rec[fieldname]
                    : '';
            };

        const isReverse =
            direction === 'desc'
                ? -1
                : 1;

        this.rawInventories =
            [...this.rawInventories].sort(
                (a, b) => {

                    let keyA =
                        parseFieldName(a);

                    let keyB =
                        parseFieldName(b);

                    if (
                        typeof keyA ===
                        'string'
                    ) {
                        keyA =
                            keyA.toLowerCase();
                    }

                    if (
                        typeof keyB ===
                        'string'
                    ) {
                        keyB =
                            keyB.toLowerCase();
                    }

                    if (keyA < keyB) {
                        return -1 * isReverse;
                    }

                    if (keyA > keyB) {
                        return 1 * isReverse;
                    }

                    return 0;
                }
            );
    }


    // ============================================================
    // Pagination
    // ============================================================

    get paginatedRecords() {

        const start =
            (this.pageNumber - 1) *
            this.pageSize;

        const end =
            start + this.pageSize;

        return this.processedInventories.slice(
            start,
            end
        );
    }


    get totalRecordsCount() {

        return this.rawInventories.length;

    }


    get showingStart() {

        if (
            this.totalRecordsCount === 0
        ) {
            return 0;
        }

        return (
            (this.pageNumber - 1) *
            this.pageSize
        ) + 1;
    }


    get showingEnd() {

        const end =
            this.pageNumber *
            this.pageSize;

        return end >
            this.totalRecordsCount
            ? this.totalRecordsCount
            : end;
    }


    get isFirstPage() {

        return this.pageNumber === 1;

    }


    get isLastPage() {

        return (
            this.pageNumber >=
            Math.ceil(
                this.totalRecordsCount /
                this.pageSize
            )
        );
    }


    handlePageChange(event) {
        if (!event || !event.detail) {
            return;
        }
        const detail = event.detail;
        const newPage = detail.page || detail.pageNumber || detail.currentPage || detail.targetPage;
        const newSize = detail.pageSize || detail.recordsPerPage || detail.limit;

        if (newPage !== undefined && newPage !== null) {
            this.pageNumber = Number(newPage);
        }
        if (newSize !== undefined && newSize !== null) {
            this.pageSize = Number(newSize);
        }
    }


    handlePrevPage() {

        if (
            this.pageNumber > 1
        ) {
            this.pageNumber--;
        }
    }


    handleNextPage() {

        if (
            !this.isLastPage
        ) {
            this.pageNumber++;
        }
    }



    // ============================================================
    // Stock Adjustment Modal
    // ============================================================

    handleOpenAdjustModal(event) {

        const id =
            event.currentTarget.dataset.id;

        const selectedRec =
            this.processedInventories.find(
                item => item.Id === id
            );

        if (selectedRec) {

            this.editRecord = {
                ...selectedRec
            };

            this.isAdjustModalOpen =
                true;

            this.isModalSaving =
                false;
        }
    }


    handleCloseAdjustModal() {
        this.isAdjustModalOpen = false;
        this.editRecord = {};
    }

    handleOpenValuationModal(event) {
        const id = event.currentTarget.dataset.id;
        const selectedRec = this.processedInventories.find(item => item.Id === id);
        if (selectedRec) {
            this.valuationRecord = { ...selectedRec };
            this.isValuationModalOpen = true;
        }
    }

    handleCloseValuationModal() {
        this.isValuationModalOpen = false;
        this.valuationRecord = {};
    }


    // ============================================================
    // Modal Field Change
    // ============================================================

    handleModalFieldChange(event) {

        const fieldName =
            event.target.name;

        const val =
            event.target.value
                ? parseFloat(
                    event.target.value
                )
                : 0;

        this.editRecord = {

            ...this.editRecord,

            [fieldName]:
                val

        };
    }


    // ============================================================
    // Calculate Available
    // ============================================================

    get modalCalculatedAvailable() {

        return (
            this.editRecord.availableQty !== undefined &&
            this.editRecord.availableQty !== null
        )
            ? this.editRecord.availableQty
            : 0;
    }



    handleApplySuggestedAvailable() {

        this.editRecord = {

            ...this.editRecord,

            availableQty:
                this.modalCalculatedAvailable

        };
    }


    // ============================================================
    // Save Adjusted Stock
    // ============================================================

    handleSaveAdjustStock() {

        const allValid = [

            ...this.template.querySelectorAll(
                '.input-custom-modal'
            )

        ].reduce(
            (
                validSoFar,
                inputFields
            ) => {

                inputFields.reportValidity();

                return (
                    validSoFar &&
                    inputFields.checkValidity()
                );

            },
            true
        );

        if (!allValid) {

            this.showToast(
                'Validation Warning',
                'Please provide valid values for stock quantities',
                'warning'
            );

            return;
        }

        this.isModalSaving =
            true;

        updateInventoryStock({

            inventoryId:
                this.editRecord.Id,

            onHand:
                this.editRecord.onHandQty,

            reserved:
                0,

            damaged:
                this.editRecord.damagedQty,

            transitIn:
                this.editRecord.transitInQty,

            transitOut:
                this.editRecord.transitOutQty,

            available:
                this.editRecord.availableQty

        })

            .then(result => {

                if (
                    result &&
                    result.isSuccess
                ) {

                    this.showToast(
                        'Success',
                        `Inventory successfully adjusted for ${this.editRecord.itemName}`,
                        'success'
                    );

                    this.isAdjustModalOpen =
                        false;

                    this.queryInventories();

                    this.fetchInitialData();

                } else {

                    this.showToast(
                        'Error saving changes',
                        result
                            ? result.errorMsg
                            : 'Unknown error',
                        'error'
                    );
                }

            })

            .catch(error => {

                console.error(
                    'Error saving stock changes',
                    error
                );

                this.showToast(
                    'Error saving changes',
                    error.body
                        ? error.body.message
                        : error.message,
                    'error'
                );

            })

            .finally(() => {

                this.isModalSaving =
                    false;

            });
    }


    // ============================================================
    // Detail Modal
    // ============================================================

    handleOpenDetailModal(event) {

        event.preventDefault();

        const invId =
            event.currentTarget.dataset.id;

        const type =
            event.currentTarget.dataset.type;

        const rec =
            this.processedInventories.find(
                item => item.Id === invId
            );

        this.detailModalType =
            type;

        this.detailModalItemName =
            rec
                ? `${rec.itemName} (${rec.itemCode})`
                : '';

        this.detailModalLocationName =
            rec
                ? rec.locationName
                : '';

        this.detailModalData =
            [];

        this.isDetailModalOpen =
            true;

        this.isDetailModalLoading =
            true;


        if (
            type === 'saleOrder'
        ) {

            this.detailModalTitle =
                'Reserved Sale Orders';

            getRelatedSaleOrders({

                inventoryId:
                    invId

            })

                .then(data => {

                    this.detailModalData =
                        data || [];

                })

                .catch(error => {

                    console.error(
                        'Error fetching sale orders:',
                        error
                    );

                    this.showToast(
                        'Error',
                        'Error retrieving sale orders',
                        'error'
                    );

                })

                .finally(() => {

                    this.isDetailModalLoading =
                        false;

                });

            return;
        }


        if (
            type === 'transfer'
        ) {

            this.detailModalTitle =
                'Reserved Inventory Transfers';

            getRelatedInventoryTransfers({

                inventoryId:
                    invId

            })

                .then(data => {

                    this.detailModalData =
                        data || [];

                })

                .catch(error => {

                    console.error(
                        'Error fetching inventory transfers:',
                        error
                    );

                    this.showToast(
                        'Error',
                        'Error retrieving inventory transfers',
                        'error'
                    );

                })

                .finally(() => {

                    this.isDetailModalLoading =
                        false;

                });

            return;
        }


        if (
            type === 'transitIn'
        ) {

            this.detailModalTitle =
                'Transit In Orders';

            getRelatedTransitInOrders({

                inventoryId:
                    invId

            })

                .then(data => {

                    this.detailModalData =
                        data || [];

                })

                .catch(error => {

                    console.error(
                        'Error fetching transit in orders:',
                        error
                    );

                    this.showToast(
                        'Error',
                        'Error retrieving transit in orders',
                        'error'
                    );

                })

                .finally(() => {

                    this.isDetailModalLoading =
                        false;

                });

            return;
        }


        if (
            type === 'transitOut'
        ) {

            this.detailModalTitle =
                'Transit Out Orders';

            getRelatedTransitOutOrders({

                inventoryId:
                    invId

            })

                .then(data => {

                    this.detailModalData =
                        data || [];

                })

                .catch(error => {

                    console.error(
                        'Error fetching transit out orders:',
                        error
                    );

                    this.showToast(
                        'Error',
                        'Error retrieving transit out orders',
                        'error'
                    );

                })

                .finally(() => {

                    this.isDetailModalLoading =
                        false;

                });

            return;
        }


        this.isDetailModalLoading =
            false;
    }


    // ============================================================
    // Close Detail Modal
    // ============================================================

    handleCloseDetailModal() {

        this.isDetailModalOpen =
            false;

        this.detailModalData =
            [];

        this.detailModalType =
            '';

        this.detailModalTitle =
            '';

    }


    // ============================================================
    // Toast
    // ============================================================

    showToast(
        title,
        message,
        variant
    ) {

        this.dispatchEvent(
            new ShowToastEvent({

                title:
                    title,

                message:
                    message,

                variant:
                    variant

            })
        );
    }
}