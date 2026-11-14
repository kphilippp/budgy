import Foundation

/// Finds charges that repeat on a schedule (subscriptions and bills) and matches
/// new transactions to the recurring items you already have.
struct RecurringDetector {
    struct Candidate {
        var name: String
        var merchantKey: String
        var amount: Double
        var frequency: Frequency
        var lastDate: Date
        var kind: RecurringKind
        /// The amount charged before the most recent change, if the price moved.
        var previousAmount: Double?
    }

    private static let knownSubscriptions = [
        "netflix", "spotify", "hulu", "disney", "max", "hbo", "apple", "icloud", "youtube", "amazon prime",
        "prime video", "peacock", "paramount", "audible", "adobe", "microsoft", "google", "chatgpt", "openai",
        "anthropic", "claude", "dropbox", "playstation", "xbox", "nintendo", "crunchyroll", "duolingo", "gym",
        "planet fitness", "peloton", "patreon", "siriusxm"
    ]

    private static let knownBills = [
        "rent", "apartment", "electric", "energy", "pge", "edison", "utilit", "water", "gas co", "internet", "comcast", "xfinity", "spectrum", "at&t",
        "verizon", "t-mobile", "insurance", "geico", "progressive", "state farm", "loan", "mortgage"
    ]

    /// Looks at the last ~13 months of spending for merchants charged at a steady interval.
    func detect(in transactions: [Transaction], existing: [RecurringItem], now: Date = .now) -> [Candidate] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: now) ?? now
        // Contributions (e.g. Roth IRA transfers) are included so they can become Pay Yourself First items.
        let outflows = transactions.filter { $0.date >= cutoff && $0.amount > 0 && ($0.kind == .expense || $0.kind == .contribution) && $0.recurringItem == nil }
        let groups = Dictionary(grouping: outflows) { $0.displayName.merchantKey }

        var candidates: [Candidate] = []
        for (key, group) in groups where !key.isEmpty && group.count >= 2 {
            if existing.contains(where: { matches(key: key, item: $0) }) { continue }

            let sorted = group.sorted { $0.date < $1.date }
            let median = Self.median(sorted.map(\.amount))
            // Amounts should be steady (within 20% of the median), or show one step up:
            // a price increase is something to flag, not a reason to miss the subscription.
            let priceStep = Self.priceStep(in: sorted)
            guard sorted.allSatisfy({ abs($0.amount - median) <= median * 0.2 }) || priceStep != nil else { continue }

            let gaps = zip(sorted.dropFirst(), sorted).map { $0.date.timeIntervalSince($1.date) / 86_400 }
            let medianGap = gaps.sorted()[gaps.count / 2]
            guard let frequency = Frequency.allCases.first(where: { abs($0.approximateDays - medianGap) <= max(3, $0.approximateDays * 0.12) }) else { continue }
            // Require 3+ charges for anything shorter than yearly, to avoid coincidences.
            if frequency != .yearly && sorted.count < 3 { continue }

            guard let last = sorted.last else { continue }
            // Skip things that seem to have stopped.
            if now.timeIntervalSince(last.date) / 86_400 > frequency.approximateDays * 1.6 { continue }

            let lowered = key.lowercased()
            // Known utilities and large charges are bills; everything else is treated as a
            // subscription (something you could cancel) so it shows up for review.
            let isKnownSubscription = Self.knownSubscriptions.contains { lowered.contains($0) }
            let isBill = !isKnownSubscription && (Self.knownBills.contains { lowered.contains($0) } || median > 250)
            let kind: RecurringKind = last.kind == .contribution ? .payYourselfFirst : (isBill ? .bill : .subscription)
            let previous = priceStep ?? sorted.dropLast().last { abs($0.amount - last.amount) > 0.009 }?.amount
            candidates.append(Candidate(name: last.displayName, merchantKey: key, amount: last.amount, frequency: frequency,
                                        lastDate: last.date, kind: kind, previousAmount: previous.flatMap { $0 < last.amount ? $0 : nil }))
        }
        return candidates
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// If the charges are steady, then jump once to a new steady higher price (up to double),
    /// returns the old price. Needs at least two charges at the old price.
    private static func priceStep(in sorted: [Transaction]) -> Double? {
        guard let latest = sorted.last?.amount, latest > 0 else { return nil }
        let atNewPrice = sorted.reversed().prefix { abs($0.amount - latest) <= latest * 0.05 }.count
        let before = sorted.dropLast(atNewPrice).map(\.amount)
        guard before.count >= 2 else { return nil }
        let oldPrice = median(before)
        guard before.allSatisfy({ abs($0 - oldPrice) <= oldPrice * 0.05 }),
              latest > oldPrice * 1.05, latest <= oldPrice * 2 else { return nil }
        return oldPrice
    }

    func matches(key: String, item: RecurringItem) -> Bool {
        let match = item.matchText.merchantKey
        guard !match.isEmpty, !key.isEmpty else { return false }
        return key.hasPrefix(match) || match.hasPrefix(key)
    }

    /// Finds the recurring item a new transaction belongs to, if any.
    func item(for transaction: Transaction, in items: [RecurringItem]) -> RecurringItem? {
        let key = transaction.displayName.merchantKey
        return items.first { item in
            guard item.isActive, matches(key: key, item: item) else { return false }
            // Pay Yourself First amounts can vary; others should be within 30%.
            if item.kind == .payYourselfFirst { return true }
            return abs(abs(transaction.amount) - item.amount) <= max(item.amount * 0.3, 2)
        }
    }

    /// Links a transaction to its recurring item, tracks price changes, and advances the due date.
    func apply(_ transaction: Transaction, to item: RecurringItem, categories: [Category] = []) {
        transaction.recurringItem = item
        // Recurring charges go straight into the Subscriptions or Bills group.
        if transaction.kind == .expense, let role = CategoryRole.role(for: item.kind),
           let group = categories.first(where: { $0.systemRole == role }) {
            transaction.category = group
            transaction.needsCategoryReview = false
        }
        if item.kind == .payYourselfFirst {
            transaction.kind = .contribution
        }
        let charged = abs(transaction.amount)
        if item.kind != .payYourselfFirst && abs(charged - item.amount) > 0.009 {
            item.previousAmount = item.amount
            item.amount = charged
        }
        if item.lastChargedDate.map({ transaction.date > $0 }) ?? true {
            item.lastChargedDate = transaction.date
        }
        item.rollForward(past: transaction.date)
        if item.category == nil { item.category = transaction.category }
    }
}
