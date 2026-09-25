import { LightningElement, wire, track, api } from "lwc";
import { refreshApex } from "@salesforce/apex";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getApprovedTransfers from "@salesforce/apex/InventroyAcceptingPannel.getApprovedTransfers";
import acceptQuantity from "@salesforce/apex/InventroyAcceptingPannel.acceptQuantity";
import acceptQuantities from "@salesforce/apex/InventroyAcceptingPannel.acceptQuantities";
import validateAcceptStatus from "@salesforce/apex/InventroyAcceptingPannel.validateAcceptStatus";
import validateAcceptStatuses from "@salesforce/apex/InventroyAcceptingPannel.validateAcceptStatuses";
// import getMaterialIssueNamesByMoli from "@salesforce/apex/InventroyAcceptingPannel.getMaterialIssueNamesByMoli";

export default class InventoryTransferAccpectingPannel extends LightningElement {
  _searchTerm = "";
  _selectedLocationId = "All";
  _sortByOption = "name-asc";

  @api
  get searchTerm() {
    return this._searchTerm;
  }
  set searchTerm(value) {
    this._searchTerm = value;
    this.currentPage = 1;
  }

  @api
  get selectedLocationId() {
    return this._selectedLocationId;
  }
  set selectedLocationId(value) {
    this._selectedLocationId = value;
    this.currentPage = 1;
  }

  _selectedRequestType = "All";

  @api
  get selectedRequestType() {
    return this._selectedRequestType;
  }
  set selectedRequestType(value) {
    this._selectedRequestType = value || "All";
    this.currentPage = 1;
  }

  @api
  get sortByOption() {
    return this._sortByOption;
  }
  set sortByOption(value) {
    this._sortByOption = value;
    this.currentPage = 1;
  }

  @track rawTransfers = [];
  @track currentPage = 1;
  pageSize = 4;
  resizeObserver;

  isLoading = false;
  error;

  // Selection Tracking
  @track selectedIds = [];
  isBulkAction = false;

  // Modal state tracking
  @track isModalOpen = false;
  selectedTransferId;
  selectedTransferName = "";
  selectedTransferItem = "";
  selectedTransferQty = 0;
  selectedTransferSource = "";
  selectedTransferDest = "";
  selectedTransferIsManufacturing = false;
  selectedTransferMoliName = "";
  selectedTransferMaterialIssueName = "";

  wiredTransfersResult;

  // Stale data modal state
  @track isStaleModalOpen = false;
  @track staleModalMessage = "";
  @track staleCountdown = 10;
  staleCountdownInterval = null;

  @wire(getApprovedTransfers)
  async wiredApprovedTransfers(result) {
    this.wiredTransfersResult = result;
    const { data, error } = result;
    if (data) {
      console.log("[InventoryTransferAcceptingPanel] Successfully loaded approved transfers:", data.length, "records");
      const transfers = data.map((record) => {
        return {
          Id: record.Id,
          TransferName: record.Name,
          ItemName: record.Item__r ? record.Item__r.Name : "",
          SourceLocationId: record.Source_Inventory_Location__c,
          SourceLocationName: record.Source_Inventory_Location__r
            ? record.Source_Inventory_Location__r.Name
            : "",
          DestinationLocationId: record.Destination_Inventory_Location__c,
          DestinationLocationName: record.Destination_Inventory_Location__r
            ? record.Destination_Inventory_Location__r.Name
            : "",
          TransferQty: record.Transfer_Qty__c,
          RequestedDate: record.Requested_Date__c,
          FormattedRequestedDate: this.formatDate(record.Requested_Date__c),
          RequestType: record.Request_Type__c || "",
          isManufacturing: record.Request_Type__c === "Manufacturing",
          MoliId: null,
          MoliName: "",
          MaterialIssueName: "",
          OrderAllocationName:
            record.Order_Allocation_Line_Item__r &&
            record.Order_Allocation_Line_Item__r.Order_Allocation__r
              ? record.Order_Allocation_Line_Item__r.Order_Allocation__r.Name
              : "",
          ItemCode: record.Item__r ? record.Item__r.Item_Code__c : "",
          OrderAllocationLineItemName: record.Order_Allocation_Line_Item__r
            ? record.Order_Allocation_Line_Item__r.Name
            : "",
          RecordUrl: `/lightning/r/Inventory_Transfer__c/${record.Id}/view`
        };
      });

      this.rawTransfers = transfers;
      this.error = undefined;
    } else if (error) {
      const errorMsg = error?.body?.message || error?.message || error;
      console.error(
        "[InventoryTransferAcceptingPanel] Error loading approved transfers:",
        errorMsg,
        JSON.stringify(error)
      );
      this.error = error;
      this.rawTransfers = [];
    }
  }

