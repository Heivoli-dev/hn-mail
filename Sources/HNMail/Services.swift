import Foundation

/// Lecture des mails envoyés à contact@ et news@ dans la boîte Gmail (lecture seule).
struct GmailAPI {
    let auth: GoogleAuth

    func fetch(mailbox: Mailbox, limit: Int = 60) async throws -> [MailMessage] {
        let token = try await auth.token()
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "to:\(mailbox.rawValue) -from:\(mailbox.rawValue)"),
            URLQueryItem(name: "maxResults", value: String(limit)),
        ]
        let list = try await get(components.url!, token: token)
        let ids = ((list["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        var result: [MailMessage] = []
        try await withThrowingTaskGroup(of: MailMessage?.self) { group in
            for id in ids {
                group.addTask {
                    let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
                    return Self.parse(try await self.get(url, token: token), mailbox: mailbox)
                }
            }
            for try await message in group { if let message { result.append(message) } }
        }
        return result.sorted { $0.date > $1.date }
    }

    private func get(_ url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? ""
            if status == 400 && (detail.contains("Mail service not enabled") || detail.contains("Precondition")) {
                throw AppError.message("Ce compte Google n'a pas de boîte Gmail. Déconnecte-toi dans les Réglages et reconnecte-toi avec heivolipro@gmail.com.")
            }
            if status == 403 { throw AppError.message("Gmail refuse l'accès : active l'API Gmail dans la console Google (\(detail)).") }
            if status == 401 { throw AppError.message("La connexion Gmail a expiré. Reconnecte-toi dans les Réglages.") }
            throw AppError.message("Gmail ne répond pas (\(status))\(detail.isEmpty ? "" : " : \(detail)").")
        }
        return json
    }

    static func parse(_ json: [String: Any], mailbox: Mailbox) -> MailMessage? {
        guard let id = json["id"] as? String, let payload = json["payload"] as? [String: Any] else { return nil }
        var headers: [String: String] = [:]
        for header in (payload["headers"] as? [[String: Any]]) ?? [] {
            if let name = header["name"] as? String, let value = header["value"] as? String { headers[name.lowercased()] = value }
        }
        let (name, email) = splitAddress(headers["from"] ?? "")
        let millis = Double(json["internalDate"] as? String ?? "") ?? 0
        let plain = findBody(payload, mime: "text/plain")
        let body = plain ?? findBody(payload, mime: "text/html").map(stripHTML) ?? (json["snippet"] as? String ?? "")
        return MailMessage(
            id: id, threadId: json["threadId"] as? String ?? id,
            fromName: name, fromEmail: email, to: headers["to"] ?? mailbox.rawValue,
            subject: headers["subject"] ?? "(sans objet)",
            date: Date(timeIntervalSince1970: millis / 1000),
            snippet: decodeEntities(json["snippet"] as? String ?? ""),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            messageIdHeader: headers["message-id"] ?? "", mailbox: mailbox)
    }

    static func findBody(_ part: [String: Any], mime: String) -> String? {
        if (part["mimeType"] as? String) == mime,
           let body = part["body"] as? [String: Any], let data = body["data"] as? String,
           let decoded = Data(base64URL: data) {
            return String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .isoLatin1)
        }
        for child in (part["parts"] as? [[String: Any]]) ?? [] {
            if let found = findBody(child, mime: mime) { return found }
        }
        return nil
    }

    static func splitAddress(_ value: String) -> (String, String) {
        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
            let name = value[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return (name, String(value[value.index(after: open)..<close]).lowercased())
        }
        return ("", value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n")
        text = text.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(text)
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
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
