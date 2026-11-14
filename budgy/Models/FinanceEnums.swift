import Foundation

/// The kind of place money lives. Drives icons, colors, and whether a balance
/// counts as an asset or a liability in net worth.
enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case checking
    case savings
    case creditCard
    case retirement401k
    case rothIRA
    case brokerage
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .creditCard: "Credit Card"
        case .retirement401k: "401(k)"
        case .rothIRA: "Roth IRA"
        case .brokerage: "Brokerage"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "building.columns.fill"
        case .savings: "banknote.fill"
        case .creditCard: "creditcard.fill"
        case .retirement401k: "chart.line.uptrend.xyaxis"
        case .rothIRA: "leaf.fill"
        case .brokerage: "chart.bar.fill"
        case .other: "wallet.bifold.fill"
        }
    }

    var isLiability: Bool { self == .creditCard }

    var isInvestment: Bool {
        self == .retirement401k || self == .rothIRA || self == .brokerage
    }

    /// Cash available for day-to-day spending. Savings remains protected.
    var isSpendableCash: Bool { self == .checking }
}

/// How a transaction affects your money. Only `.expense` counts as spending.
enum TransactionKind: String, Codable, CaseIterable, Identifiable {
    case expense
    case income
    case transfer
    case creditCardPayment
    case contribution
    case refund

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expense: "Expense"
        case .income: "Income"
        case .transfer: "Transfer"
        case .creditCardPayment: "Card Payment"
        case .contribution: "Pay Yourself First"
        case .refund: "Refund"
        }
    }
}

/// How often something repeats.
enum Frequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case semimonthly
    case monthly
    case quarterly
    case yearly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 Weeks"
        case .semimonthly: "Twice a Month"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        }
    }

    /// Average number of occurrences per year, used to normalize costs.
    var occurrencesPerYear: Double {
        switch self {
        case .weekly: 52
        case .biweekly: 26
        case .semimonthly: 24
        case .monthly: 12
        case .quarterly: 4
        case .yearly: 1
        }
    }

    /// Approximate days between occurrences, used for recurring-charge detection.
    var approximateDays: Double { 365.25 / occurrencesPerYear }

    /// Returns the next occurrence strictly after `date`.
    func advance(_ date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14, to: date) ?? date
        case .semimonthly:
            // 1st and 15th style: alternate between +15 days and the same day next month.
            let day = calendar.component(.day, from: date)
            if day < 15 {
                return calendar.date(byAdding: .day, value: 15 - day, to: date) ?? date
            } else {
                let nextMonth = calendar.date(byAdding: .month, value: 1, to: date) ?? date
                var parts = calendar.dateComponents([.year, .month, .hour, .minute], from: nextMonth)
                parts.day = 1
                return calendar.date(from: parts) ?? nextMonth
            }
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }

    /// Steps backward one occurrence. Semimonthly is approximated.
    func retreat(_ date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .weekly: calendar.date(byAdding: .day, value: -7, to: date) ?? date
        case .biweekly: calendar.date(byAdding: .day, value: -14, to: date) ?? date
        case .semimonthly: calendar.date(byAdding: .day, value: -15, to: date) ?? date
        case .monthly: calendar.date(byAdding: .month, value: -1, to: date) ?? date
        case .quarterly: calendar.date(byAdding: .month, value: -3, to: date) ?? date
        case .yearly: calendar.date(byAdding: .year, value: -1, to: date) ?? date
        }
    }
}

/// What a recurring item represents.
enum RecurringKind: String, Codable, CaseIterable, Identifiable {
    /// Essential fixed costs: rent, utilities, phone, insurance.
    case bill
    /// Services you could cancel: streaming, apps, memberships.
    case subscription
    /// Money that leaves checking but isn't spending, like a Roth IRA deposit.
    case payYourselfFirst

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bill: "Bill"
        case .subscription: "Subscription"
        case .payYourselfFirst: "Pay Yourself First"
        }
    }

    var systemImage: String {
        switch self {
        case .bill: "doc.text.fill"
        case .subscription: "repeat.circle.fill"
        case .payYourselfFirst: "arrow.up.forward.circle.fill"
        }
    }
}
