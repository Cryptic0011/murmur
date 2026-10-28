import Foundation
import Carbon.HIToolbox
import Testing
@testable import Murmur

@Suite("SettingsStore")
@MainActor
final class SettingsStoreTests {
    // A unique suite per test (tests run in parallel), removed again in deinit so no
    // com.murmur.test.<UUID>.plist is left behind in ~/Library/Preferences.
    let suiteName = "com.murmur.tests.settings.\(UUID().uuidString)"
    let defaults: UserDefaults
    var store: SettingsStore { SettingsStore(defaults: defaults) }

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("default values when unset")
    func defaultsWhenUnset() {
        let s = store
        #expect(s.maxRecordingSeconds == 300)
        #expect(s.microphoneDeviceUID == nil)
        #expect(s.cleanupFallbackEnabled == false)
        #expect(s.transcriptionProvider == TranscriptionProviderOption.freshInstallDefault().provider)
        // Zero-config default: Apple Intelligence when this Mac supports it,
        // otherwise Groq; no implicit secondary that nags for install/keys.
        let expectedPrimary: CleanupProviderOption =
            CleanupProviderOption.appleIntelligenceUsable ? .appleFoundationModels : .groqAPI
        #expect(s.primaryCleanupProvider == expectedPrimary)
        #expect(s.secondaryCleanupProvider == nil)
        #expect(s.saveHistory == false)
        #expect(s.appOverrides.isEmpty)
        #expect(s.whisperModel == "openai_whisper-small.en")
        #expect(s.groqTranscriptionModel == "whisper-large-v3-turbo")
        #expect(s.hotkeyShortcut == .default)
        #expect(s.automaticUpdateChecks == true)
        #expect(s.preferBuiltInMicOverBluetooth == false)
        #expect(s.allowURLControl == false)
    }

    @Test("round-trip values")
    func roundTrip() {
        let s = store
        s.maxRecordingSeconds = 120
        s.microphoneDeviceUID = "test-input-uid"
        s.appOverrides = [.init(bundleID: "com.apple.Terminal", mode: .light)]
        s.transcriptionProvider = .groqAPI
        s.groqTranscriptionModel = "whisper-large-v3"
        s.primaryCleanupProvider = .ollamaLocal
        s.secondaryCleanupProvider = .groqAPI
        s.hotkeyShortcut = HotkeyShortcut(keyCode: 49, modifiers: [.control, .option])
        s.automaticUpdateChecks = false
        s.preferBuiltInMicOverBluetooth = true
        s.allowURLControl = true
        let s2 = SettingsStore(defaults: defaults)
        #expect(s2.maxRecordingSeconds == 120)
        #expect(s2.microphoneDeviceUID == "test-input-uid")
        #expect(s2.appOverrides.first?.bundleID == "com.apple.Terminal")
        #expect(s2.appOverrides.first?.mode == .light)
        #expect(s2.transcriptionProvider == .groqAPI)
        #expect(s2.groqTranscriptionModel == "whisper-large-v3")
        #expect(s2.primaryCleanupProvider == .ollamaLocal)
        #expect(s2.secondaryCleanupProvider == .groqAPI)
        #expect(s2.hotkeyShortcut == HotkeyShortcut(keyCode: 49, modifiers: [.control, .option]))
        #expect(s2.automaticUpdateChecks == false)
        #expect(s2.preferBuiltInMicOverBluetooth)
        #expect(s2.allowURLControl)

        s2.microphoneDeviceUID = ""
        #expect(s2.microphoneDeviceUID == nil)
    }

    @Test("migrates legacy modifier hotkey")
    func migratesLegacyHotkey() {
        defaults.set(Int(kVK_RightCommand), forKey: "hotkeyKeyCode")

        let migrated = store.hotkeyShortcut

        #expect(migrated == HotkeyShortcut(keyCode: UInt16(kVK_RightCommand), modifiers: .command))
    }