  formatDate(dateStr) {
    if (!dateStr) return "";
    const date = new Date(dateStr);
    return date.toLocaleDateString("en-US", {
      year: "numeric",
      month: "short",
      day: "2-digit"
    });
  }

  get hasTransfers() {
    return this.allFilteredTransfers.length > 0;
  }

  get allFilteredTransfers() {
    if (!this.rawTransfers) {
      return [];
    }

    let data = this.rawTransfers;

    // 1. Filter by Location (Destination only for incoming)
    if (this._selectedLocationId && this._selectedLocationId !== "All") {
      data = data.filter(
        (item) => item.DestinationLocationId === this._selectedLocationId
      );
    }

    // 1b. Filter by Request Type
    if (this._selectedRequestType && this._selectedRequestType !== "All") {
      data = data.filter(
        (item) => item.RequestType === this._selectedRequestType
      );
    }

    // 2. Filter by Search Term (Case-Insensitive)
    if (this._searchTerm) {
      const key = this._searchTerm.toLowerCase().trim();
      data = data.filter(
        (item) =>
          (item.TransferName &&
            item.TransferName.toLowerCase().includes(key)) ||
          (item.ItemName && item.ItemName.toLowerCase().includes(key)) ||
          (item.DestinationLocationName &&
            item.DestinationLocationName.toLowerCase().includes(key)) ||
          (item.OrderAllocationName &&
            item.OrderAllocationName.toLowerCase().includes(key)) ||
          (item.ItemCode && item.ItemCode.toLowerCase().includes(key)) ||
          (item.OrderAllocationLineItemName &&
            item.OrderAllocationLineItemName.toLowerCase().includes(key))
      );
    }

    // 3. Sort data globally
    const sortOption = this._sortByOption || "name-asc";
    data = [...data].sort((a, b) => {
      let valA, valB;
      let type = "string";

      if (sortOption.startsWith("name")) {
        valA = a.ItemName ? a.ItemName.toLowerCase() : "";
        valB = b.ItemName ? b.ItemName.toLowerCase() : "";
      } else if (sortOption.startsWith("qty")) {
        valA = a.TransferQty != null ? a.TransferQty : 0;
        valB = b.TransferQty != null ? b.TransferQty : 0;
        type = "number";
      } else {
        valA = a.RequestedDate ? new Date(a.RequestedDate).getTime() : 0;
        valB = b.RequestedDate ? new Date(b.RequestedDate).getTime() : 0;
        type = "number";
      }

      if (type === "number") {
        return sortOption.endsWith("asc") ? valA - valB : valB - valA;
      }
      if (valA < valB) return sortOption.endsWith("asc") ? -1 : 1;
      if (valA > valB) return sortOption.endsWith("asc") ? 1 : -1;
      return 0;
    });

    return data;
  }

  get filteredAndSortedTransfers() {
    const data = this.allFilteredTransfers;
    const totalP = Math.ceil(data.length / this.pageSize) || 1;
    if (this.currentPage > totalP) {
      this.currentPage = totalP;
    }
    if (this.currentPage < 1) {
      this.currentPage = 1;
    }
    const start = (this.currentPage - 1) * this.pageSize;
    const end = start + this.pageSize;
    return data.slice(start, end).map((item) => {
      const isSel = this.selectedIds.includes(item.Id);
      return {
        ...item,
        isSelected: isSel,
        rowClass: isSel ? "table-row row-selected" : "table-row"
      };
    });
  }

  get totalPages() {
    return Math.ceil(this.allFilteredTransfers.length / this.pageSize) || 1;
  }

  get isPaginationRequired() {
    return this.allFilteredTransfers.length > this.pageSize;
  }

  handlePageChange(event) {
    if (event && event.detail) {
      if (typeof event.detail === "number") {
        this.currentPage = event.detail;
      } else {
        if (event.detail.currentPage !== undefined) {
          this.currentPage = event.detail.currentPage;
        } else if (event.detail.page !== undefined) {
          this.currentPage = event.detail.page;
        } else if (event.detail.pageNumber !== undefined) {
          this.currentPage = event.detail.pageNumber;
        }

        if (event.detail.pageSize !== undefined) {
          this.pageSize = event.detail.pageSize;
        }
      }
    }
  }

  // Selection Handling
  get selectedCount() {
    return this.selectedIds.length;
  }

  get isBulkActionEnabled() {
    return this.selectedIds.length > 1 && this.allFilteredTransfers.length > 1;
  }

