/**
 * @description Queueable asynchronous worker for Dealer Management System (DMS) Apex Managed Sharing.
 *              Decouples database transactions from sharing calculation to avoid governor limits.
 * @author DeepMind Antigravity
 * @date 2026-07-30
 */
public without sharing class DMSAsyncSharingWorker implements Queueable {

    private List<SObject> recordsToShare;

    /**
     * @description Constructor accepting a list of SObjects to calculate managed sharing for.
     * @param records List of SObjects requiring upward hierarchy sharing.
     */
    public DMSAsyncSharingWorker(List<SObject> records) {
        this.recordsToShare = records;
    }

    /**
     * @description Execution method called asynchronously by the Salesforce system queue.
     * @param context QueueableContext provided by Salesforce.
     */
    public void execute(QueueableContext context) {
        if (this.recordsToShare != null && !this.recordsToShare.isEmpty()) {
            RecordSharingService.shareRecords(this.recordsToShare);
        }
    }
}