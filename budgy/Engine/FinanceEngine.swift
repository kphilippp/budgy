import Foundation

/// A single upcoming obligation that Safe to Spend sets aside.
struct UpcomingCharge: Identifiable {
    enum Source { case bill, subscription, payYourselfFirst, creditCard, goal }

    let id = UUID()
    var name: String
    var amount: Double
    var date: Date
    var source: Source
    var systemImage: String
}

/// The full Safe to Spend calculation, kept itemized so the UI can explain itself.
struct SafeToSpendResult {
    var untilDate: Date
    var cash: Double
    var cardOwed: Double
    var upcoming: [UpcomingCharge]
    var expectedIncome: Double
    var paydaysBeforeDate: Int
    var goalReserve: Double

    var upcomingTotal: Double { upcoming.filter { $0.source != .creditCard && $0.source != .goal }.reduce(0) { $0 + $1.amount } }

    var amount: Double { cash - cardOwed - upcomingTotal - goalReserve + expectedIncome }

    var daysRemaining: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: untilDate)).day ?? 0
        return max(days, 1)
    }

    var dailyAllowance: Double { max(amount, 0) / Double(daysRemaining) }
}

/// One line of the paycheck waterfall.
struct BudgetLine: Identifiable {
    let id = UUID()
    var name: String
    var planned: Double
    var actual: Double
    var systemImage: String
    var colorName: String
}

/// Where a paycheck (or a month of paychecks) goes.
struct BudgetBreakdown {
    var period: PayPeriod
    var paydayCount: Int
    var expectedIncome: Double
    var actualIncome: Double
    var payYourselfFirst: [BudgetLine]
    var bills: [BudgetLine]
    var subscriptions: [BudgetLine]
    var goals: [BudgetLine]
    var categories: [BudgetLine]
    var uncategorizedSpent: Double

    /// Use money actually received once it arrives; until then, the base paycheck.
    var income: Double { actualIncome > 0 ? actualIncome : expectedIncome }

    var payYourselfFirstTotal: Double { payYourselfFirst.reduce(0) { $0 + $1.planned } }
    var billsTotal: Double { bills.reduce(0) { $0 + $1.planned } }
    var subscriptionsTotal: Double { subscriptions.reduce(0) { $0 + $1.planned } }
    var goalsTotal: Double { goals.reduce(0) { $0 + $1.planned } }
    var categoryBudgetTotal: Double { categories.reduce(0) { $0 + $1.planned } }
    var categorySpentTotal: Double { categories.reduce(0) { $0 + $1.actual } + uncategorizedSpent }

    var fixedTotal: Double { payYourselfFirstTotal + billsTotal + subscriptionsTotal + goalsTotal }

    /// What's left after fixed costs and what you've actually spent so far.
    var leftOver: Double { income - fixedTotal - categorySpentTotal }

    /// What would be left if you spend exactly your category budgets.
    var plannedLeftOver: Double { income - fixedTotal - categoryBudgetTotal }
}

/// Pure calculations over your data. Views build one from their queries.
struct FinanceEngine {
    var accounts: [Account]
    var transactions: [Transaction]
    var categories: [Category]
    var recurring: [RecurringItem]
    var goals: [Goal]
    var schedule: PaySchedule?
    var now: Date = .now
    var calendar: Calendar = .current

    // MARK: Paychecks

    var payCycle: PayCycle {
        if let schedule { return PayCycle(schedule: schedule, calendar: calendar) }
        return PayCycle(frequency: .biweekly, anchor: now, calendar: calendar)
    }

    var currentPeriod: PayPeriod { payCycle.period(containing: now) }
    var nextPayday: Date { currentPeriod.end }

    var paychecks: [Transaction] {
        transactions.filter { $0.kind == .income }.sorted { $0.date > $1.date }
    }

