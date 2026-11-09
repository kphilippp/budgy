import Foundation

/// Decides the kind and spending group of an incoming transaction.
struct Categorizer {
    var categories: [Category]
    var rules: [MerchantRule]
    var schedule: PaySchedule?

    struct Result {
        var kind: TransactionKind
        var category: Category?
        /// False when Budgy is guessing; the transaction goes to the Sort tab for you to confirm.
        var isConfident: Bool
    }

    /// - Parameters:
    ///   - amount: Plaid convention (positive = money out).
    ///   - plaidPrimary/plaidDetailed: Plaid personal_finance_category values, if any.
    func categorize(name: String, merchant: String, amount: Double, plaidPrimary: String, plaidDetailed: String, accountKind: AccountKind) -> Result {
        let key = (merchant.isEmpty ? name : merchant).merchantKey
        let text = "\(name) \(merchant)".lowercased()

        // 1. Your own rules always win.
        if let rule = rules.first(where: { !$0.merchantKey.isEmpty && key.hasPrefix($0.merchantKey) }) {
            let kind = TransactionKind(rawValue: rule.kindRaw) ?? .expense
            return Result(kind: kind, category: categories.first { $0.id == rule.categoryID }, isConfident: true)
        }

        // 2. Money in.
        if amount < 0 {
            let looksLikePay = plaidPrimary == "INCOME"
                || text.contains("payroll") || text.contains("direct dep") || text.contains("dir dep")
                || (schedule.map { !$0.matchText.isEmpty && text.contains($0.matchText) } ?? false)
            if accountKind == .creditCard { return Result(kind: .creditCardPayment, category: nil, isConfident: true) }
            if looksLikePay { return Result(kind: .income, category: nil, isConfident: true) }
            if plaidPrimary == "TRANSFER_IN" { return Result(kind: .transfer, category: nil, isConfident: true) }
            let guess = group(forPrimary: plaidPrimary, detailed: plaidDetailed, text: text)
            return Result(kind: .refund, category: guess.category, isConfident: true)
        }

        // 3. Money out that isn't spending.
        if plaidDetailed.contains("CREDIT_CARD") || text.contains("card payment") || text.contains("autopay") && text.contains("card") {
            return Result(kind: .creditCardPayment, category: nil, isConfident: true)
        }
        if plaidPrimary == "TRANSFER_OUT" || text.contains("transfer to") {
            if text.contains("schwab") || text.contains("ira") || plaidDetailed.contains("INVESTMENT") || plaidDetailed.contains("RETIREMENT") {
                return Result(kind: .contribution, category: nil, isConfident: true)
            }
            return Result(kind: .transfer, category: nil, isConfident: true)
        }

        let guess = group(forPrimary: plaidPrimary, detailed: plaidDetailed, text: text)
        return Result(kind: .expense, category: guess.category, isConfident: guess.category != nil && guess.confident)
    }

    /// Maps Plaid's categories (or keywords, as a weaker guess) onto your spending groups.
    private func group(forPrimary primary: String, detailed: String, text: String) -> (category: Category?, confident: Bool) {
        let candidates: [String]
        var role = ""
        var confident = true
        switch primary {
        case "FOOD_AND_DRINK":
            candidates = detailed.contains("GROCER") ? ["Groceries"] : ["Dining Out", "Dining", "Food"]
        case "TRANSPORTATION":
            candidates = ["Gas & Transportation", "Transportation", "Gas", "Car"]
        case "RENT_AND_UTILITIES":
            candidates = ["Bills & Utilities", "Housing", "Rent", "Utilities", "Bills"]
            role = CategoryRole.bills
        case "ENTERTAINMENT":
            candidates = ["Entertainment", "Fun"]
        case "GENERAL_MERCHANDISE", "HOME_IMPROVEMENT":
            candidates = ["Shopping"]
        case "PERSONAL_CARE", "MEDICAL":
            candidates = ["Health", "Personal Care"]
        case "TRAVEL":
            candidates = ["Travel", "Entertainment", "Fun"]
        case "GENERAL_SERVICES", "GOVERNMENT_AND_NON_PROFIT", "BANK_FEES", "LOAN_PAYMENTS":
            // Too broad to be sure; suggest Other and ask.
            candidates = ["Other"]
            confident = false
        default:
            confident = false
            if text.contains("grocery") || text.contains("market") || text.contains("trader joe") || text.contains("whole foods") {
                candidates = ["Groceries"]
            } else if text.contains("shell") || text.contains("chevron") || text.contains("exxon") || text.contains("uber") || text.contains("lyft") || text.contains("parking") {
                candidates = ["Gas & Transportation", "Transportation"]
            } else if text.contains("restaurant") || text.contains("cafe") || text.contains("coffee") || text.contains("starbucks") || text.contains("chipotle") {
                candidates = ["Dining Out", "Dining"]
            } else if text.contains("amazon") || text.contains("target") || text.contains("walmart") {
                candidates = ["Shopping"]
            } else {
                candidates = []
            }
        }
        if !role.isEmpty, let match = categories.first(where: { $0.systemRole == role }) {
            return (match, confident)
        }
        for name in candidates {
            if let match = categories.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return (match, confident)
            }
        }
        return (nil, false)
    }
}

/// Built-in group roles that recurring charges flow into.
enum CategoryRole {
    static let subscriptions = "subscriptions"
    static let bills = "bills"

    static func role(for kind: RecurringKind) -> String? {
        switch kind {
        case .subscription: subscriptions
        case .bill: bills
        case .payYourselfFirst: nil
        }
    }

    /// Puts a recurring item's charges into its Subscriptions or Bills group.
    static func applyGroup(for item: RecurringItem, categories: [Category]) {
        let group = role(for: item.kind).flatMap { role in categories.first { $0.systemRole == role } }
        for transaction in item.transactions ?? [] where transaction.kind == .expense {
            if let group { transaction.category = group }
            transaction.needsCategoryReview = false
        }
        if let group, item.category == nil || item.category?.systemRole.isEmpty == false { item.category = group }
    }
}
