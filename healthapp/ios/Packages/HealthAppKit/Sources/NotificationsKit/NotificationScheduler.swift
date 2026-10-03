import Foundation
import CoreModels

/// Notification kinds and their copy. Wording is informational and neutral (no streak pressure, no guilt).
public enum NotificationKind: String, CaseIterable, Sendable {
    case mealReminder = "MEAL_REMINDER"
    case hydration = "HYDRATION"
    case lowRecovery = "LOW_RECOVERY"
    case sleepConsistency = "SLEEP_CONSISTENCY"
    case proteinProgress = "PROTEIN_PROGRESS"
    case syncFailure = "SYNC_FAILURE"

    public var categoryIdentifier: String { rawValue }
}

public enum NotificationCopy {
    public static func mealReminder(minutesAfterMidnight m: Int) -> (title: String, body: String) {
        let meal = m < 11 * 60 ? "breakfast" : (m < 16 * 60 ? "lunch" : "dinner")
        return ("Log \(meal)?", "Snap a photo or weigh it on your scale — it only takes a moment.")
    }
    public static let hydration = (title: "Water check", body: "A glass of water now keeps you on pace for today.")
    public static let sleepConsistency = (title: "Wind-down time", body: "Going to bed around the same time helps sleep consistency.")
    public static func proteinProgress(consumed: Double, goal: Double) -> (title: String, body: String) {
        ("Protein so far", "You've logged \(Int(consumed)) g of your \(Int(goal)) g protein goal today.")
    }
    public static func lowRecovery(readiness: Int) -> (title: String, body: String) {
        ("Recovery is lower today", "Readiness is \(readiness). Consider lighter training, regular meals and an earlier night.")
    }
    public static func syncFailure(source: String) -> (title: String, body: String) {
        ("\(source) hasn't synced", "Open HealthApp to reconnect so your data stays up to date.")
    }

    /// Hex string for an APNs device token.
    public static func hexToken(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

#if canImport(UserNotifications)
import UserNotifications

/// Schedules local notifications from `NotificationPreferences`. Server-driven alerts (low recovery from Oura,
/// device sync failures) arrive as APNs pushes via SNS; this class registers categories for both.
public final class NotificationScheduler: @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private static let prefix = "healthapp."

    public init(center: UNUserNotificationCenter = .current()) { self.center = center }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func registerCategories() {
        let logPhoto = UNNotificationAction(identifier: "LOG_PHOTO", title: "Log with photo", options: [.foreground])
        let logScale = UNNotificationAction(identifier: "LOG_SCALE", title: "Weigh on scale", options: [.foreground])
        let addWater = UNNotificationAction(identifier: "ADD_WATER_250", title: "Add 250 ml", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: NotificationKind.mealReminder.categoryIdentifier, actions: [logPhoto, logScale], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationKind.hydration.categoryIdentifier, actions: [addWater], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationKind.lowRecovery.categoryIdentifier, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationKind.sleepConsistency.categoryIdentifier, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationKind.proteinProgress.categoryIdentifier, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationKind.syncFailure.categoryIdentifier, actions: [], intentIdentifiers: [], options: []),
        ])
    }

    /// Replaces all repeating local reminders according to `prefs`.
    public func apply(_ prefs: NotificationPreferences, bedtimeMinutes: Int = 22 * 60 + 30) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix + "repeat.") }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        if prefs.mealReminders {
            for m in prefs.mealReminderMinutes {
                let copy = NotificationCopy.mealReminder(minutesAfterMidnight: m)
                await add(id: "repeat.meal.\(m)", kind: .mealReminder, title: copy.title, body: copy.body, minutes: m)
            }
        }
        if prefs.hydration {
            for hour in stride(from: 10, through: 18, by: 2) {
                await add(id: "repeat.water.\(hour)", kind: .hydration, title: NotificationCopy.hydration.title,
                          body: NotificationCopy.hydration.body, minutes: hour * 60)
            }
        }
        if prefs.sleepConsistency {
            await add(id: "repeat.sleep", kind: .sleepConsistency, title: NotificationCopy.sleepConsistency.title,
                      body: NotificationCopy.sleepConsistency.body, minutes: bedtimeMinutes - 30)
        }
    }

    /// One-shot afternoon nudge, re-scheduled whenever food is logged. Skipped once the goal is met.
    public func scheduleProteinProgress(consumed: Double, goal: Double, enabled: Bool, at hour: Int = 17) async {
        let id = Self.prefix + "protein.today"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, goal > 0, consumed < goal * 0.9 else { return }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour; comps.minute = 0
        guard let fire = Calendar.current.date(from: comps), fire > Date() else { return }
        let copy = NotificationCopy.proteinProgress(consumed: consumed, goal: goal)
        let content = makeContent(kind: .proteinProgress, title: copy.title, body: copy.body)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Immediate local alert (e.g. low recovery detected on morning sync, or a source failing to sync).
    public func notifyNow(_ kind: NotificationKind, title: String, body: String) async {
        let content = makeContent(kind: kind, title: title, body: body)
        let request = UNNotificationRequest(identifier: Self.prefix + "now.\(kind.rawValue).\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try? await center.add(request)
    }

    private func add(id: String, kind: NotificationKind, title: String, body: String, minutes: Int) async {
        var comps = DateComponents()
        comps.hour = minutes / 60; comps.minute = minutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: Self.prefix + id, content: makeContent(kind: kind, title: title, body: body), trigger: trigger)
        try? await center.add(request)
    }

    private func makeContent(kind: NotificationKind, title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = kind.categoryIdentifier
        content.threadIdentifier = kind.rawValue
        return content
    }
}
#endif

#if canImport(UIKit)
import UIKit

public enum PushRegistration {
    /// Call after notification authorization; the token arrives in the app delegate.
    @MainActor
    public static func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
#endif
