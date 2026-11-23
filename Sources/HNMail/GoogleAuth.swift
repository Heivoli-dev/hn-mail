import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Connexion Google (OAuth « application de bureau » avec PKCE).
/// Le navigateur s'ouvre, l'utilisateur accepte, Google revient sur un petit serveur local (127.0.0.1).
final class GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/userinfo.email"

    var clientID: String { UserDefaults.standard.string(forKey: "googleClientID") ?? "" }
    var clientSecret: String { Keychain.get("googleClientSecret") ?? "" }
    var refreshToken: String? { Keychain.get("googleRefreshToken") }
    var isConnected: Bool { refreshToken != nil }

    private var accessToken: String?
    private var accessExpiry = Date.distantPast

    func signOut() {
        Keychain.set("googleRefreshToken", nil)
        UserDefaults.standard.removeObject(forKey: "googleEmail")
        accessToken = nil
    }

    /// Renvoie un jeton d'accès valide (rafraîchi si besoin).
    func token() async throws -> String {
        if let accessToken, accessExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refreshToken else { throw AppError.message("Connecte ton compte Gmail dans les Réglages.") }
        let data = try await post("https://oauth2.googleapis.com/token", [
            "client_id": clientID, "client_secret": clientSecret,
            "refresh_token": refreshToken, "grant_type": "refresh_token",
        ])
        return try store(data)
    }

    /// Ouvre le navigateur pour connecter Gmail, puis récupère le code sur le serveur local.
    @MainActor
    func signIn() async throws -> String {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw AppError.message("Renseigne d'abord l'identifiant et le secret du client Google.")
        }
        let verifier = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString()
        let receiver = LoopbackReceiver()
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)

        let query = try await receiver.waitForQuery()
        guard query["state"] == state else { throw AppError.message("La connexion a été interrompue. Réessaie.") }
        guard let code = query["code"] else { throw AppError.message("Google n'a pas autorisé l'accès (\(query["error"] ?? "refus")).") }

        let data = try await post("https://oauth2.googleapis.com/token", [
            "client_id": clientID, "client_secret": clientSecret, "code": code,
            "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        let token = try store(data)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (info, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: info) as? [String: Any],
           let email = json["email"] as? String {
            UserDefaults.standard.set(email, forKey: "googleEmail")
            return email
        }
        return ""
    }

    private func store(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("invalid_grant") { signOut(); throw AppError.message("La connexion Gmail a expiré. Reconnecte-toi dans les Réglages.") }
            throw AppError.message("Google a refusé la connexion.")
        }
        if let refresh = json["refresh_token"] as? String { Keychain.set("googleRefreshToken", refresh) }
        accessToken = token
        accessExpiry = Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int) ?? 3000))
        return token
    }

    private func post(_ url: String, _ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}

/// Mini serveur HTTP sur 127.0.0.1 qui attend le retour de Google, une seule fois.
final class LoopbackReceiver {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pendingQuery: [String: String]?
    private let queue = DispatchQueue(label: "hn-mail.oauth")

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForQuery() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let query = self.pendingQuery { cont.resume(returning: query) } else { self.continuation = cont }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let path = firstLine.components(separatedBy: " ").dropFirst().first ?? "/"
            let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
            var query: [String: String] = [:]
            for item in items { query[item.name] = item.value ?? "" }
            guard query["code"] != nil || query["error"] != nil else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let html = "<!DOCTYPE html><meta charset=utf-8><body style=\"font:16px -apple-system;display:grid;place-items:center;height:90vh;color:#282639\"><div style=\"text-align:center\"><h2>C'est connecté !</h2><p>Tu peux fermer cette page et revenir dans HN Mail.</p></div>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(html.utf8).count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.listener?.cancel()
            if let continuation = self.continuation {
                continuation.resume(returning: query)
                self.continuation = nil
            } else {
                self.pendingQuery = query
            }
        }
    }
}