    @Test("fresh-install engine: Parakeet on Apple Silicon, v3 outside English")
    func freshInstallDefault() {
        let english = TranscriptionProviderOption.freshInstallDefault(appleSilicon: true, preferredLanguage: "en-GB")
        #expect(english.provider == .parakeetLocal && english.parakeetModel == "v2")
        let german = TranscriptionProviderOption.freshInstallDefault(appleSilicon: true, preferredLanguage: "de-DE")
        #expect(german.provider == .parakeetLocal && german.parakeetModel == "v3")
        let intel = TranscriptionProviderOption.freshInstallDefault(appleSilicon: false, preferredLanguage: "en-US")
        #expect(intel.provider == .whisperLocal && intel.parakeetModel == nil)
    }

    @Test("existing installs keep WhisperKit; the choice is pinned once")
    func existingInstallKeepsWhisper() {
        defaults.set(true, forKey: "onboardingComplete")
        #expect(store.transcriptionProvider == .whisperLocal)

        let other = "com.murmur.tests.settings.\(UUID().uuidString)"
        let customized = UserDefaults(suiteName: other)!
        defer { customized.removePersistentDomain(forName: other) }
        customized.set("openai_whisper-base.en", forKey: "whisperModel")
        #expect(SettingsStore(defaults: customized).transcriptionProvider == .whisperLocal)
    }

    @Test("fresh install is pinned to the default engine and never switched later")
    func freshInstallPinned() {
        let fresh = TranscriptionProviderOption.freshInstallDefault()
        #expect(store.transcriptionProvider == fresh.provider)
        #expect(defaults.string(forKey: "transcriptionProvider") == fresh.provider.rawValue)
        // Completing onboarding later must not flip the pinned engine back.
        defaults.set(true, forKey: "onboardingComplete")
        #expect(store.transcriptionProvider == fresh.provider)
    }

    @Test("model migrations run once and don't revert a later choice")
    func migrationsRunOnce() {
        defaults.set("llama-3.3-70b-versatile", forKey: "groqModel")
        defaults.set("llama-3.3-70b", forKey: "cerebrasModel")
        let s = store
        #expect(s.groqModel == "openai/gpt-oss-120b")
        #expect(s.cerebrasModel == SettingsStore.defaultCerebrasModel)

        s.groqModel = "llama-3.3-70b-versatile"
        #expect(store.groqModel == "llama-3.3-70b-versatile")
        // No defaults are written into unset keys, so a future default still reaches this install.
        #expect(defaults.object(forKey: "groqTranscriptionModel") == nil)
    }

    @Test("blank model names fall back to the defaults")
    func blankModelsFallBack() {
        let s = store
        s.groqModel = "  "
        s.cerebrasModel = ""
        s.groqTranscriptionModel = "\n"
        #expect(s.groqModel == SettingsStore.defaultGroqModel)
        #expect(s.cerebrasModel == SettingsStore.defaultCerebrasModel)
        #expect(s.groqTranscriptionModel == "whisper-large-v3-turbo")
    }

    @Test("a fallback hidden by the primary is removed, not resurrected later")
    func primaryReplacesSameSecondary() {
        let s = store
        s.primaryCleanupProvider = .builtIn
        s.secondaryCleanupProvider = .groqAPI
        s.primaryCleanupProvider = .groqAPI
        #expect(s.secondaryCleanupProvider == nil)
        s.primaryCleanupProvider = .builtIn
        #expect(s.secondaryCleanupProvider == nil)
        #expect(s.cleanupFallbackEnabled == false)
    }

    @Test("removed or unavailable providers never coerce to Ollama")
    func coercionAvoidsOllama() {
        defaults.set("codexCLI", forKey: "primaryCleanupProvider")
        #expect(store.primaryCleanupProvider == CleanupProviderOption.defaultFallback)
        #expect(CleanupProviderOption.defaultFallback != .ollamaLocal)
    }

    @Test("a burst of writes posts one change notification")
    func changesCoalesce() async throws {
        let s = store
        let posts = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsStoreDidChange, object: s, queue: nil
        ) { _ in posts.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        s.playSounds = false
        s.cleanupInstructions = "a"
        s.cleanupInstructions = "ab"
        s.maxRecordingSeconds = 60
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(posts.value == 1)

        s.showHUD = false
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(posts.value == 2)
    }
}

/// Thread-safe tally for notification observers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
