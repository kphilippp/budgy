import Foundation
import SwiftData

/// Realistic example data so every screen has something to show before you connect a bank.
/// Everything created here is tagged `isSample` and can be removed in Settings.
enum SampleData {
    static func seedIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKeys.hasSeededSampleData) else { return }
        defaults.set(true, forKey: SettingsKeys.hasSeededSampleData)
        let existing = (try? context.fetchCount(FetchDescriptor<Account>())) ?? 0
        guard existing == 0 else { return }
        seed(context: context)
    }

    static func hasSampleData(context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<Account>(predicate: #Predicate { $0.isSample }))) ?? 0) > 0
    }

    static func removeSampleData(context: ModelContext) {
        try? context.delete(model: Transaction.self, where: #Predicate { $0.isSample })
        try? context.delete(model: RecurringItem.self, where: #Predicate { $0.isSample })
        try? context.delete(model: Goal.self, where: #Predicate { $0.isSample })
        try? context.delete(model: PaySchedule.self, where: #Predicate { $0.isSample })
        // Snapshots cascade from accounts.
        let sampleAccounts = (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.isSample }))) ?? []
        sampleAccounts.forEach(context.delete)
        // Keep the starter categories (they're useful); just clear their sample flag.
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        categories.forEach { $0.isSample = false }
        try? context.save()
    }

    /// Default spending groups, created even without sample data.
    @discardableResult
    static func ensureDefaultCategories(context: ModelContext, isSample: Bool = false) -> [Category] {
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        guard existing.isEmpty else {
            upgradeGroups(context: context, existing: existing)
            return existing
        }
        let defaults: [(String, String, String, Double, String)] = [
            ("Groceries", "cart.fill", "green", 180, ""),
            ("Dining Out", "fork.knife", "orange", 120, ""),
            ("Gas & Transportation", "car.fill", "blue", 90, ""),
            ("Shopping", "bag.fill", "pink", 100, ""),
            ("Subscriptions", "repeat.circle.fill", "purple", 0, CategoryRole.subscriptions),
            ("Bills & Utilities", "bolt.fill", "yellow", 0, CategoryRole.bills),
            ("Entertainment", "sparkles", "indigo", 80, ""),
            ("Health", "heart.fill", "red", 40, ""),
            ("Other", "square.grid.2x2.fill", "teal", 40, "")
        ]
        let categories = defaults.enumerated().map { index, value in
            let category = Category(name: value.0, systemImage: value.1, colorName: value.2, budgetPerPaycheck: value.3, sortOrder: index, isSample: isSample)
            category.systemRole = value.4
            return category
        }
        categories.forEach(context.insert)
        UserDefaults.standard.set(true, forKey: groupsUpgradedKey)
        return categories
    }

    private static let groupsUpgradedKey = "spendingGroupsV2"

    /// One-time upgrade of older installs to spending groups: renames, adds the
    /// Subscriptions and Bills groups, and flags uncategorized spending for the Sort tab.
    private static func upgradeGroups(context: ModelContext, existing: [Category]) {
        guard !UserDefaults.standard.bool(forKey: groupsUpgradedKey) else { return }
        UserDefaults.standard.set(true, forKey: groupsUpgradedKey)

        let renames = ["Transportation": ("Gas & Transportation", "car.fill"), "Dining": ("Dining Out", "fork.knife"), "Fun": ("Entertainment", "sparkles")]
        for category in existing {
            if let rename = renames[category.name] { category.name = rename.0 }
        }
        var all = existing
        let nextOrder = (existing.map(\.sortOrder).max() ?? 0) + 1
        if !existing.contains(where: { $0.systemRole == CategoryRole.subscriptions }) {
            let group = Category(name: "Subscriptions", systemImage: "repeat.circle.fill", colorName: "purple", budgetPerPaycheck: 0, sortOrder: nextOrder)
            group.systemRole = CategoryRole.subscriptions
            context.insert(group)
            all.append(group)
        }
        if !existing.contains(where: { $0.systemRole == CategoryRole.bills }) {
            let group = Category(name: "Bills & Utilities", systemImage: "bolt.fill", colorName: "yellow", budgetPerPaycheck: 0, sortOrder: nextOrder + 1)
            group.systemRole = CategoryRole.bills
            context.insert(group)
            all.append(group)
        }

        let recurring = (try? context.fetch(FetchDescriptor<RecurringItem>())) ?? []
        for item in recurring where item.isActive && !item.needsReview {
            CategoryRole.applyGroup(for: item, categories: all)
        }
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        for transaction in transactions where transaction.kind == .expense && transaction.category == nil && transaction.recurringItem == nil {
            transaction.needsCategoryReview = true
        }
        try? context.save()
    }

    // MARK: - Seed

    private static func seed(context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var random = SeededRandom(seed: 42)

        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }

        // Accounts
        let checking = Account(name: "Everyday Checking", institution: "Chase", kind: .checking, balance: 1_684.27, mask: "4821", isSample: true)
        let savings = Account(name: "High-Yield Savings", institution: "Ally", kind: .savings, balance: 6_250.00, mask: "1190", isSample: true)
        let card = Account(name: "Freedom Unlimited", institution: "Chase", kind: .creditCard, balance: 486.32, mask: "7713", isSample: true)
        card.paymentDueDay = 22
        card.creditLimit = 6_000
        let roth = Account(name: "Roth IRA", institution: "Charles Schwab", kind: .rothIRA, balance: 9_842.55, mask: "3307", isSample: true)
        let k401 = Account(name: "401(k)", institution: "Charles Schwab", kind: .retirement401k, balance: 21_406.10, mask: "9921", isSample: true)
        let accounts = [checking, savings, card, roth, k401]
        for (index, account) in accounts.enumerated() {
            account.sortOrder = index
            context.insert(account)
        }

        // 26 weeks of balance history with gentle growth and noise.
        for account in accounts {
            for week in stride(from: 26, through: 0, by: -1) {
                let growth: Double = switch account.kind {
                case .rothIRA, .retirement401k: 1 - Double(week) * 0.011 + random.next(in: -0.015...0.015)
                case .savings: 1 - Double(week) * 0.008
                case .creditCard: random.next(in: 0.6...1.4)
                default: random.next(in: 0.75...1.25)
                }
                let snapshot = BalanceSnapshot(date: day(-week * 7), balance: account.signedBalance * growth)
                context.insert(snapshot)
                snapshot.account = account
            }
        }

        // Categories
        let categories = ensureDefaultCategories(context: context, isSample: true)
        func category(_ name: String) -> Category? { categories.first { $0.name == name } }

        // Pay schedule: biweekly Fridays, most recent payday within the last 14 days.
        let weekday = calendar.component(.weekday, from: today) // 1 = Sunday, 6 = Friday
        let daysSinceFriday = (weekday + 1) % 7
        let lastPayday = day(-daysSinceFriday)
        let schedule = PaySchedule(employerName: "Acme Corp", frequency: .biweekly, anchorPayDate: lastPayday, estimatedAmount: 2_400, matchText: "acme corp", isSample: true)
        context.insert(schedule)

        // Recurring items
        func monthly(_ dayOfMonth: Int) -> Date {
            var parts = calendar.dateComponents([.year, .month], from: today)
            parts.day = dayOfMonth
            let thisMonth = calendar.date(from: parts) ?? today
            return thisMonth >= today ? thisMonth : (calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? thisMonth)
        }

        let rent = RecurringItem(name: "Rent", amount: 1_250, frequency: .monthly, kind: .bill, nextDueDate: monthly(1), systemImage: "house.fill", matchText: "oakwood apartments", isSample: true)
        let electric = RecurringItem(name: "Electric", amount: 84.20, frequency: .monthly, kind: .bill, nextDueDate: monthly(18), systemImage: "bolt.fill", matchText: "city power", isSample: true)
        let phone = RecurringItem(name: "Phone", amount: 65, frequency: .monthly, kind: .bill, nextDueDate: monthly(12), systemImage: "iphone", matchText: "verizon", isSample: true)
        let insurance = RecurringItem(name: "Car Insurance", amount: 132, frequency: .monthly, kind: .bill, nextDueDate: monthly(25), systemImage: "car.side.fill", matchText: "geico", isSample: true)
        let netflix = RecurringItem(name: "Netflix", amount: 15.49, frequency: .monthly, kind: .subscription, nextDueDate: monthly(9), systemImage: "tv.fill", matchText: "netflix", isSample: true)
        let spotify = RecurringItem(name: "Spotify", amount: 11.99, frequency: .monthly, kind: .subscription, nextDueDate: monthly(14), systemImage: "music.note", matchText: "spotify", isSample: true)
        let icloud = RecurringItem(name: "iCloud+", amount: 2.99, frequency: .monthly, kind: .subscription, nextDueDate: monthly(3), systemImage: "icloud.fill", matchText: "apple com bill", isSample: true)
        let claude = RecurringItem(name: "Claude Pro", amount: 20, frequency: .monthly, kind: .subscription, nextDueDate: monthly(20), systemImage: "sparkles", matchText: "anthropic", isSample: true)
        let gym = RecurringItem(name: "Gym", amount: 39.99, frequency: .monthly, kind: .subscription, nextDueDate: monthly(5), systemImage: "figure.run", matchText: "planet fitness", isSample: true)
        gym.previousAmount = 34.99
        let prime = RecurringItem(name: "Amazon Prime", amount: 139, frequency: .yearly, kind: .subscription, nextDueDate: calendar.date(byAdding: .month, value: 4, to: today) ?? today, systemImage: "shippingbox.fill", matchText: "amazon prime", isSample: true)
        let rothDeposit = RecurringItem(name: "Roth IRA Deposit", amount: 250, frequency: .biweekly, kind: .payYourselfFirst, nextDueDate: schedule.frequency.advance(lastPayday), systemImage: "leaf.fill", matchText: "schwab", isSample: true)
        rothDeposit.destinationAccountID = roth.id

        // A Hulu charge detected from history, waiting for review.
        let hulu = RecurringItem(name: "Hulu", amount: 9.99, frequency: .monthly, kind: .subscription, nextDueDate: monthly(27), systemImage: "play.tv.fill", matchText: "hulu", isSample: true)
        hulu.needsReview = true

        let recurring = [rent, electric, phone, insurance, netflix, spotify, icloud, claude, gym, prime, rothDeposit, hulu]
        recurring.forEach(context.insert)

        // Transactions: ~4 months of history.
        var transactions: [Transaction] = []
        func add(_ name: String, _ amount: Double, _ date: Date, _ kind: TransactionKind, account: Account, category: Category? = nil, recurringItem: RecurringItem? = nil) {
            let transaction = Transaction(name: name, merchant: name, amount: amount, date: date, kind: kind, isSample: true)
            context.insert(transaction)
            transaction.account = account
            transaction.category = category
            transaction.recurringItem = recurringItem
            if kind == .expense, let role = recurringItem.flatMap({ CategoryRole.role(for: $0.kind) }) {
                transaction.category = categories.first { $0.systemRole == role }
            }
            transactions.append(transaction)
        }

        // Paychecks every two weeks; the latest one includes overtime.
        var payday = lastPayday
        for index in 0..<9 {
            let overtime: Double = index == 0 ? 312.40 : (index % 3 == 1 ? random.next(in: 80...240).rounded(toPlaces: 2) : 0)
            add("Acme Corp Payroll", -(2_400 + overtime), payday, .income, account: checking)
            add("Schwab Roth IRA Transfer", 250, payday, .contribution, account: checking, recurringItem: rothDeposit)
            payday = schedule.frequency.retreat(payday)
        }
        transactions.filter { $0.kind == .income }.dropFirst().forEach { $0.extraPayHandled = true }

        // Monthly bills and subscriptions for the last 4 months.
        for monthOffset in 0..<4 {
            for item in [rent, electric, phone, insurance, netflix, spotify, icloud, claude, gym, hulu] {
                let due = calendar.date(byAdding: .month, value: -monthOffset - 1, to: item.nextDueDate) ?? item.nextDueDate
                guard due <= today else { continue }
                var amount = item.amount
                if item === electric { amount = random.next(in: 68...98).rounded(toPlaces: 2) }
                if item === gym && monthOffset >= 2 { amount = 34.99 }
                let paidFrom = item.kind == .subscription ? card : checking
                add(item.matchText.capitalized, amount, due, .expense, account: paidFrom, recurringItem: item.needsReview ? nil : item)
                if item.lastChargedDate == nil || due > (item.lastChargedDate ?? .distantPast) { item.lastChargedDate = due }
            }
        }

        // Everyday spending.
        let merchants: [(String, String, ClosedRange<Double>, Double)] = [
            ("Trader Joe's", "Groceries", 38...92, 0.22),
            ("Safeway", "Groceries", 22...70, 0.12),
            ("Chipotle", "Dining Out", 11...18, 0.14),
            ("Starbucks", "Dining Out", 5...9, 0.2),
            ("Sushi House", "Dining Out", 28...55, 0.05),
            ("Shell", "Gas & Transportation", 38...58, 0.1),
            ("Uber", "Gas & Transportation", 12...26, 0.05),
            ("Amazon", "Shopping", 14...85, 0.1),
            ("Target", "Shopping", 20...70, 0.06),
            ("AMC Theatres", "Entertainment", 16...32, 0.04),
            ("Steam", "Entertainment", 10...40, 0.03),
            ("CVS Pharmacy", "Health", 8...30, 0.04)
        ]
        for offset in stride(from: -120, through: 0, by: 1) {
            for merchant in merchants where random.next(in: 0...1) < merchant.3 {
                let amount = random.next(in: merchant.2).rounded(toPlaces: 2)
                let account = random.next(in: 0...1) < 0.55 ? card : checking
                add(merchant.0, amount, day(offset), .expense, account: account, category: category(merchant.1))
            }
        }

        // A few charges Budgy can't place on its own, for the Sort tab.
        let unsure: [(String, Double, Int)] = [("SQ *CORNER MARKET", 23.40, -1), ("PAYPAL *EBAY SELLER", 41.99, -2), ("VENMO *JORDAN", 30, -3), ("CITY OF OAKLAND PARKING", 12, -4)]
        for (name, amount, offset) in unsure {
            add(name, amount, day(offset), .expense, account: card)
            transactions.last?.needsCategoryReview = true
        }

        // Card payments and a savings transfer each month.
        for monthOffset in 1...4 {
            let date = calendar.date(byAdding: .month, value: -monthOffset, to: monthly(22)) ?? today
            add("Chase Card Payment", random.next(in: 420...780).rounded(toPlaces: 2), date, .creditCardPayment, account: checking)
            add("Chase Card Payment", -random.next(in: 420...780).rounded(toPlaces: 2), date, .creditCardPayment, account: card)
        }

        // Goals
        let japan = Goal(name: "Japan Trip", systemImage: "airplane", colorName: "pink", targetAmount: 3_000, savedAmount: 1_200,
                         deadline: calendar.date(byAdding: .month, value: 7, to: today), contributionPerPaycheck: 150, isSample: true)
        let emergency = Goal(name: "Emergency Fund", systemImage: "cross.case.fill", colorName: "teal", targetAmount: 10_000, savedAmount: 4_200,
                             contributionPerPaycheck: 100, isSample: true)
        let laptop = Goal(name: "New Laptop", systemImage: "laptopcomputer", colorName: "indigo", targetAmount: 1_800, savedAmount: 650, isSample: true)
        for (index, goal) in [japan, emergency, laptop].enumerated() {
            goal.sortOrder = index
            context.insert(goal)
        }

        try? context.save()
    }
}

/// Deterministic random numbers so the sample data looks the same every time.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
