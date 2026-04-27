import Foundation
import AppKit

struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]
    let rawValue: String
    let normalizedValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        self.normalizedValue = normalized
        self.components = normalized
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return false
            }
        }
        return true
    }

    var description: String { normalizedValue }
}

struct UpdateConfiguration: Sendable {
    let repository: String
    let releasesPageURL: URL?
    let checkInterval: TimeInterval

    init(bundle: Bundle = .main) {
        repository = (bundle.object(forInfoDictionaryKey: "MurmurUpdateRepository") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let rawURL = bundle.object(forInfoDictionaryKey: "MurmurUpdateReleasesPageURL") as? String,
           let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           !rawURL.isEmpty
        {
            releasesPageURL = url
        } else {
            releasesPageURL = nil
        }

        let hours = bundle.object(forInfoDictionaryKey: "MurmurUpdateCheckIntervalHours") as? Double ?? 12
        checkInterval = max(hours, 1) * 60 * 60
    }

    var isEnabled: Bool { !repository.isEmpty }
    var apiURL: URL? { URL(string: "https://api.github.com/repos/\(repository)/releases/latest") }
}

struct UpdateRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let name: String?
    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    var version: AppVersion { AppVersion(tagName) }

    var preferredDownloadURL: URL {
        if let dmg = assets.first(where: { $0.name.localizedCaseInsensitiveContains(".dmg") }) {
            return dmg.browserDownloadURL
        }
        return htmlURL
    }
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case disabled
    case current(version: String)
    case available(currentVersion: String, latestVersion: String)
    case failed(message: String)

    var summary: String {
        switch self {
        case .idle:
            return "Update checks have not run yet."
        case .checking:
            return "Checking GitHub for the latest release."
        case .disabled:
            return "Release checks are disabled until a GitHub repository is configured."
        case let .current(version):
            return "You are on the latest version, v\(version)."
        case let .available(_, latestVersion):
            return "Update v\(latestVersion) is available."
        case let .failed(message):
            return message
        }
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    @Published private(set) var status: UpdateStatus = .idle

    private let settings: SettingsStore
    private let bundle: Bundle
    private let session: URLSession
    private let now: () -> Date
    private(set) var latestRelease: UpdateRelease?

    init(
        settings: SettingsStore,
        bundle: Bundle = .main,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.bundle = bundle
        self.session = session
        self.now = now
    }

    var configuration: UpdateConfiguration { UpdateConfiguration(bundle: bundle) }

    var currentVersionString: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var buildString: String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var versionDescription: String {
        "v\(currentVersionString) (\(buildString))"
    }

    var lastCheckedText: String {
        guard let lastCheck = settings.lastUpdateCheckAt else { return "Never" }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }

    func checkForUpdatesIfNeeded() async {
        guard settings.automaticUpdateChecks else { return }
        guard shouldCheckAutomatically() else { return }
        await runCheck(trigger: .automatic)
    }

    func checkForUpdatesManually() async {
        await runCheck(trigger: .manual)
    }

    private func shouldCheckAutomatically() -> Bool {
        guard configuration.isEnabled else {
            status = .disabled
            return false
        }
        guard let lastCheck = settings.lastUpdateCheckAt else { return true }
        return now().timeIntervalSince(lastCheck) >= configuration.checkInterval
    }

    private func runCheck(trigger: CheckTrigger) async {
        let config = configuration
        guard config.isEnabled, let url = config.apiURL else {
            status = .disabled
            if trigger == .manual {
                presentInfoAlert(
                    title: "Updates Not Configured",
                    message: "Set `MurmurUpdateRepository` in the app bundle before shipping this build."
                )
            }
            return
        }

        status = .checking

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Murmur/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateError.httpStatus(http.statusCode)
            }

            let release = try JSONDecoder().decode(UpdateRelease.self, from: data)
            latestRelease = release
            settings.lastUpdateCheckAt = now()

            let current = AppVersion(currentVersionString)
            if release.version > current {
                status = .available(currentVersion: currentVersionString, latestVersion: release.version.normalizedValue)
                presentAvailableUpdateAlert(release: release)
            } else {
                status = .current(version: currentVersionString)
                if trigger == .manual {
                    presentInfoAlert(
                        title: "Murmur Is Up To Date",
                        message: "You’re already on \(versionDescription)."
                    )
                }
            }
        } catch {
            status = .failed(message: "Update check failed.")
            if trigger == .manual {
                presentInfoAlert(
                    title: "Update Check Failed",
                    message: updateErrorMessage(for: error)
                )
            }
        }
    }

    private func presentAvailableUpdateAlert(release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Available"
        alert.informativeText = "Murmur v\(release.version.normalizedValue) is available. You’re currently on \(versionDescription). Would you like to download the update now?"
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(release.preferredDownloadURL)
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func updateErrorMessage(for error: Error) -> String {
        if let updateError = error as? UpdateError {
            return updateError.description
        }
        if let urlError = error as? URLError {
            return urlError.localizedDescription
        }
        return "Murmur couldn’t reach GitHub Releases."
    }

    private enum CheckTrigger {
        case automatic
        case manual
    }

    private enum UpdateError: Error, CustomStringConvertible {
        case invalidResponse
        case httpStatus(Int)

        var description: String {
            switch self {
            case .invalidResponse:
                return "GitHub returned an invalid response."
            case let .httpStatus(code):
                return "GitHub Releases returned HTTP \(code)."
            }
        }
    }
}
