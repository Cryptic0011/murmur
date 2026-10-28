import AppKit
import OSLog

/// What a dictation is aimed at, captured at hotkey press: switching apps while it
/// is processing can't change its style, history label or paste target.
struct DictationTarget: Sendable, Equatable {
    /// The frontmost app at press; the paste goes nowhere else (Paster copies instead).
    /// nil: don't check — Murmur itself was frontmost, e.g. a murmur:// link activated it.
    var frontmostPID: pid_t?
    /// The app with keyboard focus at press (ContextDetector.targetApplication); a
    /// Spotlight/Raycast panel takes focus without becoming frontmost. nil when Murmur was frontmost.
    var focusedPID: pid_t?
    /// The app dictation is aimed at (see ContextDetector.targetApplication).
    var bundleID: String?
    var appName = "Unknown"
    /// Text before the caret, read only when an LLM cleanup can use it.
    var fieldText: String?
}

/// What the paste closure gets for one dictation.
struct PasteRequest: Sendable {
    let text: String
    let target: DictationTarget
    let mode: CleanupMode
    /// False for murmur:// sessions: another app must never get Return pressed for it.
    let allowsReturn: Bool
}

/// How a run ended.
enum DictationOutcome: Sendable, Equatable {
    case pasted
    case copiedOnly
    /// Nothing worth pasting: no audio, silence, or no words left after cleanup.
    case noSpeech
    /// Transcription failed; the recording is worth a retry.
    case failed
    case cancelled
}

/// Which cleanup failures the user has already been told about, so a bad key gets one
/// HUD note rather than one per dictation. Outlives the orchestrators settings rebuild.
@MainActor
final class CleanupFailureNotices {
    private var shown: [String: String] = [:]

    /// True the first time `provider` fails for `reason`, and again once it has recovered.
    func shouldNote(provider: String, reason: String) -> Bool {
        guard shown[provider] != reason else { return false }
        shown[provider] = reason
        return true
    }

    func succeeded(provider: String) { shown[provider] = nil }
}

@MainActor
final class DictationOrchestrator {
    private static let log = Logger(subsystem: "com.murmur.app", category: "pipeline")
    /// With less time than this left, a cleanup attempt can't finish; LocalCleanup takes over.
    private static let minCleanupAttemptSeconds: TimeInterval = 1

    private let transcriber: TranscriptionProvider
    private let primary: CleanupProvider?
    private let fallback: CleanupProvider?
    private let detector: ContextDetector
    private let paste: (PasteRequest) async -> Paster.PasteOutcome
    private let onStage: (DictationStage) -> Void
    private let history: HistoryStore?
    private let replacementRules: [ReplacementRule]
    private let vocabulary: [String]
    private let fuzzyVocabulary: Bool
    private let cleanupInstructions: String
    private let fieldContext: () -> String?
    private let llmCleanupWordThreshold: Int
    private let cleanupDeadline: (Int) -> TimeInterval
    private let failureNotices: CleanupFailureNotices

    init(
        transcriber: TranscriptionProvider,
        primary: CleanupProvider?,
        fallback: CleanupProvider?,
        detector: ContextDetector,
        paste: @escaping (PasteRequest) async -> Paster.PasteOutcome,
        onStage: @escaping (DictationStage) -> Void = { _ in },
        history: HistoryStore?,
        replacementRules: [ReplacementRule] = [],
        vocabulary: [String] = [],
        fuzzyVocabulary: Bool = false,
        cleanupInstructions: String = "",
        fieldContext: @escaping () -> String? = { nil },
        llmCleanupWordThreshold: Int = 12,
        cleanupDeadline: @escaping (Int) -> TimeInterval = DictationOrchestrator.cleanupDeadline(wordCount:),
        failureNotices: CleanupFailureNotices? = nil
    ) {
        self.transcriber = transcriber
        self.primary = primary
        self.fallback = fallback
        self.detector = detector
        self.paste = paste
        self.onStage = onStage
        self.history = history
        self.replacementRules = replacementRules
        self.vocabulary = vocabulary
        self.fuzzyVocabulary = fuzzyVocabulary
        self.cleanupInstructions = cleanupInstructions
        self.fieldContext = fieldContext
        self.llmCleanupWordThreshold = llmCleanupWordThreshold
        self.cleanupDeadline = cleanupDeadline
        self.failureNotices = failureNotices ?? CleanupFailureNotices()
    }

