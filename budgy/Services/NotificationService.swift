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
            for due in item.upcomingDueDates(through: horizon) {
                guard let fireDate = Calendar.current.date(byAdding: .day, value: -item.remindDaysBefore, to: due),
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

        let payday = engine.nextPayday
        if let remindAt = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: payday), remindAt > .now {
            let content = UNMutableNotificationContent()
            content.title = "It's payday 🎉"
            content.body = "Open Budgy to see your new Safe to Spend and fund your goals."
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
