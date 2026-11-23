import AppKit
import SwiftUI

@main
struct HNMailApp: App {
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
                .task { await store.refresh() }
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau mail") { showNewMail = true }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Actualiser") { Task { await store.refresh() } }.keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environmentObject(store).frame(width: 560)
        }
    }
}

/// Ouvre la fenêtre Réglages (compatible macOS 13 et 14+).
@MainActor
func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
