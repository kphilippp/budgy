import Foundation
import FoundationModels

/// An immutable, precomputed picture of your finances that the Advisor's tools read from.
/// Built on the main actor from `FinanceEngine`, then handed to tools that may run anywhere.
nonisolated struct FinanceContext: Sendable {
    struct AccountInfo: Sendable { var name: String; var kind: String; var balance: Double }
    struct GoalInfo: Sendable { var name: String; var saved: Double; var target: Double; var perPaycheck: Double; var deadline: Date?; var neededPerPaycheck: Double? }
    struct RecurringInfo: Sendable { var name: String; var kind: String; var amount: Double; var frequency: String; var nextDate: Date; var priceIncreasedFrom: Double? }
    struct SpendingInfo: Sendable { var category: String; var amount: Double }
    struct BudgetInfo: Sendable { var category: String; var budget: Double; var spent: Double }

    var today: Date
    var safeToSpendUntilPayday: Double
    var nextPayday: Date
    var basePaycheck: Double
    var payFrequency: String
    var netWorth: Double
    var checking: Double
    var creditCardOwed: Double
    var accounts: [AccountInfo]
    var goals: [GoalInfo]
    var recurring: [RecurringInfo]
    var spendingByPeriod: [String: [SpendingInfo]]
    var budgetThisPaycheck: [BudgetInfo]
    /// Safe to Spend if you were to stop at each of the next 90 days (index = days from today).
    var safeToSpendByDay: [Double]
    var rothYTD: Double
    var rothProjected: Double
    var rothLimit: Double
    var monthlySubscriptions: Double

    func dateString(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

    /// A short summary included directly in the instructions so the model always has the basics.
    var briefing: String {
        """
        Today is \(dateString(today)). Safe to Spend until next payday (\(dateString(nextPayday))): \(money(safeToSpendUntilPayday)). \
        Base paycheck: \(money(basePaycheck)) \(payFrequency). Checking: \(money(checking)). Credit card owed: \(money(creditCardOwed)). \
        Net worth: \(money(netWorth)). Subscriptions: \(money(monthlySubscriptions))/month.
        """
    }
}

extension FinanceEngine {
    func advisorContext(rothLimit: Double) -> FinanceContext {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }

        let thisPaycheck = paycheckBreakdown()
        let periods: [(String, Date, Date)] = [
            ("thisPaycheck", currentPeriod.start, day(1)),
            ("lastPaycheck", payCycle.period(offset: -1, from: now).start, currentPeriod.start),
            ("thisMonth", PayPeriod.month(containing: now).start, day(1)),
            ("lastMonth", PayPeriod.month(containing: now, offset: -1).start, PayPeriod.month(containing: now).start),
            ("last90Days", day(-90), day(1))
        ]
        var spending: [String: [FinanceContext.SpendingInfo]] = [:]
        for (key, start, end) in periods {
            spending[key] = self.spending(from: start, to: end).map { .init(category: $0.category, amount: $0.amount) }
        }

        return FinanceContext(
            today: today,
            safeToSpendUntilPayday: safeToSpend().amount,
            nextPayday: nextPayday,
            basePaycheck: basePaycheck,
            payFrequency: (schedule?.frequency ?? .biweekly).displayName.lowercased(),
            netWorth: netWorth,
            checking: spendableCash,
            creditCardOwed: creditCardOwed,
            accounts: accounts.filter { !$0.isHidden }.map { .init(name: $0.name, kind: $0.kind.displayName, balance: $0.balance) },
            goals: goals.filter { !$0.isArchived }.map {
                .init(name: $0.name, saved: $0.savedAmount, target: $0.targetAmount, perPaycheck: $0.contributionPerPaycheck,
                      deadline: $0.deadline, neededPerPaycheck: requiredPerPaycheck(for: $0))
            },
            recurring: recurring.filter { $0.isActive && !$0.needsReview }.map {
                .init(name: $0.name, kind: $0.kind.displayName, amount: $0.amount, frequency: $0.frequency.displayName,
                      nextDate: $0.nextDueDate, priceIncreasedFrom: $0.hasPriceIncrease ? $0.previousAmount : nil)
            },
            spendingByPeriod: spending,
            budgetThisPaycheck: thisPaycheck.categories.map { .init(category: $0.name, budget: $0.planned, spent: $0.actual) },
            safeToSpendByDay: (0...90).map { safeToSpend(until: day(max($0, 1))).amount },
            rothYTD: rothContributionsThisYear,
            rothProjected: rothProjectedThisYear,
            rothLimit: rothLimit,
            monthlySubscriptions: subscriptionsMonthlyTotal
        )
    }
}

// MARK: - Tools

nonisolated struct OverviewTool: Tool {
    let finance: FinanceContext
    let name = "getFinancialOverview"
    let description = "Gets account balances, net worth, Safe to Spend, and the next payday."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let accounts = finance.accounts.map { "\($0.name) (\($0.kind)): \(finance.money($0.balance))" }.joined(separator: "; ")
        return finance.briefing + " Accounts: " + accounts
    }
}

