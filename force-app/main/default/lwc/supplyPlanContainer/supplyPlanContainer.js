import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';

export default class SupplyPlanContainer extends LightningElement {
    _recordId;
    @api 
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.activePlanId = value;
        }
    }

    @track activePlanId;

    @wire(CurrentPageReference)
    getStateParameters(currentPageReference) {
        if (currentPageReference && currentPageReference.state) {
            const planParam = currentPageReference.state.c__recordId || 
                              currentPageReference.state.c__planNumber ||
                              currentPageReference.state.recordId || 
                              currentPageReference.state.c__id;
            if (planParam) {
                this.activePlanId = planParam;
            }
        }
    }

    connectedCallback() {
    }

    get hasActivePlan() {
        return !!this.activePlanId;
    }

    handlePlanSelected(event) {
        this.activePlanId = event.detail;
    }
}