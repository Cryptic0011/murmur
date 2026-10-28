import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: SettingsTab = .overview
}

@MainActor
enum AppServices {
    static let settings = SettingsStore()
    static let apiKeys = APIKeyCache()
    /// The one live set of providers: runtime, setup and Try Murmur share its instances.
    static let providers = ProviderCache(keys: apiKeys, warmsNewProviders: true)
    static let runtimeHealth = RuntimeHealthStore(settings: settings)
    static let setup = DependencySetupCoordinator(settings: settings, providers: providers)
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
        // Menu-bar agent: SettingsWindowController owns the only settings window
        // and AppDelegate decides when to show it. A WindowGroup here opened the
        // full window at every launch and login (and booted AppShellView inside
        // hosted unit tests); a Settings scene never opens on its own.
        Settings {
            EmptyView()
        }
        .commands {
            // Nothing lives in the SwiftUI Settings scene — keep ⌘, from opening it empty.
            CommandGroup(replacing: .appSettings) {}
            // Without a WindowGroup there is no File menu, so no ⌘W for the Settings and
            // Onboarding windows. performClose keeps their windowWillClose handling.
            CommandGroup(replacing: .newItem) {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
        }
    }
}
