import AppKit

@MainActor
final class DictationOrchestrator {
    private let transcriber: TranscriptionProvider
    private let primary: CleanupProvider?
    private let fallback: CleanupProvider?
    private let detector: ContextDetector
    private let paste: (String) async -> Paster.PasteOutcome
    private let onStage: (DictationStage) -> Void
    private let history: HistoryStore?
    private let replacementRules: [ReplacementRule]
    private let vocabulary: [String]
    private let fuzzyVocabulary: Bool
    private let cleanupInstructions: String
    private let fieldContext: () -> String?
    private let llmCleanupWordThreshold: Int

    private var currentTask: Task<Void, Never>?

    init(
        transcriber: TranscriptionProvider,
        primary: CleanupProvider?,
        fallback: CleanupProvider?,
        detector: ContextDetector,
        paste: @escaping (String) async -> Paster.PasteOutcome,
        onStage: @escaping (DictationStage) -> Void,
        history: HistoryStore?,
        replacementRules: [ReplacementRule] = [],
        vocabulary: [String] = [],
        fuzzyVocabulary: Bool = false,
        cleanupInstructions: String = "",
        fieldContext: @escaping () -> String? = { nil },
        llmCleanupWordThreshold: Int = 12
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
    }

    func cancel() { currentTask?.cancel(); currentTask = nil }

    func run(
        samples: [Float],
        sampleRate: Double,
        didOverflow: Bool,
        streaming: StreamingTranscriptionSession? = nil
    ) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runForTesting(
                samples: samples, sampleRate: sampleRate, didOverflow: didOverflow, streaming: streaming
            )
        }
    }

    func runForTesting(
        samples: [Float],
        sampleRate: Double,
        didOverflow: Bool,
        streaming: StreamingTranscriptionSession? = nil
    ) async {
        guard !samples.isEmpty else {
            onStage(.error(message: "No audio captured"))
            return
        }

        let trimmed = SilenceTrimmer.trim(samples: samples, sampleRate: sampleRate)
        guard !trimmed.isEmpty else {
            onStage(.error(message: "No speech detected"))
            return
        }

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
                raw = try await transcriber.transcribe(samples: trimmed, sampleRate: sampleRate)
            }
        } catch let error as WhisperKitProvider.WhisperError {
            switch error {
            case .emptyResult: onStage(.error(message: "No speech detected"))
            case .notLoaded: onStage(.error(message: "Model failed to load — check logs"))
            }
            return
        } catch StreamingTranscriptionSession.SessionError.noSpeech {
            onStage(.error(message: "No speech detected"))
            return
        } catch {
            onStage(.error(message: "Transcription failed: \(error.localizedDescription)"))
            return
        }
        if Task.isCancelled { return }

        if HallucinationFilter.isLikelyHallucination(text: raw, samples: trimmed, sampleRate: sampleRate) {
            onStage(.error(message: "No speech detected"))
            return
        }
        if fuzzyVocabulary {
            raw = VocabularyCorrector.apply(vocabulary, to: raw)
        }
        raw = TextReplacer.apply(replacementRules, to: raw)

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let mode = detector.mode(for: bundleID)

        // ponytail: under the word threshold LocalCleanup is indistinguishable from
        // LLM cleanup and saves a full model round-trip — short dictations paste instantly.
        let wordCount = raw.split(whereSeparator: \.isWhitespace).count
        let cleanupContext = CleanupContext(
            fieldText: fieldContext(), vocabulary: vocabulary, extraInstructions: cleanupInstructions
        )

        var cleanedText = raw
        var cleanProvider: String? = nil
        var cleanedByLLM = false
        if wordCount >= llmCleanupWordThreshold {
            for provider in [primary, fallback].compactMap({ $0 }) {
                do {
                    onStage(.cleaning(provider: provider.displayName))
                    cleanedText = try await provider.clean(text: raw, mode: mode, context: cleanupContext)
                    cleanProvider = provider.displayName
                    cleanedByLLM = true
                    break
                } catch {
                    if Task.isCancelled { return }
                }
            }
        }
        if !cleanedByLLM {
            cleanedText = LocalCleanup.clean(raw, mode: mode)
            cleanProvider = cleanedText == raw ? nil : LocalCleanup.displayName
        }
        if Task.isCancelled { return }

        // Re-apply after cleanup in case the LLM reintroduced a misspelling.
        if fuzzyVocabulary {
            cleanedText = VocabularyCorrector.apply(vocabulary, to: cleanedText)
        }
        cleanedText = TextReplacer.apply(replacementRules, to: cleanedText)

        let outcome = await paste(cleanedText)
        let words = cleanedText.split(separator: " ").count
        switch outcome.kind {
        case .pasted:
            onStage(.pasted(words: words))
        case .copiedOnly:
            onStage(.copiedOnly(message: outcome.detail))
        }

        if let history, let bundleID {
            try? history.append(.init(
                timestamp: .now,
                raw: raw,
                cleaned: cleanedText,
                bundleID: bundleID,
                appName: appName,
                cleanupProvider: cleanProvider ?? "Raw transcript",
                pasteResult: outcome.kind == .pasted ? "Pasted" : "Copied only",
                pasteDetail: outcome.detail
            ))
        }
    }

}
