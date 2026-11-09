import Foundation
import SwiftData

// All models give every property a default and keep relationships optional so the
// store stays compatible with CloudKit sync if you turn on iCloud later.

// MARK: - Account

@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var institution: String = ""
    var kindRaw: String = AccountKind.checking.rawValue
    /// Current balance. For credit cards this is the amount owed (positive number).
    var balance: Double = 0
    var mask: String = ""
    var lastUpdated: Date = Date.now
    var sortOrder: Int = 0
    var isHidden: Bool = false
    var isSample: Bool = false

    // Credit card details (Plaid's base products don't include due dates).
    var creditLimit: Double = 0
    /// Day of month the card payment is due, 1-31. Zero means unknown.
    var paymentDueDay: Int = 0
    /// Statement balance if you know it; otherwise the full balance is used.
    var statementBalance: Double = 0

    // Plaid linkage. Empty for manual accounts.
    var plaidAccountID: String = ""
    var plaidItemID: String = ""

    @Relationship(deleteRule: .nullify, inverse: \Transaction.account)
    var transactions: [Transaction]? = []

    @Relationship(deleteRule: .cascade, inverse: \BalanceSnapshot.account)
    var snapshots: [BalanceSnapshot]? = []

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var isLinked: Bool { !plaidAccountID.isEmpty }

    /// Balance as it contributes to net worth (liabilities are negative).
    var signedBalance: Double { kind.isLiability ? -balance : balance }

    init(name: String, institution: String = "", kind: AccountKind, balance: Double, mask: String = "", isSample: Bool = false) {
        self.name = name
        self.institution = institution
        self.kindRaw = kind.rawValue
        self.balance = balance
        self.mask = mask
        self.isSample = isSample
    }

    /// The next date this card's payment is due, if a due day is set.
    func nextPaymentDueDate(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        guard kind == .creditCard, (1...31).contains(paymentDueDay) else { return nil }
        let today = calendar.startOfDay(for: date)
        for monthOffset in 0...1 {
            guard let month = calendar.date(byAdding: .month, value: monthOffset, to: today) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: month)
            let daysInMonth = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
            parts.day = min(paymentDueDay, daysInMonth)
            if let due = calendar.date(from: parts), due >= today { return due }
        }
        return nil
    }

    /// Records today's balance for the net worth history, replacing any snapshot from today.
    func recordSnapshot(in context: ModelContext, on date: Date = .now) {
        let day = Calendar.current.startOfDay(for: date)
        if let existing = snapshots?.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            existing.balance = signedBalance
        } else {
            let snapshot = BalanceSnapshot(date: day, balance: signedBalance)
            context.insert(snapshot)
            snapshot.account = self
        }
    }
}

// MARK: - BalanceSnapshot

@Model
final class BalanceSnapshot {
    var date: Date = Date.now
    /// Signed balance (negative for liabilities).
    var balance: Double = 0
    var account: Account?

    init(date: Date, balance: Double) {
        self.date = date
        self.balance = balance
    }
}

// MARK: - Category

@Model
final class Category {
    var id: UUID = UUID()
    var name: String = ""
    var systemImage: String = "tag.fill"
    var colorName: String = "blue"
    /// How much you plan to spend in this category each paycheck.
    var budgetPerPaycheck: Double = 0
    var sortOrder: Int = 0
    var isSample: Bool = false
    /// Marks built-in groups that recurring charges flow into ("subscriptions", "bills"), even if renamed.
    var systemRole: String = ""

    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction]? = []

    init(name: String, systemImage: String, colorName: String, budgetPerPaycheck: Double, sortOrder: Int = 0, isSample: Bool = false) {
        self.name = name
        self.systemImage = systemImage
        self.colorName = colorName
        self.budgetPerPaycheck = budgetPerPaycheck
        self.sortOrder = sortOrder
        self.isSample = isSample
    }
}

// MARK: - Transaction

@Model
final class Transaction {
    var id: UUID = UUID()
    var name: String = ""
    var merchant: String = ""
    /// Positive = money out, negative = money in (Plaid's convention).
    var amount: Double = 0
    var date: Date = Date.now
    var kindRaw: String = TransactionKind.expense.rawValue
    var isPending: Bool = false
    var notes: String = ""
    var isSample: Bool = false
    /// For paychecks: whether you've already decided where the extra (overtime) pay goes.
    var extraPayHandled: Bool = false
    /// Budgy wasn't sure which spending group this belongs to; it shows up in the Sort tab.
    var needsCategoryReview: Bool = false

    var plaidTransactionID: String = ""
    /// Plaid's personal finance category, kept for re-categorizing later.
    var plaidCategory: String = ""

