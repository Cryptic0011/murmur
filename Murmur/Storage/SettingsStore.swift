import Foundation

struct AppOverride: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var mode: CleanupMode
}

enum TranscriptionProviderOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisperLocal
    case appleSpeech
    case groqAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperLocal: return "WhisperKit (local)"
        case .appleSpeech: return "Apple Speech (local)"
        case .groqAPI: return "Groq API"
        }
    }

    var familyLabel: String {
        switch self {
        case .whisperLocal, .appleSpeech: return "Local"
        case .groqAPI: return "API"
        }
    }

    var isAvailableOnThisSystem: Bool {
        switch self {
        case .whisperLocal, .groqAPI: return true
        case .appleSpeech:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }

    static var availableCases: [TranscriptionProviderOption] {
        allCases.filter(\.isAvailableOnThisSystem)
    }
}

enum CleanupProviderOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case groqAPI
    case ollamaLocal
    case appleFoundationModels
    case geminiCLI
    case codexCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groqAPI: return "Groq API"
        case .ollamaLocal: return "Gemma via Ollama"
        case .appleFoundationModels: return "Apple Intelligence (local)"
        case .geminiCLI: return "Gemini CLI (OAuth)"
        case .codexCLI: return "ChatGPT via Codex CLI (OAuth)"
        }
    }

    var familyLabel: String {
        switch self {
        case .groqAPI: return "API"
        case .ollamaLocal, .appleFoundationModels: return "Local"
        case .geminiCLI, .codexCLI: return "Cloud OAuth"
        }
    }

    var isAvailableOnThisSystem: Bool {
        switch self {
        case .groqAPI, .ollamaLocal, .geminiCLI, .codexCLI: return true
        case .appleFoundationModels:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }

    static var availableCases: [CleanupProviderOption] {
        allCases.filter(\.isAvailableOnThisSystem)
    }

    static var defaultFallback: CleanupProviderOption {
        if #available(macOS 26.0, *) { return .appleFoundationModels }
        return .ollamaLocal
    }
}

