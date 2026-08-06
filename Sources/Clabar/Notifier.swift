import Foundation
import UserNotifications

/// System notification banners for Claude events, with action buttons on asks.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let soundDefaultsKey = "notificationSound"
    static let bannersForKindKey = "bannersFor" // e.g. "bannersFor.error" = false

    private weak var store: EventStore?
    private var available = false
    /// Throttle noisy error banners: session id -> last banner date.
    private var lastErrorBanner: [String: Date] = [:]

    init(store: EventStore) {
        self.store = store
        super.init()

        // UNUserNotificationCenter requires a real app bundle; skip silently
        // under `swift run`/`swift test`.
        guard Bundle.main.bundleIdentifier != nil else { return }
        available = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        updateCategories()
    }

    /// Re-registered on every post so action titles follow language switches.
    private func updateCategories() {
        let open = UNNotificationAction(identifier: "open", title: L("Открыть", "Open"), options: [.foreground])
        let allow = UNNotificationAction(identifier: "allow", title: L("⏎ Разрешить", "⏎ Allow"), options: [.foreground])
        let deny = UNNotificationAction(identifier: "deny", title: L("⎋ Отклонить", "⎋ Deny"), options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "clabar.ask", actions: [allow, deny, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "clabar.other", actions: [open], intentIdentifiers: []),
        ])
    }

    func post(for event: ClaudeEvent) {
        guard available, bannersEnabled(for: event.kind) else { return }
        updateCategories()

        if event.kind == .error {
            let sessionKey = event.sessionId ?? "?"
            if let last = lastErrorBanner[sessionKey], Date().timeIntervalSince(last) < 60 { return }
            lastErrorBanner[sessionKey] = Date()
        }

        let content = UNMutableNotificationContent()
        content.title = "\(event.kind.emoji) \(event.kind.title) — \(event.project)"
        content.subtitle = event.sourceName
        content.body = event.message
        content.categoryIdentifier = event.kind == .ask ? "clabar.ask" : "clabar.other"
        content.userInfo = ["eventId": event.id.uuidString]
        if event.kind == .ask, UserDefaults.standard.object(forKey: Self.soundDefaultsKey) as? Bool ?? true {
            content.sound = .default
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        )
    }

    private func bannersEnabled(for kind: EventKind) -> Bool {
        UserDefaults.standard.object(forKey: "\(Self.bannersForKindKey).\(kind.rawValue)") as? Bool ?? true
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let idString = userInfo["eventId"] as? String, let id = UUID(uuidString: idString) else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            guard let store, let event = store.event(byId: id) else { return }
            store.markRead(id)
            switch action {
            case "allow": SessionFocus.answer(event, allow: true)
            case "deny": SessionFocus.answer(event, allow: false)
            default: SessionFocus.focus(event) // "open" or default click
            }
        }
    }
}
