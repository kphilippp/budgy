import Foundation

/// What SyncService needs from a bank connection. Plaid (via your relay) and the Demo Bank both provide it.
protocol BankDataSource {
    func accounts() async throws -> (accounts: [PlaidService.RemoteAccount], errors: [PlaidService.ItemError])
    func syncTransactions(cursors: [String: String]) async throws -> [PlaidService.ItemSync]
    func removeItem(_ itemID: String) async throws
}

extension PlaidService: BankDataSource {}

/// A fake bank that answers exactly like the Plaid relay would, so you can test the full
/// sync pipeline (categorizing, paycheck detection, subscription detection) in the simulator.
///
/// Data is generated relative to today and is deterministic per day, so syncing again
/// only adds new days instead of duplicating history.
struct DemoBankService: BankDataSource {
    static let checkingItemID = "demo-item-wellsfargo"
    static let cardItemID = "demo-item-capitalone"
    static let investmentsItemID = "demo-item-schwab"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.demoBankEnabled) }

    /// The "logins" the Demo Bank pretends you connected.
    static let linkedItems: [PlaidService.LinkedItem] = [
        .init(item_id: checkingItemID, institution_name: "Wells Fargo (Demo)", is_investments: false),
        .init(item_id: cardItemID, institution_name: "Capital One (Demo)", is_investments: false),
        .init(item_id: investmentsItemID, institution_name: "Charles Schwab (Demo)", is_investments: true)
    ]

    private static let checkingID = "demo-acct-checking"
    private static let savingsID = "demo-acct-savings"
    private static let cardID = "demo-acct-card"

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: BankDataSource

    func accounts() async throws -> (accounts: [PlaidService.RemoteAccount], errors: [PlaidService.ItemError]) {
        try await Task.sleep(for: .milliseconds(400)) // feel like a network call
        let accounts: [PlaidService.RemoteAccount] = [
            .init(item_id: Self.checkingItemID, institution_name: "Wells Fargo (Demo)", account_id: Self.checkingID,
                  name: "Everyday Checking", official_name: nil, mask: "0042", type: "depository", subtype: "checking",
                  current: 2_148.66, available: 2_148.66, limit: nil),
            .init(item_id: Self.checkingItemID, institution_name: "Wells Fargo (Demo)", account_id: Self.savingsID,
                  name: "Way2Save Savings", official_name: nil, mask: "7781", type: "depository", subtype: "savings",
                  current: 6_420.00, available: 6_420.00, limit: nil),
            .init(item_id: Self.cardItemID, institution_name: "Capital One (Demo)", account_id: Self.cardID,
                  name: "Quicksilver", official_name: nil, mask: "3319", type: "credit", subtype: "credit card",
                  current: 612.45, available: 4_387.55, limit: 5_000),
            .init(item_id: Self.investmentsItemID, institution_name: "Charles Schwab (Demo)", account_id: "demo-acct-roth",
                  name: "Roth IRA", official_name: nil, mask: "5560", type: "investment", subtype: "roth",
                  current: 9_842.55, available: nil, limit: nil),
            .init(item_id: Self.investmentsItemID, institution_name: "Charles Schwab (Demo)", account_id: "demo-acct-401k",
                  name: "Workplace 401(k)", official_name: nil, mask: "1187", type: "investment", subtype: "401k",
                  current: 21_406.10, available: nil, limit: nil)
        ]
        return (accounts, [])
    }

    func syncTransactions(cursors: [String: String]) async throws -> [PlaidService.ItemSync] {
        try await Task.sleep(for: .milliseconds(600))
        let today = Calendar.current.startOfDay(for: .now)
        let all = Self.generate(through: today)
        let todayString = Self.formatter.string(from: today)

        return [Self.checkingItemID, Self.cardItemID].map { itemID in
            let accountIDs: Set<String> = itemID == Self.cardItemID ? [Self.cardID] : [Self.checkingID, Self.savingsID]
            // The cursor is the last day already delivered; only send newer days.
            let cursor = cursors[itemID] ?? ""
            let added = all.filter { accountIDs.contains($0.account_id) && (cursor.isEmpty || $0.date > cursor) }
            return PlaidService.ItemSync(item_id: itemID, added: added, modified: [], removed: [], next_cursor: todayString, error: nil)
        }
    }

    func removeItem(_ itemID: String) async throws {}

    // MARK: Data generation

    private struct Recurring {
        var name: String
        var merchant: String
        var amount: Double
        var dayOfMonth: Int
        var account: String
        var primary: String
        var detailed: String
    }

    private static let monthly: [Recurring] = [
        .init(name: "OAKWOOD APARTMENTS RENT", merchant: "Oakwood Apartments", amount: 1_250, dayOfMonth: 1, account: checkingID, primary: "RENT_AND_UTILITIES", detailed: "RENT_AND_UTILITIES_RENT"),
        .init(name: "PG&E WEB ONLINE", merchant: "PG&E", amount: 0, dayOfMonth: 18, account: checkingID, primary: "RENT_AND_UTILITIES", detailed: "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY"),
        .init(name: "VERIZON WIRELESS PAYMENT", merchant: "Verizon", amount: 65, dayOfMonth: 12, account: checkingID, primary: "RENT_AND_UTILITIES", detailed: "RENT_AND_UTILITIES_TELEPHONE"),
        .init(name: "GEICO AUTO INSURANCE", merchant: "GEICO", amount: 132, dayOfMonth: 25, account: checkingID, primary: "GENERAL_SERVICES", detailed: "GENERAL_SERVICES_INSURANCE"),
        .init(name: "NETFLIX.COM", merchant: "Netflix", amount: 15.49, dayOfMonth: 9, account: cardID, primary: "ENTERTAINMENT", detailed: "ENTERTAINMENT_TV_AND_MOVIES"),
        .init(name: "SPOTIFY USA", merchant: "Spotify", amount: 11.99, dayOfMonth: 14, account: cardID, primary: "ENTERTAINMENT", detailed: "ENTERTAINMENT_MUSIC_AND_AUDIO"),
        .init(name: "APPLE.COM/BILL", merchant: "Apple iCloud", amount: 2.99, dayOfMonth: 3, account: cardID, primary: "GENERAL_SERVICES", detailed: "GENERAL_SERVICES_OTHER_GENERAL_SERVICES"),
        .init(name: "HULU 877-8244858", merchant: "Hulu", amount: 9.99, dayOfMonth: 27, account: cardID, primary: "ENTERTAINMENT", detailed: "ENTERTAINMENT_TV_AND_MOVIES"),
        .init(name: "OPENAI *CHATGPT SUBSCR", merchant: "ChatGPT", amount: 20, dayOfMonth: 20, account: cardID, primary: "GENERAL_SERVICES", detailed: "GENERAL_SERVICES_OTHER_GENERAL_SERVICES"),
        .init(name: "YOUTUBEPREMIUM GOOGLE", merchant: "YouTube Premium", amount: 13.99, dayOfMonth: 6, account: cardID, primary: "ENTERTAINMENT", detailed: "ENTERTAINMENT_TV_AND_MOVIES"),
        // Price goes up partway through the history to exercise price-increase alerts.
        .init(name: "PLANET FITNESS CLUB FEES", merchant: "Planet Fitness", amount: 39.99, dayOfMonth: 5, account: cardID, primary: "PERSONAL_CARE", detailed: "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS")
    ]

    private static let everyday: [(name: String, merchant: String, range: ClosedRange<Double>, chance: Double, primary: String, detailed: String)] = [
        ("TRADER JOE'S #123", "Trader Joe's", 35...95, 0.20, "FOOD_AND_DRINK", "FOOD_AND_DRINK_GROCERIES"),
        ("SAFEWAY #1871", "Safeway", 18...70, 0.12, "FOOD_AND_DRINK", "FOOD_AND_DRINK_GROCERIES"),
        ("CHIPOTLE 2291", "Chipotle", 11...19, 0.14, "FOOD_AND_DRINK", "FOOD_AND_DRINK_FAST_FOOD"),
        ("STARBUCKS STORE 0455", "Starbucks", 5...9, 0.22, "FOOD_AND_DRINK", "FOOD_AND_DRINK_COFFEE"),
        ("DOORDASH*THAI BASIL", "DoorDash", 22...41, 0.06, "FOOD_AND_DRINK", "FOOD_AND_DRINK_RESTAURANT"),
        ("SHELL OIL 5744", "Shell", 38...60, 0.10, "TRANSPORTATION", "TRANSPORTATION_GAS"),
        ("UBER *TRIP", "Uber", 11...28, 0.05, "TRANSPORTATION", "TRANSPORTATION_TAXIS_AND_RIDE_SHARES"),
        ("AMAZON MKTPL*2K4", "Amazon", 12...90, 0.10, "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_ONLINE_MARKETPLACES"),
        ("TARGET 00012", "Target", 18...75, 0.06, "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_SUPERSTORES"),
        ("AMC THEATRES 2211", "AMC Theatres", 15...34, 0.04, "ENTERTAINMENT", "ENTERTAINMENT_TV_AND_MOVIES"),
        ("STEAMGAMES.COM", "Steam", 9...45, 0.03, "ENTERTAINMENT", "ENTERTAINMENT_VIDEO_GAMES"),
        ("CVS/PHARMACY #4410", "CVS", 7...32, 0.04, "MEDICAL", "MEDICAL_PHARMACIES_AND_SUPPLEMENTS"),
        // Vague merchants Budgy can't group on its own; they land in the Sort tab.
        ("SQ *BLUE BOTTLE", "SQ *Blue Bottle", 6...14, 0.05, "", ""),
        ("PAYPAL *EBAYSELLER", "PayPal eBay", 15...60, 0.03, "", ""),
        ("VENMO *J SMITH", "Venmo J Smith", 10...45, 0.03, "", ""),
        ("CITY OF SF PARKING", "SF Parking", 4...18, 0.03, "GOVERNMENT_AND_NON_PROFIT", "GOVERNMENT_AND_NON_PROFIT_OTHER")
    ]

    /// Every transaction from ~120 days ago through `today`.
    static func generate(through today: Date) -> [PlaidService.RemoteTransaction] {
        let calendar = Calendar.current
        var result: [PlaidService.RemoteTransaction] = []

        func add(_ id: String, _ date: Date, _ name: String, _ merchant: String?, _ amount: Double, _ account: String, _ primary: String, _ detailed: String) {
            let day = formatter.string(from: date)
            result.append(.init(transaction_id: "demo-\(id)-\(day)", account_id: account, amount: amount.rounded(toPlaces: 2),
                                date: day, name: name, merchant_name: merchant, pending: false,
                                category_primary: primary, category_detailed: detailed))
        }

        // Biweekly Friday paychecks with varying overtime, plus a Roth IRA transfer each payday.
        let weekday = calendar.component(.weekday, from: today)
        var payday = calendar.date(byAdding: .day, value: -((weekday + 1) % 7), to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -120, to: today) ?? today
        var payIndex = 0
        while payday >= start {
            var random = SeededRandom(seed: dayNumber(payday))
            let overtime = payIndex == 0 ? 312.40 : (random.next(in: 0...1) < 0.4 ? random.next(in: 60...260) : 0)
            add("payroll", payday, "ACME CORP PAYROLL DIRECT DEP", "Acme Corp", -(2_400 + overtime), checkingID, "INCOME", "INCOME_WAGES")
            add("roth", payday, "SCHWAB BROKERAGE TRANSFER ROTH IRA", "Charles Schwab", 250, checkingID, "TRANSFER_OUT", "TRANSFER_OUT_INVESTMENT_AND_RETIREMENT_FUNDS")
            payday = calendar.date(byAdding: .day, value: -14, to: payday) ?? start
            payIndex += 1
        }

        for offset in stride(from: -120, through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let dayOfMonth = calendar.component(.day, from: date)
            var random = SeededRandom(seed: dayNumber(date))

            // Monthly bills and subscriptions.
            for item in monthly where item.dayOfMonth == dayOfMonth {
                var amount = item.amount
                if item.merchant == "PG&E" { amount = random.next(in: 64...102) }
                if item.merchant == "Planet Fitness" && offset < -45 { amount = 34.99 }
                add(item.merchant.merchantKey.replacingOccurrences(of: " ", with: "-"), date, item.name, item.merchant, amount, item.account, item.primary, item.detailed)
            }

            // Card autopay from checking, mirrored as a payment on the card.
            if dayOfMonth == 22 {
                let payment = random.next(in: 420...760)
                add("cardpay-out", date, "CAPITAL ONE AUTOPAY PYMT", "Capital One", payment, checkingID, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
                add("cardpay-in", date, "CAPITAL ONE AUTOPAY PYMT - THANK YOU", "Capital One", -payment, cardID, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
            }

            // Monthly transfer to savings.
            if dayOfMonth == 2 {
                add("sav-out", date, "ONLINE TRANSFER TO WAY2SAVE SAVINGS", nil, 200, checkingID, "TRANSFER_OUT", "TRANSFER_OUT_SAVINGS")
                add("sav-in", date, "ONLINE TRANSFER FROM EVERYDAY CHECKING", nil, -200, savingsID, "TRANSFER_IN", "TRANSFER_IN_SAVINGS")
            }

            // Everyday spending, split between the card and checking.
            for (index, merchant) in everyday.enumerated() where random.next(in: 0...1) < merchant.chance {
                let amount = random.next(in: merchant.range)
                let account = random.next(in: 0...1) < 0.6 ? cardID : checkingID
                add("spend\(index)", date, merchant.name, merchant.merchant, amount, account, merchant.primary, merchant.detailed)
            }
        }
        return result
    }

    private static func dayNumber(_ date: Date) -> UInt64 {
        UInt64(max(date.timeIntervalSince1970 / 86_400, 0).rounded()) &* 2_654_435_761
    }
}
