import Foundation
import SwiftData
import Observation
import OSLog

private let syncLog = Logger(subsystem: "com.kevinphilip.budgy", category: "Sync")

/// Pulls balances and transactions from Plaid (via your relay) into SwiftData,
/// then categorizes, matches recurring charges, and detects new subscriptions.
@Observable
final class SyncService {
    var isSyncing = false
    var lastError: String?
    var lastSynced: Date? = UserDefaults.standard.object(forKey: SettingsKeys.lastSync) as? Date

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: Linking

    /// Records a newly linked bank login, then syncs it.
    func registerLinkedItems(_ items: [PlaidService.LinkedItem], context: ModelContext) async {
        let existing = (try? context.fetch(FetchDescriptor<PlaidItem>())) ?? []
        for item in items where !existing.contains(where: { $0.itemID == item.item_id }) {
            context.insert(PlaidItem(itemID: item.item_id, institutionName: item.institution_name, isInvestments: item.is_investments))
        }
        try? context.save()
        await sync(context: context)
    }

    /// The bank connection to sync from: the Demo Bank while it's connected, otherwise your Plaid relay.
    static var dataSource: BankDataSource? {
        DemoBankService.isEnabled ? DemoBankService() : PlaidService.configured
    }

    // MARK: Demo Bank

    /// Connects the fake Demo Bank so the full sync pipeline can be tested without Plaid.
    /// Sample data is removed first so balances aren't counted twice.
    func connectDemoBank(context: ModelContext) async {
        SampleData.removeSampleData(context: context)
        UserDefaults.standard.set(true, forKey: SettingsKeys.demoBankEnabled)
        await registerLinkedItems(DemoBankService.linkedItems, context: context)
    }

    /// Removes everything the Demo Bank created.
    func disconnectDemoBank(context: ModelContext) {
        UserDefaults.standard.set(false, forKey: SettingsKeys.demoBankEnabled)
        let demoItemIDs = Set(DemoBankService.linkedItems.map(\.item_id))

        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let demoTransactions = transactions.filter { $0.plaidTransactionID.hasPrefix("demo-") }
        // Recurring items found from demo history go too.
        let recurringIDs = Set(demoTransactions.compactMap { $0.recurringItem?.id })
        let recurring = (try? context.fetch(FetchDescriptor<RecurringItem>())) ?? []
        recurring.filter { recurringIDs.contains($0.id) }.forEach(context.delete)
        demoTransactions.forEach(context.delete)

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        accounts.filter { demoItemIDs.contains($0.plaidItemID) }.forEach(context.delete)
        let items = (try? context.fetch(FetchDescriptor<PlaidItem>())) ?? []
        items.filter { demoItemIDs.contains($0.itemID) }.forEach(context.delete)

        // Drop a pay schedule that was inferred from demo paychecks.
        let schedules = (try? context.fetch(FetchDescriptor<PaySchedule>())) ?? []
        schedules.filter { $0.matchText.contains("acme") && !$0.isSample }.forEach(context.delete)

        try? context.save()
        Self.performHousekeeping(context: context)
    }

