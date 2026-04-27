import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: SettingsTab = .overview
}

@MainActor
enum AppServices {
    static let settings = SettingsStore()
    static let runtimeHealth = RuntimeHealthStore(settings: settings)
    static let setup = DependencySetupCoordinator(settings: settings)
    static let updates = UpdateManager(settings: settings)
    static let history: HistoryStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        return HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
    }()
    static let router = AppRouter()
}

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Murmur") {
            AppShellView(
                settings: AppServices.settings,
                history: AppServices.history,
                runtimeHealth: AppServices.runtimeHealth,
                setup: AppServices.setup,
                router: AppServices.router,
                updates: AppServices.updates
            )
            .frame(minWidth: 1080, minHeight: 720)
        }
    }
}