    /// Whether cleanup can reach an LLM, i.e. whether the field text is worth reading.
    var usesLLMCleanup: Bool {
        [primary, fallback].contains { provider in
            guard let provider else { return false }
            return !(provider is BuiltInCleanupProvider)
        }
    }

    /// The app dictation is aimed at right now, plus the text before the caret when an
    /// LLM may use it. Called at hotkey press.
    func captureTarget(includingFieldText: Bool = true) -> DictationTarget {
        let app = ContextDetector.targetApplication()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownFront = frontmost == ProcessInfo.processInfo.processIdentifier
        return DictationTarget(
            frontmostPID: ownFront ? nil : frontmost,
            focusedPID: ownFront ? nil : app?.processIdentifier,
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName ?? "Unknown",
            fieldText: includingFieldText ? fieldTextForCleanup() : nil
        )
    }

    /// The text before the caret, only when an LLM could use it: a synchronous
    /// Accessibility read that Built-in rules never need.
    func fieldTextForCleanup() -> String? {
        usesLLMCleanup ? fieldContext() : nil
    }

    @discardableResult
    func runForTesting(
        samples: [Float],
        sampleRate: Double,
        didOverflow: Bool = false,
        streaming: StreamingTranscriptionSession? = nil
    ) async -> DictationOutcome {
        await process(samples: samples, sampleRate: sampleRate, didOverflow: didOverflow, streaming: streaming)
    }

