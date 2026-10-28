import Foundation

struct AppOverride: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var mode: CleanupMode
}

enum TranscriptionProviderOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisperLocal
    case parakeetLocal
    case appleSpeech
    case groqAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperLocal: return "WhisperKit (local)"
        case .parakeetLocal: return "Parakeet (local)"
        case .appleSpeech: return "Apple Speech (local)"
        case .groqAPI: return "Groq API"
        }
    }

    var familyLabel: String {
        switch self {
        case .whisperLocal, .parakeetLocal, .appleSpeech: return "Local"
        case .groqAPI: return "API"
        }
    }

    var isAvailableOnThisSystem: Bool {
        switch self {
        case .whisperLocal, .parakeetLocal, .groqAPI: return true
        case .appleSpeech:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }

    static var availableCases: [TranscriptionProviderOption] {
        allCases.filter(\.isAvailableOnThisSystem)
    }

    /// The engine a fresh install starts on: Parakeet on Apple Silicon (v2 for English,
    /// v3 for other languages), WhisperKit elsewhere. Existing installs are never switched.
    static func freshInstallDefault(
        appleSilicon: Bool = isAppleSilicon,
        preferredLanguage: String? = Locale.preferredLanguages.first
    ) -> (provider: TranscriptionProviderOption, parakeetModel: String?) {
        guard appleSilicon else { return (.whisperLocal, nil) }
        let english = preferredLanguage?.lowercased().hasPrefix("en") ?? true
        return (.parakeetLocal, english ? "v2" : "v3")
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

enum CleanupProviderOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case groqAPI
    case cerebrasAPI
    case customAPI
    case builtIn
    case ollamaLocal
    case appleFoundationModels

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groqAPI: return "Groq API"
        case .cerebrasAPI: return "Cerebras API"
        case .builtIn: return "Built-in rules only"
        case .customAPI: return "Custom endpoint"
        case .ollamaLocal: return "Ollama"
        case .appleFoundationModels: return "Apple Intelligence (local)"
        }
    }

    var familyLabel: String {
        switch self {
        case .groqAPI, .cerebrasAPI, .customAPI: return "API"
        case .builtIn, .ollamaLocal, .appleFoundationModels: return "Local"
        }
    }

    var isAvailableOnThisSystem: Bool {
        switch self {
        case .builtIn, .groqAPI, .cerebrasAPI, .customAPI, .ollamaLocal: return true
        case .appleFoundationModels:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }

    static var availableCases: [CleanupProviderOption] {
        allCases.filter(\.isAvailableOnThisSystem)
    }

    /// The keyless, install-free local choice: Apple Intelligence when usable, otherwise
    /// the built-in rules. Never Ollama, which most Macs don't have installed.
    static var defaultFallback: CleanupProviderOption {
        appleIntelligenceUsable ? .appleFoundationModels : .builtIn
    }

    /// Cached per launch — availability only changes via System Settings.
    static let appleIntelligenceUsable: Bool = {
        if #available(macOS 26.0, *) { return AppleFoundationModelsProvider.isAvailable() }
        return false
    }()
}

extension Notification.Name {
    static let settingsStoreDidChange = Notification.Name("SettingsStoreDidChange")
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    static let defaultGroqModel = "openai/gpt-oss-20b"
    static let defaultCerebrasModel = "gpt-oss-120b"

