import AppKit
import Sparkle

enum UpdateStatus: Equatable {
    case idle
    case checking
    case current
    case available(version: String)
    case downloading(version: String, progress: Double?)
    case installing(version: String)
    case failed(message: String)

    var summary: String {
        switch self {
        case .idle: return "Sparkle is ready to check for updates."
        case .checking: return "Checking for updates…"
        case .current: return "Murmur is up to date."
        case .available(let version): return "Version \(version) is available."
        case .downloading(let version, let progress):
            if let progress { return "Downloading \(version)… \(Int(progress * 100))%" }
            return "Downloading \(version)…"
        case .installing(let version): return "Installing \(version)…"
        case .failed(let message): return message
        }
    }

    /// The version to offer as "Update to x.y.z…" (status menu, Overview card);
    /// nil while nothing is waiting or an install is already under way.
    var availableVersion: String? {
        if case .available(let version) = self { return version }
        return nil
    }

    /// Where a Sparkle session teardown leaves the status: progress states
    /// (a check or install that was dismissed, cancelled or overtaken) fall back
    /// to the known update, or idle; results (available/current/failed) stay.
    func afterSessionEnded(foundVersion: String) -> UpdateStatus {
        switch self {
        case .checking, .downloading, .installing:
            return foundVersion.isEmpty ? .idle : .available(version: foundVersion)
        case .idle, .current, .available, .failed:
            return self
        }
    }
}

/// Owns Sparkle's updater for the lifetime of the application. Murmur acts as
/// Sparkle's user driver, so no Sparkle windows ever appear: background checks
/// only surface `.available` state, and `installAndRelaunch()` auto-accepts
/// every stage for a one-click download → install → relaunch.
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUserDriver {
    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var canCheckForUpdates = false

    private let settings: SettingsStore
    private let defaults: UserDefaults
    private var hasStarted = false
    /// Armed only by an explicit "Restart to Update" click, and disarmed whenever
    /// that session ends — a stale flag would let a later background check
    /// download, install and relaunch with no click.
    private var installOnNextFound = false
    private var foundVersion = ""
    private var expectedDownloadLength: UInt64 = 0
    private var receivedDownloadLength: UInt64 = 0
    private var updaterObservations: [NSKeyValueObservation] = []
    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: self,
        delegate: nil
    )

    private enum Key {
        static let foundDisplayVersion = "updateFoundDisplayVersion"
        static let foundBuildVersion = "updateFoundBuildVersion"
    }

    init(settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        super.init()
        restoreFoundUpdate()
    }

    var versionDescription: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(short) (\(build))"
    }

    var lastCheckedText: String {
        guard hasStarted, let date = updater.lastUpdateCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var automaticallyChecksForUpdates: Bool {
        get { hasStarted ? updater.automaticallyChecksForUpdates : settings.automaticUpdateChecks }
        set {
            settings.automaticUpdateChecks = newValue
            guard hasStarted else { return }
            updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    func start() {
        guard !hasStarted else { return }
        do {
            try updater.start()
        } catch {
            // Not started: checks stay no-ops instead of spinning on a session
            // Sparkle will never run, and the next call retries.
            status = .failed(message: error.localizedDescription)
            return
        }
        hasStarted = true
        updaterObservations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.objectWillChange.send() }
            },
        ]
        // Murmur's own setting (About tab) is the source of truth; Sparkle follows it.
        updater.automaticallyChecksForUpdates = settings.automaticUpdateChecks
        refreshAvailability()
    }

    func checkForUpdatesManually() {
        guard beginSession() else { return }
        installOnNextFound = false
        status = .checking
        updater.checkForUpdates()
        refreshAvailability()
    }

    /// One-click update: re-runs the check with install intent; as the user
    /// driver we auto-accept each stage, so Sparkle downloads the DMG,
    /// installs, and relaunches Murmur without any dialogs.
    func installAndRelaunch() {
        guard beginSession() else { return }
        installOnNextFound = true
        if !foundVersion.isEmpty { status = .downloading(version: foundVersion, progress: nil) }
        updater.checkForUpdates()
        refreshAvailability()
    }

    /// Starts Sparkle if needed; false while a session is already running (or
    /// Sparkle couldn't start). Sparkle silently ignores checks then, so neither
    /// the status nor the install flag may change — that left "Checking…" or
    /// "Installing…" spinning forever.
    private func beginSession() -> Bool {
        start()
        guard hasStarted, updater.canCheckForUpdates else {
            refreshAvailability()
            return false
        }
        return true
    }

    private func refreshAvailability() {
        canCheckForUpdates = hasStarted && updater.canCheckForUpdates
        objectWillChange.send()
    }

    // MARK: - Found-update persistence

    /// Whether a persisted update build is still newer than the running build.
    nonisolated static func isNewer(_ build: String, than currentBuild: String) -> Bool {
        !build.isEmpty && SUStandardVersionComparator().compareVersion(build, toVersion: currentBuild) == .orderedDescending
    }

    /// Re-offers an update found before a relaunch, unless this build already is
    /// that version (or newer) — Sparkle's next scheduled check can be hours away.
    private func restoreFoundUpdate() {
        let display = defaults.string(forKey: Key.foundDisplayVersion) ?? ""
        let build = defaults.string(forKey: Key.foundBuildVersion) ?? ""
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard !display.isEmpty, Self.isNewer(build, than: current) else {
            forgetFoundUpdate()
            return
        }
        foundVersion = display
        status = .available(version: display)
    }

    private func rememberFoundUpdate(_ item: SUAppcastItem) {
        foundVersion = item.displayVersionString
        defaults.set(item.displayVersionString, forKey: Key.foundDisplayVersion)
        defaults.set(item.versionString, forKey: Key.foundBuildVersion)
    }

    private func forgetFoundUpdate() {
        foundVersion = ""
        defaults.removeObject(forKey: Key.foundDisplayVersion)
        defaults.removeObject(forKey: Key.foundBuildVersion)
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Never show Sparkle's permission prompt; the About tab owns this toggle.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: settings.automaticUpdateChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // An install click already shows its own progress; don't flash "Checking…".
        if !installOnNextFound { status = .checking }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        rememberFoundUpdate(appcastItem)
        if appcastItem.isInformationOnlyUpdate {
            // Nothing to download (Sparkle forbids .install here): send an explicit
            // install click to the release page instead.
            if installOnNextFound, let infoURL = appcastItem.infoURL {
                NSWorkspace.shared.open(infoURL)
            }
            installOnNextFound = false
            status = .available(version: foundVersion)
            reply(.dismiss)
        } else if installOnNextFound {
            status = .downloading(version: foundVersion, progress: nil)
            reply(.install)
        } else {
            status = .available(version: foundVersion)
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installOnNextFound = false
        forgetFoundUpdate()
        status = .current
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installOnNextFound = false
        status = .failed(message: error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        status = .downloading(version: foundVersion, progress: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength += length
        guard expectedDownloadLength > 0 else { return }
        let progress = min(1, Double(receivedDownloadLength) / Double(expectedDownloadLength))
        status = .downloading(version: foundVersion, progress: progress)
    }

    func showDownloadDidStartExtractingUpdate() {
        status = .installing(version: foundVersion)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(installOnNextFound ? .install : .dismiss)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        status = .installing(version: foundVersion)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        // Session teardown fires after every check. Keep `.available` so the
        // Overview card and status-menu item survive; a dismissed or overtaken
        // download/install falls back to "available" rather than spinning.
        installOnNextFound = false
        status = status.afterSessionEnded(foundVersion: foundVersion)
    }
}