    var account: Account?
    var category: Category?
    var recurringItem: RecurringItem?

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// Money that leaves you as spending.
    var spendingAmount: Double {
        switch kind {
        case .expense: max(amount, 0)
        case .refund: -abs(amount)
        default: 0
        }
    }

    var displayName: String { merchant.isEmpty ? name : merchant }

    init(name: String, merchant: String = "", amount: Double, date: Date, kind: TransactionKind, isSample: Bool = false) {
        self.name = name
        self.merchant = merchant
        self.amount = amount
        self.date = date
        self.kindRaw = kind.rawValue
        self.isSample = isSample
    }
}

// MARK: - RecurringItem

/// A bill, subscription, or Pay Yourself First transfer that repeats on a schedule.
@Model
final class RecurringItem {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    /// The amount before the most recent price change, for increase alerts.
    var previousAmount: Double = 0
    var frequencyRaw: String = Frequency.monthly.rawValue
    var kindRaw: String = RecurringKind.subscription.rawValue
    var nextDueDate: Date = Date.now
    var isActive: Bool = true
    /// Detected automatically and waiting for you to confirm.
    var needsReview: Bool = false
    var systemImage: String = "repeat.circle.fill"
    /// Lowercased text used to match incoming transactions to this item.
    var matchText: String = ""
    var remindDaysBefore: Int = 2
    var lastChargedDate: Date?
    var isSample: Bool = false

    /// For Pay Yourself First: the account the money goes to (e.g. Roth IRA).
    var destinationAccountID: UUID?

