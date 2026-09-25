import { LightningElement, track, api, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import {
  publish,
  subscribe,
  unsubscribe,
  MessageContext
} from "lightning/messageService";
import SUPPLY_PLAN_UPDATE_MC from "@salesforce/messageChannel/SupplyPlanUpdate__c";
import SUPPLY_PLAN_ACTION_MC from "@salesforce/messageChannel/SupplyPlanAction__c";
import searchAndFilterMessageChannel from "@salesforce/messageChannel/searchAndFilterMessage__c";
import paginationMessageChannel from "@salesforce/messageChannel/paginationMessage__c";
import getSupplyPlanData from "@salesforce/apex/SupplyOrderPlanner.getSupplyPlanData";
import updateLineItemReviewStatus from "@salesforce/apex/SupplyOrderPlanner.updateLineItemReviewStatus";
import updateBulkLineItemReviewStatus from "@salesforce/apex/SupplyOrderPlanner.updateBulkLineItemReviewStatus";
import submitPlanning from "@salesforce/apex/SupplyOrderPlanner.submitPlanning";

let stylesInjected = false;

export default class SupplyOrderPlanner extends LightningElement {
  _recordId;
  @api
  get recordId() {
    return this._recordId;
  }
  set recordId(value) {
    this._recordId = value;
    this.planNumber = value;
    if (value) {
      this.fetchPlanData();
    }
  }
  @track planNumber = "OA - 0000"; // Default search query populated with setup data
  @track isLoading = false;
  @track showTable = false;
  @track planData = {};
  @track transferLocations = [];
  @track lineItems = [];
  @track pageSize = 7; // Number of products per page
  @track currentPage = 1; // Current page index (1‑based)
  @track searchKey = "";
  @track sortOption = "default";

  @track errorMessage = "";
  @track isModalOpen = false;
  @track modalSummary = {
    reservations: [],
    transfers: [],
    procurements: []
  };
  @track modalHeader = "";
  @track modalSubtitle = "";
  @track successToastMessage = "Sales allocation saved successfully.";
  @track isErrorModalOpen = false;
  @track errorModalMessage = "";
  @track errorCountdown = 10;
  countdownInterval = null;

  @track isInventoryModalOpen = false;
  @track selectedInventoryItemId = null;
  @track selectedInventoryLocationId = null;
  @track selectedInventoryAccountId = null;

  get effectiveRecordId() {
    return (this.planData && this.planData.planId) ? this.planData.planId : this.recordId;
  }

  get planId() {
    return this.effectiveRecordId;
  }

  @wire(MessageContext)
  messageContext;
  actionSubscription = null;
  searchSubscription = null;
  paginationSubscription = null;

  sortOptions = [
    { label: "Line Item Sequence", value: "default" },
    { label: "Product Name: A to Z", value: "name-asc" },
    { label: "Product Name: Z to A", value: "name-desc" },
    { label: "Required Qty: High to Low", value: "qty-desc" },
    { label: "Required Qty: Low to High", value: "qty-asc" }
  ];

  get isRecordPage() {
    return !!this.recordId;
  }

  get isPlanningExecuted() {
    return (
      this.planData && this.planData.status && this.planData.status !== "Draft"
    );
  }

  get isAllReviewed() {
    const coveredItems = this.lineItems.filter((item) => item.isCovered);
    return (
      coveredItems.length > 0 &&
      coveredItems.every((item) => item.isReviewed)
    );
  }

  get isAllReviewedDisabled() {
    return (
      this.isPlanningExecuted ||
      this.lineItems.length === 0 ||
      !this.lineItems.some((item) => item.isCovered) ||
      this.lineItems.some((item) => item.isUpdatingReview)
    );
  }

  get isLocationConfigured() {
    return this.planData && !!this.planData.destinationLocationId;
  }

  get isLocationActive() {
    return this.planData && !!this.planData.isDestinationLocationActive;
  }

  get destinationLocationSublabel() {
    if (!this.isLocationConfigured) {
      return "(Location not configured)";
    }
    if (!this.isLocationActive) {
      return "(Inactive Location)";
    }
    return "Available";
  }

  get isSublabelRed() {
    return !this.isLocationConfigured || !this.isLocationActive;
  }

  connectedCallback() {
    this.subscribeToActionChannel();
    this.subscribeToSearchChannel();
    this.subscribeToPaginationChannel();
    this.injectCustomStyles();
    if (this.recordId) {
      this.planNumber = this.recordId;
      this.fetchPlanData();
    } else {
      // Automatically fetch the default test data on load for a premium user experience
      this.fetchPlanData();
    }
  }

  disconnectedCallback() {
    if (this.actionSubscription) {
      unsubscribe(this.actionSubscription);
      this.actionSubscription = null;
    }
    if (this.searchSubscription) {
      unsubscribe(this.searchSubscription);
      this.searchSubscription = null;
    }
    if (this.paginationSubscription) {
      unsubscribe(this.paginationSubscription);
      this.paginationSubscription = null;
    }
    if (this.countdownInterval) {
      clearInterval(this.countdownInterval);
      this.countdownInterval = null;
    }
  }

  subscribeToActionChannel() {
    if (!this.actionSubscription) {
      this.actionSubscription = subscribe(
        this.messageContext,
        SUPPLY_PLAN_ACTION_MC,
        (message) => this.handleActionMessage(message)
      );
    }
  }

  handleActionMessage(message) {
    if (message && message.actionType === "SUBMIT_PLAN") {
      this.handleSubmitPlanning();
    }
  }

  subscribeToSearchChannel() {
    if (!this.searchSubscription) {
      this.searchSubscription = subscribe(
        this.messageContext,
        searchAndFilterMessageChannel,
        (message) => this.handleSearchMessage(message)
      );
    }
  }

  handleSearchMessage(message) {
    if (message && message.sourceComponent === "genericSearchAndFilterPanel") {
      this.searchKey = message.searchText || "";
      if (message.filterColumn === "SortOrder") {
        this.sortOption = message.filterValue || "default";
      }
      this.currentPage = 1;
    }
  }

  subscribeToPaginationChannel() {
    if (!this.paginationSubscription) {
      this.paginationSubscription = subscribe(
        this.messageContext,
        paginationMessageChannel,
        (message) => this.handlePaginationMessage(message)
      );
    }
  }

  handlePaginationMessage(message) {
    if (message && message.sourceComponent === "genericPagination") {
      this.currentPage = message.currentPage || 1;
      this.pageSize = message.pageSize || 7;
      this.scrollToHeader();
    }
  }

  injectCustomStyles() {
    if (!stylesInjected) {
      const style = document.createElement("style");
      style.innerText = `
                .generic-search-panel .search-filter-panel {
                    background: #ffffff !important;
                    border: 1px solid #e2e8f0 !important;
                    border-radius: 12px !important;
                    box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05) !important;
                    padding: 16px 20px !important;
                    transition: all 0.3s ease !important;
                }
                .generic-search-panel .search-filter-panel:hover {
                    box-shadow: 0 8px 12px -2px rgba(0, 0, 0, 0.06) !important;
                }
                .generic-search-panel .reset-btn-custom {
                    height: 38px !important;
                    white-space: nowrap !important;
                    padding: 0 1.25rem !important;
                    border-radius: 8px !important;
                }
                @media (min-width: 768px) {
                    .generic-search-panel .action-btn-col {
                        min-width: 155px !important;
                    }
                }
            `;
      document.head.appendChild(style);
      stylesInjected = true;
    }
  }

  handleSearchChange(event) {
    this.planNumber = event.target.value;
  }

  get procurementHeaderLabel() {
    if (this.planData && this.planData.procurementAccountName) {
      return `Procurement (${this.planData.procurementAccountName})`;
    }
    return "Procurement";
  }

  handleSearchSubmit() {
    this.fetchPlanData();
  }

  fetchPlanData() {
    if (!this.planNumber || !this.planNumber.trim()) {
      this.showToast(
        "Error",
        "Please enter a Sales Allocation Number.",
        "error"
      );
      return Promise.reject(new Error("No plan number"));
    }

    this.isLoading = true;
    this.errorMessage = "";
    this.showTable = false;

    return getSupplyPlanData({ planNumber: this.planNumber.trim() })
      .then((result) => {
        this.planData = result;
        this.transferLocations = result.transferLocations || [];
        // Reset pagination and filters when new data arrives
        this.currentPage = 1;
        this.searchKey = "";
        this.sortOption = "default";

        // Map line items to include local reactively bound inputs with default prefilled allocations
        // isExecuted: true only when the plan is Awaiting Inventory — load saved planned values.
        // For Draft status, always auto-calculate reserve/transfer/procure from available stock.
        const isExecuted = result.status && result.status !== "Draft";
        this.lineItems = (result.lineItems || []).map((item, index) => {
          const requiredQty = item.requiredQty || 0;
          const destinationStock = (item.destinationStock !== null && item.destinationStock !== undefined) ? item.destinationStock : null;
          const hasDestinationInventory = destinationStock !== null;

          let reserveQty = 0;
          let procureQty = 0;
          let transfers = [];

          if (isExecuted) {
            // Load pre-saved planned values from wrapper
            reserveQty = item.reserveQtyPlanned || 0;
            procureQty = item.procureQtyPlanned || 0;
            transfers = this.transferLocations.map((loc) => {
              const rawStock = item.transferStocks ? item.transferStocks[loc.locationId] : undefined;
              const availableStock = (rawStock !== null && rawStock !== undefined) ? rawStock : null;
              const hasInventory = availableStock !== null;
              const qty =
                (item.transferQtyPlannedMap &&
                  item.transferQtyPlannedMap[loc.locationId]) ||
                0;
              return {
                locationId: loc.locationId,
                locationName: loc.locationName,
                availableStock: availableStock,
                availableStockDisplay: hasInventory ? availableStock : "-",
                qty: qty,
                stockClass:
                  !hasInventory ? "stock-none" : (availableStock > 0 ? "stock-available" : "stock-zero"),
                inputClass: "qty-input",
                hasInventory: hasInventory
              };
            });

            if (transfers.length > 0 && transfers.reduce((sum, t) => sum + (Number(t.qty) || 0), 0) === 0 && (Number(item.transferQtyPlanned) || 0) > 0) {
              const targetTrans = transfers.find(t => t.availableStock > 0) || transfers[0];
              targetTrans.qty = Number(item.transferQtyPlanned);
            }
          } else {
            // Fallback to dynamic on-the-fly calculation
            let remaining = requiredQty;
            reserveQty = this.isLocationActive
              ? Math.min(remaining, destinationStock || 0)
              : 0;
            remaining -= reserveQty;

            transfers = this.transferLocations.map((loc) => {
              const rawStock = item.transferStocks ? item.transferStocks[loc.locationId] : undefined;
              const availableStock = (rawStock !== null && rawStock !== undefined) ? rawStock : null;
              const hasInventory = availableStock !== null;
              const qty = Math.min(remaining, availableStock || 0);
              remaining -= qty;

              return {
                locationId: loc.locationId,
                locationName: loc.locationName,
                availableStock: availableStock,
                availableStockDisplay: hasInventory ? availableStock : "-",
                qty: qty,
                stockClass:
                  !hasInventory ? "stock-none" : (availableStock > 0 ? "stock-available" : "stock-zero"),
                inputClass: "qty-input",
                hasInventory: hasInventory
              };
            });
            procureQty = remaining;
          }

          const mappedItem = {
            sequence: index,
            lineItemId: item.lineItemId,
            lineItemName: item.lineItemName,
            itemId: item.itemId,
            itemName: item.itemName,
            itemCode: item.itemCode,
            requiredQty: requiredQty,
            destinationStock: destinationStock,
            destinationStockDisplay: hasDestinationInventory ? destinationStock : "-",
            destStockClass:
              destinationStock > 0 ? "stock-available" : (destinationStock === null ? "stock-none" : "stock-zero"),
            reserveQty: reserveQty,
            reserveInputClass: "qty-input",
            hasDestinationInventory: hasDestinationInventory,
            transfers: transfers,
            procureQty: procureQty,
            status: item.status || 'Draft',
            isReviewed: item.isReviewed || false,
            isUpdatingReview: false,

            // Recalculated states
            remainingQty: 0,
            coveragePercentage: 0,
            isCovered: false,
            coverageText: "0% Covered",
            coverageStatus: "pending",
            badgeClass: "status-badge badge-pending",
            progressClass: "progress-bar-fill bg-pending",
            progressStyle: "width: 0%;"
          };

          this.recalculateItem(mappedItem);
          return mappedItem;
        });

        this.recalculateTotals();
        this.showTable = true;
        this.isLoading = false;
        // Ensure pagination reflects the new list size
        this.currentPage = 1;
      })
      .catch((error) => {
        this.isLoading = false;
        this.showTable = false;
        this.errorMessage =
          (error && error.body && error.body.message) ||
          "Error retrieving sales allocation data.";
        this.showToast("Search Failed", this.errorMessage, "error");
        throw error;
      });
  }

  handleNumberKeyDown(event) {
    const allowedKeys = [
      "Backspace",
      "Tab",
      "Delete",
      "ArrowLeft",
      "ArrowRight",
      "ArrowUp",
      "ArrowDown",
      "Enter",
      "Home",
      "End"
    ];
    if (allowedKeys.includes(event.key) || event.ctrlKey || event.metaKey) {
      return;
    }
    if (!/^[0-9]$/.test(event.key)) {
      event.preventDefault();
      event.stopPropagation();
    }
  }

  uncheckReviewIfNeeded(item) {
    if (item.isReviewed) {
      item.isReviewed = false;
      updateLineItemReviewStatus({
        lineItemId: item.lineItemId,
        isReviewed: false
      }).catch((error) => {
        console.error("Error auto-unchecking review status:", error);
      });
    }
  }

  handleReserveChange(event) {
    const itemId = event.target.dataset.itemId;
    let rawVal = event.target.value;
    if (rawVal !== null && rawVal !== undefined) {
      rawVal = String(rawVal).replace(/\D/g, "");
    }
    let val = rawVal === "" ? "" : Math.max(0, parseInt(rawVal, 10) || 0);

    this.lineItems = this.lineItems.map((item) => {
      if (item.itemId === itemId) {
        const newItem = { ...item };
        const otherAllocations =
          newItem.transfers.reduce((sum, t) => sum + (Number(t.qty) || 0), 0) +
          (Number(newItem.procureQty) || 0);
        const maxAllowed = Math.max(0, newItem.requiredQty - otherAllocations);
        const limit = Math.min(newItem.destinationStock || 0, maxAllowed);

        if (val !== "" && val > limit) {
          val = limit;
          event.target.value = val;
        }
        if (newItem.reserveQty !== val) {
          newItem.reserveQty = val;
          this.uncheckReviewIfNeeded(newItem);
        }
        newItem.reserveInputClass = "qty-input";
        this.recalculateItem(newItem);
        return newItem;
      }
      return item;
    });

    this.recalculateTotals();
  }

  handleTransferChange(event) {
    const itemId = event.target.dataset.itemId;
    const locId = event.target.dataset.locId;
    let rawVal = event.target.value;
    if (rawVal !== null && rawVal !== undefined) {
      rawVal = String(rawVal).replace(/\D/g, "");
    }
    let val = rawVal === "" ? "" : Math.max(0, parseInt(rawVal, 10) || 0);

    this.lineItems = this.lineItems.map((item) => {
      if (item.itemId === itemId) {
        const newItem = { ...item };
        const otherTransfers = newItem.transfers.reduce((sum, t) => {
          return t.locationId !== locId ? sum + (Number(t.qty) || 0) : sum;
        }, 0);
        const otherAllocations =
          (Number(newItem.reserveQty) || 0) +
          (Number(newItem.procureQty) || 0) +
          otherTransfers;
        const maxAllowed = Math.max(0, newItem.requiredQty - otherAllocations);

        let changed = false;
        newItem.transfers = newItem.transfers.map((t) => {
          if (t.locationId === locId) {
            const newT = { ...t };
            const limit = Math.min(newT.availableStock || 0, maxAllowed);
            if (val !== "" && val > limit) {
              val = limit;
              event.target.value = val;
            }
            if (newT.qty !== val) {
              newT.qty = val;
              changed = true;
            }
            newT.inputClass = "qty-input";
            return newT;
          }
          return t;
        });
        if (changed) {
          this.uncheckReviewIfNeeded(newItem);
        }
        this.recalculateItem(newItem);
        return newItem;
      }
      return item;
    });

    this.recalculateTotals();
  }

  handleProcureChange(event) {
    const itemId = event.target.dataset.itemId;
    let rawVal = event.target.value;
    if (rawVal !== null && rawVal !== undefined) {
      rawVal = String(rawVal).replace(/\D/g, "");
    }
    let val = rawVal === "" ? "" : Math.max(0, parseInt(rawVal, 10) || 0);

    this.lineItems = this.lineItems.map((item) => {
      if (item.itemId === itemId) {
        const newItem = { ...item };
        const otherAllocations =
          (Number(newItem.reserveQty) || 0) +
          newItem.transfers.reduce((sum, t) => sum + (Number(t.qty) || 0), 0);
        const maxAllowed = Math.max(0, newItem.requiredQty - otherAllocations);

        if (val !== "" && val > maxAllowed) {
          val = maxAllowed;
          event.target.value = val;
        }
        if (newItem.procureQty !== val) {
          newItem.procureQty = val;
          this.uncheckReviewIfNeeded(newItem);
        }
        this.recalculateItem(newItem);
        return newItem;
      }
      return item;
    });

    this.recalculateTotals();
  }

  // Auto-allocate Stock based on business rules: Reserve -> Transfer -> Procure
  handleAutoAllocate() {
    this.lineItems = this.lineItems.map((item) => {
      const newItem = { ...item };
      let remaining = newItem.requiredQty;

      // 1. Reserve first from destination stock (only if active)
      const reserveAlloc = this.isLocationActive
        ? Math.min(remaining, newItem.destinationStock || 0)
        : 0;
      const prevReserve = newItem.reserveQty;
      newItem.reserveQty = reserveAlloc;
      newItem.reserveInputClass = "qty-input";
      remaining -= reserveAlloc;

      // 2. Transfer from other locations
      let transferChanged = false;
      newItem.transfers = newItem.transfers.map((t) => {
        const newT = { ...t };
        const transAlloc = Math.min(remaining, newT.availableStock || 0);
        if (newT.qty !== transAlloc) {
          transferChanged = true;
        }
        newT.qty = transAlloc;
        newT.inputClass = "qty-input";
        remaining -= transAlloc;
        return newT;
      });

      // 3. Procure remaining
      const prevProcure = newItem.procureQty;
      newItem.procureQty = remaining;

      if (
        prevReserve !== reserveAlloc ||
        transferChanged ||
        prevProcure !== remaining
      ) {
        this.uncheckReviewIfNeeded(newItem);
      }

      this.recalculateItem(newItem);
      return newItem;
    });

    this.recalculateTotals();
    this.showToast(
      "Success",
      "Successfully auto-allocated stock allocations.",
      "success"
    );
  }

  handleResetPlanning() {
    this.lineItems = this.lineItems.map((item) => {
      const newItem = { ...item };
      let changed = false;
      if (newItem.reserveQty !== 0) {
        newItem.reserveQty = 0;
        changed = true;
      }
      newItem.reserveInputClass = "qty-input";
      if (newItem.procureQty !== 0) {
        newItem.procureQty = 0;
        changed = true;
      }
      newItem.transfers = newItem.transfers.map((t) => {
        const newT = { ...t };
        if (newT.qty !== 0) {
          newT.qty = 0;
          changed = true;
        }
        newT.inputClass = "qty-input";
        return newT;
      });
      if (changed) {
        this.uncheckReviewIfNeeded(newItem);
      }
      this.recalculateItem(newItem);
      return newItem;
    });

    this.recalculateTotals();
    this.showToast(
      "Reset Complete",
      "All plan allocations have been cleared.",
      "info"
    );
  }

  recalculateItem(item) {
    const totalAllocated =
      (Number(item.reserveQty) || 0) +
      item.transfers.reduce((sum, t) => sum + (Number(t.qty) || 0), 0) +
      (Number(item.procureQty) || 0);

    const isFulfilled = totalAllocated >= item.requiredQty;
    const isExecuted = this.isPlanningExecuted;

    const hasDestInventory = item.destinationStock !== null && item.destinationStock !== undefined;
    item.isReserveDisabled =
      isExecuted ||
      !hasDestInventory ||
      item.destinationStock <= 0 ||
      (isFulfilled && (Number(item.reserveQty) || 0) === 0);
    item.reserveTitle = isExecuted
      ? "Planning has been executed"
      : !hasDestInventory
        ? "No inventory record exists"
        : item.destinationStock <= 0
          ? "No stock available"
          : item.isReserveDisabled
            ? "Required quantity has been fulfilled"
            : "";

    item.transfers = item.transfers.map((t) => {
      const newT = { ...t };
      const hasInventory = newT.availableStock !== null;
      newT.isDisabled =
        isExecuted ||
        !hasInventory ||
        newT.availableStock <= 0 ||
        (isFulfilled && (Number(newT.qty) || 0) === 0);
      newT.title = isExecuted
        ? "Planning has been executed"
        : !hasInventory
          ? "No inventory record exists"
          : newT.availableStock <= 0
            ? "No stock available"
            : newT.isDisabled
              ? "Required quantity has been fulfilled"
              : "";
      return newT;
    });

    item.isProcureDisabled =
      isExecuted || (isFulfilled && (Number(item.procureQty) || 0) === 0);
    item.procureTitle = isExecuted
      ? "Planning has been executed"
      : item.isProcureDisabled
        ? "Required quantity has been fulfilled"
        : "";

    item.remainingQty = Math.max(0, item.requiredQty - totalAllocated);

    const pct =
      item.requiredQty > 0 ? (totalAllocated / item.requiredQty) * 100 : 0;
    item.coveragePercentage =
      totalAllocated < item.requiredQty
        ? Math.min(99, Math.round(pct))
        : Math.round(pct);

    if (totalAllocated === 0) {
      item.coverageStatus = "pending";
      item.isCovered = false;
      item.coverageText = "0% Covered";
      item.badgeClass = "status-badge badge-pending";
      item.progressClass = "progress-bar-fill bg-pending";
      item.progressStyle = "width: 0%;";
    } else if (totalAllocated < item.requiredQty) {
      item.coverageStatus = "partial";
      item.isCovered = false;
      item.coverageText = `${item.coveragePercentage}% Covered`;
      item.badgeClass = "status-badge badge-partial";
      item.progressClass = "progress-bar-fill bg-partial";
      item.progressStyle = `width: ${Math.min(100, item.coveragePercentage)}%;`;
    } else if (totalAllocated === item.requiredQty) {
      item.coverageStatus = "covered";
      item.isCovered = true;
      item.coverageText = "100% Covered";
      item.badgeClass = "status-badge badge-covered";
      item.progressClass = "progress-bar-fill bg-covered";
      item.progressStyle = "width: 100%;";
    } else {
      item.coverageStatus = "over";
      item.isCovered = false;
      item.coverageText = `Over (+${totalAllocated - item.requiredQty})`;
      item.badgeClass = "status-badge badge-over";
      item.progressClass = "progress-bar-fill bg-over";
      item.progressStyle = "width: 100%;";
    }

    if (!item.isCovered) {
      this.uncheckReviewIfNeeded(item);
    }
  }

  // ---------- Search, Sorting and Filtering ----------
  handleClearSearch() {
    this.searchKey = "";
    this.currentPage = 1;
  }

  get filteredAndSortedLineItems() {
    let items = [...this.lineItems];

    // Apply search query filter
    if (this.searchKey && this.searchKey.trim()) {
      const search = this.searchKey.trim().toLowerCase();
      items = items.filter((item) => {
        const name = item.itemName ? item.itemName.toLowerCase() : "";
        const code = item.itemCode ? item.itemCode.toLowerCase() : "";
        const lineItemName = item.lineItemName
          ? item.lineItemName.toLowerCase()
          : "";
        return (
          name.includes(search) ||
          code.includes(search) ||
          lineItemName.includes(search)
        );
      });
    }

    // Apply sorting selection
    items.sort((a, b) => {
      if (this.sortOption === "default" || this.sortOption === "line-asc") {
        if (a.lineItemName && b.lineItemName) {
          const comp = a.lineItemName.localeCompare(b.lineItemName, undefined, { numeric: true, sensitivity: 'base' });
          if (comp !== 0) return comp;
        }
        return (a.sequence || 0) - (b.sequence || 0);
      } else if (this.sortOption === "name-asc") {
        return (a.itemName || "").localeCompare(b.itemName || "");
      } else if (this.sortOption === "name-desc") {
        return (b.itemName || "").localeCompare(a.itemName || "");
      } else if (this.sortOption === "qty-desc") {
        return (b.requiredQty || 0) - (a.requiredQty || 0);
      } else if (this.sortOption === "qty-asc") {
        return (a.requiredQty || 0) - (b.requiredQty || 0);
      }
      return 0;
    });

    return items;
  }

  get hasMatchingItems() {
    return this.filteredAndSortedLineItems.length > 0;
  }

  handleSelectAllReview(event) {
    const checked = event.target.checked;

    const eligibleItems = this.lineItems.filter((item) => item.isCovered);
    if (eligibleItems.length === 0) {
      return;
    }

    const eligibleIds = eligibleItems.map((item) => item.lineItemId);
    const eligibleIdSet = new Set(eligibleIds);

    // Mark eligible items as updating review state to show local spinner loaders
    this.lineItems = this.lineItems.map((item) => {
      if (eligibleIdSet.has(item.lineItemId)) {
        return { ...item, isUpdatingReview: true };
      }
      return item;
    });

    updateBulkLineItemReviewStatus({
      lineItemIds: eligibleIds,
      isReviewed: checked
    })
      .then(() => {
        this.lineItems = this.lineItems.map((item) => {
          if (eligibleIdSet.has(item.lineItemId)) {
            return { ...item, isReviewed: checked, isUpdatingReview: false };
          }
          return item;
        });
        this.recalculateTotals();
      })
      .catch((error) => {
        this.lineItems = this.lineItems.map((item) => {
          if (eligibleIdSet.has(item.lineItemId)) {
            return { ...item, isUpdatingReview: false };
          }
          return item;
        });
        const msg =
          (error && error.body && error.body.message) ||
          "Error updating review status.";
        this.showToast("Error", msg, "error");
      });
  }

  handleReviewChange(event) {
    const lineItemId = event.target.dataset.lineItemId;
    const checked = event.target.checked;

    // Mark this line item as updating review state to show local loader
    this.lineItems = this.lineItems.map((item) => {
      if (item.lineItemId === lineItemId) {
        return { ...item, isUpdatingReview: true };
      }
      return item;
    });

    updateLineItemReviewStatus({ lineItemId: lineItemId, isReviewed: checked })
      .then(() => {
        this.lineItems = this.lineItems.map((item) => {
          if (item.lineItemId === lineItemId) {
            return { ...item, isReviewed: checked, isUpdatingReview: false };
          }
          return item;
        });
        this.recalculateTotals();
      })
      .catch((error) => {
        this.lineItems = this.lineItems.map((item) => {
          if (item.lineItemId === lineItemId) {
            return { ...item, isUpdatingReview: false };
          }
          return item;
        });
        const msg =
          (error && error.body && error.body.message) ||
          "Error updating review status.";
        this.showToast("Error", msg, "error");
      });
  }

  get showSubmitButton() {
    return (
      !this.isPlanningExecuted &&
      this.lineItems.length > 0 &&
      this.lineItems.every((item) => item.isCovered && item.isReviewed)
    );
  }

  // ---------- Pagination Helpers ----------
  get pagedLineItems() {
    const start = (this.currentPage - 1) * this.pageSize;
    const end = start + this.pageSize;
    return this.filteredAndSortedLineItems.slice(start, end);
  }

  get showPagination() {
    return this.filteredAndSortedLineItems.length > this.pageSize;
  }

  handlePageChange(event) {
    this.currentPage = event.detail.currentPage;
    this.pageSize = event.detail.pageSize;
    this.scrollToHeader();
  }

  scrollToHeader() {
    const headerElement = this.template.querySelector(".app-wrapper");
    if (headerElement) {
      headerElement.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }

  get transferHeaderColspan() {
    return this.transferLocations ? this.transferLocations.length : 1;
  }

  get showTransferColumns() {
    return this.transferLocations && this.transferLocations.length > 0;
  }

  get totalColumns() {
    return 7 + (this.transferLocations ? this.transferLocations.length : 0);
  }

  get totals() {
    let reqTotal = 0;
    let reserveTotal = 0;
    let procureTotal = 0;
    let remainingTotal = 0;

    const transferTotalsMap = {};
    if (this.transferLocations) {
      this.transferLocations.forEach((loc) => {
        transferTotalsMap[loc.locationId] = 0;
      });
    }

    const itemsToSum = this.filteredAndSortedLineItems || [];

    itemsToSum.forEach((item) => {
      reqTotal += Number(item.requiredQty) || 0;
      reserveTotal += Number(item.reserveQty) || 0;
      procureTotal += Number(item.procureQty) || 0;
      remainingTotal += Number(item.remainingQty) || 0;
      if (item.transfers) {
        item.transfers.forEach((t) => {
          transferTotalsMap[t.locationId] += Number(t.qty) || 0;
        });
      }
    });

    const transferTotalsArray = (this.transferLocations || []).map((loc) => {
      return {
        locationId: loc.locationId,
        total: transferTotalsMap[loc.locationId] || 0
      };
    });

    const totalTransfers = transferTotalsArray.reduce(
      (sum, t) => sum + t.total,
      0
    );
    const totalPlanned = reserveTotal + totalTransfers + procureTotal;

    return {
      required: reqTotal,
      reserve: reserveTotal,
      procure: procureTotal,
      remaining: remainingTotal,
      transfers: transferTotalsArray,
      planned: totalPlanned
    };
  }

  recalculateTotals() {
    this.publishPlanUpdate();
  }

  publishPlanUpdate() {
    let totalRequired = 0;
    let reservedQty = 0;
    let transferQty = 0;
    let procurementQty = 0;
    let totalCovered = 0;

    if (this.lineItems) {
      this.lineItems.forEach((item) => {
        totalRequired += Number(item.requiredQty) || 0;
        reservedQty += Number(item.reserveQty) || 0;
        procurementQty += Number(item.procureQty) || 0;
        if (item.transfers) {
          item.transfers.forEach((t) => {
            transferQty += Number(t.qty) || 0;
          });
        }
      });
    }
    totalCovered = reservedQty + transferQty + procurementQty;

    const reservedPercent =
      totalRequired > 0 ? ((reservedQty / totalRequired) * 100).toFixed(2) : 0;
    const transferPercent =
      totalRequired > 0 ? ((transferQty / totalRequired) * 100).toFixed(2) : 0;
    const procurementPercent =
      totalRequired > 0
        ? ((procurementQty / totalRequired) * 100).toFixed(2)
        : 0;
    const totalCoveredPercent =
      totalRequired > 0 ? ((totalCovered / totalRequired) * 100).toFixed(2) : 0;

    let planDetails = [];
    let detailIndex = 1;

    const currentPlanStatus = this.planData && this.planData.status ? this.planData.status : "Draft";

    this.lineItems.forEach((item) => {
      const itemStatus = item.isReviewed ? "Reviewed" : currentPlanStatus;
      if ((Number(item.reserveQty) || 0) > 0) {
        planDetails.push({
          index: detailIndex++,
          sourceType: "Reservation",
          fromWarehouse: this.planData ? (this.planData.destinationLocationName || "Destination") : "Destination",
          productName: item.itemName,
          lineItemName: item.lineItemName,
          lineItemId: item.lineItemId,
          qty: Number(item.reserveQty),
          badgeClass: "badge-reservation",
          lineItemUrl: "/" + item.lineItemId,
          sourceNumber: "Not Generated",
          status: itemStatus,
          reason: `Reservation record not generated yet (Plan status: ${currentPlanStatus})`
        });
      }
      item.transfers.forEach((t) => {
        if ((Number(t.qty) || 0) > 0) {
          // 1. Transfer Supply Request
          planDetails.push({
            index: detailIndex++,
            sourceType: "Transfer SR",
            requestType: "Transfer SR",
            fromWarehouse: t.locationName,
            productName: item.itemName,
            lineItemName: item.lineItemName,
            lineItemId: item.lineItemId,
            qty: Number(t.qty),
            badgeClass: "badge-transfer",
            lineItemUrl: "/" + item.lineItemId,
            sourceNumber: "Not Generated",
            status: itemStatus,
            reason: `Transfer SR record not generated yet (Plan status: ${currentPlanStatus})`
          });
          // 2. Transfer Purchase Order
          planDetails.push({
            index: detailIndex++,
            sourceType: "Purchase Order",
            requestType: "Purchase Order",
            fromWarehouse: this.planData ? (this.planData.supplyingAccountName || "Dealer") : "Dealer",
            productName: item.itemName,
            lineItemName: item.lineItemName,
            lineItemId: item.lineItemId,
            qty: Number(t.qty),
            badgeClass: "badge-procurement",
            lineItemUrl: "/" + item.lineItemId,
            sourceNumber: "Not Generated",
            status: itemStatus,
            reason: `Transfer Purchase Order record not generated yet (Plan status: ${currentPlanStatus})`
          });
        }
      });
      if ((Number(item.procureQty) || 0) > 0) {
        // 1. Procurement Purchase Order
        planDetails.push({
          index: detailIndex++,
          sourceType: "Purchase Order",
          requestType: "Purchase Order",
          fromWarehouse: this.planData ? (this.planData.procurementAccountName || "Vendor") : "Vendor",
          productName: item.itemName,
          lineItemName: item.lineItemName,
          lineItemId: item.lineItemId,
          qty: Number(item.procureQty),
          badgeClass: "badge-procurement",
          lineItemUrl: "/" + item.lineItemId,
          sourceNumber: "Not Generated",
          status: itemStatus,
          reason: `Purchase Order record not generated yet (Plan status: ${currentPlanStatus})`
        });
        // 2. Procurement Supply Request
        planDetails.push({
          index: detailIndex++,
          sourceType: "Purchase SR",
          requestType: "Purchase SR",
          fromWarehouse: this.planData ? (this.planData.procurementAccountName || "Vendor") : "Vendor",
          productName: item.itemName,
          lineItemName: item.lineItemName,
          lineItemId: item.lineItemId,
          qty: Number(item.procureQty),
          badgeClass: "badge-supply-request",
          lineItemUrl: "/" + item.lineItemId,
          sourceNumber: "Not Generated",
          status: itemStatus,
          reason: `Purchase SR record not generated yet (Plan status: ${currentPlanStatus})`
        });
      }
    });

    const lineItemCoverages = {};
    this.lineItems.forEach((item) => {
      lineItemCoverages[item.lineItemId] = {
        coverage: item.coveragePercentage,
        status: item.isReviewed
          ? "Reviewed"
          : this.planData
            ? this.planData.status
            : "Draft"
      };
    });

    const allReviewed =
      this.lineItems.length > 0 &&
      this.lineItems.every((item) => item.isCovered && item.isReviewed);

    const payload = {
      summaryData: {
        isFound: true,
        status: this.planData ? this.planData.status : "",
        allReviewed,
        planNumber: this.planNumber,
        totalRequired,
        reservedQty,
        transferQty,
        procurementQty,
        totalCovered,
        reservedPercent,
        transferPercent,
        procurementPercent,
        totalCoveredPercent,
        planDetails,
        lineItemCoverages
      }
    };

    publish(this.messageContext, SUPPLY_PLAN_UPDATE_MC, payload);
  }

  get overallPercentage() {
    if (this.totals.required === 0) return 0;
    const pct = (this.totals.planned / this.totals.required) * 100;
    return this.totals.planned < this.totals.required
      ? Math.min(99, Math.round(pct))
      : Math.round(pct);
  }

  get overallProgressStyle() {
    return `width: ${Math.min(100, this.overallPercentage)}%;`;
  }

  get overallProgressClass() {
    const pct = this.overallPercentage;
    if (pct === 0) return "progress-bar-fill bg-pending";
    if (pct < 100) return "progress-bar-fill bg-partial";
    if (pct === 100) return "progress-bar-fill bg-covered";
    return "progress-bar-fill bg-over";
  }

  handleSaveDraft() {
    // Check for any input validation errors
    let hasErrors = false;
    this.lineItems.forEach((item) => {
      if (
        (Number(item.reserveQty) || 0) > (Number(item.destinationStock) || 0)
      ) {
        hasErrors = true;
      }
      item.transfers.forEach((t) => {
        if ((Number(t.qty) || 0) > (Number(t.availableStock) || 0)) {
          hasErrors = true;
        }
      });
    });

    if (hasErrors) {
      this.showToast(
        "Validation Error",
        "Cannot save draft. One or more entries exceed available stock.",
        "error"
      );
      return;
    }

    // Construct modal summary details
    const reservations = [];
    const transfers = [];
    const procurements = [];

    this.lineItems.forEach((item) => {
      if ((Number(item.reserveQty) || 0) > 0) {
        reservations.push({
          itemName: item.itemName,
          qty: Number(item.reserveQty)
        });
      }

      item.transfers.forEach((t) => {
        if ((Number(t.qty) || 0) > 0) {
          transfers.push({
            key: `${item.itemId}_${t.locationId}`,
            itemName: item.itemName,
            qty: Number(t.qty),
            fromLoc: t.locationName
          });
        }
      });

      if ((Number(item.procureQty) || 0) > 0) {
        procurements.push({
          itemName: item.itemName,
          qty: Number(item.procureQty)
        });
      }
    });

    if (
      reservations.length === 0 &&
      transfers.length === 0 &&
      procurements.length === 0
    ) {
      this.showToast(
        "No Allocation",
        "Please allocate quantities before saving a draft.",
        "warning"
      );
      return;
    }

    this.modalSummary = {
      reservations,
      transfers,
      procurements
    };

    this.modalHeader = "Sales Allocation Draft Saved!";
    this.modalSubtitle = `The following draft allocations have been prepared for ${this.planData.planName || ""}:`;
    this.successToastMessage = "Sales allocation draft saved successfully.";
    this.isModalOpen = true;
  }

  handleSubmitPlanning() {
    // Check for any input validation errors
    let hasErrors = false;
    this.lineItems.forEach((item) => {
      if (
        (Number(item.reserveQty) || 0) > (Number(item.destinationStock) || 0)
      ) {
        hasErrors = true;
      }
      item.transfers.forEach((t) => {
        if ((Number(t.qty) || 0) > (Number(t.availableStock) || 0)) {
          hasErrors = true;
        }
      });
    });

    if (hasErrors) {
      this.showToast(
        "Validation Error",
        "Cannot submit planning. One or more entries exceed available stock.",
        "error"
      );
      return;
    }

    this.isLoading = true;

    // Map line items to the format expected by the Apex controller
    const allocations = this.lineItems.map((item) => {
      return {
        lineItemId: item.lineItemId,
        reserveQty: Number(item.reserveQty) || 0,
        transfers: item.transfers.map((t) => {
          return {
            locationId: t.locationId,
            qty: Number(t.qty) || 0
          };
        }),
        procureQty: Number(item.procureQty) || 0
      };
    });

    // Submit planning allocations payload to Apex controller to create IR, IT, PR, PO, POLI, and POA records
    submitPlanning({ allocations: allocations })
      .then(() => {
        // Display toast notification confirming that IR, IT, PR, PO, POLI, and POA records were generated
        // this.showToast(
        //   "Plan Confirmed",
        //   "Sales allocation plan confirmed. Inventory Reservations, Transfers, Purchase Requisitions, Purchase Orders, Line Items, and Allocations created successfully.",
        //   "success"
        // );
        // Publish message to notify sibling components that plan submission is complete
        publish(this.messageContext, SUPPLY_PLAN_ACTION_MC, {
          actionType: "SUBMIT_COMPLETE",
          planNumber: this.planNumber
        });
        // Refresh plan data to reflect updated stock levels and status
        this.fetchPlanData();
      })
      .catch((error) => {
        this.isLoading = false;
        const msg =
          (error && error.body && error.body.message) ||
          "Error submitting planning.";

        // Publish SUBMIT_FAIL so the search component stops loading spinner
        publish(this.messageContext, SUPPLY_PLAN_ACTION_MC, {
          actionType: "SUBMIT_FAIL",
          planNumber: this.planNumber
        });

        if (msg.includes("INSUFFICIENT_STOCK:")) {
          const productName = msg.split("INSUFFICIENT_STOCK:")[1].trim();
          this.errorModalMessage = `For this product ${productName}, there is quantity not available`;
          this.errorCountdown = 10;
          this.isErrorModalOpen = true;

          if (this.countdownInterval) {
            clearInterval(this.countdownInterval);
          }
          // eslint-disable-next-line @lwc/lwc/no-async-operation
          this.countdownInterval = setInterval(() => {
            this.errorCountdown--;
            if (this.errorCountdown <= 0) {
              this.handleRefreshPlanData();
            }
          }, 1000);
        } else {
          this.showToast("Submission Failed", msg, "error");
        }
      });
  }

  handleRefreshPlanData() {
    if (this.countdownInterval) {
      clearInterval(this.countdownInterval);
      this.countdownInterval = null;
    }
    this.isErrorModalOpen = false;
    this.fetchPlanData();
  }

  handleRefreshPlan() {
    this.fetchPlanData()
      .then(() => {
        this.showToast(
          "Success",
          "Plan and inventory data refreshed successfully.",
          "success"
        );
      })
      .catch((error) => {
        console.error("Error refreshing plan data:", error);
      });
  }

  handleStockQtyClick(event) {
    event.stopPropagation();
    const itemId = event.currentTarget.dataset.itemId;
    const locationId = event.currentTarget.dataset.locationId;
    const accountId = event.currentTarget.dataset.accountId;

    this.selectedInventoryItemId = itemId || null;
    this.selectedInventoryLocationId = locationId || null;
    this.selectedInventoryAccountId = accountId || null;
    this.isInventoryModalOpen = true;
  }

  closeInventoryModal() {
    this.isInventoryModalOpen = false;
    this.selectedInventoryItemId = null;
    this.selectedInventoryLocationId = null;
    this.selectedInventoryAccountId = null;
  }

  closeModal() {
    this.isModalOpen = false;
    this.showToast("Completed", this.successToastMessage, "success");
  }

  showToast(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant
      })
    );
  }
}