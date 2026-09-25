import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTrace from '@salesforce/apex/DMSFulfillmentTraceController.getTrace';
import getTraceBySearch from '@salesforce/apex/DMSFulfillmentTraceController.getTraceBySearch';

export default class DmsFulfillmentTrace extends NavigationMixin(LightningElement) {
    @api recordId;

    @track isLoading = false;
    @track traceData = null;
    @track selectedNode = null;
    @track searchInput = '';
    @track collapsedNodeIds = new Set();
    @track errorMessage = null;

    connectedCallback() {
        if (this.recordId) {
            this.loadTrace(this.recordId);
        }
    }

    /**
     * Re-fetch trace if recordId changes dynamically on record page
     */
    @api
    setRecordId(val) {
        this.recordId = val;
        if (this.recordId) {
            this.loadTrace(this.recordId);
        }
    }

    get hasData() {
        return !!(this.traceData && this.traceData.rootNode);
    }

    get summary() {
        return this.traceData ? this.traceData.summary : null;
    }

    get reconciliations() {
        return this.traceData && this.traceData.reconciliations ? this.traceData.reconciliations : [];
    }

    get hasReconciliations() {
        return this.reconciliations.length > 0;
    }

    get reconciliationBannerClass() {
        if (!this.summary) return 'reconciliation-banner';
        return this.summary.hasMismatch 
            ? 'reconciliation-banner reconciliation-banner-mismatch' 
            : 'reconciliation-banner reconciliation-banner-balanced';
    }

    get reconciliationIcon() {
        return this.summary && this.summary.hasMismatch ? 'utility:warning' : 'utility:success';
    }

    get reconciliationTitle() {
        if (!this.summary) return '';
        return this.summary.hasMismatch 
            ? 'Quantity Warning Detected' 
            : 'Fulfillment Quantities Reconciled';
    }

    get reconciliationDescription() {
        if (!this.summary) return '';
        return this.summary.hasMismatch 
            ? this.summary.mismatchMessage 
            : 'All planned and received fulfillment quantities reconcile with requirement.';
    }

    /**
     * Flattens the hierarchical tree into a rendered list respecting expand/collapse state.
     */
    get flattenedNodes() {
        if (!this.traceData || !this.traceData.rootNode) {
            return [];
        }

        const flatList = [];
        this.flattenNode(this.traceData.rootNode, 1, flatList);
        return flatList;
    }

    flattenNode(node, level, list) {
        const hasChildren = node.children && node.children.length > 0;
        const isExpanded = !this.collapsedNodeIds.has(node.id);
        const isSelected = this.selectedNode && this.selectedNode.id === node.id;

        const flatItem = {
            id: node.id,
            name: node.name,
            nodeType: node.nodeType,
            status: node.status,
            requestType: node.requestType,
            supplyMethod: node.supplyMethod,
            itemName: node.itemName,
            itemCode: node.itemCode,
            requestedQty: node.requestedQty,
            reservedQty: node.reservedQty,
            reservedPlannedQty: node.reservedPlannedQty,
            transferPlannedQty: node.transferPlannedQty,
            transferReceivedQty: node.transferReceivedQty,
            procurementPlannedQty: node.procurementPlannedQty,
            procurementReceivedQty: node.procurementReceivedQty,
            receivedQty: node.receivedQty,
            remainingQty: node.remainingQty,
            physicalMovement: node.physicalMovement,
            relationshipReason: node.relationshipReason,
            requestingAccount: node.requestingAccount,
            supplyingAccount: node.supplyingAccount,
            sourceLocation: node.sourceLocation,
            targetLocation: node.targetLocation,
            isCurrentRecord: node.isCurrentRecord,
            isRoot: node.isRoot,
            level: level,
            levelClass: `tree-level-${Math.min(level, 4)}`,
            cardClass: this.computeCardClass(node, isSelected),
            badgeClass: this.computeBadgeClass(node.nodeType),
            hasChildren: hasChildren,
            isExpanded: isExpanded,
            expandIcon: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
            rawNode: node
        };

        list.push(flatItem);

        if (hasChildren && isExpanded) {
            node.children.forEach(child => {
                this.flattenNode(child, level + 1, list);
            });
        }
    }

    computeCardClass(node, isSelected) {
        let classes = 'node-card';
        if (isSelected) classes += ' selected-node';
        if (node.isCurrentRecord) classes += ' current-record-node';
        return classes;
    }