    /// Transcribes, cleans and pastes one recording.
    /// - Parameters:
    ///   - target: captured at hotkey press; nil resolves it now.
    ///   - notice: a remark for the result HUD, e.g. that the length limit was hit.
    ///   - previous: the run before this one. This run waits for it right before pasting,
    ///     so back-to-back dictations paste in order and never race on the clipboard.
    ///     Nothing here cancels another run.
    ///   - onStage: this run's stage handler (the init's by default).
    ///   - onPasteBegan: the point of no return; from here the paste always completes.
    @discardableResult
    func process(
        samples: [Float],
        sampleRate: Double,
        didOverflow: Bool = false,
        streaming: StreamingTranscriptionSession? = nil,
        target: DictationTarget? = nil,
        allowsReturn: Bool = true,
        notice: String? = nil,
        after previous: Task<Void, Never>? = nil,
        onStage stageHandler: ((DictationStage) -> Void)? = nil,
        onPasteBegan: (() -> Void)? = nil
    ) async -> DictationOutcome {
        let onStage = stageHandler ?? self.onStage
        // A cancelled or failed run must not leave chunk transcriptions running.
        defer { streaming?.cancel() }

        guard !samples.isEmpty else {
            onStage(.error(message: "No audio captured"))
            return .noSpeech
        }

        let trimmed = SilenceTrimmer.trim(samples: samples, sampleRate: sampleRate)
        guard !trimmed.isEmpty else {
            onStage(.error(message: "No speech detected"))
            return .noSpeech
        }

        let target = target ?? captureTarget()
        let mode = detector.mode(for: target.bundleID)
        let cleanupContext = CleanupContext(
            fieldText: target.fieldText, vocabulary: vocabulary, extraInstructions: cleanupInstructions
        )

        if let wk = transcriber as? WhisperKitProvider {
            let loaded = await wk.isLoaded()
            if !loaded { onStage(.loadingModel) }
        } else if let pk = transcriber as? ParakeetProvider {
            let loaded = await pk.isLoaded()
            if !loaded { onStage(.loadingModel) }
        }
        onStage(.transcribing)
        var raw: String
        do {
            if let streaming {
                // Chunks were transcribed during recording; this joins them + the tail.
                raw = try await streaming.finish(samples: samples)
            } else {
                // A whole clip (a retry, say) is its own recording; it mustn't reuse the previous one's language.
                await transcriber.beginRecording()
                raw = try await transcriber.transcribe(samples: trimmed, sampleRate: sampleRate)
            }
        } catch {
            return transcriptionFailed(error, onStage: onStage)
        }
        if Task.isCancelled { return .cancelled }

        if HallucinationFilter.isLikelyHallucination(text: raw, samples: trimmed, sampleRate: sampleRate) {
            onStage(.error(message: "No speech detected"))
            return .noSpeech
        }
        raw = applyRules(to: raw)
        guard Self.hasWords(raw) else {
            onStage(.error(message: "No speech detected"))
            return .noSpeech
        }

        // ponytail: under the word threshold LocalCleanup is indistinguishable from
        // LLM cleanup and saves a full model round-trip — short dictations paste instantly.
        let wordCount = Self.wordCount(raw)

        var cleanedText = raw
        var cleanProvider: String? = nil
        var cleanedByLLM = false
        var notes = [notice ?? (didOverflow ? "Stopped at the length limit" : nil)].compactMap { $0 }
        if wordCount >= llmCleanupWordThreshold {
            // One cap for primary + fallback together, so a hung provider and a slow fallback
            // can't hold the paste back; LocalCleanup takes over when it runs out.
            let deadline = Date().addingTimeInterval(cleanupDeadline(wordCount))
            var primaryFailure: String?
            for (attempt, provider) in [primary, fallback].compactMap({ $0 }).enumerated() {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > Self.minCleanupAttemptSeconds else { break }
                onStage(.cleaning(provider: provider.displayName))
                do {
                    let text = raw
                    cleanedText = try await withCleanupTimeout(
                        seconds: min(provider.timeBudget(wordCount: wordCount) + 0.5, remaining)
                    ) {
                        try await provider.clean(text: text, mode: mode, context: cleanupContext)
                    }
                    cleanProvider = provider.displayName
                    cleanedByLLM = true
                    failureNotices.succeeded(provider: provider.displayName)
                    break
                } catch {
                    if Task.isCancelled { return .cancelled }
                    let reason = Self.cleanupFailureReason(error)
                    Self.log.error("\(provider.displayName, privacy: .public) cleanup failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .private)")
                    // Only a configured cloud provider earns a note: its failures (a bad key,
                    // a quota) are the user's to fix, and otherwise only show up as worse text.
                    if attempt == 0, primary is OpenAICompatibleProvider { primaryFailure = reason }
                }
            }
            if let reason = primaryFailure, let name = primary?.displayName,
               failureNotices.shouldNote(provider: name, reason: reason) {
                notes.append("\(name) cleanup failed (\(reason)) — used \(cleanProvider ?? "built-in rules")")
            }
        }
        if !cleanedByLLM {
            cleanedText = LocalCleanup.clean(raw, mode: mode)
            cleanProvider = cleanedText == raw ? nil : LocalCleanup.displayName
        }
        if Task.isCancelled { return .cancelled }

        // Again after cleanup: an LLM can reintroduce a misspelling, and LocalCleanup's
        // sentence capitalization undoes a rule's casing ("iPhone" → "IPhone"). TextReplacer
        // is safe to apply twice, so expansions never double.
        cleanedText = applyRules(to: cleanedText)
        // Never paste (or press Return on) nothing.
        guard Self.hasWords(cleanedText) else {
            onStage(.error(message: "No speech detected"))
            return .noSpeech
        }

        // Pastes land in dictation order and never overlap on the clipboard.
        await previous?.value
        if Task.isCancelled { return .cancelled }

        onPasteBegan?()
        let request = PasteRequest(text: cleanedText, target: target, mode: mode, allowsReturn: allowsReturn)
        let paste = self.paste
        // Unstructured on purpose: once Cmd-V is on its way, cancellation must not cut the
        // confirm and clipboard-restore waits short.
        let outcome = await Task { await paste(request) }.value

        // Cancelled mid-paste: whoever cancelled has already reset the HUD, but the text landed.
        if !Task.isCancelled {
            switch outcome.kind {
            case .pasted:
                onStage(.pasted(words: Self.wordCount(cleanedText), note: notes.isEmpty ? nil : notes.joined(separator: " · ")))
            case .copiedOnly:
                onStage(.copiedOnly(message: outcome.detail))
            }
        }

        // Dictated passwords never reach history.json.
        if let history, !outcome.isSecureTarget {
            do {
                try history.append(.init(
                    timestamp: .now,
                    raw: raw,
                    cleaned: cleanedText,
                    bundleID: target.bundleID ?? "unknown",
                    appName: target.appName,
                    cleanupProvider: cleanProvider ?? "Raw transcript",
                    pasteResult: outcome.kind == .pasted ? "Pasted" : "Copied only",
                    pasteDetail: outcome.detail
                ))
            } catch {
                Self.log.error("History append failed: \(String(describing: error), privacy: .public)")
            }
        }
        return outcome.kind == .pasted ? .pasted : .copiedOnly
    }

