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

    private var currentTask: Task<Void, Never>?

    init(
        transcriber: TranscriptionProvider,
        primary: CleanupProvider?,
        fallback: CleanupProvider?,
        detector: ContextDetector,
        paste: @escaping (String) async -> Paster.PasteOutcome,
        onStage: @escaping (DictationStage) -> Void,
        history: HistoryStore?
    ) {
        self.transcriber = transcriber
        self.primary = primary
        self.fallback = fallback
        self.detector = detector
        self.paste = paste
        self.onStage = onStage
        self.history = history
    }

    func cancel() { currentTask?.cancel(); currentTask = nil }

    func run(samples: [Float], sampleRate: Double, didOverflow: Bool) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runForTesting(samples: samples, sampleRate: sampleRate, didOverflow: didOverflow)
        }
    }

    func runForTesting(samples: [Float], sampleRate: Double, didOverflow: Bool) async {
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
        }
        onStage(.transcribing)
        let raw: String
        do {
            raw = try await transcriber.transcribe(samples: trimmed, sampleRate: sampleRate)
        } catch let error as WhisperKitProvider.WhisperError {
            switch error {
            case .emptyResult: onStage(.error(message: "No speech detected"))
            case .notLoaded, .loadTimeout: onStage(.error(message: "Model failed to load — check logs"))
            }
            return
        } catch {
            onStage(.error(message: "Transcription failed: \(error.localizedDescription)"))
            return
        }
        if Task.isCancelled { return }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let mode = detector.mode(for: bundleID)

        var cleanedText = raw
        var cleanProvider: String? = nil
        if let primary {
            do {
                onStage(.cleaning(provider: primary.displayName))
                cleanedText = try await primary.clean(text: raw, mode: mode)
                cleanProvider = primary.displayName
            } catch {
                if let fallback {
                    do {
                        onStage(.cleaning(provider: fallback.displayName))
                        cleanedText = try await fallback.clean(text: raw, mode: mode)
                        cleanProvider = fallback.displayName
                    } catch {
                        cleanedText = LocalCleanup.clean(raw, mode: mode)
                        cleanProvider = cleanedText == raw ? nil : LocalCleanup.displayName
                    }
                } else {
                    cleanedText = LocalCleanup.clean(raw, mode: mode)
                    cleanProvider = cleanedText == raw ? nil : LocalCleanup.displayName
                }
            }
        } else if let fallback {
            do {
                onStage(.cleaning(provider: fallback.displayName))
                cleanedText = try await fallback.clean(text: raw, mode: mode)
                cleanProvider = fallback.displayName
            } catch {
                cleanedText = LocalCleanup.clean(raw, mode: mode)
                cleanProvider = cleanedText == raw ? nil : LocalCleanup.displayName
            }
        } else {
            cleanedText = LocalCleanup.clean(raw, mode: mode)
            cleanProvider = cleanedText == raw ? nil : LocalCleanup.displayName
        }
        if Task.isCancelled { return }

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
