import Foundation
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Boîte de réception : le Worker de heivoli-network.fr garde les mails reçus sur contact@ et news@.
struct InboxAPI {
    static let url = URL(string: "https://heivoli-discord-auth.heivoli-discord-auth.workers.dev/api/inbox")!

    static var key: String? { Keychain.get("hnMailKey") }
    static var isConfigured: Bool { (key ?? "").count >= 24 }

    /// Crée une clé aléatoire (à installer aussi sur le Worker).
    static func generateKey() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 40)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    func fetch() async throws -> [MailMessage] {
        guard let key = Self.key, Self.isConfigured else { throw AppError.message("Ajoute la clé HN Mail dans les Réglages.") }
        var request = URLRequest(url: Self.url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            throw AppError.message((json["error"] as? String) ?? "Le serveur ne répond pas (\(status)).")
        }
        return ((json["messages"] as? [[String: Any]]) ?? []).compactMap(Self.parse)
    }

    /// Marque un mail « répondu » (ou à traiter) pour toute l'équipe.
    func setReplied(id: String, value: Bool, by name: String) async throws {
        guard let key = Self.key, Self.isConfigured else { throw AppError.message("Ajoute la clé HN Mail dans les Réglages.") }
        var request = URLRequest(url: Self.url.appendingPathComponent("replied"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "value": value, "by": name])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("Le serveur n'a pas enregistré l'état du mail.") }
    }

    /// Mails envoyés par l'équipe (Mac et Windows).
    func fetchSent() async throws -> [SentMail] {
        guard let key = Self.key, Self.isConfigured else { throw AppError.message("Ajoute la clé HN Mail dans les Réglages.") }
        var request = URLRequest(url: Self.url.appendingPathComponent("sent"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("Envoyés indisponibles (mets le Worker à jour).")
        }
        return ((json["sent"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return SentMail(id: id, mailbox: item["mailbox"] as? String ?? "contact", toEmail: item["toEmail"] as? String ?? "",
                            toName: item["toName"] as? String ?? "", subject: item["subject"] as? String ?? "",
                            text: item["text"] as? String ?? "", html: item["html"] as? String ?? "",
                            sentAt: Self.parseDate(item["sentAt"] as? String) ?? Date(), by: item["by"] as? String ?? "",
                            inboxId: item["inboxId"] as? String ?? "", template: item["template"] as? String ?? "", synced: true)
        }
    }

    func saveSent(_ mail: SentMail) async throws {
        guard let key = Self.key, Self.isConfigured else { throw AppError.message("Ajoute la clé HN Mail dans les Réglages.") }
        var request = URLRequest(url: Self.url.appendingPathComponent("sent"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": mail.id, "mailbox": mail.mailbox, "toEmail": mail.toEmail, "toName": mail.toName, "subject": mail.subject,
            "text": mail.text, "html": mail.html, "by": mail.by, "inboxId": mail.inboxId, "template": mail.template,
            "sentAt": ISO8601DateFormatter().string(from: mail.sentAt),
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("Le serveur n'a pas gardé le mail envoyé.") }
    }

    static func parse(_ item: [String: Any]) -> MailMessage? {
        guard let id = item["id"] as? String else { return nil }
        let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let mailbox: Mailbox = (item["mailbox"] as? String) == "news" ? .news : .contact
        let replyTo = item["replyTo"] as? String ?? ""
        return MailMessage(
            id: id, threadId: id,
            fromName: item["fromName"] as? String ?? "",
            fromEmail: replyTo.isEmpty ? (item["fromEmail"] as? String ?? "") : replyTo,
            to: item["to"] as? String ?? mailbox.rawValue,
            subject: item["subject"] as? String ?? "(sans objet)",
            date: parseDate(item["date"] as? String) ?? parseDate(item["receivedAt"] as? String) ?? Date(),
            snippet: String(snippet.prefix(200)),
            body: text,
            messageIdHeader: item["messageId"] as? String ?? "",
            mailbox: mailbox,
            attachments: item["attachments"] as? [String] ?? [],
            repliedAt: parseDate(item["repliedAt"] as? String),
            repliedBy: item["repliedBy"] as? String ?? "")
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Envoi des réponses avec Brevo, depuis contact@ ou news@.
struct BrevoAPI {
    var apiKey: String? { Keychain.get("brevoApiKey") }

    func send(from mailbox: Mailbox, toEmail: String, toName: String, subject: String, html: String, inReplyTo: String?) async throws {
        guard let apiKey, !apiKey.isEmpty else { throw AppError.message("Ajoute ta clé Brevo dans les Réglages.") }
        var payload: [String: Any] = [
            "sender": ["name": "Heivoli Network", "email": mailbox.rawValue],
            "replyTo": ["name": "Heivoli Network", "email": Mailbox.contact.rawValue],
            "to": [toName.isEmpty ? ["email": toEmail] : ["email": toEmail, "name": toName]],
            "subject": subject,
            "htmlContent": html,
        ]
        if let inReplyTo, !inReplyTo.isEmpty {
            payload["headers"] = ["In-Reply-To": inReplyTo, "References": inReplyTo]
        }
        var request = URLRequest(url: URL(string: "https://api.brevo.com/v3/smtp/email")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "erreur \(status)"
            throw AppError.message("Brevo a refusé l'envoi : \(detail)")
        }
    }
}

/// Anciens mails envoyés, retrouvés dans l'historique de Brevo.
struct BrevoSentLog {
    let uuid: String
    let email: String
    let subject: String
    let from: String
    let date: Date?
}

extension BrevoAPI {
    private func get(_ url: URL) async throws -> [String: Any] {
        guard let apiKey, !apiKey.isEmpty else { throw AppError.message("Ajoute ta clé Brevo dans les Réglages.") }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 404 { return [:] }
        guard (200..<300).contains(status) else { throw AppError.message((json["message"] as? String) ?? "Brevo ne répond pas (\(status)).") }
        return json
    }

    /// Mails envoyés à une adresse pendant une période d'un mois (0 = les 30 derniers jours, 1 = le mois d'avant…).
    func sentLogs(to email: String, monthsAgo: Int) async throws -> [BrevoSentLog] {
        let day: TimeInterval = 86400
        let end = Date().addingTimeInterval(-Double(monthsAgo * 30) * day)
        let start = end.addingTimeInterval(-29 * day)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        var components = URLComponents(string: "https://api.brevo.com/v3/smtp/emails")!
        components.queryItems = [
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "startDate", value: format.string(from: start)),
            URLQueryItem(name: "endDate", value: format.string(from: end)),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        let json = try await get(components.url!)
        return ((json["transactionalEmails"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let uuid = item["uuid"] as? String else { return nil }
            return BrevoSentLog(uuid: uuid, email: (item["email"] as? String ?? email).lowercased(), subject: item["subject"] as? String ?? "",
                                from: (item["from"] as? String ?? "").lowercased(), date: InboxAPI.parseDate(item["date"] as? String))
        }
    }

    /// Le HTML exact d'un mail envoyé.
    func sentContent(uuid: String) async throws -> String {
        let safe = uuid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? uuid
        return try await get(URL(string: "https://api.brevo.com/v3/smtp/emails/\(safe)")!)["body"] as? String ?? ""
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [("(?is)<(style|script|head)[^>]*>.*?</\\1>", ""), ("(?i)<br\\s*/?>", "\n"), ("(?i)</(p|div|tr|h[1-6]|li)>", "\n"), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "’"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// IA de HN Mail (sur le Worker) : propose une réponse ou corrige le texte.
/// Les consignes de l'IA sont sur le serveur : on peut les changer sans réinstaller l'app.
struct AIAPI {
    static let url = InboxAPI.url.appendingPathComponent("ai")

    func draft(mailFrom: String, subject: String, body: String, template: ReplyTemplate, current: String, instruction: String) async throws -> String {
        let engine = AIEngine.current
        if engine != .claude {
            // Le modèle d'Apple a une petite mémoire : on coupe les très longs mails.
            let prompt = AIPrompts.draftRequest(from: mailFrom, subject: subject, body: body, template: template, current: current,
                                                instruction: instruction, maxMail: engine == .apple ? 4000 : 20000)
            return try await local(engine, system: AIPrompts.draft, prompt: prompt)
        }
        return try await call([
            "action": "draft",
            "mail": ["fromName": mailFrom, "subject": subject, "text": body],
            "template": ["name": template.name, "title": template.title, "message": template.message],
            "current": current,
            "instruction": instruction,
        ])
    }

    func correct(_ text: String) async throws -> String {
        let engine = AIEngine.current
        if engine != .claude {
            let result = AIPrompts.clean(try await local(engine, system: AIPrompts.correct, prompt: "<texte>\n\(text)\n</texte>"))
            return result.isEmpty ? text : result
        }
        return try await call(["action": "correct", "text": text])
    }

    private func local(_ engine: AIEngine, system: String, prompt: String) async throws -> String {
        let text = engine == .apple ? try await AppleAI.respond(system: system, prompt: prompt)
                                    : try await OllamaAI.respond(system: system, prompt: prompt)
        guard !text.isEmpty else { throw AppError.message("L'IA n'a rien proposé, réessaie.") }
        return text
    }

    private func call(_ payload: [String: Any]) async throws -> String {
        guard let key = InboxAPI.key, InboxAPI.isConfigured else { throw AppError.message("Ajoute la clé HN Mail dans les Réglages.") }
        var request = URLRequest(url: Self.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw AppError.message("L'IA ne répond pas. Vérifie ta connexion Internet.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 404 { throw AppError.message("L'IA n'est pas encore installée sur le serveur (mets le Worker à jour).") }
        guard status == 200, let text = json["text"] as? String else {
            throw AppError.message((json["error"] as? String) ?? "L'IA ne répond pas (\(status)).")
        }
        return text
    }
}