    /// A conservative "normal" paycheck: the lower quartile of your last 6 checks,
    /// so overtime spikes don't inflate your budget.
    var basePaycheck: Double {
        if let schedule, schedule.baseAmountOverride > 0 { return schedule.baseAmountOverride }
        let recent = paychecks.prefix(6).map { -$0.amount }.filter { $0 > 0 }.sorted()
        if recent.count >= 3 {
            let index = Int((Double(recent.count - 1) * 0.25).rounded(.down))
            return recent[index]
        }
        return schedule?.estimatedAmount ?? recent.last ?? 0
    }

    /// Paychecks with pay above your base that you haven't assigned yet.
    var unassignedExtraPay: [(transaction: Transaction, extra: Double)] {
        let base = basePaycheck
        guard base > 0 else { return [] }
        let threshold = max(25, base * 0.03)
        let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        return paychecks
            .filter { !$0.extraPayHandled && $0.date >= cutoff }
            .compactMap { paycheck in
                let extra = -paycheck.amount - base
                return extra >= threshold ? (paycheck, extra.rounded(toPlaces: 2)) : nil
            }
    }

    // MARK: Safe to Spend

    var spendableCash: Double {
        accounts.filter { $0.kind.isSpendableCash && !$0.isHidden }.reduce(0) { $0 + $1.balance }
    }

    var creditCardOwed: Double {
        accounts.filter { $0.kind == .creditCard && !$0.isHidden }.reduce(0) { $0 + $1.balance }
    }

    /// Goal contributions for the current period you haven't marked as moved yet.
    var unfundedGoalsThisPeriod: [Goal] {
        goals.filter { !$0.isArchived && !$0.isComplete && $0.contributionPerPaycheck > 0 && !$0.isFunded(forPeriodStarting: currentPeriod.start) }
    }

    func safeToSpend(until date: Date? = nil) -> SafeToSpendResult {
        let until = calendar.startOfDay(for: date ?? nextPayday)
        let today = calendar.startOfDay(for: now)
        var upcoming: [UpcomingCharge] = []

        for item in recurring {
            for due in item.upcomingDueDates(through: until) where due >= today {
                let source: UpcomingCharge.Source = switch item.kind {
                case .bill: .bill
                case .subscription: .subscription
                case .payYourselfFirst: .payYourselfFirst
                }
                upcoming.append(UpcomingCharge(name: item.name, amount: item.amount, date: due, source: source, systemImage: item.systemImage))
            }
        }

        // Card purchases already count as spent, so reserve the whole card balance.
        for card in accounts where card.kind == .creditCard && !card.isHidden && card.balance > 0 {
            let due = card.nextPaymentDueDate(after: now) ?? until
            upcoming.append(UpcomingCharge(name: "\(card.name) payment", amount: card.balance, date: due, source: .creditCard, systemImage: "creditcard.fill"))
        }

        // Future paydays before the target date bring in base pay but also goal contributions.
        let futurePaydays = payCycle.paydays(from: calendar.date(byAdding: .day, value: 1, to: today) ?? today, to: until)
        let goalPerPaycheck = goals.filter { !$0.isArchived && !$0.isComplete }.reduce(0) { $0 + $1.contributionPerPaycheck }
        let currentGoalReserve = unfundedGoalsThisPeriod.reduce(0) { $0 + $1.contributionPerPaycheck }
        let goalReserve = currentGoalReserve + goalPerPaycheck * Double(futurePaydays.count)

        for goal in unfundedGoalsThisPeriod {
            upcoming.append(UpcomingCharge(name: goal.name, amount: goal.contributionPerPaycheck, date: today, source: .goal, systemImage: goal.systemImage))
        }

        return SafeToSpendResult(
            untilDate: until,
            cash: spendableCash,
            cardOwed: creditCardOwed,
            upcoming: upcoming.sorted { $0.date < $1.date },
            expectedIncome: basePaycheck * Double(futurePaydays.count),
            paydaysBeforeDate: futurePaydays.count,
            goalReserve: goalReserve
        )
    }

    // MARK: Budget breakdown

    func paycheckBreakdown(offset: Int = 0) -> BudgetBreakdown {
        let period = payCycle.period(offset: offset, from: now)
        return breakdown(for: period, categoryFactor: 1)
    }

