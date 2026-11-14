import Foundation
import UserNotifications

/// Local reminders: upcoming charges and payday. Nothing leaves the device.
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private let prefix = "budgy."

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.notificationsEnabled) }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: SettingsKeys.notificationsEnabled)
        return granted
    }

    /// Replaces all Budgy reminders with fresh ones for the next 30 days.
    func reschedule(recurring: [RecurringItem], engine: FinanceEngine) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard isEnabled else { return }

        let horizon = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        var requests: [UNNotificationRequest] = []

        for item in recurring where item.isActive && !item.needsReview && item.kind != .payYourselfFirst {
            // Yearly and quarterly renewals are big, easy-to-forget charges; give a week to cancel.
            let isLongCycle = item.kind == .subscription && (item.frequency == .yearly || item.frequency == .quarterly)
            let leadDays = isLongCycle ? max(item.remindDaysBefore, 7) : item.remindDaysBefore
            for due in item.upcomingDueDates(through: horizon) {
                guard let fireDate = Calendar.current.date(byAdding: .day, value: -leadDays, to: due),
                      let remindAt = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: fireDate),
                      remindAt > .now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(item.name) renews \(due.relativeDayText)"
                content.body = "\(item.amount.currency) will be charged \(due.formatted(.dateTime.weekday(.wide).month().day()))."
                if item.hasPriceIncrease {
                    content.body += " Heads up: the price went up from \(item.previousAmount.currency)."
                }
                content.sound = .default
                requests.append(request(id: "\(prefix)charge.\(item.id).\(Int(due.timeIntervalSince1970))", content: content, at: remindAt))
            }
        }

        for card in engine.includedAccounts where card.kind == .creditCard {
            if card.utilizationPaymentNeeded > 0,
               let statementDate = card.nextStatementClosingDate(),
               statementDate <= horizon,
               let reminderDay = Calendar.current.date(byAdding: .day, value: -3, to: statementDate),
               let remindAt = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: reminderDay),
               remindAt > .now {
                let content = UNMutableNotificationContent()
                content.title = "Lower \(card.name) utilization"
                content.body = "Pay \(card.utilizationPaymentNeeded.currency) before the statement closes on \(statementDate.formatted(.dateTime.month().day())) to report below 30%."
                content.sound = .default
                requests.append(request(id: "\(prefix)card.statement.\(card.id)", content: content, at: remindAt))
            }

            if card.balance > 0,
               let dueDate = card.nextPaymentDueDate(),
               dueDate <= horizon,
               let reminderDay = Calendar.current.date(byAdding: .day, value: -3, to: dueDate),
               let remindAt = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: reminderDay),
               remindAt > .now {
                let content = UNMutableNotificationContent()
                content.title = "Pay \(card.name) in full"
                content.body = "Your \(card.balance.currency) balance is due \(dueDate.formatted(.dateTime.month().day())). Pay the statement balance in full to avoid interest."
                content.sound = .default
                requests.append(request(id: "\(prefix)card.due.\(card.id)", content: content, at: remindAt))
            }
        }

        let payday = engine.nextPayday
        if let remindAt = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: payday), remindAt > .now {
            let content = UNMutableNotificationContent()
            let savingsAmount = engine.basePaycheck * (engine.schedule?.savingsRate ?? 0)
            content.title = savingsAmount > 0 ? "Pay yourself first" : "It's payday 🎉"
            content.body = savingsAmount > 0
                ? "Move \(savingsAmount.currency) to savings or investments before you spend the rest."
                : "Open Budgy to see your new Safe to Spend and fund your goals."
            content.sound = .default
            requests.append(request(id: "\(prefix)payday", content: content, at: remindAt))
        }

        for request in requests.prefix(60) {
            try? await center.add(request)
        }
    }

    private func request(id: String, content: UNNotificationContent, at date: Date) -> UNNotificationRequest {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