  get isAllSelected() {
    const visibleItems = this.filteredAndSortedTransfers;
    if (visibleItems.length === 0) return false;
    return visibleItems.every((item) => this.selectedIds.includes(item.Id));
  }

  get bulkSelectedTransfers() {
    return this.rawTransfers.filter((item) =>
      this.selectedIds.includes(item.Id)
    );
  }

  get modalTitle() {
    return this.isBulkAction ? "Confirm Bulk Acceptance" : "Confirm Acceptance";
  }

  get modalActionLabel() {
    return this.isBulkAction ? "Accept Selected Quantities" : "Accept Quantity";
  }

  handleSelectRow(event) {
    const recordId = event.target.dataset.id;
    const isChecked = event.target.checked;
    if (isChecked) {
      if (!this.selectedIds.includes(recordId)) {
        this.selectedIds = [...this.selectedIds, recordId];
      }
    } else {
      this.selectedIds = this.selectedIds.filter((id) => id !== recordId);
    }
  }

  handleSelectAll(event) {
    const isChecked = event.target.checked;
    const visibleItems = this.filteredAndSortedTransfers;
    let newSelectedIds = [...this.selectedIds];

    if (isChecked) {
      visibleItems.forEach((item) => {
        if (!newSelectedIds.includes(item.Id)) {
          newSelectedIds.push(item.Id);
        }
      });
    } else {
      const visibleIds = visibleItems.map((item) => item.Id);
      newSelectedIds = newSelectedIds.filter((id) => !visibleIds.includes(id));
    }
    this.selectedIds = newSelectedIds;
  }

  // Custom Confirmation Modal Handling
  openConfirmModal(event) {
    const transferId = event.currentTarget.dataset.id;
    const record = this.rawTransfers.find((item) => item.Id === transferId);
    if (record) {
      this.selectedTransferId = transferId;
      this.selectedTransferName = record.TransferName;
      this.selectedTransferItem = record.ItemName;
      this.selectedTransferQty = record.TransferQty;
      this.selectedTransferSource = record.SourceLocationName;
      this.selectedTransferDest = record.DestinationLocationName;
      this.selectedTransferIsManufacturing = record.isManufacturing;
      this.selectedTransferMoliName = record.MoliName;
      this.selectedTransferMaterialIssueName = record.MaterialIssueName;
      this.isBulkAction = false;
      this.isModalOpen = true;
      console.log("[InventoryTransferAcceptingPanel] Opening confirm modal for single transfer:", transferId);
    }
  }

  openBulkConfirmModal() {
    if (this.isBulkActionEnabled) {
      this.isBulkAction = true;
      this.isModalOpen = true;
      console.log("[InventoryTransferAcceptingPanel] Opening confirm modal for bulk transfers:", this.selectedIds);
    }
  }

  closeConfirmModal() {
    this.isModalOpen = false;
    this.selectedTransferId = undefined;
  }

