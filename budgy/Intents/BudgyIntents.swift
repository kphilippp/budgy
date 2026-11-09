import AppIntents
import Foundation

/// "Hey Siri, what's my safe to spend in Budgy?"
struct SafeToSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Safe to Spend"
    static let description = IntentDescription("Tells you how much you can spend until your next payday.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        guard let snapshot = SnapshotStore.read() else {
            return .result(value: 0, dialog: "Open Budgy once so it can calculate your Safe to Spend.")
        }
        let amount = snapshot.safeToSpend.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        let daily = snapshot.dailyAllowance.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        let days = snapshot.daysUntilPayday
        let dialog: IntentDialog = snapshot.safeToSpend >= 0
            ? "You have \(amount) safe to spend for the next \(days) days. That's about \(daily) a day."
            : "You're \(amount) over until payday in \(days) days. Try to hold off on extra spending."
        return .result(value: snapshot.safeToSpend, dialog: dialog)
    }
}

struct BudgyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SafeToSpendIntent(),
            phrases: [
                "What's my safe to spend in \(.applicationName)",
                "How much can I spend in \(.applicationName)",
                "Check \(.applicationName)"
            ],
            shortTitle: "Safe to Spend",
            systemImageName: "dollarsign.circle"
        )
    }
}