    func disconnect(_ item: PlaidItem, context: ModelContext) async {
        if item.itemID.hasPrefix("demo-") {
            disconnectDemoBank(context: context)
            return
        }
        guard let service = PlaidService.configured else { return }
        do {
            try await service.removeItem(item.itemID)
            // Keep history but detach the accounts so they become manual.
            let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            for account in accounts where account.plaidItemID == item.itemID {
                account.plaidItemID = ""
                account.plaidAccountID = ""
            }
            context.delete(item)
            try? context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Sync

    func sync(context: ModelContext) async {
        guard !isSyncing else { return }
        guard let service = Self.dataSource else {
            Self.performHousekeeping(context: context)
            return
        }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await syncAccounts(service: service, context: context)
            try await syncTransactions(service: service, context: context)
            detectRecurring(context: context)
            inferPaySchedule(context: context)
            try? context.save()
            lastSynced = .now
            UserDefaults.standard.set(Date.now, forKey: SettingsKeys.lastSync)
        } catch {
            syncLog.error("Sync failed: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
        }
        let itemErrors = ((try? context.fetch(FetchDescriptor<PlaidItem>())) ?? []).filter { !$0.lastError.isEmpty }
        for item in itemErrors {
            syncLog.error("\(item.institutionName, privacy: .public): \(item.lastError, privacy: .public)")
        }
        Self.performHousekeeping(context: context)
    }

    private func syncAccounts(service: BankDataSource, context: ModelContext) async throws {
        let (remote, errors) = try await service.accounts()
        var accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []

        for remoteAccount in remote {
            let account: Account
            if let match = accounts.first(where: { $0.plaidAccountID == remoteAccount.account_id }) {
                account = match
            } else {
                account = Account(name: remoteAccount.name, institution: remoteAccount.institution_name, kind: Self.kind(for: remoteAccount), balance: 0, mask: remoteAccount.mask ?? "")
                account.plaidAccountID = remoteAccount.account_id
                account.plaidItemID = remoteAccount.item_id
                account.sortOrder = accounts.count
                context.insert(account)
                accounts.append(account)
            }
            account.balance = remoteAccount.current ?? remoteAccount.available ?? account.balance
            if let limit = remoteAccount.limit { account.creditLimit = limit }
            account.lastUpdated = .now
            account.recordSnapshot(in: context)
        }

        let items = (try? context.fetch(FetchDescriptor<PlaidItem>())) ?? []
        for item in items {
            item.lastError = errors.first { $0.item_id == item.itemID }?.error ?? ""
        }
    }

    private func syncTransactions(service: BankDataSource, context: ModelContext) async throws {
        let items = ((try? context.fetch(FetchDescriptor<PlaidItem>())) ?? []).filter { !$0.isInvestments }
        guard !items.isEmpty else { return }
        let cursors = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0.cursor) })
        let results = try await service.syncTransactions(cursors: cursors)

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let rules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []
        let schedule = (try? context.fetch(FetchDescriptor<PaySchedule>()))?.first
        let recurring = (try? context.fetch(FetchDescriptor<RecurringItem>())) ?? []
        let existing = ((try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.plaidTransactionID != "" }))) ?? [])
        var byPlaidID = Dictionary(existing.map { ($0.plaidTransactionID, $0) }, uniquingKeysWith: { first, _ in first })

        let categorizer = Categorizer(categories: categories, rules: rules, schedule: schedule)
        let detector = RecurringDetector()

        for result in results {
            if let error = result.error {
                items.first { $0.itemID == result.item_id }?.lastError = error
                continue
            }
            for remote in result.added + result.modified {
                let account = accounts.first { $0.plaidAccountID == remote.account_id }
                let date = Self.dateFormatter.date(from: remote.date) ?? .now
                if let transaction = byPlaidID[remote.transaction_id] {
                    transaction.amount = remote.amount
                    transaction.date = date
                    transaction.isPending = remote.pending
                    continue
                }
                let categorized = categorizer.categorize(
                    name: remote.name, merchant: remote.merchant_name ?? "", amount: remote.amount,
                    plaidPrimary: remote.category_primary, plaidDetailed: remote.category_detailed,
                    accountKind: account?.kind ?? .checking
                )
                let transaction = Transaction(name: remote.name, merchant: remote.merchant_name ?? "", amount: remote.amount, date: date, kind: categorized.kind)
                transaction.plaidTransactionID = remote.transaction_id
                transaction.plaidCategory = remote.category_detailed
                transaction.isPending = remote.pending
                context.insert(transaction)
                transaction.account = account
                transaction.category = categorized.category
                transaction.needsCategoryReview = transaction.kind == .expense && !categorized.isConfident
                if !remote.pending, transaction.kind == .expense || transaction.kind == .contribution || transaction.kind == .transfer,
                   let item = detector.item(for: transaction, in: recurring) {
                    detector.apply(transaction, to: item, categories: categories)
                }
                byPlaidID[remote.transaction_id] = transaction
            }
            for removedID in result.removed {
                if let transaction = byPlaidID.removeValue(forKey: removedID) {
                    context.delete(transaction)
                }
            }
            if let item = items.first(where: { $0.itemID == result.item_id }) {
                item.cursor = result.next_cursor
                item.lastSynced = .now
                item.lastError = ""
            }
        }
    }

    /// Adds newly found subscriptions and bills for you to review.
    private func detectRecurring(context: ModelContext) {
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let recurring = (try? context.fetch(FetchDescriptor<RecurringItem>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let detector = RecurringDetector()
        for candidate in detector.detect(in: transactions, existing: recurring) {
            let item = RecurringItem(
                name: candidate.name, amount: candidate.amount, frequency: candidate.frequency, kind: candidate.kind,
                nextDueDate: candidate.frequency.advance(candidate.lastDate), matchText: candidate.merchantKey
            )
            item.needsReview = true
            item.lastChargedDate = candidate.lastDate
            item.previousAmount = candidate.previousAmount ?? 0
            if candidate.kind == .payYourselfFirst {
                // Point retirement transfers at your Roth IRA if you have one.
                let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
                item.destinationAccountID = accounts.first { $0.kind == .rothIRA }?.id
                item.systemImage = "leaf.fill"
            }
            context.insert(item)
            // Link the history so price-change tracking and budgets work right away.
            for transaction in transactions where transaction.recurringItem == nil
                && (transaction.kind == .expense || transaction.kind == .contribution)
                && detector.matches(key: transaction.displayName.merchantKey, item: item) && transaction.amount > 0 {
                transaction.recurringItem = item
            }
            CategoryRole.applyGroup(for: item, categories: categories)
        }
    }

    /// Creates a pay schedule from detected paychecks if you haven't set one up.
    private func inferPaySchedule(context: ModelContext) {
        guard ((try? context.fetch(FetchDescriptor<PaySchedule>())) ?? []).isEmpty else { return }
        let paychecks = ((try? context.fetch(FetchDescriptor<Transaction>())) ?? [])
            .filter { $0.kind == .income }
            .sorted { $0.date < $1.date }
        guard paychecks.count >= 2, let last = paychecks.last else { return }
        let gaps = zip(paychecks.dropFirst(), paychecks).map { $0.date.timeIntervalSince($1.date) / 86_400 }
        let medianGap = gaps.sorted()[gaps.count / 2]
        let frequency = [Frequency.weekly, .biweekly, .semimonthly, .monthly].min { abs($0.approximateDays - medianGap) < abs($1.approximateDays - medianGap) } ?? .biweekly
        let schedule = PaySchedule(employerName: last.displayName, frequency: frequency, anchorPayDate: last.date, estimatedAmount: -last.amount, matchText: last.displayName.merchantKey)
        context.insert(schedule)
    }

    private static func kind(for account: PlaidService.RemoteAccount) -> AccountKind {
        let subtype = (account.subtype ?? "").lowercased()
        switch account.type {
        case "depository":
            return subtype == "savings" || subtype == "money market" || subtype == "cd" ? .savings : .checking
        case "credit":
            return .creditCard
        case "investment":
            if subtype.contains("401") || subtype.contains("403") { return .retirement401k }
            if subtype.contains("roth") { return .rothIRA }
            return .brokerage
        default:
            return .other
        }
    }

    // MARK: Housekeeping

    /// Work that runs after every launch and sync, with or without Plaid:
    /// rolls past-due recurring items forward, refreshes reminders, and updates the widget.
    static func performHousekeeping(context: ModelContext) {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let recurring = (try? context.fetch(FetchDescriptor<RecurringItem>())) ?? []
        for item in recurring where item.nextDueDate < startOfToday {
            item.rollForward(past: startOfToday.addingTimeInterval(-1))
        }
        try? context.save()

        let engine = FinanceEngine.fetch(from: context)
        SnapshotStore.write(engine: engine)
        Task { await NotificationService.shared.reschedule(recurring: recurring, engine: engine) }
    }
}

extension FinanceEngine {
    /// Builds an engine straight from the store (for services, intents, and the advisor).
    static func fetch(from context: ModelContext) -> FinanceEngine {
        FinanceEngine(
            accounts: (try? context.fetch(FetchDescriptor<Account>())) ?? [],
            transactions: (try? context.fetch(FetchDescriptor<Transaction>())) ?? [],
            categories: (try? context.fetch(FetchDescriptor<Category>())) ?? [],
            recurring: (try? context.fetch(FetchDescriptor<RecurringItem>())) ?? [],
            goals: (try? context.fetch(FetchDescriptor<Goal>())) ?? [],
            schedule: (try? context.fetch(FetchDescriptor<PaySchedule>()))?.first
        )
    }
}
