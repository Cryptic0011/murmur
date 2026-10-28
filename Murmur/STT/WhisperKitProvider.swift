import Foundation
import OSLog
@preconcurrency import WhisperKit

actor WhisperKitProvider: TranscriptionProvider {
    enum WhisperError: Error, LocalizedError {
        case notLoaded, emptyResult

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "The Whisper model failed to load."
            case .emptyResult: return "No speech detected."
            }
        }
    }
    nonisolated let displayName = "WhisperKit (local)"

    /// Prompt tokens are force-decoded one by one (they bypass WhisperKit's prefill
    /// cache), so a long glossary adds latency to every 30 s window. VocabularyCorrector
    /// still covers the terms past this cap.
    static let maxPromptTokens = 64
    private static let migrationKey = "whisperModelsMigratedToAppSupport"

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?
    /// transcribe() calls in progress (warm-ups and setup's join aren't counted).
    private var transcriptions = 0
    /// Bumped when a recording starts; a short clip reuses only its own recording's detection.
    private var recording = 0
    /// The language last detected on a clip long enough to trust, and the recording it came
    /// from; a short clip later in that recording (a streaming tail) reuses it.
    private var detectedLanguage: (code: String, recording: Int)?
    private let modelName: String
    private let modelFolder: URL?
    private let vocabularyPrompt: String?
    private let translateToEnglish: Bool
    private let gate = SerialGate()
    private let log = Logger(subsystem: "com.murmur.app", category: "whisper")

    init(modelName: String, vocabularyPrompt: String? = nil, translateToEnglish: Bool = false, modelFolder: URL? = nil) {
        self.modelName = modelName
        self.modelFolder = modelFolder
        self.vocabularyPrompt = vocabularyPrompt
        // English-only (.en) models can't run the translate task.
        self.translateToEnglish = translateToEnglish && !modelName.hasSuffix(".en")
    }

    /// tiny/base decode a few seconds of audio in well under the preview interval.
    nonisolated var supportsLivePreview: Bool {
        modelName.contains("tiny") || modelName.contains("base")
    }

    /// ~/Library/Application Support/Murmur/Models — WhisperKit's Hub download base
    /// (models land in `models/argmaxinc/whisperkit-coreml/<model>`, tokenizers in
    /// `models/openai/<tokenizer>`). Kept out of ~/Documents: no folder-access prompt,
    /// no iCloud Desktop & Documents sync or eviction.
    nonisolated static var modelStore: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Murmur/Models", isDirectory: true)
    }

    /// The model's folder in the store (or under `base`, a Hub download base) when every
    /// required CoreML bundle is present; nil for missing or half-finished downloads.
    nonisolated static func downloadedModelFolder(model: String, base: URL? = nil) -> URL? {
        guard !model.isEmpty, !model.contains("/"), !model.contains(".."),
              let base = base ?? modelStore else {
            return nil
        }
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model)
        guard ["AudioEncoder", "MelSpectrogram", "TextDecoder"].allSatisfy({ name in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".mlmodelc").path) ||
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".mlpackage").path)
        }) else { return nil }
        return folder
    }

    /// Legacy layout: `<documents>/huggingface/models/...` as used before the store moved.
    nonisolated static func downloadedModelFolder(model: String, documents: URL) -> URL? {
        downloadedModelFolder(model: model, base: documents.appendingPathComponent("huggingface"))
    }

    /// One-time copy of the configured model (and the Whisper tokenizers) that ≤0.2.x
    /// downloaded into ~/Documents/huggingface. The caller passes `isExistingInstall`; fresh
    /// installs never touch ~/Documents (that alone would raise the folder-access prompt).
    /// Runs at most once either way; a failed copy just means the model is downloaded again.
    ///
    /// ~/Documents/huggingface is HubApi's default download base, shared by every WhisperKit
    /// tool (whisperkit-cli, other apps), so nothing there is moved: only the model Murmur
    /// uses is copied (an APFS clone: instant, no extra space), other variants and `.cache`
    /// stay untouched, and the originals keep working for whoever else uses them.
    @discardableResult
    nonisolated static func migrateLegacyModelsIfNeeded(
        isExistingInstall: Bool,
        defaults: UserDefaults = .standard,
        documents: URL? = nil,
        store: URL? = nil
    ) -> [URL] {
        guard !defaults.bool(forKey: migrationKey) else { return [] }
        defaults.set(true, forKey: migrationKey)
        let fm = FileManager.default
        guard isExistingInstall,
              let documents = documents ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let store = store ?? modelStore else { return [] }

        let log = Logger(subsystem: "com.murmur.app", category: "whisper")
        // SettingsStore's `whisperModel` key and default.
        let model = defaults.string(forKey: "whisperModel") ?? "openai_whisper-small.en"
        var copied: [URL] = []
        // (repo folder, which children are ours) — tokenizers sit beside other HF repos.
        // ponytail: every openai/whisper* tokenizer is copied (a few MB, cloned); mapping the
        // model to its exact tokenizer needs WhisperKit's variant detection.
        let repos: [(String, (String) -> Bool)] = [
            ("argmaxinc/whisperkit-coreml", { $0 == model }),
            ("openai", { $0.hasPrefix("whisper") }),
        ]
        for (repo, isOurs) in repos {
            let source = documents.appendingPathComponent("huggingface/models").appendingPathComponent(repo)
            guard let children = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { continue }
            let destination = store.appendingPathComponent("models").appendingPathComponent(repo)
            for child in children where isOurs(child.lastPathComponent) {
                let target = destination.appendingPathComponent(child.lastPathComponent)
                guard !fm.fileExists(atPath: target.path) else { continue }
                do {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    try fm.copyItem(at: child, to: target)
                    copied.append(target)
                } catch {
                    try? fm.removeItem(at: target) // no half-copied model left looking complete
                    log.error("Model migration failed for \(child.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if !copied.isEmpty { Self.prepareStore(store) }
        return copied
    }

    /// Creates the store and keeps its gigabytes of re-downloadable models out of backups.
    private nonisolated static func prepareStore(_ store: URL) {
        var url = store
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Logger(subsystem: "com.murmur.app", category: "whisper")
                .error("Model store setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Downloads `model` into the store unless it is already there. No network at all when
    /// it is on disk. `force` re-runs the Hub snapshot, which fetches only missing files.
    /// `onProgress` gets 0...1 while downloading.
    nonisolated static func downloadModelIfNeeded(
        model: String,
        force: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if !force, let folder = downloadedModelFolder(model: model) { return folder }
        guard let store = modelStore else { throw WhisperError.notLoaded }
        return try await Self.downloads.folder(for: model) {
            Self.prepareStore(store)
            return try await WhisperKit.download(variant: model, downloadBase: store, progressCallback: { progress in
                onProgress?(progress.fractionCompleted)
            })
        }
    }

    /// Setup and the runtime provider both ask for the model at launch; share one download.
    private static let downloads = DownloadRegistry()

    actor DownloadRegistry {
        /// Each download with the callers still waiting on it. Every caller has its own
        /// continuation: awaiting the shared task's value can't end early on cancellation.
        private var inFlight: [String: (id: UUID, task: Task<Void, Never>, waiters: [UUID: CheckedContinuation<URL, Error>])] = [:]

        // ponytail: a second caller joins the first download without its own progress callback.
        /// Joins `model`'s download or starts it. A cancelled caller leaves it at once; the
        /// download itself is cancelled only once every caller has left, so one superseded
        /// provider can't fail another's join of the same model.
        func folder(for model: String, start: @escaping @Sendable () async throws -> URL) async throws -> URL {
            let caller = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if inFlight[model] != nil {
                        inFlight[model]?.waiters[caller] = continuation
                    } else {
                        let id = UUID()
                        let task = Task {
                            let result: Result<URL, Error>
                            do { result = .success(try await start()) } catch { result = .failure(error) }
                            self.finish(model, id, result)
                        }
                        inFlight[model] = (id, task, [caller: continuation])
                    }
                }
            } onCancel: {
                Task { await self.leave(model, caller) }
            }
        }

        private func finish(_ model: String, _ id: UUID, _ result: Result<URL, Error>) {
            guard let entry = inFlight[model], entry.id == id else { return }
            inFlight[model] = nil
            entry.waiters.values.forEach { $0.resume(with: result) }
        }

        private func leave(_ model: String, _ caller: UUID) {
            guard let continuation = inFlight[model]?.waiters.removeValue(forKey: caller) else { return }
            continuation.resume(throwing: CancellationError())
            guard let entry = inFlight[model], entry.waiters.isEmpty else { return }
            // Gone from the table at once, so a new caller starts afresh instead of
            // joining a download that is winding down.
            inFlight[model] = nil
            entry.task.cancel()
        }
    }

    func isLoaded() -> Bool { pipe != nil }

    /// Loads the CoreML models (downloading first only when they aren't on disk).
    func ensureLoaded(logFailures: Bool = true, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if pipe != nil { return }
        if let loadTask {
            pipe = try await loadTask.value
            return
        }

        let name = modelName
        let explicitFolder = modelFolder
        let task = Task { () async throws -> WhisperKit in
            // load: true actually loads the models here (WhisperKit only auto-loads when it
            // was given a folder). download: false — the folder exists, so no Hub call and a
            // cached model works offline. Tokenizers resolve under the store (downloadBase).
            func load(_ folder: URL) async throws -> WhisperKit {
                try await WhisperKit(WhisperKitConfig(
                    model: name, downloadBase: Self.modelStore, modelFolder: folder.path,
                    load: true, download: false
                ))
            }
            if let explicitFolder { return try await load(explicitFolder) }
            let folder = try await Self.downloadModelIfNeeded(model: name, onProgress: onProgress)
            // Superseded meanwhile: don't spend a full CoreML load on an abandoned model.
            try Task.checkCancellation()
            do {
                return try await load(folder)
            } catch {
                // A cached folder that won't load is usually a download cut short (CoreML
                // bundles land file by file). Let the Hub fill in the gaps once; offline,
                // the original error stands.
                guard !Self.isCancellationLike(error), !Task.isCancelled,
                      let repaired = try? await Self.downloadModelIfNeeded(model: name, force: true, onProgress: onProgress)
                else { throw error }
                return try await load(repaired)
            }
        }
        loadTask = task
        log.info("Loading WhisperKit model '\(self.modelName, privacy: .public)'...")
        let started = Date()
        do {
            pipe = try await task.value
            if loadTask == task { loadTask = nil }
            log.info("Model loaded in \(Date().timeIntervalSince(started))s")
        } catch {
            // A cancelled load finishing late must not clear a newer one.
            if loadTask == task { loadTask = nil }
            if logFailures, !Self.isCancellationLike(error) {
                log.error("WhisperKit init failed: \(String(describing: error), privacy: .public)")
            } else {
                log.info("WhisperKit load was cancelled before completion.")
            }
            throw error
        }
    }

    /// Abandons the in-flight download and load (the instance was superseded by a
    /// different model). The download stops unless another caller still waits on it.
    /// A dictation already waiting on this instance keeps its load: cancelling would drop it.
    // ponytail: a skipped cancel isn't redone later; a transcription only stops waiting once the load has ended.
    func cancelLoad() {
        guard transcriptions == 0 else { return }
        loadTask?.cancel()
        loadTask = nil
    }

    func beginRecording() {
        recording += 1
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        transcriptions += 1
        defer { transcriptions -= 1 }
        // Taken before any await: a tail queued behind its chunks keeps its own recording.
        let recording = self.recording
        try await ensureLoaded(logFailures: true)
        // One decode at a time on the shared pipe; queued callers re-check cancellation.
        return try await gate.run {
            try await self.decode(samples: samples, recording: recording)
        }
    }

    private func decode(samples: [Float], recording: Int) async throws -> String {
        try Task.checkCancellation()
        guard let pipe else { throw WhisperError.notLoaded }
        let started = Date()
        var options = DecodingOptions()
        // With no language set, WhisperKit's prefill forces <|en|> on multilingual models
        // (detectLanguage defaults to false while usePrefillPrompt is on), so other languages
        // came out as English. Detect it per window; WhisperKit skips this for English-only models.
        options.detectLanguage = true
        // Language ID on a short, mostly padded window is Whisper's weakest case (a 0.5 s
        // tail could come out as German), so a short clip reuses its own recording's language.
        let seconds = Double(samples.count) / Double(WhisperKit.sampleRate)
        options.language = Self.pinnedLanguage(seconds: seconds, lastDetected: detectedLanguage, recording: recording)
        if translateToEnglish {
            options.task = .translate
        }
        // Bias decoding toward the user's custom vocabulary via Whisper's prompt window.
        if let vocabularyPrompt, !vocabularyPrompt.isEmpty, let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + vocabularyPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                .prefix(Self.maxPromptTokens)
            if !tokens.isEmpty {
                options.promptTokens = Array(tokens)
                options.usePrefillPrompt = true
            }
        }
        // Whisper decoding isn't natively cancellable; the progress callback
        // returning false aborts the decode when our task gets cancelled (Esc).
        let cancelFlag = CancelFlag()
        let results = try await withTaskCancellationHandler {
            try await pipe.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in
                cancelFlag.isSet ? false : nil
            })
        } onCancel: {
            cancelFlag.set()
        }
        try Task.checkCancellation()
        log.info("Transcribed in \(Date().timeIntervalSince(started))s")
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw WhisperError.emptyResult }
        // Only a long clip's detection is kept; a short one's (or the warm-up's) is the guess we avoid reusing.
        if seconds >= Self.minLanguageDetectionSeconds, let language = results.first?.language {
            detectedLanguage = (language, recording)
        }
        return text
    }

    /// Below this, Whisper's language ID is unreliable ("Yes.", a streaming tail).
    static let minLanguageDetectionSeconds = 2.0

    /// The language to force on a clip of `seconds`, or nil to let Whisper detect it. A short
    /// clip reuses a language detected earlier in its own recording; a new recording's short
    /// clip is detected, so a standalone "Thanks." isn't forced into the previous dictation's language.
    // ponytail: no languageProbs confidence check; WhisperKit's transcribe doesn't return them.
    static func pinnedLanguage(
        seconds: Double, lastDetected: (code: String, recording: Int)?, recording: Int
    ) -> String? {
        guard seconds < minLanguageDetectionSeconds, let lastDetected,
              lastDetected.recording == recording else { return nil }
        return lastDetected.code
    }

    func warmUp() async {
        // ponytail: settings changes rebuild providers and cancel the previous warm-up;
        // a short pause coalesces a burst of rebuilds into one model load.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        do {
            try await ensureLoaded(logFailures: false)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        // The first CoreML/ANE prediction after a load pays for program setup and
        // specialization; spend it on 1 s of silence now instead of at key release.
        _ = try? await transcribe(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    private static func isCancellationLike(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return String(describing: error).localizedCaseInsensitiveContains("cancelled")
    }
}

extension WhisperKitProvider: WarmableTranscriptionProvider {}
extension WhisperKitProvider: ModelLoadCancellable {}