    computeBadgeClass(nodeType) {
        if (!nodeType) return 'node-type-badge';
        const lower = nodeType.toLowerCase();
        if (lower.includes('root supply')) return 'node-type-badge badge-root-sr';
        if (lower.includes('root order')) return 'node-type-badge badge-root-oa';
        if (lower.includes('allocation line')) return 'node-type-badge badge-oali';
        if (lower.includes('procurement')) return 'node-type-badge badge-procurement-sr';
        if (lower.includes('transfer supply') || lower.includes('transfer sr')) return 'node-type-badge badge-transfer-sr';
        if (lower.includes('purchase order') || lower.includes('poli')) return 'node-type-badge badge-po';
        if (lower.includes('transfer')) return 'node-type-badge badge-transfer';
        if (lower.includes('reservation')) return 'node-type-badge badge-reservation';
        return 'node-type-badge';
    }

    // =========================================================================
    // DATA FETCHING
    // =========================================================================

    loadTrace(targetRecordId) {
        this.isLoading = true;
        this.errorMessage = null;

        getTrace({ recordId: targetRecordId })
            .then(result => {
                if (result.success) {
                    this.traceData = result;
                    // Default selected node to the current record node or root node
                    if (result.allNodesMap && result.allNodesMap[targetRecordId]) {
                        this.selectedNode = result.allNodesMap[targetRecordId];
                    } else {
                        this.selectedNode = result.rootNode;
                    }
                } else {
                    this.errorMessage = result.errorMessage;
                    this.showToast('Error', result.errorMessage, 'error');
                }
            })
            .catch(error => {
                this.errorMessage = error?.body?.message || 'An unexpected error occurred while generating the fulfillment trace.';
                this.showToast('Error Loading Trace', this.errorMessage, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleSearchChange(event) {
        this.searchInput = event.target.value;
    }

    handleSearchKeyUp(event) {
        if (event.keyCode === 13) {
            this.handleSearch();
        }
    }

    handleSearch() {
        if (!this.searchInput || !this.searchInput.trim()) {
            this.showToast('Warning', 'Please enter a record Name or ID to trace.', 'warning');
            return;
        }

        this.isLoading = true;
        this.errorMessage = null;

        getTraceBySearch({ searchTerm: this.searchInput.trim() })
            .then(result => {
                if (result.success) {
                    this.traceData = result;
                    this.selectedNode = result.rootNode;
                } else {
                    this.errorMessage = result.errorMessage;
                    this.showToast('Not Found', result.errorMessage, 'warning');
                }
            })
            .catch(error => {
                this.errorMessage = error?.body?.message || 'Search failed.';
                this.showToast('Search Error', this.errorMessage, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleRefresh() {
        if (this.traceData && this.traceData.startingRecordId) {
            this.loadTrace(this.traceData.startingRecordId);
        } else if (this.recordId) {
            this.loadTrace(this.recordId);
        }
    }

    // =========================================================================
    // USER INTERACTIONS
    // =========================================================================

    handleNodeClick(event) {
        const nodeId = event.currentTarget.dataset.id;
        if (this.traceData && this.traceData.allNodesMap && this.traceData.allNodesMap[nodeId]) {
            this.selectedNode = this.traceData.allNodesMap[nodeId];
        }
    }

    handleToggleExpand(event) {
        event.stopPropagation();
        const nodeId = event.currentTarget.dataset.id;
        if (this.collapsedNodeIds.has(nodeId)) {
            this.collapsedNodeIds.delete(nodeId);
        } else {
            this.collapsedNodeIds.add(nodeId);
        }
        // Trigger re-render of flattenedNodes getter
        this.collapsedNodeIds = new Set(this.collapsedNodeIds);
    }

    handleExpandAll() {
        this.collapsedNodeIds = new Set();
    }

    handleCollapseAll() {
        if (!this.traceData || !this.traceData.allNodesMap) return;
        const newSet = new Set();
        Object.keys(this.traceData.allNodesMap).forEach(key => {
            const node = this.traceData.allNodesMap[key];
            if (node.children && node.children.length > 0) {
                newSet.add(node.id);
            }
        });
        this.collapsedNodeIds = newSet;
    }

    /**
     * Standard Salesforce Record Navigation using NavigationMixin
     */
    handleNavigateRecord(event) {
        event.stopPropagation();
        const recId = event.currentTarget.dataset.id;
        if (!recId) return;

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: recId,
                actionName: 'view'
            }
        });
    }

    handleNavigateSelected() {
        if (!this.selectedNode || !this.selectedNode.id) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.selectedNode.id,
                actionName: 'view'
            }
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }

    get selectedNodeAttributes() {
        if (!this.selectedNode || !this.selectedNode.keyAttributes) return [];
        return Object.keys(this.selectedNode.keyAttributes).map(key => ({
            label: key,
            value: this.selectedNode.keyAttributes[key]
        }));
    }
}