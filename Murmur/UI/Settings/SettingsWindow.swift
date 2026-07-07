import SwiftUI
import AppKit

enum SettingsTab: String, Hashable, CaseIterable {
    case overview
    case tryMurmur
    case general
    case providers
    case appOverrides
    case dictionary
    case history
    case about

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .tryMurmur: return "Try Murmur"
        case .general: return "General"
        case .providers: return "Providers"
        case .appOverrides: return "App Overrides"
        case .dictionary: return "Dictionary"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Runtime status, quick controls, and recent dictation activity."
        case .tryMurmur: return "Walk through permissions, microphone input, provider readiness, and cleanup output."
        case .general: return "Recording behavior, hotkey setup, and app-level toggles."
        case .providers: return "Speech and cleanup providers, models, and connection health."
        case .appOverrides: return "Per-app cleanup styles for email, chat, prompts, notes, and code."
        case .dictionary: return "Custom vocabulary and find-and-replace rules applied to every dictation."
        case .history: return "Saved dictations with cleanup and paste outcome details."
        case .about: return "Permissions, runtime state, and local app data."
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "waveform.and.mic"
        case .tryMurmur: return "checklist.checked"
        case .general: return "slider.horizontal.3"
        case .providers: return "bolt.horizontal.circle"
        case .appOverrides: return "square.stack.3d.up"
        case .dictionary: return "character.book.closed"
        case .history: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let windowTitle = "Murmur"

    private var fallbackWindow: NSWindow?
    let settings: SettingsStore
    let history: HistoryStore
    let runtimeHealth = AppServices.runtimeHealth
    let setup = AppServices.setup
    let updates = AppServices.updates

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    func show(initialTab: SettingsTab = .overview) {
        AppServices.router.selectedTab = initialTab
        // Match the main WindowGroup window by title — "first titled window"
        // could front an unrelated auxiliary window instead of settings.
        if let window = NSApp.windows.first(where: {
            !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.title == Self.windowTitle
        }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let fallbackWindow {
            fallbackWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: AppShellView(
                settings: settings,
                history: history,
                runtimeHealth: runtimeHealth,
                setup: setup,
                router: AppServices.router,
                updates: updates
            )
                .frame(minWidth: 780, minHeight: 520)
        )
        let window = NSWindow(contentViewController: host)
        window.title = Self.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        fallbackWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppShellView: View {
    @ObservedObject var settings: SettingsStore
    let history: HistoryStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator
    @ObservedObject var router: AppRouter
    @ObservedObject var updates: UpdateManager

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .background(MurmurBackdrop())
    }

    private var sidebar: some View {
        ZStack {
            MurmurBackdrop()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image("MurmurMark")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 42, height: 42)
                        Text("Murmur")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                    Text("Dictation that actually tells you what happened.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                List(selection: $router.selectedTab) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tag(tab)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)

                MurmurSidebarFooter(settings: settings, runtimeHealth: runtimeHealth, setup: setup)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 200)
    }

    private var detail: some View {
        ZStack {
            MurmurBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MurmurHeroCard(
                        title: router.selectedTab.title,
                        subtitle: router.selectedTab.subtitle,
                        symbol: router.selectedTab.symbol
                    )

                    switch router.selectedTab {
                    case .overview:
                        OverviewTab(settings: settings, history: history, runtimeHealth: runtimeHealth, setup: setup)
                    case .tryMurmur:
                        TryMurmurTab(settings: settings, runtimeHealth: runtimeHealth, setup: setup)
                    case .general:
                        GeneralTab(settings: settings)
                    case .providers:
                        ProvidersTab(settings: settings, setup: setup)
                    case .appOverrides:
                        AppOverridesTab(settings: settings)
                    case .dictionary:
                        DictionaryTab(settings: settings)
                    case .history:
                        HistoryTab(store: history, settings: settings)
                    case .about:
                        AboutTab(history: history, settings: settings, runtimeHealth: runtimeHealth, updates: updates)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
    }
}
