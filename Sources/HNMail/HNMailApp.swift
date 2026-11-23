import AppKit
import SwiftUI

@main
struct HNMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MailStore()
    @State private var showNewMail = false

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("HN Mail") {
            ContentView(showNewMail: $showNewMail)
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 680)
                .task { await store.start() }
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau mail") { showNewMail = true }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Actualiser") { Task { await store.refresh() } }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Réglages…") { openSettingsWindow() }.keyboardShortcut(",")
            }
        }

        Settings {
            SettingsView().environmentObject(store).frame(width: 560)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            Image(systemName: store.count(.todo) > 0 ? "envelope.badge.fill" : "envelope")
        }
    }
}

/// Ouvre les Réglages dans la fenêtre principale (fonctionne sur toutes les versions de macOS).
extension Notification.Name {
    static let openSettings = Notification.Name("HNMailOpenSettings")
}

@MainActor
func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name: .openSettings, object: nil)
}