    private func transcriptionFailed(_ error: Error, onStage: (DictationStage) -> Void) -> DictationOutcome {
        // Esc, not a failure: the HUD is already idle.
        if Task.isCancelled { return .cancelled }  // Esc cancels the run's own task
        // A provider cancelled itself while the run went on: keep the recording for Retry.
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            onStage(.error(message: "Transcription was interrupted — use Retry Last Dictation"))
            return .failed
        }
        if TranscriptionError.isNoSpeech(error)
            || (error as? StreamingTranscriptionSession.SessionError) == .noSpeech {
            onStage(.error(message: "No speech detected"))
            return .noSpeech
        }
        Self.log.error("Transcription failed: \(String(describing: error), privacy: .public)")
        if case .notLoaded? = error as? WhisperKitProvider.WhisperError {
            onStage(.error(message: "Model failed to load — check logs"))
        } else if case .notLoaded? = error as? ParakeetProvider.ParakeetError {
            onStage(.error(message: "Model failed to load — check logs"))
        } else {
            onStage(.error(message: "Transcription failed: \(error.localizedDescription)"))
        }
        return .failed
    }

    private func applyRules(to text: String) -> String {
        let corrected = fuzzyVocabulary ? VocabularyCorrector.apply(vocabulary, to: text) : text
        return TextReplacer.apply(replacementRules, to: corrected)
    }

    /// Overall cleanup cap, primary and fallback together: room for one provider's own
    /// budget plus most of a fallback's, but never half a minute of waiting to paste.
    nonisolated static func cleanupDeadline(wordCount: Int) -> TimeInterval {
        min(20, 10 + 0.03 * Double(wordCount))
    }

    /// Words, for the LLM threshold and the HUD. Chinese and Japanese are written without
    /// spaces, so each character counts (a word there is one to three of them); other
    /// unspaced scripts (Thai) count dictionary words. Punctuation and bullets don't count.
    nonisolated static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            guard let word else { return }
            count += max(word.unicodeScalars.filter(isCJK).count, 1)
        }
        return count
    }

    // ponytail: Han plus Hiragana/Katakana; Hangul is written with spaces, halfwidth kana is rare.
    nonisolated private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
    }

    /// Anything worth pasting: a letter or digit, not just spaces and punctuation.
    nonisolated static func hasWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// A short, content-free reason for logs and the HUD note.
    nonisolated static func cleanupFailureReason(_ error: Error) -> String {
        if #available(macOS 26.0, *), let error = error as? AppleFoundationModelsProvider.FoundationModelsError {
            switch error {
            case .truncated, .emptyResponse: return "unusable reply"
            case .inputTooLong: return "too long"
            case .modelUnavailable: return "error"
            }
        }
        switch error {
        case is CleanupTimeoutError:
            return "timed out"
        case let error as OpenAICompatibleProvider.ProviderError:
            switch error {
            case .badStatus(401, _), .badStatus(403, _): return "invalid API key"
            case .badStatus(429, _): return "rate limited"
            case .badStatus(let code, _): return "HTTP \(code)"
            case .missingAPIKey: return "no API key"
            case .insecureEndpoint: return "endpoint must use HTTPS"
            case .decodeFailed, .truncated, .rejectedByGuard: return "unusable reply"
            }
        case let error as URLError:
            return error.code == .notConnectedToInternet ? "offline" : "network error"
        default:
            return "error"
        }
    }
}
