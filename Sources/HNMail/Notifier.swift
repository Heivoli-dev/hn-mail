import AppKit
import Foundation
import UserNotifications

/// Notifications macOS (bannières du Centre de notifications) pour les nouveaux mails.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Appelé quand on clique sur une notification : identifiant du mail à ouvrir.
    var onOpen: (@MainActor (String) -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter n'existe que dans une vraie app (.app avec identifiant).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setup() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }

    func notify(_ messages: [MailMessage]) {
        guard enabled, let center, !messages.isEmpty else { return }
        if messages.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "HN Mail"
            content.body = "\(messages.count) nouveaux mails sur contact@heivoli-network.fr"
            content.sound = .default
            content.userInfo = ["id": messages[0].id]
            center.add(UNNotificationRequest(identifier: "batch-\(messages[0].id)", content: content, trigger: nil))
            return
        }
        for message in messages {
            let content = UNMutableNotificationContent()
            content.title = message.fromName.isEmpty ? message.fromEmail : message.fromName
            content.subtitle = message.subject
            content.body = String(message.snippet.prefix(180))
            content.sound = .default
            content.threadIdentifier = message.mailbox.rawValue
            content.userInfo = ["id": message.id]
            center.add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
        }
    }

    // Affiche la bannière même si l'app est au premier plan.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // Clic sur la notification : ouvre le mail.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["id"] as? String {
            let open = onOpen
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                open?(id)
            }
        }
        completionHandler()
    }
}

/// Garde l'app ouverte (dans la barre des menus) quand on ferme la fenêtre, pour continuer à notifier.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setup()
        Task { @MainActor in await Updater.shared.startAutoCheck() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}
