import Foundation
import SwiftUI

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
    @Published var googleEmail: String = UserDefaults.standard.string(forKey: "googleEmail") ?? ""

    let auth = GoogleAuth()
    let brevo = BrevoAPI()

    private let repliedKey = "repliedMessages"
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

    var isReady: Bool { auth.isConnected && brevo.apiKey != nil }

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
        guard auth.isConnected else { error = "Connecte ton compte Gmail dans les Réglages (⌘,)."; return }
        loading = true
        defer { loading = false }
        do {
            let api = GmailAPI(auth: auth)
            async let contact = api.fetch(mailbox: .contact)
            async let news = api.fetch(mailbox: .news, limit: 30)
            let all = try await contact + news
            var seen = Set<String>()
            messages = all.filter { seen.insert($0.id).inserted }.sorted { $0.date > $1.date }
            error = nil
            if selectedID == nil || selected == nil { selectedID = visible.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markReplied(_ message: MailMessage, _ value: Bool = true) {
        replied[message.id] = value ? Date() : nil
        UserDefaults.standard.set(replied.mapValues { $0.timeIntervalSince1970 }, forKey: repliedKey)
    }

    func connectGoogle() async {
        do {
            googleEmail = try await auth.signIn()
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func disconnectGoogle() {
        auth.signOut()
        googleEmail = ""
        messages = []
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
