import { LightningElement, api, wire, track } from "lwc";
import { publish, MessageContext } from "lightning/messageService";
import paginationMessageChannel from "@salesforce/messageChannel/paginationMessage__c";

export default class GenericPagination extends LightningElement {
  @api enableLms = false;
  @api showPageSizeSelector = false;
  @api hideGoToPage = false;
  @api hideGoTo = false;

  @track _currentPage = 1;
  @track _pageSize = 10;
  @track _totalRecords = 0;
  @track isGoToPopupOpen = false;
  @track goToInputValue = "";
  @track _pageSizes = [
    { label: "5", value: 5 },
    { label: "10", value: 10 },
    { label: "20", value: 20 },
    { label: "50", value: 50 }
  ];

  @wire(MessageContext)
  messageContext;

  @api
  get currentPage() {
    return this._currentPage;
  }
  set currentPage(value) {
    const parsed = parseInt(value, 10);
    this._currentPage = isNaN(parsed) ? 1 : parsed;
  }

  @api
  get pageSize() {
    return this._pageSize;
  }
  set pageSize(value) {
    const parsed = parseInt(value, 10);
    this._pageSize = isNaN(parsed) ? 10 : parsed;
  }

  @api
  get totalRecords() {
    return this._totalRecords;
  }
  set totalRecords(value) {
    const parsed = parseInt(value, 10);
    this._totalRecords = isNaN(parsed) ? 0 : parsed;
    // Adjust current page if it is out of bounds
    const maxPage = this.totalPages;
    if (this._currentPage > maxPage) {
      this._currentPage = maxPage;
    }
  }

  @api
  get pageSizes() {
    return this._pageSizes.map((opt) => ({
      ...opt,
      isSelected: Number(opt.value) === Number(this._pageSize)
    }));
  }
  set pageSizes(value) {
    if (Array.isArray(value)) {
      this._pageSizes = value;
    }
  }

  get totalPages() {
    return Math.ceil(this._totalRecords / this._pageSize) || 1;
  }

  get showGoTo() {
    return !this.hideGoToPage && !this.hideGoTo;
  }

  get isFirstPage() {
    return this._currentPage <= 1;
  }

  get isLastPage() {
    return this._currentPage >= this.totalPages;
  }

  get showingStart() {
    if (this._totalRecords === 0) return 0;
    return (this._currentPage - 1) * this._pageSize + 1;
  }

  get showingEnd() {
    return Math.min(this._currentPage * this._pageSize, this._totalRecords);
  }

  get pagesList() {
    const total = this.totalPages;
    const current = this._currentPage;
    const pages = [];

    if (total <= 5) {
      for (let i = 1; i <= total; i++) {
        pages.push({
          value: i,
          label: `${i}`,
          isPage: true,
          isActive: i === current,
          className: i === current ? "page-btn active" : "page-btn"
        });
      }
    } else {
      // Always show page 1
      pages.push({
        value: 1,
        label: "1",
        isPage: true,
        isActive: current === 1,
        className: current === 1 ? "page-btn active" : "page-btn"
      });

      let start = Math.max(2, current - 1);
      let end = Math.min(total - 1, current + 1);

      if (current <= 3) {
        end = 4;
      } else if (current >= total - 2) {
        start = total - 3;
      }

      if (start > 2) {
        pages.push({
          value: "prev_dots",
          label: "...",
          isPage: false,
          isActive: false,
          className: "page-dots"
        });
      }

      for (let i = start; i <= end; i++) {
        pages.push({
          value: i,
          label: `${i}`,
          isPage: true,
          isActive: i === current,
          className: i === current ? "page-btn active" : "page-btn"
        });
      }

      if (end < total - 1) {
        pages.push({
          value: "next_dots",
          label: "...",
          isPage: false,
          isActive: false,
          className: "page-dots"
        });
      }

      // Always show last page
      pages.push({
        value: total,
        label: `${total}`,
        isPage: true,
        isActive: current === total,
        className: current === total ? "page-btn active" : "page-btn"
      });
    }
    return pages;
  }

  handleFirstPage() {
    if (this._currentPage !== 1) {
      this._currentPage = 1;
      this.dispatchChange();
    }
  }

  handlePrev() {
    if (this._currentPage > 1) {
      this._currentPage -= 1;
      this.dispatchChange();
    }
  }

  handleNext() {
    if (this._currentPage < this.totalPages) {
      this._currentPage += 1;
      this.dispatchChange();
    }
  }

  handleLastPage() {
    const last = this.totalPages;
    if (this._currentPage !== last) {
      this._currentPage = last;
      this.dispatchChange();
    }
  }

  handlePageClick(event) {
    const page = parseInt(event.target.dataset.page, 10);
    if (!isNaN(page) && page !== this._currentPage) {
      this._currentPage = page;
      this.dispatchChange();
    }
  }

  handlePageSizeChange(event) {
    const val =
      event.detail && event.detail.value !== undefined
        ? event.detail.value
        : event.target.value;
    this._pageSize = parseInt(val, 10);
    this._currentPage = 1;
    this.dispatchChange();
  }

  toggleGoToPopup() {
    this.isGoToPopupOpen = !this.isGoToPopupOpen;
  }

  closeGoToPopup() {
    this.isGoToPopupOpen = false;
  }

  get pageListOptions() {
    const options = [];
    const total = this.totalPages;
    const current = this._currentPage;
    for (let i = 1; i <= total; i++) {
      options.push({
        value: i,
        label: `${i}`,
        className: i === current ? "page-list-item active" : "page-list-item"
      });
    }
    return options;
  }

  handleGoToPageClick(event) {
    const page = parseInt(event.currentTarget.dataset.page, 10);
    if (!isNaN(page) && page !== this._currentPage) {
      this._currentPage = page;
      this.dispatchChange();
    }
    this.closeGoToPopup();
  }

  dispatchChange() {
    const detail = {
      currentPage: this._currentPage,
      pageSize: this._pageSize
    };
    this.dispatchEvent(new CustomEvent("pagechange", { detail }));

    if (this.enableLms) {
      const payload = {
        currentPage: this._currentPage,
        pageSize: this._pageSize,
        totalRecords: this._totalRecords,
        sourceComponent: "genericPagination"
      };
      publish(this.messageContext, paginationMessageChannel, payload);
    }
  }
}