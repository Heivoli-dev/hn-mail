import AppKit
import CryptoKit
import Foundation

/// Mise à jour par Internet : HN Mail regarde la dernière Release GitHub et s'installe toute seule.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let build: Int
        let notes: String
        let assetURL: URL
        let digest: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var latest: Release?
    @Published var lastCheck: Date?
    @Published var dismissed = false

    static let releasesURL = URL(string: "https://api.github.com/repos/Heivoli-dev/hn-mail/releases/latest")!
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate"); objectWillChange.send() }
    }

    var busy: Bool { state == .checking || state == .downloading || state == .installing }

    /// Vérifie au lancement puis toutes les 6 heures.
    func startAutoCheck() async {
        while !Task.isCancelled {
            if autoCheck { await check(silent: true) }
            try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
        }
    }

    func check(silent: Bool) async {
        guard !busy else { return }
        state = .checking
        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("HN-Mail/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppError.message("GitHub ne répond pas, réessaie plus tard.")
            }
            let tag = json["tag_name"] as? String ?? ""
            var build = 0
            if let range = tag.range(of: #"build\d+"#, options: .regularExpression) {
                build = Int(tag[range].dropFirst(5)) ?? 0
            }
            let version = String(tag.dropFirst(tag.hasPrefix("v") ? 1 : 0)).components(separatedBy: "-build").first ?? tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard let asset = assets.first(where: { ($0["name"] as? String) == "HN-Mail.dmg" }),
                  let link = asset["browser_download_url"] as? String,
                  let url = URL(string: link), url.scheme == "https", url.host == "github.com" else {
                throw AppError.message("La dernière version n'a pas de fichier pour Mac.")
            }
            latest = Release(version: version, build: build, notes: json["body"] as? String ?? "", assetURL: url, digest: asset["digest"] as? String)
            lastCheck = Date()
            // Une app compilée à la main (build 0) ne se met jamais à jour toute seule.
            state = (currentBuild > 0 && build > currentBuild) ? .available : .upToDate
            if state == .available { dismissed = false }
        } catch {
            state = silent ? .idle : .failed(error.localizedDescription)
        }
    }

    /// Télécharge le .dmg, vérifie son empreinte, remplace l'app puis la relance.
    func install() async {
        guard let release = latest, !busy else { return }
        state = .downloading
        do {
            var request = URLRequest(url: release.assetURL)
            request.setValue("HN-Mail/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 300
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("Le téléchargement a échoué.") }

            let work = FileManager.default.temporaryDirectory.appendingPathComponent("hn-mail-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("HN-Mail.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)

            if let digest = release.digest?.lowercased(), digest.hasPrefix("sha256:") {
                let hash = try await Task.detached { () -> String in
                    let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }.value
                guard "sha256:\(hash)" == digest else { throw AppError.message("Le fichier téléchargé est abîmé. Réessaie.") }
            }

            state = .installing
            var target = Bundle.main.bundleURL
            if target.path.contains("/AppTranslocation/") { target = URL(fileURLWithPath: "/Applications/HN Mail.app") }
            let folder = target.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: folder) else {
                NSWorkspace.shared.open(dmg)
                throw AppError.message("Je ne peux pas écrire dans \(folder). Le .dmg est ouvert : glisse HN Mail dans Applications.")
            }

            let mount = work.appendingPathComponent("mnt", isDirectory: true)
            let staged = work.appendingPathComponent("HN Mail.app", isDirectory: true)
            try await Task.detached {
                try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path])
                defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
                let app = mount.appendingPathComponent("HN Mail.app")
                guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/HNMail").path) else {
                    throw AppError.message("Le .dmg ne contient pas HN Mail.")
                }
                try Self.run("/usr/bin/ditto", [app.path, staged.path])
            }.value

            // Un petit script attend que l'app se ferme, remplace l'ancienne version et relance la nouvelle.
            let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.3; done
            /bin/rm -rf "$TARGET.old"
            if /bin/mv "$TARGET" "$TARGET.old" && /usr/bin/ditto "$STAGED" "$TARGET"; then
              /bin/rm -rf "$TARGET.old"
            else
              /bin/rm -rf "$TARGET"; /bin/mv "$TARGET.old" "$TARGET"
            fi
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
            /usr/bin/open "$TARGET"
            /bin/rm -rf "$WORK"
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["TARGET": target.path, "STAGED": staged.path, "WORK": work.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppError.message("L'installation a échoué (\((tool as NSString).lastPathComponent)).")
        }
    }
}
