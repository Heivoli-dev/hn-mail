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
    @Published var sent: [SentMail] = []
    @Published var selectedSentID: SentMail.ID?

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

    private var sentURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HN Mail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sent.json")
    }

    init() {
        if let data = try? Data(contentsOf: sentURL), let list = try? JSONDecoder().decode([SentMail].self, from: data) {
            sent = list
        }
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
        case .todo: base = messages.filter { $0.mailbox == .contact && !isReplied($0) }
        case .replied: base = messages.filter { isReplied($0) }
        case .all: base = messages.filter { $0.mailbox == .contact }
        case .news: base = messages.filter { $0.mailbox == .news }
        case .sent: base = []
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { "\($0.fromName) \($0.fromEmail) \($0.subject) \($0.body)".lowercased().contains(query) }
    }

    func count(_ folder: Folder) -> Int {
        switch folder {
        case .todo: return messages.filter { $0.mailbox == .contact && !isReplied($0) }.count
        case .replied: return messages.filter { isReplied($0) }.count
        case .all: return messages.filter { $0.mailbox == .contact }.count
        case .news: return messages.filter { $0.mailbox == .news && !isReplied($0) }.count
        case .sent: return 0
        }
    }

    // MARK: Envoyés

    var visibleSent: [SentMail] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sent }
        return sent.filter { "\($0.toName) \($0.toEmail) \($0.subject) \($0.text) \($0.by)".lowercased().contains(query) }
    }

    var selectedSent: SentMail? { sent.first { $0.id == selectedSentID } }

    /// Réponses déjà envoyées à un mail reçu.
    func sentReplies(to message: MailMessage) -> [SentMail] {
        sent.filter { $0.inboxId == message.id }.sorted { $0.sentAt < $1.sentAt }
    }

    /// Garde le mail envoyé sur ce Mac puis le partage avec l'équipe.
    func recordSent(_ mail: SentMail) {
        sent.insert(mail, at: 0)
        saveSentList()
        Task { await pushPendingSent() }
    }

    private func saveSentList() {
        sent = Array(sent.sorted { $0.sentAt > $1.sentAt }.prefix(300))
        if let data = try? JSONEncoder().encode(sent) { try? data.write(to: sentURL, options: .atomic) }
    }

    private func pushPendingSent() async {
        for mail in sent where !mail.synced {
            guard (try? await InboxAPI().saveSent(mail)) != nil else { return }
            if let index = sent.firstIndex(where: { $0.id == mail.id }) { sent[index].synced = true }
        }
        saveSentList()
    }

    private func refreshSent() async {
        await pushPendingSent()
        guard let remote = try? await InboxAPI().fetchSent() else { return }
        var merged = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for mail in sent where !mail.synced && merged[mail.id] == nil { merged[mail.id] = mail }
        sent = Array(merged.values)
        saveSentList()
        if folder == .sent && selectedSent == nil { selectedSentID = sent.first?.id }
    }

    var selected: MailMessage? { messages.first { $0.id == selectedID } }

    func isReplied(_ message: MailMessage) -> Bool { message.repliedAt != nil || replied[message.id] != nil }

    func repliedLabel(_ message: MailMessage) -> String {
        guard isReplied(message) else { return "" }
        let by = message.repliedBy.isEmpty ? teamName : message.repliedBy
        return by == teamName ? "Répondu" : "Répondu par \(by)"
    }

    /// Ton prénom, affiché à l'équipe (« Répondu par … »).
    var teamName: String {
        let saved = UserDefaults.standard.string(forKey: "teamName") ?? ""
        return saved.isEmpty ? (Host.current().localizedName ?? "Mac") : saved
    }

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
            let fresh = messages.filter { !seen.contains($0.id) && !isReplied($0) }
            if !seen.isEmpty { Notifier.shared.notify(fresh) }
            seen.formUnion(messages.map(\.id))
            UserDefaults.standard.set(Array(seen.suffix(2000)), forKey: seenKey)
            updateBadge()
            await pushPendingReplied()
            await refreshSent()
            error = nil
            if selectedID == nil || selected == nil { selectedID = visible.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markReplied(_ message: MailMessage, _ value: Bool = true) {
        // Mise à jour immédiate dans l'app, puis enregistrement sur le serveur pour toute l'équipe.
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].repliedAt = value ? Date() : nil
            messages[index].repliedBy = value ? teamName : ""
        }
        replied[message.id] = value ? Date() : nil
        saveReplied()
        updateBadge()
        Task {
            do {
                try await InboxAPI().setReplied(id: message.id, value: value, by: teamName)
                replied[message.id] = nil
                saveReplied()
            } catch {
                self.error = "État « répondu » pas encore synchronisé : \(error.localizedDescription)"
            }
        }
    }

    private func saveReplied() {
        UserDefaults.standard.set(replied.mapValues { $0.timeIntervalSince1970 }, forKey: repliedKey)
    }

    /// Envoie au serveur les mails marqués « répondu » sur ce Mac mais pas encore partagés.
    private func pushPendingReplied() async {
        for message in messages where replied[message.id] != nil && message.repliedAt == nil {
            if (try? await InboxAPI().setReplied(id: message.id, value: true, by: teamName)) != nil {
                replied[message.id] = nil
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].repliedAt = Date()
                    messages[index].repliedBy = teamName
                }
            }
        }
        // Les mails déjà marqués sur le serveur n'ont plus besoin d'être gardés ici.
        for message in messages where message.repliedAt != nil { replied[message.id] = nil }
        saveReplied()
    }

    /// Premier lancement : charge les mails puis vérifie régulièrement les nouveaux.
    func start() async {
        guard !started else { return }
        started = true
        Notifier.shared.onOpen = { [weak self] id in
            guard let self else { return }
            let message = self.messages.first { $0.id == id }
            self.folder = message.map { self.isReplied($0) } == true ? .replied : (message?.mailbox == .news ? .news : .todo)
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
