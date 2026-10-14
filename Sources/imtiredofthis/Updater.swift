import AppKit
import Observation

/// Keeps up with the latest GitHub release: checks at launch and every few hours, and installs a
/// newer one when asked, then restarts into it.
@MainActor
@Observable
final class Updater {
    static let repository = URL(string: "https://github.com/yekta/imtiredofthis")!
    private static let latest = URL(string: "https://api.github.com/repos/yekta/imtiredofthis/releases/latest")!
    private static let assetName = "imtiredofthis.zip"
    /// An update must be signed by the same team as the releases.
    private static let teamID = "44R7KF7645"
    private static let interval: TimeInterval = 6 * 60 * 60

    struct Release: Decodable, Equatable {
        let tagName: String
        let assets: [Asset]

        var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v")) }

        struct Asset: Decodable, Equatable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private(set) var available: Release?
    private(set) var isChecking = false
    private(set) var isInstalling = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        Task { try? await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task { try? await self?.refresh() }
            }
        }
    }

    /// Checks when asked to, and says what it found.
    func check() async {
        do {
            try await refresh()
            guard let available else {
                present(message: "imtiredofthis is up to date", detail: "Version \(Self.currentVersion) is the latest.")
                return
            }
            let alert = NSAlert()
            alert.messageText = "imtiredofthis \(available.version) is available"
            alert.informativeText = "You have version \(Self.currentVersion). imtiredofthis restarts once it is installed."
            alert.addButton(withTitle: "Install and Restart")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await install()
        } catch {
            present(message: "Couldn't check for updates", detail: error.localizedDescription)
        }
    }

    func install() async {
        guard let available, !isInstalling,
              let asset = available.assets.first(where: { $0.name == Self.assetName }) else { return }
        setInstalling(true)
        do {
            try await install(from: asset.browserDownloadURL)
        } catch {
            setInstalling(false)
            present(message: "Couldn't update imtiredofthis", detail: error.localizedDescription)
        }
    }

    private func refresh() async throws {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: Self.latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        let isNewer = release.version.compare(Self.currentVersion, options: .numeric) == .orderedDescending
        let hasAsset = release.assets.contains { $0.name == Self.assetName }
        let found = isNewer && hasAsset ? release : nil
        guard found != available else { return }
        available = found
        onChange?()
    }

    /// Unzips the update, checks who signed it, then hands over to a shell that waits for this app
    /// to quit, puts the new one in its place and opens it.
    private func install(from url: URL) async throws {
        let (download, _) = try await URLSession.shared.download(from: url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", download.path, folder.path])
        let update = folder.appendingPathComponent("imtiredofthis.app")
        guard FileManager.default.fileExists(atPath: update.path) else {
            throw UpdateError("The download has no app in it.")
        }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.teamID)\""
        guard (try? Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", update.path])) != nil else {
            throw UpdateError("The download isn't signed by imtiredofthis's developer.")
        }

        let swap = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2" && mv "$3" "$2"
            open "$2"
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", swap, "sh", "\(ProcessInfo.processInfo.processIdentifier)",
                           Bundle.main.bundleURL.path, update.path]
        try shell.run()
        NSApp.terminate(nil)
    }

    private func setInstalling(_ installing: Bool) {
        isInstalling = installing
        onChange?()
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed.")
        }
    }

    private func present(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
