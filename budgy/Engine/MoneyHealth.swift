import Foundation

// Domain rules for saving, investing, credit, and subscriptions.
// See .claude/skills/budgy-finance/SKILL.md for the reasoning behind every threshold here.

// MARK: - Credit

/// How a utilization ratio reads to scoring models. The effect is non-linear.
enum UtilizationBand: Comparable {
    case excellent, good, fair, high, veryHigh

    init(_ ratio: Double) {
        switch ratio {
        case ..<0.10: self = .excellent
        case ..<0.30: self = .good
        case ..<0.50: self = .fair
        case ..<0.70: self = .high
        default: self = .veryHigh
        }
    }

    var title: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .fair: "Fair"
        case .high: "High"
        case .veryHigh: "Very high"
        }
    }

    /// Under 30% is fine; everything above is worth working on.
    var needsAttention: Bool { self >= .fair }
}

struct CreditSnapshot {
    /// Visible cards that have a credit limit set.
    var cards: [Account]
    var cardsMissingLimit: Int
    var totalBalance: Double
    var totalLimit: Double
    /// Interest charged on cards over the last 90 days.
    var interestPaid90Days: Double
    /// Late fees over the last 12 months — a sign a reported late payment may be close.
    var lateFees12Months: Double

    var overallUtilization: Double? { totalLimit > 0 ? totalBalance / totalLimit : nil }
    var overallBand: UtilizationBand? { overallUtilization.map(UtilizationBand.init) }

    /// Cards over 30%, worst first — pay these down first because per-card utilization counts on its own.
    var cardsOverTarget: [Account] {
        cards.filter { $0.utilizationPaymentNeeded > 0 }.sorted { $0.utilization > $1.utilization }
    }

    /// Total to pay before statements close so every card reports under 30%.
    var paydownToThirtyPercent: Double { cards.reduce(0) { $0 + $1.utilizationPaymentNeeded } }

    /// Total to pay so overall utilization reports under 10% (the stretch target).
    var paydownToTenPercent: Double { max(totalBalance - totalLimit * 0.09, 0) }
}

// MARK: - Emergency fund

struct EmergencyFundStatus {
    /// Savings counted as emergency money.
    var amount: Double
    var monthlySpending: Double
    /// True when monthly spending comes from bills and budgets instead of real history.
    var spendingIsEstimated: Bool

    static let solidMonths = 3.0
    static let fullMonths = 6.0

    var monthsCovered: Double { monthlySpending > 0 ? amount / monthlySpending : 0 }
    /// The smaller of $1,000 or one month of spending.
    var starterTarget: Double { monthlySpending > 0 ? min(1_000, monthlySpending) : 1_000 }
    var solidTarget: Double { monthlySpending * Self.solidMonths }
    var fullTarget: Double { monthlySpending * Self.fullMonths }

    var hasStarterCushion: Bool { amount >= starterTarget }
    var isSolid: Bool { monthlySpending > 0 && monthsCovered >= Self.solidMonths }
}

// MARK: - Next-dollar ladder

/// The single most useful thing to do with spare money right now.
struct MoneyStep: Identifiable {
    enum Kind: Int, CaseIterable {
        case starterCushion = 1, stopCardInterest, emergencyFund, rothIRA, investMore
    }

    var kind: Kind
    var title: String
    var detail: String
    /// Progress toward this step's target, 0...1, when it has one.
    var progress: Double?
    var systemImage: String

    var id: Int { kind.rawValue }
    var number: Int { kind.rawValue }
    static var stepCount: Int { Kind.allCases.count }
}

// MARK: - Subscription insights

struct SubscriptionInsights {
    struct ChargeAfterCancel: Identifiable {
        var item: RecurringItem
        var transaction: Transaction
        var id: UUID { transaction.id }
    }

    /// Switched off by the user but still being charged. Highest priority.
    var chargedAfterCancel: [ChargeAfterCancel]
    /// Active, but no charge for well over one billing interval — may already be cancelled.
    var noRecentCharge: [RecurringItem]
    /// Yearly and quarterly subscriptions renewing in the next 30 days.
    var renewingSoon: [RecurringItem]