@Generable
enum SpendingPeriod: String {
    case thisPaycheck, lastPaycheck, thisMonth, lastMonth, last90Days
}

nonisolated struct SpendingTool: Tool {
    let finance: FinanceContext
    let name = "getSpending"
    let description = "Gets spending totals by category for a period, plus this paycheck's category budgets."

    @Generable
    struct Arguments {
        @Guide(description: "Which period to look at")
        var period: SpendingPeriod
    }

    func call(arguments: Arguments) async throws -> String {
        let rows = finance.spendingByPeriod[arguments.period.rawValue] ?? []
        let total = rows.reduce(0) { $0 + $1.amount }
        var text = "Spending \(arguments.period.rawValue): total \(finance.money(total)). "
        text += rows.prefix(10).map { "\($0.category) \(finance.money($0.amount))" }.joined(separator: ", ")
        if arguments.period == .thisPaycheck {
            let budgets = finance.budgetThisPaycheck.filter { $0.budget > 0 }
                .map { "\($0.category): spent \(finance.money($0.spent)) of \(finance.money($0.budget))" }
                .joined(separator: "; ")
            text += ". Budgets: " + budgets
        }
        return text
    }
}

nonisolated struct GoalsTool: Tool {
    let finance: FinanceContext
    let name = "getGoals"
    let description = "Gets savings goals with progress, per-paycheck contributions, and deadlines."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        guard !finance.goals.isEmpty else { return "No savings goals yet." }
        return finance.goals.map { goal in
            var line = "\(goal.name): \(finance.money(goal.saved)) of \(finance.money(goal.target)), \(finance.money(goal.perPaycheck)) per paycheck"
            if let deadline = goal.deadline { line += ", deadline \(finance.dateString(deadline))" }
            if let needed = goal.neededPerPaycheck { line += ", needs \(finance.money(needed)) per paycheck to finish on time" }
            return line
        }.joined(separator: ". ")
    }
}

nonisolated struct RecurringTool: Tool {
    let finance: FinanceContext
    let name = "getBillsAndSubscriptions"
    let description = "Gets recurring bills, subscriptions, and Pay Yourself First transfers with amounts and next dates."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let lines = finance.recurring.map { item in
            var line = "\(item.name) (\(item.kind)) \(finance.money(item.amount)) \(item.frequency.lowercased()), next \(finance.dateString(item.nextDate))"
            if let old = item.priceIncreasedFrom { line += ", price went up from \(finance.money(old))" }
            return line
        }
        return "Subscriptions total \(finance.money(finance.monthlySubscriptions))/month. " + lines.joined(separator: "; ")
    }
}

nonisolated struct AffordabilityTool: Tool {
    let finance: FinanceContext
    let name = "checkAffordability"
    let description = "Checks whether a purchase is affordable by comparing it with Safe to Spend on a date."

    @Generable
    struct Arguments {
        @Guide(description: "Purchase amount in dollars")
        var amount: Double
        @Guide(description: "Days from today until the purchase or until money is needed. Use 0 for today.", .range(0...90))
        var daysFromNow: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let index = min(max(arguments.daysFromNow, 0), finance.safeToSpendByDay.count - 1)
        // Safe to Spend through the payday after the purchase date is the honest comparison.
        let through = min(index + 14, finance.safeToSpendByDay.count - 1)
        let available = finance.safeToSpendByDay[max(index, 1)]
        let laterAvailable = finance.safeToSpendByDay[through]
        let after = available - arguments.amount
        return """
        Safe to Spend through day \(index): \(finance.money(available)). After a \(finance.money(arguments.amount)) purchase: \(finance.money(after)). \
        Two weeks later (including base pay): \(finance.money(laterAvailable - arguments.amount)). \
        \(after >= 0 ? "Affordable without touching bills or goals." : "Not affordable yet without cutting into bills, Roth, or goal money.")
        """
    }
}

nonisolated struct RetirementTool: Tool {
    let finance: FinanceContext
    let name = "getRetirement"
    let description = "Gets Roth IRA contributions this year versus the IRS limit, and retirement balances."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let balances = finance.accounts.filter { $0.kind == "Roth IRA" || $0.kind == "401(k)" || $0.kind == "Brokerage" }
            .map { "\($0.name) \(finance.money($0.balance))" }.joined(separator: ", ")
        return "Roth IRA contributed this year: \(finance.money(finance.rothYTD)) of \(finance.money(finance.rothLimit)) limit; projected by Dec 31: \(finance.money(finance.rothProjected)). Balances: \(balances)."
    }
}

// MARK: - Structured paycheck plan

@Generable
struct PaycheckPlan {
    @Guide(description: "Two or three friendly sentences explaining the plan")
    var summary: String
    @Guide(description: "How much to put toward each existing goal per paycheck", .count(1...6))
    var allocations: [GoalAllocation]
}

@Generable
struct GoalAllocation {
    @Guide(description: "Exact name of one of the user's existing goals")
    var goalName: String
    @Guide(description: "Dollars per paycheck", .range(0...2000))
    var amountPerPaycheck: Int
    @Guide(description: "A short reason")
    var reason: String
}
