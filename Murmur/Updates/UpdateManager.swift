import Foundation
import Sparkle

enum UpdateStatus: Equatable {
    case idle
    case checking
    case current
    case available(version: String)
    case failed(message: String)

    var summary: String {
        switch self {
        case .idle: return "Sparkle is ready to check for updates."
        case .checking: return "Checking for updates…"
        case .current: return "Murmur is up to date."
        case .available(let version): return "Version \(version) is available."
        case .failed(let message): return message
        }
    }
}

/// Owns Sparkle's updater for the lifetime of the application and exposes the
/// small amount of state used by Murmur's SwiftUI settings surface.
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var canCheckForUpdates = false

    private let settings: SettingsStore
    private var hasStarted = false
    private var updaterObservations: [NSKeyValueObservation] = []
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    var versionDescription: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(short) (\(build))"
    }

    var lastCheckedText: String {
        guard hasStarted, let date = controller.updater.lastUpdateCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var automaticallyChecksForUpdates: Bool {
        get { hasStarted ? controller.updater.automaticallyChecksForUpdates : settings.automaticUpdateChecks }
        set {
            settings.automaticUpdateChecks = newValue
            guard hasStarted else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        updaterObservations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.objectWillChange.send() }
            },
        ]
        controller.startUpdater()
        // Preserve the preference used by Murmur's previous GitHub updater.
        controller.updater.automaticallyChecksForUpdates = settings.automaticUpdateChecks
        refreshAvailability()
    }

    func checkForUpdatesManually() {
        start()
        status = .checking
        controller.checkForUpdates(nil)
        refreshAvailability()
    }

    private func refreshAvailability() {
        canCheckForUpdates = hasStarted && controller.updater.canCheckForUpdates
        objectWillChange.send()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(version: item.displayVersionString)
        refreshAvailability()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = .current
        refreshAvailability()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error, status == .checking {
            status = .failed(message: error.localizedDescription)
        } else if status == .checking {
            status = .current
        }
        refreshAvailability()
    }
}
