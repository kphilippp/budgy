import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// A small, precomputed summary shared with the widget and Siri.
/// Stored in the App Group so the widget extension can read it without opening the database.
nonisolated struct BudgySnapshot: Codable, Sendable {
    var safeToSpend: Double
    var dailyAllowance: Double
    var daysUntilPayday: Int
    var nextPayday: Date
    var netWorth: Double
    var nextChargeName: String?
    var nextChargeAmount: Double?
    var nextChargeDate: Date?
    var updatedAt: Date

    static let placeholder = BudgySnapshot(
        safeToSpend: 342.18, dailyAllowance: 57.03, daysUntilPayday: 6,
        nextPayday: .now.addingTimeInterval(6 * 86_400), netWorth: 24_810,
        nextChargeName: "Spotify", nextChargeAmount: 11.99, nextChargeDate: .now.addingTimeInterval(2 * 86_400),
        updatedAt: .now
    )
}

nonisolated enum SnapshotStore {
    static let appGroup = "group.com.budgy.shared"
    private static let key = "budgySnapshot"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func read() -> BudgySnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BudgySnapshot.self, from: data)
    }

    @MainActor
    static func write(engine: FinanceEngine) {
        let result = engine.safeToSpend()
        let nextCharge = result.upcoming.first { $0.source != .goal }
        let snapshot = BudgySnapshot(
            safeToSpend: result.amount,
            dailyAllowance: result.dailyAllowance,
            daysUntilPayday: result.daysRemaining,
            nextPayday: engine.nextPayday,
            netWorth: engine.netWorth,
            nextChargeName: nextCharge?.name,
            nextChargeAmount: nextCharge?.amount,
            nextChargeDate: nextCharge?.date,
            updatedAt: .now
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
