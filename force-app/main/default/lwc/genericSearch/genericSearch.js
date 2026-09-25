import { LightningElement, api } from "lwc";

export default class GenericSearch extends LightningElement {
  @api label = "Search";
  @api placeholder = "Search...";
  @api value = "";
  @api debounceDelay = 300;

  delayTimeout;

  handleChange(event) {
    const searchVal = event.target.value;
    this.value = searchVal;

    window.clearTimeout(this.delayTimeout);
    this.delayTimeout = setTimeout(() => {
      this.dispatchEvent(
        new CustomEvent("search", {
          detail: { value: this.value }
        })
      );
    }, this.debounceDelay);
  }

  handleFocus() {
    this.dispatchEvent(new CustomEvent("focus"));
  }

  handleBlur() {
    this.dispatchEvent(new CustomEvent("blur"));
  }
}