extension Notification.Name {
    static let settingsStoreDidChange = Notification.Name("SettingsStoreDidChange")
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let microphoneDeviceUID = "microphoneDeviceUID"
        static let cleanupFallbackEnabled = "cleanupFallbackEnabled"
        static let saveHistory = "saveHistory"
        static let appOverrides = "appOverrides"
        static let transcriptionProvider = "transcriptionProvider"
        static let whisperModel = "whisperModel"
        static let groqTranscriptionModel = "groqTranscriptionModel"
        static let primaryCleanupProvider = "primaryCleanupProvider"
        static let secondaryCleanupProvider = "secondaryCleanupProvider"
        static let groqModel = "groqModel"
        static let ollamaModel = "ollamaModel"
        static let geminiModel = "geminiModel"
        static let codexModel = "codexModel"
        static let hotkeyShortcut = "hotkeyShortcut"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let pauseHotkey = "pauseHotkey"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let launchAtLogin = "launchAtLogin"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let lastUpdateCheckAt = "lastUpdateCheckAt"
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            NotificationCenter.default.post(name: .settingsStoreDidChange, object: self)
        }
    }

    var maxRecordingSeconds: Int {
        get { defaults.object(forKey: Key.maxRecordingSeconds) as? Int ?? 60 }
        set { defaults.set(newValue, forKey: Key.maxRecordingSeconds); notifyChanged() }
    }

    var microphoneDeviceUID: String? {
        get { defaults.string(forKey: Key.microphoneDeviceUID) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.microphoneDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.microphoneDeviceUID)
            }
            notifyChanged()
        }
    }

    var cleanupFallbackEnabled: Bool {
        get { secondaryCleanupProvider != nil }
        set {
            secondaryCleanupProvider = newValue ? CleanupProviderOption.defaultFallback : nil
        }
    }

    var transcriptionProvider: TranscriptionProviderOption {
        get {
            guard let raw = defaults.string(forKey: Key.transcriptionProvider),
                  let provider = TranscriptionProviderOption(rawValue: raw) else {
                return .whisperLocal
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.transcriptionProvider)
            notifyChanged()
        }
    }

    var saveHistory: Bool {
        get { (defaults.object(forKey: Key.saveHistory) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: Key.saveHistory); notifyChanged() }
    }

    var whisperModel: String {
        get { defaults.string(forKey: Key.whisperModel) ?? "openai_whisper-small.en" }
        set { defaults.set(newValue, forKey: Key.whisperModel); notifyChanged() }
    }

    var groqTranscriptionModel: String {
        get { defaults.string(forKey: Key.groqTranscriptionModel) ?? "whisper-large-v3-turbo" }
        set { defaults.set(newValue, forKey: Key.groqTranscriptionModel); notifyChanged() }
    }

    var primaryCleanupProvider: CleanupProviderOption {
        get {
            guard let raw = defaults.string(forKey: Key.primaryCleanupProvider),
                  let provider = CleanupProviderOption(rawValue: raw) else {
                return .groqAPI
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.primaryCleanupProvider)
            if secondaryCleanupProvider == newValue {
                defaults.removeObject(forKey: Key.secondaryCleanupProvider)
            }
            notifyChanged()
        }
    }

    var secondaryCleanupProvider: CleanupProviderOption? {
        get {
            if let raw = defaults.string(forKey: Key.secondaryCleanupProvider),
               let provider = CleanupProviderOption(rawValue: raw)
            {
                return provider
            }

            if (defaults.object(forKey: Key.cleanupFallbackEnabled) as? Bool) ?? true {
                return CleanupProviderOption.defaultFallback
            }
            return nil
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.secondaryCleanupProvider)
            } else {
                defaults.removeObject(forKey: Key.secondaryCleanupProvider)
            }
            defaults.set(newValue != nil, forKey: Key.cleanupFallbackEnabled)
            notifyChanged()
        }
    }

    var groqModel: String {
        get { defaults.string(forKey: Key.groqModel) ?? "llama-3.1-8b-instant" }
        set { defaults.set(newValue, forKey: Key.groqModel); notifyChanged() }
    }

    var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "gemma4:e2b" }
        set { defaults.set(newValue, forKey: Key.ollamaModel); notifyChanged() }
    }

    var geminiModel: String {
        get { defaults.string(forKey: Key.geminiModel) ?? "gemini-2.5-flash" }
        set { defaults.set(newValue, forKey: Key.geminiModel); notifyChanged() }
    }

    var codexModel: String {
        get { defaults.string(forKey: Key.codexModel) ?? CodexCLIProvider.ModelCatalog.recommended }
        set { defaults.set(newValue, forKey: Key.codexModel); notifyChanged() }
    }

    var hotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Key.hotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data),
               shortcut.hasModifiers
            {
                return shortcut
            }

            if let stored = defaults.object(forKey: Key.hotkeyKeyCode) as? Int,
               let migrated = MurmurHotkeyCatalog.legacyShortcut(for: UInt16(stored))
            {
                return migrated
            }

            return .default
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.hotkeyShortcut)
            notifyChanged()
        }
    }

    var pauseHotkey: Bool {
        get { (defaults.object(forKey: Key.pauseHotkey) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: Key.pauseHotkey); notifyChanged() }
    }

    var showMenuBarIcon: Bool {
        get { (defaults.object(forKey: Key.showMenuBarIcon) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon); notifyChanged() }
    }

    var launchAtLogin: Bool {
        get { (defaults.object(forKey: Key.launchAtLogin) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: Key.launchAtLogin); notifyChanged() }
    }

    var automaticUpdateChecks: Bool {
        get { (defaults.object(forKey: Key.automaticUpdateChecks) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.automaticUpdateChecks); notifyChanged() }
    }

    var lastUpdateCheckAt: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheckAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheckAt) }
    }

    var appOverrides: [AppOverride] {
        get {
            guard let data = defaults.data(forKey: Key.appOverrides),
                  let arr = try? JSONDecoder().decode([AppOverride].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.appOverrides)
            notifyChanged()
        }
    }

    var usesLocalWhisper: Bool {
        transcriptionProvider == .whisperLocal
    }

    var usesGroqAPI: Bool {
        transcriptionProvider == .groqAPI ||
        primaryCleanupProvider == .groqAPI ||
        secondaryCleanupProvider == .groqAPI
    }

    var usesLocalOllama: Bool {
        primaryCleanupProvider == .ollamaLocal ||
        secondaryCleanupProvider == .ollamaLocal
    }

    var usesAppleFoundationModels: Bool {
        primaryCleanupProvider == .appleFoundationModels ||
        secondaryCleanupProvider == .appleFoundationModels
    }

    var usesGeminiCLI: Bool {
        primaryCleanupProvider == .geminiCLI ||
        secondaryCleanupProvider == .geminiCLI
    }

    var usesCodexCLI: Bool {
        primaryCleanupProvider == .codexCLI ||
        secondaryCleanupProvider == .codexCLI
    }
}