    func monthlyBreakdown(offset: Int = 0) -> BudgetBreakdown {
        let period = PayPeriod.month(containing: now, offset: offset, calendar: calendar)
        let perYear = schedule?.frequency.occurrencesPerYear ?? 26
        return breakdown(for: period, categoryFactor: perYear / 12)
    }

    private func breakdown(for period: PayPeriod, categoryFactor: Double) -> BudgetBreakdown {
        let paydays = payCycle.paydays(from: period.start, to: period.end)
        let inPeriod = transactions.filter { period.contains($0.date) }

        func lines(_ kind: RecurringKind) -> [BudgetLine] {
            recurring.filter { $0.kind == kind && $0.isActive && !$0.needsReview }.compactMap { item in
                let count = item.dueDates(from: period.start, to: period.end).count
                guard count > 0 else { return nil }
                let paid = inPeriod.filter { $0.recurringItem?.id == item.id }.reduce(0) { $0 + abs($1.amount) }
                return BudgetLine(name: item.name, planned: item.amount * Double(count), actual: paid, systemImage: item.systemImage, colorName: kind == .payYourselfFirst ? "green" : "orange")
            }
        }

        let goalLines = goals.filter { !$0.isArchived && $0.contributionPerPaycheck > 0 }.map {
            BudgetLine(name: $0.name, planned: $0.contributionPerPaycheck * Double(paydays.count), actual: 0, systemImage: $0.systemImage, colorName: $0.colorName)
        }

        // Spending tied to a bill or subscription is already counted in those lines.
        let variableSpending = inPeriod.filter { $0.recurringItem == nil }
        let categoryLines = categories.sorted { $0.sortOrder < $1.sortOrder }.map { category in
            let spent = variableSpending.filter { $0.category?.id == category.id }.reduce(0) { $0 + $1.spendingAmount }
            return BudgetLine(name: category.name, planned: category.budgetPerPaycheck * categoryFactor, actual: spent, systemImage: category.systemImage, colorName: category.colorName)
        }
        let uncategorized = variableSpending.filter { $0.category == nil }.reduce(0) { $0 + $1.spendingAmount }

        let actualIncome = inPeriod.filter { $0.kind == .income }.reduce(0) { $0 - $1.amount }

        return BudgetBreakdown(
            period: period,
            paydayCount: paydays.count,
            expectedIncome: basePaycheck * Double(paydays.count),
            actualIncome: max(actualIncome, 0),
            payYourselfFirst: lines(.payYourselfFirst),
            bills: lines(.bill),
            subscriptions: lines(.subscription),
            goals: goalLines,
            categories: categoryLines,
            uncategorizedSpent: uncategorized
        )
    }

    // MARK: Spending window (Home card)

    /// Everyday spending (not bills, subscriptions, or Pay Yourself First) since `start`.
    func discretionarySpent(since start: Date) -> Double {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return transactions
            .filter { $0.date >= start && $0.date < end && $0.recurringItem == nil }
            .reduce(0) { $0 + $1.spendingAmount }
    }

    struct GroupSpend: Identifiable {
        var id: UUID { category?.id ?? Self.uncategorizedID }
        var category: Category?
        var spent: Double
        var budget: Double
        /// Only everyday spending, used for the donut (bills and subscriptions are already set aside).
        var discretionary: Double

        static let uncategorizedID = UUID()
        var name: String { category?.name ?? "Unsorted" }
        var systemImage: String { category?.systemImage ?? "questionmark" }
        var colorName: String { category?.colorName ?? "gray" }
    }

    /// Spending per group since `start`, with budgets scaled to the window length.
    func groupSpending(since start: Date, until date: Date) -> [GroupSpend] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let inWindow = transactions.filter { $0.date >= start && $0.date < end && $0.spendingAmount != 0 }
        let windowDays = Double(max(calendar.dateComponents([.day], from: start, to: date).day ?? 14, 1))
        let periodDays = Double(currentPeriod.dayCount)
        let scale = windowDays / periodDays