  async confirmAction() {
    this.isLoading = true;
    const isBulk = this.isBulkAction;
    const tId = this.selectedTransferId;
    const tIds = this.selectedIds;
    this.closeConfirmModal();

    console.log("[InventoryTransferAcceptingPanel] Executing confirmAction. Is Bulk:", isBulk, "Single ID:", tId, "Bulk IDs:", tIds);

    try {
      // Pre-validate: check if records are still in the expected status
      if (isBulk) {
        const validation = await validateAcceptStatuses({ transferIds: tIds });
        if (!validation.valid) {
          console.warn("[InventoryTransferAcceptingPanel] Bulk validation failed:", validation.message);
          this.isLoading = false;
          this.showStaleModal(validation.message);
          return;
        }
      } else {
        const validation = await validateAcceptStatus({ transferId: tId });
        if (!validation.valid) {
          console.warn("[InventoryTransferAcceptingPanel] Single validation failed:", validation.message);
          this.isLoading = false;
          this.showStaleModal(validation.message);
          return;
        }
      }

      if (isBulk) {
        console.log("[InventoryTransferAcceptingPanel] Calling acceptQuantitiesApex with IDs:", tIds);
        await acceptQuantities({ transferIds: tIds });
        console.log("[InventoryTransferAcceptingPanel] acceptQuantities complete");
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Success",
            message: `Successfully accepted ${tIds.length} inventory transfers in bulk.`,
            variant: "success"
          })
        );
        this.selectedIds = [];
      } else {
        console.log("[InventoryTransferAcceptingPanel] Calling acceptQuantityApex with ID:", tId);
        await acceptQuantity({ transferId: tId });
        console.log("[InventoryTransferAcceptingPanel] acceptQuantity complete");
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Success",
            message: "Inventory transfer accepted successfully.",
            variant: "success"
          })
        );
        this.selectedIds = this.selectedIds.filter((id) => id !== tId);
      }
      this.dispatchEvent(new CustomEvent("accepted"));
      console.log("[InventoryTransferAcceptingPanel] Refreshing apex data after acceptance...");
      await refreshApex(this.wiredTransfersResult);
      console.log("[InventoryTransferAcceptingPanel] Apex data refreshed successfully");
      this.error = undefined;
    } catch (error) {
      const msg = error.body ? error.body.message : error.message;
      console.error("[InventoryTransferAcceptingPanel] Error during acceptance:", msg, error);
      if (msg && msg.includes("ALREADY_ACTIONED:")) {
        const staleMsg = msg.split("ALREADY_ACTIONED:")[1].trim();
        this.showStaleModal(staleMsg);
      } else {
        this.error = error;
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Error",
            message: msg,
            variant: "error"
          })
        );
      }
    } finally {
      this.isLoading = false;
    }
  }

  showStaleModal(message) {
    this.staleModalMessage = message;
    this.staleCountdown = 10;
    this.isStaleModalOpen = true;
    this.clearStaleCountdown();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.staleCountdownInterval = setInterval(() => {
      this.staleCountdown = this.staleCountdown - 1;
      if (this.staleCountdown <= 0) {
        this.closeStaleModal();
      }
    }, 1000);
  }

  clearStaleCountdown() {
    if (this.staleCountdownInterval) {
      clearInterval(this.staleCountdownInterval);
      this.staleCountdownInterval = null;
    }
  }

  async closeStaleModal() {
    this.clearStaleCountdown();
    this.isStaleModalOpen = false;
    this.staleModalMessage = "";
    this.isLoading = true;
    try {
      console.log("[InventoryTransferAcceptingPanel] Refreshing data from stale modal close...");
      await refreshApex(this.wiredTransfersResult);
      this.error = undefined;
    } catch (err) {
      console.error("[InventoryTransferAcceptingPanel] Error refreshing from stale modal close:", err);
      this.error = err;
    } finally {
      this.isLoading = false;
    }
    this.dispatchEvent(new CustomEvent("refreshed"));
  }

  get staleProgressWidth() {
    return `width: ${(this.staleCountdown / 10) * 100}%;`;
  }

  async handleRefresh() {
    this.isLoading = true;
    try {
      console.log("[InventoryTransferAcceptingPanel] Manual handleRefresh called");
      await refreshApex(this.wiredTransfersResult);
      this.error = undefined;
    } catch (error) {
      console.error("[InventoryTransferAcceptingPanel] Error in handleRefresh:", error);
      this.error = error;
    } finally {
      this.isLoading = false;
    }
    this.dispatchEvent(new CustomEvent("refreshed"));
  }

  @api
  async refreshData() {
    this.isLoading = true;
    try {
      console.log("[InventoryTransferAcceptingPanel] Public refreshData API called");
      await refreshApex(this.wiredTransfersResult);
      this.error = undefined;
    } catch (error) {
      console.error("[InventoryTransferAcceptingPanel] Error in refreshData:", error);
      this.error = error;
    } finally {
      this.isLoading = false;
    }
  }

  renderedCallback() {
    if (!this.resizeObserver) {
      const container = this.template.querySelector(".custom-card-body");
      if (container) {
        this.resizeObserver = new ResizeObserver((entries) => {
          for (let entry of entries) {
            this.calculatePageSize(entry.contentRect.height);
          }
        });
        this.resizeObserver.observe(container);
      }
    }
  }

  disconnectedCallback() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
    this.clearStaleCountdown();
  }

  calculatePageSize(cardBodyHeight) {
    if (window.innerWidth < 768) {
      this.pageSize = 4;
      return;
    }

    if (cardBodyHeight === undefined) {
      const cardBody = this.template.querySelector(".custom-card-body");
      cardBodyHeight = cardBody ? cardBody.clientHeight : 0;
    }

    if (cardBodyHeight > 0) {
      const overheadHeight = 130;
      const rowHeight = 56;
      const availableHeight = cardBodyHeight - overheadHeight;
      const calculatedSize = Math.floor(availableHeight / rowHeight);

      const newPageSize = Math.max(1, calculatedSize);
      if (this.pageSize !== newPageSize) {
        this.pageSize = newPageSize;
        if (this.currentPage > this.totalPages) {
          this.currentPage = Math.max(1, this.totalPages);
        }
      }
    }
  }
}