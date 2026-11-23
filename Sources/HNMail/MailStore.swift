import Foundation
import SwiftUI
import AppKit

/// État de l'app : mails, réponses prêtes, mails déjà répondus.
@MainActor
final class MailStore: ObservableObject {
    @Published var messages: [MailMessage] = []
    @Published var folder: Folder = .todo
    @Published var selectedID: MailMessage.ID?
    @Published var search = ""
    @Published var loading = false
    @Published var error: String?
    @Published var templates: [ReplyTemplate] = []
    @Published private(set) var replied: [String: Date] = [:]
    @Published var inboxConfigured = InboxAPI.isConfigured

    let brevo = BrevoAPI()

    private let repliedKey = "repliedMessages"
    private let seenKey = "seenMessages"
    private var seen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "seenMessages") ?? [])
    private var poller: Task<Void, Never>?
    private var started = false
    private var templatesURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HN Mail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("templates.json")
    }

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: repliedKey) as? [String: Double] {
            replied = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
        if let data = try? Data(contentsOf: templatesURL), let list = try? JSONDecoder().decode([ReplyTemplate].self, from: data), !list.isEmpty {
            templates = list
        } else {
            templates = ReplyTemplate.defaults
        }
    }

    var isReady: Bool { inboxConfigured && brevo.apiKey != nil }

    var visible: [MailMessage] {
        let base: [MailMessage]
        switch folder {
        case .todo: base = messages.filter { $0.mailbox == .contact && replied[$0.id] == nil }
        case .replied: base = messages.filter { replied[$0.id] != nil }
        case .all: base = messages.filter { $0.mailbox == .contact }
        case .news: base = messages.filter { $0.mailbox == .news }
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { "\($0.fromName) \($0.fromEmail) \($0.subject) \($0.body)".lowercased().contains(query) }
    }

    func count(_ folder: Folder) -> Int {
        switch folder {
        case .todo: return messages.filter { $0.mailbox == .contact && replied[$0.id] == nil }.count
        case .replied: return messages.filter { replied[$0.id] != nil }.count
        case .all: return messages.filter { $0.mailbox == .contact }.count
        case .news: return messages.filter { $0.mailbox == .news && replied[$0.id] == nil }.count
        }
    }

    var selected: MailMessage? { messages.first { $0.id == selectedID } }

    func isReplied(_ message: MailMessage) -> Bool { replied[message.id] != nil }

    func refresh() async {
        inboxConfigured = InboxAPI.isConfigured
        guard inboxConfigured else { error = "Ajoute la clé HN Mail dans les Réglages (⌘,)."; return }
        loading = true
        defer { loading = false }
        do {
            let all = try await InboxAPI().fetch()
            var unique = Set<String>()
            messages = all.filter { unique.insert($0.id).inserted }.sorted { $0.date > $1.date }
            // Notifie seulement les mails jamais vus (pas au tout premier chargement).
            let fresh = messages.filter { !seen.contains($0.id) && replied[$0.id] == nil }
            if !seen.isEmpty { Notifier.shared.notify(fresh) }
            seen.formUnion(messages.map(\.id))
            UserDefaults.standard.set(Array(seen.suffix(2000)), forKey: seenKey)
            updateBadge()
            error = nil
            if selectedID == nil || selected == nil { selectedID = visible.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markReplied(_ message: MailMessage, _ value: Bool = true) {
        replied[message.id] = value ? Date() : nil
        UserDefaults.standard.set(replied.mapValues { $0.timeIntervalSince1970 }, forKey: repliedKey)
        updateBadge()
    }

    /// Premier lancement : charge les mails puis vérifie régulièrement les nouveaux.
    func start() async {
        guard !started else { return }
        started = true
        Notifier.shared.onOpen = { [weak self] id in
            guard let self else { return }
            self.folder = self.replied[id] == nil ? (self.messages.first { $0.id == id }?.mailbox == .news ? .news : .todo) : .replied
            self.search = ""
            self.selectedID = id
        }
        await refresh()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = max(1, UserDefaults.standard.integer(forKey: "pollMinutes") == 0 ? 2 : UserDefaults.standard.integer(forKey: "pollMinutes"))
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                guard let self else { return }
                if self.inboxConfigured { await self.refresh() }
            }
        }
    }

    func updateBadge() {
        let count = count(.todo)
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    func saveInboxKey(_ key: String) async {
        Keychain.set("hnMailKey", key.trimmingCharacters(in: .whitespacesAndNewlines))
        inboxConfigured = InboxAPI.isConfigured
        await refresh()
    }

    func saveTemplates() {
        if let data = try? JSONEncoder().encode(templates) { try? data.write(to: templatesURL) }
    }

    func resetTemplates() {
        templates = ReplyTemplate.defaults
        saveTemplates()
    }

    func template(_ id: String) -> ReplyTemplate {
        templates.first { $0.id == id } ?? templates.last ?? ReplyTemplate.defaults.last!
    }
}
