/**
 * FinancialDashboardController
 *
 * Apex controller for the Financial Overview Dashboard LWC.
 *
 * Account Visibility Hierarchy (mirrors SupplyRequestPlannerController):
 *   Logged-in User
 *     → Public Group Membership (GroupMember)
 *     → Account_Public_Group_Mapping__c
 *     → Mapped Account(s)                    ← primary authorised accounts
 *     → Eligible 1-Level Child Accounts       ← via SupplyOrderGenService.getEligibleChildAccounts()
 *     → Financial records visible to the user
 *
 * Filtering is enforced server-side in SOQL.
 * The class uses `without sharing` so that the Public-Group / mapping queries
 * can run freely (same pattern as SupplyRequestPlannerController), while the
 * actual financial-record queries are implicitly scoped by the SOQL WHERE clause
 * restricting to permitted account IDs.
 *
 * DO NOT rely on User.AccountId for record visibility — internal DMS users
 * are linked to their dealer Account via Public Group mappings, not via the
 * standard User.AccountId field.
 */
public without sharing class FinancialDashboardController {

    // ─── Page size ────────────────────────────────────────────────────────────
    private static final Integer PAGE_SIZE = 50;

    // =========================================================================
    // WRAPPERS
    // =========================================================================

    public class UserAccountContext {
        @AuraEnabled public Id     accountId;   // primary mapped account
        @AuraEnabled public String accountName;
    }

    public class PayableWrapper {
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  payableNumber;
        @AuraEnabled public Id      supplyingAccountId;
        @AuraEnabled public String  supplyingAccountName;
        @AuraEnabled public Id      requestingAccountId;
        @AuraEnabled public String  requestingAccountName;
        @AuraEnabled public Id      invoiceId;
        @AuraEnabled public String  invoiceNumber;
        @AuraEnabled public Date    payableDate;
        @AuraEnabled public Date    dueDate;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Decimal amountPaid;
        @AuraEnabled public Decimal outstandingBalance;
        @AuraEnabled public String  status;
        @AuraEnabled public String  paymentStatus;
    }

    public class ReceivableWrapper {
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  receivableNumber;
        @AuraEnabled public Id      requestingAccountId;
        @AuraEnabled public String  requestingAccountName;
        @AuraEnabled public Id      supplyingAccountId;
        @AuraEnabled public String  supplyingAccountName;
        @AuraEnabled public Id      customerId;
        @AuraEnabled public String  customerName;
        @AuraEnabled public Id      invoiceId;
        @AuraEnabled public String  invoiceNumber;
        @AuraEnabled public Date    receivableDate;
        @AuraEnabled public Date    dueDate;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Decimal amountReceived;
        @AuraEnabled public Decimal outstandingBalance;
        @AuraEnabled public String  status;
        @AuraEnabled public String  collectionStatus;
    }

    public class InvoiceWrapper {
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  invoiceNumber;
        @AuraEnabled public Id      requestingAccountId;
        @AuraEnabled public String  requestingAccountName;
        @AuraEnabled public Id      supplyingAccountId;
        @AuraEnabled public String  supplyingAccountName;
        @AuraEnabled public Date    invoiceDate;
        @AuraEnabled public Date    dueDate;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Decimal amountPaid;
        @AuraEnabled public Decimal balanceDue;
        @AuraEnabled public String  status;
        @AuraEnabled public String  type;
        @AuraEnabled public String  paymentTerms;
    }

    public class DashboardSummary {
        // Top Hero Tiles (Valuation & Outstanding)
        @AuraEnabled public Decimal myValuation             = 0;
        @AuraEnabled public Decimal myOutstanding           = 0;
        @AuraEnabled public Decimal networkValuation        = 0;
        @AuraEnabled public Decimal networkOutstanding      = 0;

        // Existing Secondary KPI Cards
        @AuraEnabled public Decimal totalPayables          = 0;
        @AuraEnabled public Decimal totalReceivables       = 0;
        @AuraEnabled public Integer totalInvoiceCount      = 0;
        @AuraEnabled public Decimal overduePayables        = 0;
        @AuraEnabled public Decimal overdueReceivables     = 0;
        @AuraEnabled public Decimal dueSoonPayables        = 0;
        @AuraEnabled public Decimal dueSoonReceivables     = 0;
        @AuraEnabled public Decimal outstandingPayables    = 0;
        @AuraEnabled public Decimal outstandingReceivables = 0;
    }

    public class DashboardData {
        @AuraEnabled public UserAccountContext      userContext;
        @AuraEnabled public DashboardSummary        summary;
        @AuraEnabled public List<PayableWrapper>    payables;
        @AuraEnabled public List<ReceivableWrapper> receivables;
        @AuraEnabled public List<InvoiceWrapper>    invoices;
    }

    // =========================================================================
    // ACCOUNT HIERARCHY RESOLUTION
    // Identical pattern to SupplyRequestPlannerController.getUserAccountIds()
    // =========================================================================

    /**
     * Step 1: Resolve the mapped account IDs for the current user via Public Group memberships.
     *   User → GroupMember → Account_Public_Group_Mapping__c → Account
     *
     * Mirrors SupplyRequestPlannerController.getUserAccountIds() exactly.
     */
    private static Set<Id> getMappedAccountIds() {
        Id currentUserId = UserInfo.getUserId();

        // 1. Find all Public Groups the user is a member of
        Set<Id>     groupIds    = new Set<Id>();
        Set<String> groupTokens = new Set<String>();

        for (GroupMember gm : [
            SELECT GroupId, Group.Name, Group.DeveloperName
            FROM GroupMember
            WHERE UserOrGroupId = :currentUserId
        ]) {
            groupIds.add(gm.GroupId);
            groupTokens.add(String.valueOf(gm.GroupId));
            if (gm.Group != null) {
                if (String.isNotBlank(gm.Group.Name))          { groupTokens.add(gm.Group.Name); }
                if (String.isNotBlank(gm.Group.DeveloperName)) { groupTokens.add(gm.Group.DeveloperName); }
            }
        }

        Set<Id> accountIds = new Set<Id>();
        if (groupIds.isEmpty()) {
            return accountIds;
        }

        // 2. Introspect Account_Public_Group_Mapping__c schema dynamically
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account_Public_Group_Mapping__c.fields.getMap();
        String       accountFieldName  = 'Account__c';
        String       activeFieldName   = null;
        List<String> groupConditions   = new List<String>();

        for (String fName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(fName).getDescribe();
            String lowerName = fName.toLowerCase();

            // Detect Account lookup field
            if (lowerName == 'account__c') {
                accountFieldName = dfr.getName();
            } else if (accountFieldName == null && dfr.isCustom()) {
                for (Schema.sObjectType ref : dfr.getReferenceTo()) {
                    if (ref == Account.SObjectType) { accountFieldName = dfr.getName(); break; }
                }
            }

            // Detect Active boolean flag
            if (dfr.getType() == Schema.DisplayType.BOOLEAN) {
                if (lowerName == 'isactive__c' || lowerName == 'is_active__c' || lowerName == 'active__c') {
                    activeFieldName = dfr.getName();
                }
            }

            // Detect Group reference / token fields
            if (dfr.isCustom() && lowerName != accountFieldName.toLowerCase() && lowerName != 'id' && lowerName != 'name') {
                Boolean isGroupRef = false;
                for (Schema.sObjectType ref : dfr.getReferenceTo()) {
                    if (ref == Group.SObjectType) { isGroupRef = true; break; }
                }
                if (isGroupRef) {
                    groupConditions.add(dfr.getName() + ' IN :groupIds');
                } else if (lowerName.contains('group')) {
                    groupConditions.add('(' + dfr.getName() + ' IN :groupIds OR ' + dfr.getName() + ' IN :groupTokens)');
                }
            }
        }

        // 3. Dynamic SOQL against Account_Public_Group_Mapping__c
        if (!groupConditions.isEmpty() && accountFieldName != null) {
            String query = 'SELECT ' + String.escapeSingleQuotes(accountFieldName)
                         + ' FROM Account_Public_Group_Mapping__c'
                         + ' WHERE (' + String.join(groupConditions, ' OR ') + ')';

            if (activeFieldName != null) {
                query += ' AND ' + String.escapeSingleQuotes(activeFieldName) + ' = true';
            }

            for (SObject mapping : Database.query(query)) {
                Id accId = (Id) mapping.get(accountFieldName);
                if (accId != null) { accountIds.add(accId); }
            }
        }

        return accountIds;
    }

    /**
     * Helper to determine if the logged-in user is an Admin or OEM profile.
     */
    private static Boolean isUserAdminOrOem() {
        Id profileId = UserInfo.getProfileId();
        if (profileId != null) {
            List<Profile> profs = [SELECT Name FROM Profile WHERE Id = :profileId LIMIT 1];
            if (!profs.isEmpty()) {
                String pName = profs[0].Name.toLowerCase();
                if (pName.contains('admin') || pName.contains('oem') || pName.contains('system administrator')) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Helper to check if any of the mapped accounts is an OEM account.
     */
    private static Boolean isAnyAccountOem(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return false;
        }
        List<Account> oemAccs = [
            SELECT Id
            FROM Account
            WHERE Id IN :accountIds
              AND (Type = 'OEM' OR RecordType.DeveloperName = 'OEM')
            LIMIT 1
        ];
        return !oemAccs.isEmpty();
    }

    /**
     * Step 2: Build the full permitted account set for financial record visibility.
     *   = Mapped Account(s) + Eligible 1-Level Child Accounts
     * For Admin/OEM users or unmapped profiles: grants full system-wide visibility.
     *
     * Returns a set that is safe to use directly in SOQL IN clauses.
     */
    private static Set<Id> resolvePermittedAccountIds() {
        Set<Id> mappedIds = getMappedAccountIds();
        Boolean isAdminOrOemUser = isUserAdminOrOem();
        Boolean hasOemAccount    = isAnyAccountOem(mappedIds);

        // If user is Admin/OEM, mapped to an OEM account, or has no specific mapped account: grant visibility to all accounts
        if (mappedIds.isEmpty() || isAdminOrOemUser || hasOemAccount) {
            Map<Id, Account> allAccsMap = new Map<Id, Account>([
                SELECT Id FROM Account LIMIT 2000
            ]);
            return allAccsMap.keySet();
        }

        Set<Id> permitted = new Set<Id>(mappedIds);

        // Add 1-level child accounts for each mapped account (same as SupplyRequestPlannerController)
        for (Id accId : mappedIds) {
            Set<Id> childIds = SupplyOrderGenService.getEligibleChildAccounts(accId);
            if (childIds != null) {
                permitted.addAll(childIds);
            }
        }

        return permitted;
    }

    // =========================================================================
    // GET USER ACCOUNT CONTEXT  (called by LWC on load)
    // =========================================================================

    /**
     * Returns the primary mapped account for the logged-in user.
     * Uses Public Group → Account_Public_Group_Mapping__c → Account hierarchy.
     * Falls back to OEM Account or top-level Account for Admin/OEM users.
     */
    @AuraEnabled(cacheable=true)
    public static UserAccountContext getUserAccountContext() {
        try {
            Set<Id> mappedIds = getMappedAccountIds();
            Boolean isAdminOrOemUser = isUserAdminOrOem();
            Boolean hasOemAccount    = isAnyAccountOem(mappedIds);

            UserAccountContext ctx = new UserAccountContext();

            if (!mappedIds.isEmpty() && !isAdminOrOemUser && !hasOemAccount) {
                // Use the first mapped account as the "primary" display account
                List<Account> accts = [
                    SELECT Id, Name
                    FROM Account
                    WHERE Id IN :mappedIds
                    ORDER BY Name ASC
                    LIMIT 1
                ];
                if (!accts.isEmpty()) {
                    ctx.accountId   = accts[0].Id;
                    ctx.accountName = accts[0].Name;
                }
            } else {
                // Admin / OEM user or unmapped user: resolve OEM account or top-level account
                List<Account> oemAccts = [
                    SELECT Id, Name
                    FROM Account
                    WHERE Type = 'OEM' OR RecordType.DeveloperName = 'OEM'
                    ORDER BY Name ASC
                    LIMIT 1
                ];
                if (!oemAccts.isEmpty()) {
                    ctx.accountId   = oemAccts[0].Id;
                    ctx.accountName = oemAccts[0].Name;
                } else {
                    List<Account> topAccts = [
                        SELECT Id, Name
                        FROM Account
                        WHERE ParentId = null
                        ORDER BY Name ASC
                        LIMIT 1
                    ];
                    if (!topAccts.isEmpty()) {
                        ctx.accountId   = topAccts[0].Id;
                        ctx.accountName = topAccts[0].Name;
                    } else {
                        List<Account> anyAccts = [
                            SELECT Id, Name
                            FROM Account
                            ORDER BY Name ASC
                            LIMIT 1
                        ];
                        if (!anyAccts.isEmpty()) {
                            ctx.accountId   = anyAccts[0].Id;
                            ctx.accountName = anyAccts[0].Name;
                        }
                    }
                }
            }

            return ctx;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to resolve user account context: ' + e.getMessage());
        }
    }

    // =========================================================================
    // GET ALL DASHBOARD DATA (single call from LWC)
    // =========================================================================

    /**
     * Returns all dashboard data (Payables, Receivables, Invoices, Summary)
     * scoped to the logged-in user's permitted account hierarchy.
     *
     * The accountId parameter is used only for display context (account name in header).
     * Actual record filtering always resolves fresh from the sharing hierarchy.
     */
    @AuraEnabled
    public static DashboardData getDashboardData(Id accountId, Integer pageSize, Integer offset) {

        Integer limitSize = (pageSize != null && pageSize > 0 && pageSize <= 200) ? pageSize : PAGE_SIZE;
        Integer off       = (offset   != null && offset  >= 0)                   ? offset   : 0;

        // Always resolve permitted accounts from hierarchy — never trust the passed accountId alone
        Set<Id> permittedIds = resolvePermittedAccountIds();

        if (permittedIds.isEmpty()) {
            // No accounts found in system — return empty dashboard
            DashboardData empty = new DashboardData();
            empty.userContext   = new UserAccountContext();
            empty.summary       = new DashboardSummary();
            empty.payables      = new List<PayableWrapper>();
            empty.receivables   = new List<ReceivableWrapper>();
            empty.invoices      = new List<InvoiceWrapper>();
            return empty;
        }

        DashboardData data = new DashboardData();
        data.userContext = new UserAccountContext();

        // Resolve display name for the header (primary mapped account)
        if (accountId != null && permittedIds.contains(accountId)) {
            try {
                Account acct = [SELECT Id, Name FROM Account WHERE Id = :accountId LIMIT 1];
                data.userContext.accountId   = acct.Id;
                data.userContext.accountName = acct.Name;
            } catch (Exception e) { /* non-fatal */ }
        }
        if (data.userContext.accountId == null) {
            List<Account> primary = [
                SELECT Id, Name FROM Account WHERE Type = 'OEM' OR RecordType.DeveloperName = 'OEM' ORDER BY Name ASC LIMIT 1
            ];
            if (primary.isEmpty()) {
                primary = [
                    SELECT Id, Name FROM Account WHERE ParentId = null ORDER BY Name ASC LIMIT 1
                ];
            }
            if (primary.isEmpty()) {
                primary = [
                    SELECT Id, Name FROM Account WHERE Id IN :permittedIds ORDER BY Name ASC LIMIT 1
                ];
            }
            if (!primary.isEmpty()) {
                data.userContext.accountId   = primary[0].Id;
                data.userContext.accountName = primary[0].Name;
            }
        }

        data.payables    = fetchPayables(permittedIds, limitSize, off);
        data.receivables = fetchReceivables(permittedIds, limitSize, off);
        data.invoices    = fetchInvoices(permittedIds, limitSize, off);
        data.summary     = buildSummary(permittedIds, data.userContext.accountId);

        return data;
    }

    // =========================================================================
    // PAYABLES
    // Visibility: Requesting_Account__c IN permittedIds
    // (the logged-in account's hierarchy is the one that must PAY)
    // =========================================================================

    @AuraEnabled
    public static List<PayableWrapper> getPayables(Id accountId, Integer limitSize, Integer offset) {
        Set<Id> permittedIds = resolvePermittedAccountIds();
        if (permittedIds.isEmpty()) { return new List<PayableWrapper>(); }
        Integer lim = (limitSize != null && limitSize > 0) ? limitSize : PAGE_SIZE;
        Integer off = (offset    != null && offset   >= 0) ? offset    : 0;
        return fetchPayables(permittedIds, lim, off);
    }

    private static List<PayableWrapper> fetchPayables(Set<Id> permittedIds, Integer lim, Integer off) {
        List<Payable__c> records = [
            SELECT Id, Name,
                   Supplying_Account__c, Supplying_Account__r.Name,
                   Requesting_Account__c, Requesting_Account__r.Name,
                   Invoice__c, Invoice__r.Name,
                   Payable_Date__c, Due_Date__c,
                   Total_Amount__c, Amount_Paid__c, Outstanding_Balance__c,
                   Status__c, Payment_Status__c
            FROM Payable__c
            WHERE Requesting_Account__c IN :permittedIds
            ORDER BY Due_Date__c ASC NULLS LAST
            LIMIT :lim
            OFFSET :off
        ];

        records.sort(new PayableStatusComparator());

        List<PayableWrapper> wrappers = new List<PayableWrapper>();
        for (Payable__c r : records) {
            PayableWrapper w = new PayableWrapper();
            w.recordId              = r.Id;
            w.payableNumber         = r.Name;
            w.supplyingAccountId    = r.Supplying_Account__c;
            w.supplyingAccountName  = r.Supplying_Account__r  != null ? r.Supplying_Account__r.Name  : null;
            w.requestingAccountId   = r.Requesting_Account__c;
            w.requestingAccountName = r.Requesting_Account__r != null ? r.Requesting_Account__r.Name : null;
            w.invoiceId             = r.Invoice__c;
            w.invoiceNumber         = r.Invoice__r != null ? r.Invoice__r.Name : null;
            w.payableDate           = r.Payable_Date__c;
            w.dueDate               = r.Due_Date__c;
            w.totalAmount           = r.Total_Amount__c        != null ? r.Total_Amount__c        : 0;
            w.amountPaid            = r.Amount_Paid__c         != null ? r.Amount_Paid__c         : 0;
            w.outstandingBalance    = r.Outstanding_Balance__c != null ? r.Outstanding_Balance__c : 0;
            w.status                = r.Status__c;
            w.paymentStatus         = r.Payment_Status__c;
            wrappers.add(w);
        }
        return wrappers;
    }

    // =========================================================================
    // RECEIVABLES
    // Visibility: Supplying_Account__c IN permittedIds
    // (the logged-in account's hierarchy is the one that must COLLECT payment)
    // =========================================================================

    @AuraEnabled
    public static List<ReceivableWrapper> getReceivables(Id accountId, Integer limitSize, Integer offset) {
        Set<Id> permittedIds = resolvePermittedAccountIds();
        if (permittedIds.isEmpty()) { return new List<ReceivableWrapper>(); }
        Integer lim = (limitSize != null && limitSize > 0) ? limitSize : PAGE_SIZE;
        Integer off = (offset    != null && offset   >= 0) ? offset    : 0;
        return fetchReceivables(permittedIds, lim, off);
    }

    private static List<ReceivableWrapper> fetchReceivables(Set<Id> permittedIds, Integer lim, Integer off) {
        List<Receivable__c> records = [
            SELECT Id, Name,
                   Requesting_Account__c, Requesting_Account__r.Name,
                   Supplying_Account__c,  Supplying_Account__r.Name,
                   Customer__c, Customer__r.Name,
                   Invoice__c, Invoice__r.Name,
                   Receivable_Date__c, Due_Date__c,
                   Total_Amount__c, Amount_Received__c, Outstanding_Balance__c,
                   Status__c, Collection_Status__c
            FROM Receivable__c
            WHERE Supplying_Account__c IN :permittedIds
            ORDER BY Due_Date__c ASC NULLS LAST
            LIMIT :lim
            OFFSET :off
        ];

        records.sort(new ReceivableStatusComparator());

        List<ReceivableWrapper> wrappers = new List<ReceivableWrapper>();
        for (Receivable__c r : records) {
            ReceivableWrapper w = new ReceivableWrapper();
            w.recordId              = r.Id;
            w.receivableNumber      = r.Name;
            w.requestingAccountId   = r.Requesting_Account__c;
            w.requestingAccountName = r.Requesting_Account__r != null ? r.Requesting_Account__r.Name : null;
            w.supplyingAccountId    = r.Supplying_Account__c;
            w.supplyingAccountName  = r.Supplying_Account__r  != null ? r.Supplying_Account__r.Name  : null;
            w.customerId            = r.Customer__c;
            w.customerName          = r.Customer__r  != null ? r.Customer__r.Name  : null;
            w.invoiceId             = r.Invoice__c;
            w.invoiceNumber         = r.Invoice__r   != null ? r.Invoice__r.Name   : null;
            w.receivableDate        = r.Receivable_Date__c;
            w.dueDate               = r.Due_Date__c;
            w.totalAmount           = r.Total_Amount__c        != null ? r.Total_Amount__c        : 0;
            w.amountReceived        = r.Amount_Received__c     != null ? r.Amount_Received__c     : 0;
            w.outstandingBalance    = r.Outstanding_Balance__c != null ? r.Outstanding_Balance__c : 0;
            w.status                = r.Status__c;
            w.collectionStatus      = r.Collection_Status__c;
            wrappers.add(w);
        }
        return wrappers;
    }

    // =========================================================================
    // INVOICES
    // Visibility: Requesting_Account__c OR Supplying_Account__c IN permittedIds
    // (the account appears on either side of the invoice)
    // =========================================================================

    @AuraEnabled
    public static List<InvoiceWrapper> getInvoices(Id accountId, Integer limitSize, Integer offset) {
        Set<Id> permittedIds = resolvePermittedAccountIds();
        if (permittedIds.isEmpty()) { return new List<InvoiceWrapper>(); }
        Integer lim = (limitSize != null && limitSize > 0) ? limitSize : PAGE_SIZE;
        Integer off = (offset    != null && offset   >= 0) ? offset    : 0;
        return fetchInvoices(permittedIds, lim, off);
    }

    private static List<InvoiceWrapper> fetchInvoices(Set<Id> permittedIds, Integer lim, Integer off) {
        List<Invoice__c> records = [
            SELECT Id, Name,
                   Requesting_Account__c, Requesting_Account__r.Name,
                   Supplying_Account__c,  Supplying_Account__r.Name,
                   Invoice_Date__c, Due_Date__c,
                   Total_Amount__c, Amount_Paid__c, Balance_Due__c,
                   Status__c, Type__c, Payment_Terms__c
            FROM Invoice__c
            WHERE Requesting_Account__c IN :permittedIds
               OR Supplying_Account__c  IN :permittedIds
            ORDER BY Due_Date__c ASC NULLS LAST
            LIMIT :lim
            OFFSET :off
        ];

        records.sort(new InvoiceStatusComparator());

        List<InvoiceWrapper> wrappers = new List<InvoiceWrapper>();
        for (Invoice__c r : records) {
            InvoiceWrapper w = new InvoiceWrapper();
            w.recordId              = r.Id;
            w.invoiceNumber         = r.Name;
            w.requestingAccountId   = r.Requesting_Account__c;
            w.requestingAccountName = r.Requesting_Account__r != null ? r.Requesting_Account__r.Name : null;
            w.supplyingAccountId    = r.Supplying_Account__c;
            w.supplyingAccountName  = r.Supplying_Account__r  != null ? r.Supplying_Account__r.Name  : null;
            w.invoiceDate           = r.Invoice_Date__c;
            w.dueDate               = r.Due_Date__c;
            w.totalAmount           = r.Total_Amount__c  != null ? r.Total_Amount__c  : 0;
            w.amountPaid            = r.Amount_Paid__c   != null ? r.Amount_Paid__c   : 0;
            w.balanceDue            = r.Balance_Due__c   != null ? r.Balance_Due__c   : 0;
            w.status                = r.Status__c;
            w.type                  = r.Type__c;
            w.paymentTerms          = r.Payment_Terms__c;
            wrappers.add(w);
        }
        return wrappers;
    }

    // =========================================================================
    // SUMMARY BUILDER
    // SOQL Aggregate Queries for 100% accuracy across all permitted records
    // =========================================================================

    private static DashboardSummary buildSummary(Set<Id> permittedIds, Id myAccountId) {
        DashboardSummary s = new DashboardSummary();
        if (permittedIds == null || permittedIds.isEmpty()) {
            return s;
        }

        Date today         = Date.today();
        Date dueSoonCutoff = today.addDays(7);

        // 1. Payables summary for permitted accounts
        for (AggregateResult ar : [
            SELECT SUM(Total_Amount__c) tot, SUM(Outstanding_Balance__c) out
            FROM Payable__c
            WHERE Requesting_Account__c IN :permittedIds
        ]) {
            s.totalPayables       += ar.get('tot') != null ? (Decimal) ar.get('tot') : 0;
            s.outstandingPayables += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
        }

        // Overdue Payables
        for (AggregateResult ar : [
            SELECT SUM(Outstanding_Balance__c) out
            FROM Payable__c
            WHERE Requesting_Account__c IN :permittedIds
              AND Due_Date__c < :today
              AND Outstanding_Balance__c > 0
        ]) {
            s.overduePayables += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
        }

        // Due Soon Payables
        for (AggregateResult ar : [
            SELECT SUM(Outstanding_Balance__c) out
            FROM Payable__c
            WHERE Requesting_Account__c IN :permittedIds
              AND Due_Date__c >= :today
              AND Due_Date__c <= :dueSoonCutoff
              AND Outstanding_Balance__c > 0
        ]) {
            s.dueSoonPayables += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
        }

        // 2. Receivables summary for permitted accounts
        for (AggregateResult ar : [
            SELECT SUM(Total_Amount__c) tot, SUM(Outstanding_Balance__c) out
            FROM Receivable__c
            WHERE Supplying_Account__c IN :permittedIds
        ]) {
            s.totalReceivables       += ar.get('tot') != null ? (Decimal) ar.get('tot') : 0;
            s.outstandingReceivables += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
        }

        // Overdue Receivables
        for (AggregateResult ar : [
            SELECT SUM(Outstanding_Balance__c) out
            FROM Receivable__c
            WHERE Supplying_Account__c IN :permittedIds
              AND Due_Date__c < :today
              AND Outstanding_Balance__c > 0
        ]) {
            s.overdueReceivables += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
        }

        // Due Soon Receivables
        for (AggregateResult ar : [
            SELECT SUM(Outstanding_Balance__c) out
            FROM Receivable__c
            WHERE Supplying_Account__c IN :permittedIds
              AND Due_Date__c >= :today
              AND Due_Date__c <= :dueSoonCutoff
              AND Outstanding_Balance__c > 0
        ]) {
            s.dueSoonReceivables += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
        }

        // 3. Invoice Count
        s.totalInvoiceCount = [
            SELECT COUNT()
            FROM Invoice__c
            WHERE Requesting_Account__c IN :permittedIds
               OR Supplying_Account__c  IN :permittedIds
        ];

        // ── 4. My Account vs Network Accounts Valuation & Outstanding ─────────
        Set<Id> networkIds = new Set<Id>(permittedIds);
        if (myAccountId != null) {
            networkIds.remove(myAccountId);
        }

        // My Account Calculations
        if (myAccountId != null) {
            Decimal myRecTot = 0;
            Decimal myRecOut = 0;
            for (AggregateResult ar : [
                SELECT SUM(Total_Amount__c) tot, SUM(Outstanding_Balance__c) out
                FROM Receivable__c
                WHERE Supplying_Account__c = :myAccountId
            ]) {
                myRecTot += ar.get('tot') != null ? (Decimal) ar.get('tot') : 0;
                myRecOut += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
            }

            Decimal myPayTot = 0;
            Decimal myPayOut = 0;
            for (AggregateResult ar : [
                SELECT SUM(Total_Amount__c) tot, SUM(Outstanding_Balance__c) out
                FROM Payable__c
                WHERE Requesting_Account__c = :myAccountId
            ]) {
                myPayTot += ar.get('tot') != null ? (Decimal) ar.get('tot') : 0;
                myPayOut += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
            }

            s.myValuation   = myRecTot + myPayTot;
            s.myOutstanding = myRecOut + myPayOut;
        }

        // Network Accounts Calculations
        if (!networkIds.isEmpty()) {
            Decimal netRecTot = 0;
            Decimal netRecOut = 0;
            for (AggregateResult ar : [
                SELECT SUM(Total_Amount__c) tot, SUM(Outstanding_Balance__c) out
                FROM Receivable__c
                WHERE Supplying_Account__c IN :networkIds
            ]) {
                netRecTot += ar.get('tot') != null ? (Decimal) ar.get('tot') : 0;
                netRecOut += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
            }

            Decimal netPayTot = 0;
            Decimal netPayOut = 0;
            for (AggregateResult ar : [
                SELECT SUM(Total_Amount__c) tot, SUM(Outstanding_Balance__c) out
                FROM Payable__c
                WHERE Requesting_Account__c IN :networkIds
            ]) {
                netPayTot += ar.get('tot') != null ? (Decimal) ar.get('tot') : 0;
                netPayOut += ar.get('out') != null ? (Decimal) ar.get('out') : 0;
            }

            s.networkValuation   = netRecTot + netPayTot;
            s.networkOutstanding = netRecOut + netPayOut;
        }

        return s;
    }

    // =========================================================================
    // INNER COMPARATORS — priority sort after SOQL (CASE WHEN not valid in SOQL)
    // Overdue → Unpaid → Partially Paid → Paid, then Due Date ASC
    // =========================================================================

    private static Integer payableStatusPriority(String status) {
        if (status == 'Overdue')        return 1;
        if (status == 'Unpaid')         return 2;
        if (status == 'Partially Paid') return 3;
        if (status == 'Paid')           return 4;
        return 5;
    }

    private static Integer receivableStatusPriority(String status) {
        if (status == 'Overdue')        return 1;
        if (status == 'Unpaid')         return 2;
        if (status == 'Partially Paid') return 3;
        if (status == 'Paid')           return 4;
        return 5;
    }

    private static Integer invoiceStatusPriority(String status) {
        if (status == 'Overdue')        return 1;
        if (status == 'Issued')         return 2;
        if (status == 'Approved')       return 3;
        if (status == 'Partially Paid') return 4;
        if (status == 'Draft')          return 5;
        if (status == 'Paid')           return 6;
        return 7;
    }

    private class PayableStatusComparator implements Comparator<Payable__c> {
        public Integer compare(Payable__c a, Payable__c b) {
            Integer pa = payableStatusPriority(a.Status__c);
            Integer pb = payableStatusPriority(b.Status__c);
            if (pa != pb) return pa - pb;
            if (a.Due_Date__c == null && b.Due_Date__c == null) return 0;
            if (a.Due_Date__c == null) return 1;
            if (b.Due_Date__c == null) return -1;
            return a.Due_Date__c < b.Due_Date__c ? -1 : (a.Due_Date__c > b.Due_Date__c ? 1 : 0);
        }
    }

    private class ReceivableStatusComparator implements Comparator<Receivable__c> {
        public Integer compare(Receivable__c a, Receivable__c b) {
            Integer pa = receivableStatusPriority(a.Status__c);
            Integer pb = receivableStatusPriority(b.Status__c);
            if (pa != pb) return pa - pb;
            if (a.Due_Date__c == null && b.Due_Date__c == null) return 0;
            if (a.Due_Date__c == null) return 1;
            if (b.Due_Date__c == null) return -1;
            return a.Due_Date__c < b.Due_Date__c ? -1 : (a.Due_Date__c > b.Due_Date__c ? 1 : 0);
        }
    }

    private class InvoiceStatusComparator implements Comparator<Invoice__c> {
        public Integer compare(Invoice__c a, Invoice__c b) {
            Integer pa = invoiceStatusPriority(a.Status__c);
            Integer pb = invoiceStatusPriority(b.Status__c);
            if (pa != pb) return pa - pb;
            if (a.Due_Date__c == null && b.Due_Date__c == null) return 0;
            if (a.Due_Date__c == null) return 1;
            if (b.Due_Date__c == null) return -1;
            return a.Due_Date__c < b.Due_Date__c ? -1 : (a.Due_Date__c > b.Due_Date__c ? 1 : 0);
        }
    }
}