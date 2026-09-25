import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import inspectSharing from '@salesforce/apex/RecordSharingInspectorController.inspectSharing';

/**
 * @description Enterprise-grade Generic Record Sharing Inspector LWC.
 *              Allows inspecting Apex Managed Sharing for any custom object
 *              by entering a Record Id or Record Name/AutoNumber.
 * @author DeepMind Antigravity
 * @date 2026-08-04
 */
export default class RecordSharingInspector extends LightningElement {

    searchInput = '';
    @track result = null;
    isLoading = false;
    lastSearchInput = '';

    // =========================================================================
    // GETTERS: Conditional rendering & computed properties
    // =========================================================================

    get hasResult() {
        return this.result !== null && this.result !== undefined;
    }

    get hasShareRecords() {
        return this.result && this.result.shareRecords && this.result.shareRecords.length > 0;
    }

    get hasGroups() {
        return this.result && this.result.groupsWithMembers && this.result.groupsWithMembers.length > 0;
    }

    get hasEffectiveUsers() {
        return this.result && this.result.effectiveUserNames && this.result.effectiveUserNames.length > 0;
    }

    get hasMappings() {
        return this.result && this.result.accountMappings && this.result.accountMappings.length > 0;
    }

    get isRefreshDisabled() {
        return !this.lastSearchInput;
    }

    get displayAccountName() {
        if (!this.result || !this.result.recordDetail) return '—';
        const detail = this.result.recordDetail;
        if (detail.accountName) return detail.accountName;
        if (detail.accountId) return detail.accountId;
        return 'None (null)';
    }

    // =========================================================================
    // EVENT HANDLERS
    // =========================================================================

    handleSearchInputChange(event) {
        this.searchInput = event.target.value;
    }

    handleKeyUp(event) {
        if (event.keyCode === 13) {
            this.handleInspect();
        }
    }

    handleRefresh() {
        if (this.lastSearchInput) {
            this.searchInput = this.lastSearchInput;
            this.handleInspect();
        }
    }

    handleInspect() {
        const input = this.searchInput ? this.searchInput.trim() : '';
        if (!input) {
            this.showToast('Error', 'Please enter a Record Id or Record Name.', 'error');
            return;
        }

        this.isLoading = true;
        this.result = null;
        this.lastSearchInput = input;

        inspectSharing({ searchInput: input })
            .then(data => {
                this.result = this.enrichResult(data);
                this.showToast('Success', 'Sharing inspection complete.', 'success');
            })
            .catch(error => {
                const msg = this.extractErrorMessage(error);
                this.showToast('Error', msg, 'error');
                this.result = null;
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    // =========================================================================
    // COPY ACTIONS
    // =========================================================================

    handleCopyJson() {
        if (!this.result) return;
        const json = JSON.stringify(this.result, null, 2);
        this.copyToClipboard(json, 'Full inspection JSON copied to clipboard.');
    }

    handleCopySoql() {
        if (!this.result || !this.result.shareSoql) return;
        this.copyToClipboard(this.result.shareSoql, 'Share SOQL query copied to clipboard.');
    }

    copyToClipboard(text, successMsg) {
        const el = document.createElement('textarea');
        el.value = text;
        el.setAttribute('readonly', '');
        el.style.position = 'absolute';
        el.style.left = '-9999px';
        document.body.appendChild(el);
        el.select();
        document.execCommand('copy');
        document.body.removeChild(el);
        this.showToast('Copied', successMsg, 'success');
    }

    // =========================================================================
    // DATA ENRICHMENT: Add computed CSS classes and icons to result
    // =========================================================================

    enrichResult(data) {
        if (!data) return data;

        // Enrich share records with CSS classes
        if (data.shareRecords) {
            data.shareRecords = data.shareRecords.map(share => ({
                ...share,
                typeClass: share.userOrGroupType === 'Public Group'
                    ? 'slds-badge badge-group' : 'slds-badge badge-user',
                accessClass: share.accessLevel === 'Edit'
                    ? 'slds-badge badge-edit' : 'slds-badge badge-read',
                causeClass: share.rowCause === 'Manual'
                    ? 'slds-badge badge-manual' : 'slds-badge badge-owner'
            }));
        }

        // Enrich groups with accordion labels, member icons, and hasMembers flag
        if (data.groupsWithMembers) {
            data.groupsWithMembers = data.groupsWithMembers.map(grp => ({
                ...grp,
                accordionLabel: grp.groupName + ' (' + (grp.members ? grp.members.length : 0) + ' members)',
                hasMembers: grp.members && grp.members.length > 0,
                members: (grp.members || []).map(m => ({
                    ...m,
                    iconName: m.memberType === 'User' ? 'standard:user' : 'standard:groups'
                }))
            }));
        }

        // Enrich diagnostics with icons and CSS classes
        if (data.diagnostics) {
            data.diagnostics = data.diagnostics.map(diag => ({
                ...diag,
                iconName: diag.status === 'pass'
                    ? 'utility:check' : diag.status === 'warn'
                    ? 'utility:warning' : 'utility:close',
                iconVariant: diag.status === 'pass'
                    ? 'success' : diag.status === 'warn'
                    ? 'warning' : 'error',
                containerClass: 'diag-item diag-' + diag.status
            }));
        }

        return data;
    }

    // =========================================================================
    // UTILITIES
    // =========================================================================

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractErrorMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'An unexpected error occurred.';
    }
}