    var isEmpty: Bool { chargedAfterCancel.isEmpty && noRecentCharge.isEmpty && renewingSoon.isEmpty }
}

// MARK: - Engine

extension FinanceEngine {
    private func days(_ value: Int) -> Date {
        calendar.date(byAdding: .day, value: value, to: calendar.startOfDay(for: now)) ?? now
    }

    private func fees(matching category: String, namePhrase: String, since start: Date) -> Double {
        includedTransactions
            .filter { $0.date >= start && $0.amount > 0 }
            .filter { $0.plaidCategory == category || $0.name.lowercased().contains(namePhrase) }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: Credit

    var credit: CreditSnapshot {
        let visible = includedAccounts.filter { $0.kind == .creditCard }
        let withLimit = visible.filter { $0.creditLimit > 0 }
        return CreditSnapshot(
            cards: withLimit.sorted { $0.utilization > $1.utilization },
            cardsMissingLimit: visible.count - withLimit.count,
            totalBalance: withLimit.reduce(0) { $0 + max($1.balance, 0) },
            totalLimit: withLimit.reduce(0) { $0 + $1.creditLimit },
            interestPaid90Days: fees(matching: "BANK_FEES_INTEREST_CHARGE", namePhrase: "interest charge", since: days(-90)),
            lateFees12Months: fees(matching: "BANK_FEES_LATE_PAYMENT", namePhrase: "late fee", since: days(-365))
        )
    }

    // MARK: Emergency fund

    /// What a normal month costs: the trailing 90-day average, or bills + budgets without enough history.
    var monthlySpendingEstimate: (amount: Double, isEstimated: Bool) {
        let start = days(-90)
        let window = includedTransactions.filter { $0.date >= start && $0.date < days(1) }
        let earliest = includedTransactions.map(\.date).min() ?? now
        let historyDays = calendar.dateComponents([.day], from: earliest, to: now).day ?? 0
        let spent = window.reduce(0) { $0 + $1.spendingAmount }
        if historyDays >= 60, spent > 0 {
            let coveredDays = Double(min(historyDays, 90))
            return (spent / coveredDays * 30.44, false)
        }
        let fixed = recurring
            .filter { $0.isActive && !$0.needsReview && $0.kind != .payYourselfFirst }
            .reduce(0) { $0 + $1.monthlyCost }
        let budgets = categories.filter { $0.systemRole.isEmpty }.reduce(0) { $0 + $1.monthlyBudget }
        return (fixed + budgets, true)
    }

    var emergencyFund: EmergencyFundStatus {
        let savings = includedAccounts.filter { $0.kind == .savings }.reduce(0) { $0 + $1.balance }
        let activeGoals = goals.filter { !$0.isArchived }
        let emergencyGoals = activeGoals.filter { $0.name.localizedCaseInsensitiveContains("emergency") }
        let otherEarmarks = activeGoals.filter { goal in !emergencyGoals.contains { $0.id == goal.id } }
            .reduce(0) { $0 + $1.savedAmount }
        // Money earmarked for a trip isn't emergency money; an "Emergency fund" goal is.
        let unearmarked = max(savings - otherEarmarks, 0)
        let fromGoals = emergencyGoals.reduce(0) { $0 + $1.savedAmount }
        let estimate = monthlySpendingEstimate
        return EmergencyFundStatus(
            amount: emergencyGoals.isEmpty ? unearmarked : min(fromGoals, unearmarked),
            monthlySpending: estimate.amount,
            spendingIsEstimated: estimate.isEstimated
        )
    }

    // MARK: Next-dollar ladder

    func nextMoneyStep(rothLimit: Double) -> MoneyStep {
        let fund = emergencyFund
        let credit = self.credit

        if !fund.hasStarterCushion {
            return MoneyStep(
                kind: .starterCushion,
                title: "Build a \(fund.starterTarget.currencyWhole) starter cushion",
                detail: "\((fund.starterTarget - fund.amount).currencyWhole) to go. A small cushion keeps a surprise bill off your credit card.",
                progress: fund.starterTarget > 0 ? min(fund.amount / fund.starterTarget, 1) : nil,
                systemImage: "lifepreserver.fill"
            )
        }

        if credit.interestPaid90Days > 0.5 || creditCardOwed > spendableCash + 1 {
            let detail = credit.interestPaid90Days > 0.5
                ? "You paid \(credit.interestPaid90Days.currency) in card interest over the last 90 days. Paying the full statement balance each month stops it, and that beats any investment return."
                : "Card balances are higher than your checking cash. Pay cards in full each month before investing, because card interest costs more than investments earn."
            return MoneyStep(kind: .stopCardInterest, title: "Stop paying card interest", detail: detail, progress: nil, systemImage: "creditcard.fill")
        }

        if !fund.isSolid {
            return MoneyStep(
                kind: .emergencyFund,
                title: "Grow your emergency fund to 3 months",
                detail: "\(fund.monthsCovered.formatted(.number.precision(.fractionLength(1)))) of 3 months covered. \((fund.solidTarget - fund.amount).currencyWhole) to go.",
                progress: min(fund.monthsCovered / EmergencyFundStatus.solidMonths, 1),
                systemImage: "shield.lefthalf.filled"
            )
        }

        let rothRemaining = max(rothLimit - rothProjectedThisYear, 0)
        if rothLimit > 0, rothRemaining > 1 {
            let endOfYear = calendar.dateInterval(of: .year, for: now)?.end ?? now
            let paydaysLeft = max(payCycle.paydays(from: now, to: endOfYear).count, 1)
            return MoneyStep(
                kind: .rothIRA,
                title: "Max out your Roth IRA",
                detail: "\(rothRemaining.currencyWhole) of room left this year, about \((rothRemaining / Double(paydaysLeft)).currencyWhole) per paycheck. If your employer matches 401(k) contributions, make sure you're getting the full match first.",
                progress: min(rothProjectedThisYear / rothLimit, 1),
                systemImage: "leaf.fill"
            )
        }

        return MoneyStep(
            kind: .investMore,
            title: "Invest more",
            detail: "Emergency fund and Roth are on track. Consider raising your savings rate or 401(k) contribution, or investing in low-cost index funds.",
            progress: nil,
            systemImage: "chart.line.uptrend.xyaxis"
        )
    }

    // MARK: Subscriptions

    var subscriptionInsights: SubscriptionInsights {
        let detector = RecurringDetector()
        let soon = days(30)

        let cancelled = recurring.filter { !$0.isActive && $0.kind == .subscription && $0.cancelledAt != nil }
        var afterCancel: [SubscriptionInsights.ChargeAfterCancel] = []
        for item in cancelled {
            guard let cancelledAt = item.cancelledAt,
                  let graceEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cancelledAt)) else { continue }
            let match = includedTransactions
                .filter { $0.kind == .expense && $0.amount > 0 && $0.date >= graceEnd }
                .filter { detector.matches(key: $0.displayName.merchantKey, item: item) }
                .filter { abs($0.amount - item.amount) <= max(item.amount * 0.3, 2) }
                .max { $0.date < $1.date }
            if let match { afterCancel.append(.init(item: item, transaction: match)) }
        }

        let noRecent = activeSubscriptions.filter { item in
            guard let last = item.lastChargedDate else { return false }
            let quietDays = now.timeIntervalSince(last) / 86_400
            return quietDays > item.frequency.approximateDays * 1.6 + 7
        }

        let renewing = activeSubscriptions
            .filter { ($0.frequency == .yearly || $0.frequency == .quarterly) && $0.nextDueDate <= soon }
            .sorted { $0.nextDueDate < $1.nextDueDate }

        return SubscriptionInsights(
            chargedAfterCancel: afterCancel.sorted { $0.transaction.date > $1.transaction.date },
            noRecentCharge: noRecent,
            renewingSoon: renewing
        )
    }
}