    var category: Category?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.recurringItem)
    var transactions: [Transaction]? = []

    var frequency: Frequency {
        get { Frequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    var kind: RecurringKind {
        get { RecurringKind(rawValue: kindRaw) ?? .subscription }
        set { kindRaw = newValue.rawValue }
    }

    var monthlyCost: Double { amount * frequency.occurrencesPerYear / 12 }
    var yearlyCost: Double { amount * frequency.occurrencesPerYear }

    /// Only subscriptions get price alerts; bills like utilities vary naturally.
    var hasPriceIncrease: Bool { kind == .subscription && previousAmount > 0 && amount > previousAmount + 0.009 }

    init(name: String, amount: Double, frequency: Frequency, kind: RecurringKind, nextDueDate: Date, systemImage: String? = nil, matchText: String = "", isSample: Bool = false) {
        self.name = name
        self.amount = amount
        self.frequencyRaw = frequency.rawValue
        self.kindRaw = kind.rawValue
        self.nextDueDate = nextDueDate
        self.systemImage = systemImage ?? kind.systemImage
        self.matchText = matchText.isEmpty ? name.lowercased() : matchText.lowercased()
        self.isSample = isSample
    }

    /// All due dates in `[start, end)`, walking from `nextDueDate`.
    func dueDates(from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        guard isActive, !needsReview, end > start else { return [] }
        let startDay = calendar.startOfDay(for: start)
        var dates: [Date] = []
        var cursor = calendar.startOfDay(for: nextDueDate)
        var guardCount = 0
        // Step back before the window, then forward into it, so the anchor can be anywhere.
        while cursor >= startDay && guardCount < 400 {
            cursor = frequency.retreat(cursor, calendar: calendar)
            guardCount += 1
        }
        while cursor < startDay && guardCount < 800 {
            cursor = frequency.advance(cursor, calendar: calendar)
            guardCount += 1
        }
        while cursor < end && guardCount < 1200 {
            dates.append(cursor)
            cursor = frequency.advance(cursor, calendar: calendar)
            guardCount += 1
        }
        return dates
    }

    /// Unpaid occurrences from `nextDueDate` up to (not including) `end`.
    /// Used for Safe to Spend, where already-paid charges must not be counted again.
    func upcomingDueDates(through end: Date, calendar: Calendar = .current) -> [Date] {
        guard isActive, !needsReview else { return [] }
        var dates: [Date] = []
        var cursor = calendar.startOfDay(for: nextDueDate)
        var guardCount = 0
        while cursor < end && guardCount < 400 {
            dates.append(cursor)
            cursor = frequency.advance(cursor, calendar: calendar)
            guardCount += 1
        }
        return dates
    }

    /// Moves `nextDueDate` forward past `date`.
    func rollForward(past date: Date, calendar: Calendar = .current) {
        var guardCount = 0
        while nextDueDate <= date && guardCount < 400 {
            nextDueDate = frequency.advance(nextDueDate, calendar: calendar)
            guardCount += 1
        }
    }
}

// MARK: - Goal

/// Something you're saving for. Money stays in your savings account;
/// the goal just earmarks part of it.
@Model
final class Goal {
    var id: UUID = UUID()
    var name: String = ""
    var systemImage: String = "star.fill"
    var colorName: String = "purple"
    var targetAmount: Double = 0
    /// Earmarked so far.
    var savedAmount: Double = 0
    var deadline: Date?
    var contributionPerPaycheck: Double = 0
    /// Start date of the pay period you last funded this goal for.
    var lastFundedPeriodStart: Date?
    var createdAt: Date = Date.now
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var isSample: Bool = false

    var progress: Double {
        guard targetAmount > 0 else { return 0 }
        return min(savedAmount / targetAmount, 1)
    }

    var remaining: Double { max(targetAmount - savedAmount, 0) }
    var isComplete: Bool { targetAmount > 0 && savedAmount >= targetAmount }

    init(name: String, systemImage: String, colorName: String, targetAmount: Double, savedAmount: Double = 0, deadline: Date? = nil, contributionPerPaycheck: Double = 0, isSample: Bool = false) {
        self.name = name
        self.systemImage = systemImage
        self.colorName = colorName
        self.targetAmount = targetAmount
        self.savedAmount = savedAmount
        self.deadline = deadline
        self.contributionPerPaycheck = contributionPerPaycheck
        self.isSample = isSample
    }

    func isFunded(forPeriodStarting periodStart: Date) -> Bool {
        guard let lastFundedPeriodStart else { return false }
        return Calendar.current.isDate(lastFundedPeriodStart, inSameDayAs: periodStart)
    }
}

// MARK: - PaySchedule

/// Your paycheck schedule. Budgy budgets on a conservative base amount so
/// overtime becomes a bonus instead of something you depend on.
@Model
final class PaySchedule {
    var id: UUID = UUID()
    var employerName: String = "Paycheck"
    var frequencyRaw: String = Frequency.biweekly.rawValue
    /// Any known payday, used as the anchor for computing all others.
    var anchorPayDate: Date = Date.now
    /// Your estimate of a normal check (used until Budgy has seen 3+ paychecks).
    var estimatedAmount: Double = 0
    /// If set (> 0), always use this as the base paycheck.
    var baseAmountOverride: Double = 0
    /// Lowercased text that identifies paycheck deposits, e.g. "acme payroll".
    var matchText: String = ""
    var isSample: Bool = false

    var frequency: Frequency {
        get { Frequency(rawValue: frequencyRaw) ?? .biweekly }
        set { frequencyRaw = newValue.rawValue }
    }

    init(employerName: String, frequency: Frequency, anchorPayDate: Date, estimatedAmount: Double, matchText: String = "", isSample: Bool = false) {
        self.employerName = employerName
        self.frequencyRaw = frequency.rawValue
        self.anchorPayDate = anchorPayDate
        self.estimatedAmount = estimatedAmount
        self.matchText = matchText.lowercased()
        self.isSample = isSample
    }
}

// MARK: - PlaidItem

/// One bank login connected through Plaid. The access token lives on your relay server, not here.
@Model
final class PlaidItem {
    var itemID: String = ""
    var institutionName: String = ""
    /// Cursor for /transactions/sync so each sync only fetches changes.
    var cursor: String = ""
    var lastSynced: Date?
    var isInvestments: Bool = false
    var lastError: String = ""

    init(itemID: String, institutionName: String, isInvestments: Bool) {
        self.itemID = itemID
        self.institutionName = institutionName
        self.isInvestments = isInvestments
    }
}

// MARK: - MerchantRule

/// Remembers the category you chose for a merchant so future transactions follow it.
@Model
final class MerchantRule {
    var merchantKey: String = ""
    var categoryID: UUID?
    var kindRaw: String = TransactionKind.expense.rawValue

    init(merchantKey: String, categoryID: UUID?, kind: TransactionKind) {
        self.merchantKey = merchantKey
        self.categoryID = categoryID
        self.kindRaw = kind.rawValue
    }
}

extension String {
    /// Normalizes a merchant name for matching: lowercased, digits and punctuation stripped.
    var merchantKey: String {
        let lowered = lowercased()
        let allowed = lowered.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(allowed))
            .split(separator: " ")
            .prefix(3)
            .joined(separator: " ")
    }
}

/// All model types, for building the container.
enum BudgySchema {
    static let models: [any PersistentModel.Type] = [
        Account.self, BalanceSnapshot.self, Category.self, Transaction.self,
        RecurringItem.self, Goal.self, PaySchedule.self, PlaidItem.self, MerchantRule.self
    ]
}
