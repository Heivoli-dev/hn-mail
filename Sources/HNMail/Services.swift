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
            attachments: item["attachments"] as? [String] ?? [])
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
