import Foundation

/// The monthly budget, which runs from the day you pay your credit card off to the same day next month.
struct MonthlySpendResult {
    var period: PayPeriod
    var safeUntilDate: Date
    /// Current included checking and savings cash.
    var cash: Double
    /// Current balances owed across included credit cards.
    var cardOwed: Double
    /// Unpaid bills, subscriptions, and Pay Yourself First transfers remaining in the period.
    var upcoming: Double
    var billReserve: Double
    var plannedSavings: Double
    /// Base pay expected before the end of the period.
    var expectedIncome: Double
    /// Goal contributions still reserved before the end of the period.
    var goalReserve: Double
    /// Cash deliberately left untouched in checking.
    var checkingBuffer: Double
    var income: Double
    var incomeIsEstimated: Bool
    var bills: Double
    var subscriptions: Double
    var payYourselfFirst: Double
    var goals: Double
    /// Everyday spending so far this budget month (bills and subscriptions are counted above).
    var spent: Double
    /// Bills, subscriptions, and transfers scheduled this budget month, for the breakdown sheet.
    var scheduled: [UpcomingCharge]

    var fixedTotal: Double { bills + subscriptions + payYourselfFirst + goals }
    /// Cash left after paying cards and remaining commitments, including expected base pay.
    var left: Double { cash - cardOwed - upcoming - goalReserve - checkingBuffer + expectedIncome }

    var daysRemaining: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: safeUntilDate).day ?? 0
        return max(days, 1)
    }

    var perDay: Double { max(left, 0) / Double(daysRemaining) }
}

extension FinanceEngine {
    // MARK: Budget month

    /// How many paychecks Budgy counts on per budget month. A third biweekly check is treated as extra pay.
    var paychecksPerMonth: Int {
        switch schedule?.frequency ?? .biweekly {
        case .weekly: 4
        case .biweekly, .semimonthly: 2
        case .monthly, .quarterly, .yearly: 1
        }
    }

    /// The day of the month you usually pay your card off, from your card payments.
    var detectedBudgetCycleDay: Int? {
        let payments = includedTransactions
            .filter { $0.kind == .creditCardPayment && $0.amount > 0 }
            .sorted { $0.date > $1.date }
            .prefix(6)
        guard !payments.isEmpty else { return nil }
        let days = payments.map { calendar.component(.day, from: $0.date) }
        // The most common payment day; ties go to the most recent.
        let counts = Dictionary(grouping: days, by: { $0 }).mapValues(\.count)
        return days.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
    }

    /// The day the budget month starts: your setting, else detected from card payments, else the card's due day, else the 1st.
    var budgetCycleDay: Int {
        if let day = schedule?.budgetCycleDay, day > 0 { return day }
        if let detected = detectedBudgetCycleDay { return detected }
        if let due = includedAccounts.first(where: { $0.kind == .creditCard && $0.paymentDueDay > 0 })?.paymentDueDay { return due }
        return 1
    }

    /// The budget month containing today, or `offset` months away.
    func budgetMonth(offset: Int = 0) -> PayPeriod {
        func anchor(in month: Date) -> Date {
            var parts = calendar.dateComponents([.year, .month], from: month)
            let length = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
            parts.day = min(budgetCycleDay, length)
            return calendar.date(from: parts) ?? month
        }
        let today = calendar.startOfDay(for: now)
        var start = anchor(in: today)
        if start > today {
            start = anchor(in: calendar.date(byAdding: .month, value: -1, to: today) ?? today)
        }
        if offset != 0 {
            start = anchor(in: calendar.date(byAdding: .month, value: offset, to: start) ?? start)
        }
        let end = anchor(in: calendar.date(byAdding: .month, value: 1, to: start) ?? start)
        return PayPeriod(start: start, end: end)
    }

    // MARK: Monthly income

    /// Base paycheck × paychecks per month, from the paychecks deposited to your checking account.
    var detectedMonthlyIncome: Double { basePaycheck * Double(paychecksPerMonth) }

    var monthlyIncome: Double {
        if let override = schedule?.monthlyIncomeOverride, override > 0 { return override }
        return detectedMonthlyIncome
    }

    // MARK: Monthly Safe to Spend

    func monthlySpend(offset: Int = 0) -> MonthlySpendResult {
        let period = budgetMonth(offset: offset)
        var scheduled: [UpcomingCharge] = []
        var totals: [RecurringKind: Double] = [:]

        // Charges Budgy found but you haven't reviewed yet still count, so the budget stays conservative.
        for item in recurring where item.isActive {
            var dates = item.dueDates(from: period.start, to: period.end, includingUnreviewed: true)
            // Per-paycheck transfers follow your paychecks: a bonus third paycheck covers its own transfer.
            if item.kind == .payYourselfFirst, item.frequency == (schedule?.frequency ?? .biweekly) {
                dates = Array(dates.prefix(paychecksPerMonth))
            }
            for due in dates {
                totals[item.kind, default: 0] += item.amount
                let source: UpcomingCharge.Source = switch item.kind {
                case .bill: .bill
                case .subscription: .subscription
                case .payYourselfFirst: .payYourselfFirst
                }
                scheduled.append(UpcomingCharge(name: item.name, amount: item.amount, date: due, source: source, systemImage: item.systemImage))
            }
        }

        let goals = self.goals
            .filter { !$0.isArchived && !$0.isComplete }
            .reduce(0) { $0 + $1.contributionPerPaycheck * Double(paychecksPerMonth) }

        let end = min(period.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? period.end)
        let spent = includedTransactions
            .filter { $0.date >= period.start && $0.date < end && $0.recurringItem == nil }
            .reduce(0) { $0 + $1.spendingAmount }
        let safe = safeToSpend()

        return MonthlySpendResult(
            period: period,
            safeUntilDate: safe.untilDate,
            cash: safe.cash,
            cardOwed: safe.cardOwed,
            upcoming: safe.upcomingTotal,
            billReserve: safe.billReserve,
            plannedSavings: safe.savingsReserve,
            expectedIncome: safe.expectedIncome,
            goalReserve: safe.goalReserve,
            checkingBuffer: safe.checkingBuffer,
            income: monthlyIncome,
            incomeIsEstimated: (schedule?.monthlyIncomeOverride ?? 0) <= 0,
            bills: totals[.bill] ?? 0,
            subscriptions: totals[.subscription] ?? 0,
            payYourselfFirst: totals[.payYourselfFirst] ?? 0,
            goals: goals,
            spent: spent,
            scheduled: scheduled.sorted { $0.date < $1.date }
        )
    }
}