        var result = categories.sorted { $0.sortOrder < $1.sortOrder }.map { category in
            let items = inWindow.filter { $0.category?.id == category.id }
            return GroupSpend(
                category: category,
                spent: items.reduce(0) { $0 + $1.spendingAmount },
                budget: category.budgetPerPaycheck * scale,
                discretionary: items.filter { $0.recurringItem == nil }.reduce(0) { $0 + $1.spendingAmount }
            )
        }
        let unsorted = inWindow.filter { $0.category == nil }
        if !unsorted.isEmpty {
            result.append(GroupSpend(category: nil, spent: unsorted.reduce(0) { $0 + $1.spendingAmount }, budget: 0,
                                     discretionary: unsorted.filter { $0.recurringItem == nil }.reduce(0) { $0 + $1.spendingAmount }))
        }
        return result
    }

    /// Transactions Budgy wasn't sure how to group.
    var unsortedTransactions: [Transaction] {
        transactions.filter { $0.needsCategoryReview && $0.kind == .expense }.sorted { $0.date > $1.date }
    }

    // MARK: Spending queries (also used by the Advisor)

    func spending(from start: Date, to end: Date) -> [(category: String, amount: Double)] {
        let inRange = transactions.filter { $0.date >= start && $0.date < end && $0.spendingAmount != 0 }
        let grouped = Dictionary(grouping: inRange) { $0.category?.name ?? ($0.recurringItem?.kind.displayName ?? "Uncategorized") }
        return grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.spendingAmount }) }
            .sorted { $0.amount > $1.amount }
    }

    // MARK: Accounts & retirement

    var netWorth: Double { accounts.filter { !$0.isHidden }.reduce(0) { $0 + $1.signedBalance } }

    /// Roth IRA contributions this calendar year, from Pay Yourself First transfers into Roth accounts.
    var rothContributionsThisYear: Double {
        let rothIDs = Set(accounts.filter { $0.kind == .rothIRA }.map(\.id))
        let year = calendar.component(.year, from: now)
        return transactions
            .filter { $0.kind == .contribution && calendar.component(.year, from: $0.date) == year }
            .filter { txn in
                guard let destination = txn.recurringItem?.destinationAccountID else { return rothIDs.isEmpty == false }
                return rothIDs.contains(destination)
            }
            .reduce(0) { $0 + abs($1.amount) }
    }

    /// Projected Roth contributions by Dec 31 at the current Pay Yourself First pace.
    var rothProjectedThisYear: Double {
        let rothIDs = Set(accounts.filter { $0.kind == .rothIRA }.map(\.id))
        guard let endOfYear = calendar.dateInterval(of: .year, for: now)?.end else { return rothContributionsThisYear }
        let remaining = recurring
            .filter { $0.kind == .payYourselfFirst && ($0.destinationAccountID.map(rothIDs.contains) ?? false) }
            .reduce(0) { $0 + $1.amount * Double($1.upcomingDueDates(through: endOfYear).count) }
        return rothContributionsThisYear + remaining
    }

    // MARK: Subscriptions

    var activeSubscriptions: [RecurringItem] {
        recurring.filter { $0.kind == .subscription && $0.isActive && !$0.needsReview }
    }

    var subscriptionsMonthlyTotal: Double { activeSubscriptions.reduce(0) { $0 + $1.monthlyCost } }

    // MARK: Goals

    /// Per-paycheck amount needed to hit a goal's deadline.
    func requiredPerPaycheck(for goal: Goal) -> Double? {
        guard let deadline = goal.deadline, goal.remaining > 0 else { return nil }
        let paydays = payCycle.paydays(from: now, to: deadline).count
        return paydays > 0 ? goal.remaining / Double(paydays) : goal.remaining
    }

    /// Estimated completion date at a given per-paycheck contribution.
    func projectedCompletion(for goal: Goal, perPaycheck: Double) -> Date? {
        guard perPaycheck > 0 else { return nil }
        if goal.remaining <= 0 { return now }
        let paychecksNeeded = Int((goal.remaining / perPaycheck).rounded(.up))
        var date = nextPayday
        for _ in 1..<max(paychecksNeeded, 1) { date = payCycle.frequency.advance(date, calendar: calendar) }
        return date
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