    /// Bumped when a one-time settings migration is added; see migrate().
    private static let settingsVersion = 1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrate()
    }

    /// One-time rewrites, guarded by a stored version so later launches never revert a
    /// value the user picked deliberately. Getters fall back to the defaults on their own,
    /// so nothing is written into empty keys (a stored default would look like a choice).
    private func migrate() {
        guard defaults.integer(forKey: Key.settingsVersion) < 1 else { return }
        // v1: retired llama cleanup defaults → their gpt-oss replacements.
        switch defaults.string(forKey: Key.groqModel) {
        case "llama-3.3-70b-versatile": defaults.set("openai/gpt-oss-120b", forKey: Key.groqModel)
        case "llama-3.1-8b-instant": defaults.set(Self.defaultGroqModel, forKey: Key.groqModel)
        default: break
        }
        if let cerebras = defaults.string(forKey: Key.cerebrasModel), ["llama3.1-8b", "llama-3.3-70b"].contains(cerebras) {
            defaults.set(Self.defaultCerebrasModel, forKey: Key.cerebrasModel)
        }
        // v1: pin the speech engine. Existing installs keep WhisperKit, the old implicit
        // default; a fresh install starts on the faster engine for this Mac.
        if defaults.string(forKey: Key.transcriptionProvider) == nil {
            let existingInstall = defaults.bool(forKey: Key.onboardingComplete) ||
                defaults.object(forKey: Key.whisperModel) != nil
            let fresh = TranscriptionProviderOption.freshInstallDefault()
            defaults.set((existingInstall ? .whisperLocal : fresh.provider).rawValue, forKey: Key.transcriptionProvider)
            if !existingInstall, let parakeet = fresh.parakeetModel, defaults.object(forKey: Key.parakeetModel) == nil {
                defaults.set(parakeet, forKey: Key.parakeetModel)
            }
        }
        defaults.set(Self.settingsVersion, forKey: Key.settingsVersion)
    }

    private enum Key {
        static let playSounds = "playSounds"
        static let showHUD = "showHUD"
        static let llmCleanupWordThreshold = "llmCleanupWordThreshold"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let microphoneDeviceUID = "microphoneDeviceUID"
        static let cleanupFallbackEnabled = "cleanupFallbackEnabled"
        static let saveHistory = "saveHistory"
        static let appOverrides = "appOverrides"
        static let transcriptionProvider = "transcriptionProvider"
        static let whisperModel = "whisperModel"
        static let parakeetModel = "parakeetModel"
        static let groqTranscriptionModel = "groqTranscriptionModel"
        static let primaryCleanupProvider = "primaryCleanupProvider"
        static let secondaryCleanupProvider = "secondaryCleanupProvider"
        static let groqModel = "groqModel"
        static let cerebrasModel = "cerebrasModel"
        static let customBaseURL = "customBaseURL"
        static let customModel = "customModel"
        static let ollamaModel = "ollamaModel"
        static let cleanupInstructions = "cleanupInstructions"
        static let translateToEnglish = "translateToEnglish"
        static let returnAfterPaste = "returnAfterPaste"
        static let appendTrailingSpace = "appendTrailingSpace"
        static let fuzzyVocabularyCorrection = "fuzzyVocabularyCorrection"
        static let muteWhileRecording = "muteWhileRecording"
        static let customVocabulary = "customVocabulary"
        static let replacementRules = "replacementRules"
        static let hotkeyShortcut = "hotkeyShortcut"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let pauseHotkey = "pauseHotkey"
        static let toggleMode = "toggleMode"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let launchAtLogin = "launchAtLogin"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let preferBuiltInMicOverBluetooth = "preferBuiltInMicOverBluetooth"
        static let allowURLControl = "allowURLControl"
        static let settingsVersion = "settingsVersion"
        /// Written by AppDelegate; read here only to tell an upgrade from a fresh install.
        static let onboardingComplete = "onboardingComplete"
    }

    private var changePosted = false

    private func notifyChanged() {
        // objectWillChange must fire before the mutation is observed (we're @MainActor,
        // called synchronously from setters). The rebuild notification is posted once per
        // runloop turn, however many setters ran in it.
        objectWillChange.send()
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changePosted = false
                NotificationCenter.default.post(name: .settingsStoreDidChange, object: self)
            }
        }
    }

    /// A stored string with surrounding whitespace removed; `fallback` when unset or blank.
    private func nonBlankString(_ key: String, fallback: String) -> String {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    var playSounds: Bool {
        get { defaults.object(forKey: Key.playSounds) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSounds); notifyChanged() }
    }

    var showHUD: Bool {
        get { defaults.object(forKey: Key.showHUD) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showHUD); notifyChanged() }
    }

    var llmCleanupWordThreshold: Int {
        get { max(0, min(200, defaults.object(forKey: Key.llmCleanupWordThreshold) as? Int ?? 12)) }
        set { defaults.set(max(0, min(200, newValue)), forKey: Key.llmCleanupWordThreshold); notifyChanged() }
    }

    var maxRecordingSeconds: Int {
        get { defaults.object(forKey: Key.maxRecordingSeconds) as? Int ?? 300 }
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
                // migrate() pins a value at first launch; this only covers a removed key.
                return TranscriptionProviderOption.freshInstallDefault().provider
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

    /// Parakeet model version: "v2" (English, highest recall) or "v3" (25 European languages).
    var parakeetModel: String {
        get { defaults.string(forKey: Key.parakeetModel) ?? "v2" }
        set { defaults.set(newValue, forKey: Key.parakeetModel); notifyChanged() }
    }

    var groqTranscriptionModel: String {
        get { nonBlankString(Key.groqTranscriptionModel, fallback: "whisper-large-v3-turbo") }
        set { defaults.set(newValue, forKey: Key.groqTranscriptionModel); notifyChanged() }
    }

    var primaryCleanupProvider: CleanupProviderOption {
        get {
            guard let raw = defaults.string(forKey: Key.primaryCleanupProvider) else {
                // Zero-config first run: Apple Intelligence needs no account,
                // key, or install. Groq only when that isn't usable here.
                return CleanupProviderOption.appleIntelligenceUsable ? .appleFoundationModels : .groqAPI
            }
            // A stored provider that no longer exists (removed options like the old
            // CLI providers) or isn't available on this system coerces to a keyless,
            // install-free local default, not a cloud API the user may have no key for.
            guard let provider = CleanupProviderOption(rawValue: raw),
                  provider.isAvailableOnThisSystem else {
                return .defaultFallback
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.primaryCleanupProvider)
            // Compare the stored value: the secondary getter already hides a fallback equal
            // to the primary, and a hidden one would come back when the primary changes.
            if defaults.string(forKey: Key.secondaryCleanupProvider) == newValue.rawValue {
                defaults.removeObject(forKey: Key.secondaryCleanupProvider)
                defaults.set(false, forKey: Key.cleanupFallbackEnabled)
            }
            notifyChanged()
        }
    }

    var secondaryCleanupProvider: CleanupProviderOption? {
        get {
            if let raw = defaults.string(forKey: Key.secondaryCleanupProvider),
               let provider = CleanupProviderOption(rawValue: raw)
            {
                let fallback = provider.isAvailableOnThisSystem ? provider : CleanupProviderOption.defaultFallback
                return fallback == primaryCleanupProvider ? nil : fallback
            }

            // Fallback is on by default only when it's zero-config (Apple
            // Intelligence); implicitly defaulting to Ollama nagged fresh
            // installs to install software they never chose.
            if (defaults.object(forKey: Key.cleanupFallbackEnabled) as? Bool) ?? CleanupProviderOption.appleIntelligenceUsable {
                let fallback = CleanupProviderOption.defaultFallback
                return fallback == primaryCleanupProvider ? nil : fallback
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
        get { nonBlankString(Key.groqModel, fallback: Self.defaultGroqModel) }
        set { defaults.set(newValue, forKey: Key.groqModel); notifyChanged() }
    }

    var cerebrasModel: String {
        get { nonBlankString(Key.cerebrasModel, fallback: Self.defaultCerebrasModel) }
        set { defaults.set(newValue, forKey: Key.cerebrasModel); notifyChanged() }
    }

    var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "gemma4:e2b" }
        set { defaults.set(newValue, forKey: Key.ollamaModel); notifyChanged() }
    }

    /// OpenAI-compatible base URL for the custom cleanup endpoint
    /// (LM Studio, OpenRouter, llama.cpp, LiteLLM, …).
    var customBaseURL: String {
        get { defaults.string(forKey: Key.customBaseURL) ?? "http://localhost:1234/v1" }
        set { defaults.set(newValue, forKey: Key.customBaseURL); notifyChanged() }
    }

    var customModel: String {
        get { defaults.string(forKey: Key.customModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.customModel); notifyChanged() }
    }

    /// Extra user style instructions appended to every cleanup prompt.
    var cleanupInstructions: String {
        get { defaults.string(forKey: Key.cleanupInstructions) ?? "" }
        set { defaults.set(newValue, forKey: Key.cleanupInstructions); notifyChanged() }
    }

    /// Whisper translate task: any spoken language comes out as English.
    var translateToEnglish: Bool {
        get { defaults.bool(forKey: Key.translateToEnglish) }
        set { defaults.set(newValue, forKey: Key.translateToEnglish); notifyChanged() }
    }

    /// Press Return after a successful paste (auto-send in chat apps).
    var returnAfterPaste: Bool {
        get { defaults.bool(forKey: Key.returnAfterPaste) }
        set { defaults.set(newValue, forKey: Key.returnAfterPaste); notifyChanged() }
    }

    var appendTrailingSpace: Bool {
        get { defaults.bool(forKey: Key.appendTrailingSpace) }
        set { defaults.set(newValue, forKey: Key.appendTrailingSpace); notifyChanged() }
    }

    /// Fuzzy-match transcript words against dictionary terms (distance ≤ 1).
    var fuzzyVocabularyCorrection: Bool {
        get { (defaults.object(forKey: Key.fuzzyVocabularyCorrection) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.fuzzyVocabularyCorrection); notifyChanged() }
    }

    var muteWhileRecording: Bool {
        get { defaults.bool(forKey: Key.muteWhileRecording) }
        set { defaults.set(newValue, forKey: Key.muteWhileRecording); notifyChanged() }
    }

    /// Free-text custom vocabulary; terms separated by commas or new lines.
    var customVocabulary: String {
        get { defaults.string(forKey: Key.customVocabulary) ?? "" }
        set { defaults.set(newValue, forKey: Key.customVocabulary); notifyChanged() }
    }

    var vocabularyTerms: [String] {
        customVocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Natural-language prompt used to bias transcription toward the user's vocabulary.
    var vocabularyPrompt: String? {
        let terms = vocabularyTerms
        guard !terms.isEmpty else { return nil }
        return "Glossary: " + terms.joined(separator: ", ") + "."
    }

    var replacementRules: [ReplacementRule] {
        get {
            guard let data = defaults.data(forKey: Key.replacementRules),
                  let rules = try? JSONDecoder().decode([ReplacementRule].self, from: data)
            else { return [] }
            return rules
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.replacementRules)
            notifyChanged()
        }
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

    /// false = hold to talk (release submits); true = tap to start, tap again to submit.
    var toggleMode: Bool {
        get { (defaults.object(forKey: Key.toggleMode) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: Key.toggleMode); notifyChanged() }
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

    /// Record from the Mac's own mic when the system default input is a Bluetooth headset
    /// (not when a mic is pinned, nor while the lid is closed), so the headset keeps its
    /// high-quality output profile (AudioRecorder avoidBluetoothInput).
    var preferBuiltInMicOverBluetooth: Bool {
        get { defaults.bool(forKey: Key.preferBuiltInMicOverBluetooth) }
        set { defaults.set(newValue, forKey: Key.preferBuiltInMicOverBluetooth); notifyChanged() }
    }

    /// murmur:// links can start, stop and cancel dictation. Off by default: any app or
    /// web page can open them.
    var allowURLControl: Bool {
        get { defaults.bool(forKey: Key.allowURLControl) }
        set { defaults.set(newValue, forKey: Key.allowURLControl); notifyChanged() }
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

    var usesLocalParakeet: Bool {
        transcriptionProvider == .parakeetLocal
    }

    var usesGroqAPI: Bool {
        transcriptionProvider == .groqAPI ||
        primaryCleanupProvider == .groqAPI ||
        secondaryCleanupProvider == .groqAPI
    }

    var usesCerebrasAPI: Bool {
        primaryCleanupProvider == .cerebrasAPI ||
        secondaryCleanupProvider == .cerebrasAPI
    }

    var usesCustomAPI: Bool {
        primaryCleanupProvider == .customAPI ||
        secondaryCleanupProvider == .customAPI
    }

    var usesLocalOllama: Bool {
        primaryCleanupProvider == .ollamaLocal ||
        secondaryCleanupProvider == .ollamaLocal
    }

    var usesAppleFoundationModels: Bool {
        primaryCleanupProvider == .appleFoundationModels ||
        secondaryCleanupProvider == .appleFoundationModels
    }

}
