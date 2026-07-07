import Foundation
import Carbon.HIToolbox
import Testing
@testable import Murmur

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    let defaults = UserDefaults(suiteName: "com.murmur.test.\(UUID().uuidString)")!
    var store: SettingsStore { SettingsStore(defaults: defaults) }

    @Test("default values when unset")
    func defaultsWhenUnset() {
        let s = store
        #expect(s.maxRecordingSeconds == 300)
        #expect(s.microphoneDeviceUID == nil)
        #expect(s.cleanupFallbackEnabled == false)
        #expect(s.transcriptionProvider == .whisperLocal)
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
        #expect(s.lastUpdateCheckAt == nil)
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
        let checkedAt = Date(timeIntervalSince1970: 1234)
        s.automaticUpdateChecks = false
        s.lastUpdateCheckAt = checkedAt
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
        #expect(s2.lastUpdateCheckAt == checkedAt)

        s2.microphoneDeviceUID = ""
        #expect(s2.microphoneDeviceUID == nil)
    }

    @Test("migrates legacy modifier hotkey")
    func migratesLegacyHotkey() {
        defaults.set(Int(kVK_RightCommand), forKey: "hotkeyKeyCode")

        let migrated = store.hotkeyShortcut

        #expect(migrated == HotkeyShortcut(keyCode: UInt16(kVK_RightCommand), modifiers: .command))
    }
}
