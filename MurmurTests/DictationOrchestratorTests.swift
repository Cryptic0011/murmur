import Testing
import Foundation
@testable import Murmur

actor MockTranscriber: TranscriptionProvider {
    var result: Result<String, Error>
    nonisolated let displayName = "Mock STT"
    init(_ r: Result<String, Error>) { result = r }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String { try result.get() }
}

/// Answers after `delay` seconds; a cancelled caller gets CancellationError, like WhisperKit.
actor SlowTranscriber: TranscriptionProvider {
    nonisolated let displayName = "Slow STT"
    private let text: String
    private let delay: TimeInterval
    init(_ text: String, delay: TimeInterval) {
        self.text = text
        self.delay = delay
    }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return text
    }
}

@MainActor
final class StageRecorder {
    var stages: [DictationStage] = []
    func record(_ s: DictationStage) { stages.append(s) }
    var sawError: Bool { stages.contains { if case .error = $0 { return true } else { return false } } }
}

/// Every paste, in order, and whether two ever ran at once.
@MainActor
final class PasteLog {
    var texts: [String] = []
    var overlapped = false
    /// Whether each paste could still see its caller's cancellation after its waits.
    var sawCancellation: [Bool] = []
    private var active = 0

    func paste(_ request: PasteRequest, taking seconds: TimeInterval = 0) async -> Paster.PasteOutcome {
        active += 1
        if active > 1 { overlapped = true }
        texts.append(request.text)
        if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        sawCancellation.append(Task.isCancelled)
        active -= 1
        return .pasted()
    }
}

@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Suite("DictationOrchestrator")
struct DictationOrchestratorTests {
    /// Loud enough for SilenceTrimmer, so the transcriber is actually called.
    static let speech = [Float](repeating: 0.2, count: 1_600)
    static let detector = ContextDetector(defaults: [:], userOverrides: [])

    @MainActor
    @Test("happy path: transcribe → groq cleanup → paste the cleaned text")
    func happyPath() async throws {
        let recorder = StageRecorder()
        let log = PasteLog()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello world")),
            primary: MockCleanupProvider(name: "Groq", responses: [.success("Hello, world.")]),
            fallback: nil,
            detector: Self.detector,
            paste: { await log.paste($0) },
            onStage: { recorder.record($0) },
            history: nil,
            llmCleanupWordThreshold: 0
        )
        let outcome = await orch.runForTesting(samples: [0.1, 0.2], sampleRate: 16_000)
        #expect(outcome == .pasted)
        #expect(log.texts == ["Hello, world."])
        #expect(recorder.stages.contains(.transcribing))
        #expect(recorder.stages.contains(.cleaning(provider: "Groq")))
        #expect(recorder.stages.last == .pasted(words: 2))
    }

    @MainActor
    @Test("short dictation skips LLM cleanup")
    func shortDictationSkipsLLM() async throws {
        let recorder = StageRecorder()
        let log = PasteLog()
        let cleanup = MockCleanupProvider(name: "Groq", responses: [.success("should not be used")])
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("send it over now please")),
            primary: cleanup,
            fallback: nil,
            detector: Self.detector,
            paste: { await log.paste($0) },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0.1, 0.2], sampleRate: 16_000)
        let cleanedViaLLM = recorder.stages.contains { if case .cleaning = $0 { return true } else { return false } }
        #expect(!cleanedViaLLM)
        #expect(await cleanup.callCount() == 0)
        #expect(log.texts == [LocalCleanup.clean("send it over now please", mode: .prose)])
        #expect(recorder.stages.contains(.pasted(words: 5)))
    }

    @MainActor
    @Test("vocabulary and field context reach the cleanup provider")
    func contextReachesProvider() async throws {
        let cleanup = MockCleanupProvider(name: "Groq", responses: [.success("Cleaned.")])
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello world")),
            primary: cleanup,
            fallback: nil,
            detector: Self.detector,
            paste: { _ in .pasted() },
            onStage: { _ in },
            history: nil,
            vocabulary: ["Murmur"],
            fieldContext: { "Hi team," },
            llmCleanupWordThreshold: 0
        )
        await orch.runForTesting(samples: [0.1], sampleRate: 16_000)
        let context = await cleanup.calls.first?.context
        #expect(context == CleanupContext(fieldText: "Hi team,", vocabulary: ["Murmur"]))
    }

    @MainActor
    @Test("the field is read only when an LLM could use it")
    func fieldContextOnlyForLLM() async throws {
        let reads = Box(0)
        func orchestrator(primary: CleanupProvider?) -> DictationOrchestrator {
            DictationOrchestrator(
                transcriber: MockTranscriber(.success("x")), primary: primary, fallback: nil,
                detector: Self.detector, paste: { _ in .pasted() }, history: nil,
                fieldContext: { reads.value += 1; return "before" }
            )
        }
        #expect(orchestrator(primary: BuiltInCleanupProvider()).fieldTextForCleanup() == nil)
        #expect(orchestrator(primary: nil).fieldTextForCleanup() == nil)
        #expect(reads.value == 0)
        #expect(orchestrator(primary: MockCleanupProvider(responses: [])).fieldTextForCleanup() == "before")
        #expect(reads.value == 1)
    }

    @MainActor
    @Test("primary fails → fallback used")
    func fallback() async throws {
        let recorder = StageRecorder()
        let log = PasteLog()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello")),
            primary: MockCleanupProvider(name: "Groq", responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(name: "Gemma", responses: [.success("Hello.")]),
            detector: Self.detector,
            paste: { await log.paste($0) },
            onStage: { recorder.record($0) },
            history: nil,
            llmCleanupWordThreshold: 0
        )
        await orch.runForTesting(samples: [0.1], sampleRate: 16_000)
        #expect(recorder.stages.contains(.cleaning(provider: "Gemma")))
        #expect(recorder.stages.contains(.pasted(words: 1)))
        #expect(log.texts == ["Hello."])
    }

    @MainActor
    @Test("both providers fail → local cleanup is pasted")
    func bothFail() async throws {
        let recorder = StageRecorder()
        let log = PasteLog()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("raw text here")),
            primary: MockCleanupProvider(responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(responses: [.failure(NSError(domain: "y", code: 2))]),
            detector: Self.detector,
            paste: { await log.paste($0) },
            onStage: { recorder.record($0) },
            history: nil,
            llmCleanupWordThreshold: 0
        )
        await orch.runForTesting(samples: [0.1], sampleRate: 16_000)
        #expect(recorder.stages.contains(.pasted(words: 3)))
        #expect(log.texts == [LocalCleanup.clean("raw text here", mode: .prose)])
    }

    @MainActor
    @Test("empty transcription → error stage")
    func emptyStt() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.failure(WhisperKitProvider.WhisperError.emptyResult)),
            primary: MockCleanupProvider(responses: []),
            fallback: nil,
            detector: Self.detector,
            paste: { _ in .pasted() },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0], sampleRate: 16_000)
        #expect(recorder.sawError)
    }

    @MainActor
    @Test("every engine's empty result reads as no speech, not a failure")
    func emptyResultsAreNoSpeech() async throws {
        let errors: [Error] = [
            ParakeetProvider.ParakeetError.emptyResult,
            TranscriptionError.noSpeech,
            StreamingTranscriptionSession.SessionError.noSpeech,
        ]
        for error in errors {
            let recorder = StageRecorder()
            let orch = DictationOrchestrator(
                transcriber: MockTranscriber(.failure(error)), primary: nil, fallback: nil,
                detector: Self.detector, paste: { _ in .pasted() }, onStage: { recorder.record($0) }, history: nil
            )
            let outcome = await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget())
            #expect(outcome == .noSpeech)
            #expect(recorder.stages.last == .error(message: "No speech detected"))
        }
    }

    @MainActor
    @Test("back-to-back dictations both paste, in order, never overlapping")
    func backToBackPastesInOrder() async throws {
        let log = PasteLog()
        let paste: (PasteRequest) async -> Paster.PasteOutcome = { await log.paste($0, taking: 0.05) }
        // Different instances, as after a settings change between the two dictations.
        let slow = DictationOrchestrator(
            transcriber: SlowTranscriber("first one", delay: 0.3), primary: nil, fallback: nil,
            detector: Self.detector, paste: paste, history: nil
        )
        let fast = DictationOrchestrator(
            transcriber: SlowTranscriber("second one", delay: 0), primary: nil, fallback: nil,
            detector: Self.detector, paste: paste, history: nil
        )
        let first = Task { await slow.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget()) }
        let firstDone = Task<Void, Never> { _ = await first.value }
        let second = Task {
            await fast.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget(), after: firstDone)
        }
        #expect(await first.value == .pasted)
        #expect(await second.value == .pasted)
        #expect(log.texts == [
            LocalCleanup.clean("first one", mode: .prose),
            LocalCleanup.clean("second one", mode: .prose),
        ])
        #expect(!log.overlapped)
    }

    @MainActor
    @Test("cancelling during transcription is silent: no error, nothing pasted")
    func cancelDuringTranscriptionIsSilent() async throws {
        let recorder = StageRecorder()
        let log = PasteLog()
        let orch = DictationOrchestrator(
            transcriber: SlowTranscriber("never", delay: 30), primary: nil, fallback: nil,
            detector: Self.detector, paste: { await log.paste($0) }, onStage: { recorder.record($0) }, history: nil
        )
        let run = Task { await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget()) }
        try await Task.sleep(nanoseconds: 100_000_000)
        run.cancel()
        #expect(await run.value == .cancelled)
        #expect(!recorder.sawError)
        #expect(log.texts.isEmpty)
    }

    @MainActor
    @Test("a provider's own cancellation, without Esc, is reported and retryable")
    func providerCancellationIsRetryable() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.failure(URLError(.cancelled))), primary: nil, fallback: nil,
            detector: Self.detector, paste: { _ in .pasted() }, onStage: { recorder.record($0) }, history: nil
        )
        #expect(await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget()) == .failed)
        #expect(recorder.sawError)
    }

    @MainActor
    @Test("a real transcription failure is reported and retryable")
    func transcriptionFailure() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.failure(URLError(.notConnectedToInternet))), primary: nil, fallback: nil,
            detector: Self.detector, paste: { _ in .pasted() }, onStage: { recorder.record($0) }, history: nil
        )
        #expect(await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget()) == .failed)
        #expect(recorder.sawError)
    }

    @MainActor
    @Test("once the paste has begun, cancellation can't cut it short")
    func pasteIsShieldedFromCancellation() async throws {
        let recorder = StageRecorder()
        let log = PasteLog()
        let run = Box<Task<DictationOutcome, Never>?>(nil)
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello there")), primary: nil, fallback: nil,
            detector: Self.detector, paste: { await log.paste($0, taking: 0.1) }, history: nil
        )
        run.value = Task {
            await orch.process(
                samples: Self.speech, sampleRate: 16_000, target: DictationTarget(),
                onStage: { recorder.record($0) },
                onPasteBegan: { run.value?.cancel() }
            )
        }
        #expect(await run.value?.value == .pasted)
        #expect(log.sawCancellation == [false])
        // Whoever cancelled owns the HUD now: no result stage over it.
        #expect(!recorder.stages.contains { if case .pasted = $0 { return true } else { return false } })
    }

    @MainActor
    @Test("empty or punctuation-only output is never pasted")
    func emptyOutputNotPasted() async throws {
        let log = PasteLog()
        let recorder = StageRecorder()
        // A rule that deletes the whole transcript.
        let byRule = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello")), primary: nil, fallback: nil,
            detector: Self.detector, paste: { await log.paste($0) }, onStage: { recorder.record($0) }, history: nil,
            replacementRules: [ReplacementRule(find: "hello", replace: "")]
        )
        #expect(await byRule.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget()) == .noSpeech)
        // An LLM that answers with punctuation only.
        let byLLM = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello world")),
            primary: MockCleanupProvider(responses: [.success(" … ")]), fallback: nil,
            detector: Self.detector, paste: { await log.paste($0) }, onStage: { recorder.record($0) }, history: nil,
            llmCleanupWordThreshold: 0
        )
        #expect(await byLLM.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget()) == .noSpeech)
        #expect(log.texts.isEmpty)
        #expect(recorder.stages.last == .error(message: "No speech detected"))
    }

    @MainActor
    @Test("rules are re-applied after an LLM without doubling an expansion")
    func replacementsDontDouble() async throws {
        let rules = [ReplacementRule(find: "murmur", replace: "Murmur app")]
        let llmLog = PasteLog()
        let viaLLM = DictationOrchestrator(
            transcriber: MockTranscriber(.success("i love murmur")),
            // The LLM echoes the already-expanded text and reintroduces the lowercase term.
            primary: MockCleanupProvider(responses: [.success("I love murmur app.")]), fallback: nil,
            detector: Self.detector, paste: { await llmLog.paste($0) }, history: nil,
            replacementRules: rules, llmCleanupWordThreshold: 0
        )
        await viaLLM.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget())
        #expect(llmLog.texts == ["I love Murmur app."])

        let localLog = PasteLog()
        let local = DictationOrchestrator(
            transcriber: MockTranscriber(.success("i love murmur")), primary: nil, fallback: nil,
            detector: Self.detector, paste: { await localLog.paste($0) }, history: nil,
            replacementRules: rules
        )
        await local.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget())
        #expect(localLog.texts == [LocalCleanup.clean("i love Murmur app", mode: .prose)])
    }

    @MainActor
    @Test("LocalCleanup's sentence capitalization doesn't undo a rule's casing")
    func ruleCasingSurvivesLocalCleanup() async throws {
        let log = PasteLog()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("iphone battery is low")), primary: nil, fallback: nil,
            detector: Self.detector, paste: { await log.paste($0) }, history: nil,
            replacementRules: [ReplacementRule(find: "iphone", replace: "iPhone")],
            llmCleanupWordThreshold: 12
        )
        await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget())
        #expect(log.texts == ["iPhone battery is low."])
    }

    @MainActor
    @Test("a hung cleanup provider gives way to LocalCleanup at the deadline")
    func cleanupDeadlineFallsBackToLocal() async throws {
        let log = PasteLog()
        let fallback = MockCleanupProvider(name: "Fallback", responses: [.success("never used")])
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("um hello world")),
            primary: MockCleanupProvider(name: "Hung", responses: [.success("too late")], delay: 30),
            fallback: fallback,
            detector: Self.detector, paste: { await log.paste($0) }, history: nil,
            llmCleanupWordThreshold: 0,
            cleanupDeadline: { _ in 1.2 }
        )
        let started = Date()
        #expect(await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget()) == .pasted)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(log.texts == [LocalCleanup.clean("um hello world", mode: .prose)])
        // Less than a second was left for the fallback, so it wasn't started.
        #expect(await fallback.callCount() == 0)
    }

    @MainActor
    @Test("the default cleanup deadline grows with length and is capped")
    func defaultCleanupDeadline() {
        #expect(DictationOrchestrator.cleanupDeadline(wordCount: 0) == 10)
        #expect(DictationOrchestrator.cleanupDeadline(wordCount: 100) == 13)
        #expect(DictationOrchestrator.cleanupDeadline(wordCount: 10_000) == 20)
    }

    @MainActor
    @Test("a failing cloud key earns one HUD note, not one per dictation")
    func cloudFailureNotedOnce() async throws {
        let notices = CleanupFailureNotices()
        func dictate() async -> DictationStage? {
            let recorder = StageRecorder()
            let orch = DictationOrchestrator(
                transcriber: MockTranscriber(.success("hello there friend")),
                primary: OpenAICompatibleProvider.groq(apiKey: "", model: "m"), // no key: fails offline
                fallback: nil,
                detector: Self.detector, paste: { _ in .pasted() }, onStage: { recorder.record($0) }, history: nil,
                llmCleanupWordThreshold: 0, failureNotices: notices
            )
            await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget())
            return recorder.stages.last
        }
        #expect(await dictate() == .pasted(words: 3, note: "Groq cleanup failed (no API key) — used built-in rules"))
        #expect(await dictate() == .pasted(words: 3))
    }

    @MainActor
    @Test("cleanup failure reasons are short and content-free")
    func cleanupFailureReasons() {
        typealias PE = OpenAICompatibleProvider.ProviderError
        #expect(DictationOrchestrator.cleanupFailureReason(PE.badStatus(401, message: "secret text")) == "invalid API key")
        #expect(DictationOrchestrator.cleanupFailureReason(PE.badStatus(429, message: nil)) == "rate limited")
        #expect(DictationOrchestrator.cleanupFailureReason(PE.badStatus(500, message: nil)) == "HTTP 500")
        #expect(DictationOrchestrator.cleanupFailureReason(CleanupTimeoutError()) == "timed out")
        #expect(DictationOrchestrator.cleanupFailureReason(URLError(.notConnectedToInternet)) == "offline")
    }

    @MainActor
    @Test("a length-limited recording says so with the result")
    func overflowNote() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello")), primary: nil, fallback: nil,
            detector: Self.detector, paste: { _ in .pasted() }, onStage: { recorder.record($0) }, history: nil
        )
        await orch.process(samples: Self.speech, sampleRate: 16_000, didOverflow: true, target: DictationTarget())
        #expect(recorder.stages.last == .pasted(words: 1, note: "Stopped at the length limit"))
    }

    @MainActor
    @Test("CJK text counts characters, so the LLM threshold and the HUD work")
    func cjkWordCount() async throws {
        let recorder = StageRecorder()
        let cleanup = MockCleanupProvider(responses: [.success("我今天去商店买了很多东西。")])
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("我今天去商店买了很多东西")), // 12 characters, no spaces
            primary: cleanup, fallback: nil,
            detector: Self.detector, paste: { _ in .pasted() }, onStage: { recorder.record($0) }, history: nil,
            llmCleanupWordThreshold: 12
        )
        await orch.process(samples: Self.speech, sampleRate: 16_000, target: DictationTarget())
        #expect(await cleanup.callCount() == 1)
        #expect(recorder.stages.last == .pasted(words: 12))
    }

    @Test("word count: punctuation and bullets don't count; unspaced scripts do")
    func wordCountRules() {
        #expect(DictationOrchestrator.wordCount("Hello, world — test.") == 3)
        #expect(DictationOrchestrator.wordCount("- one\n- two\nthree") == 3)
        #expect(DictationOrchestrator.wordCount("今日はいい天気ですね") == 10)
        #expect(DictationOrchestrator.wordCount("안녕하세요 반갑습니다") == 2)
        #expect(DictationOrchestrator.wordCount("สวัสดีครับ") >= 2)
        #expect(DictationOrchestrator.wordCount(" … ") == 0)
    }

    @MainActor
    @Test("history keeps the press-time app, even without a bundle id, and skips password fields")
    func historyUsesTarget() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        let outcome = Box(Paster.PasteOutcome.pasted())
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello there")), primary: nil, fallback: nil,
            detector: Self.detector, paste: { _ in outcome.value }, history: store
        )
        let target = DictationTarget(frontmostPID: nil, bundleID: nil, appName: "Some Tool")
        await orch.process(samples: Self.speech, sampleRate: 16_000, target: target)
        let entries = try store.read()
        #expect(entries.count == 1)
        #expect(entries.first?.bundleID == "unknown")
        #expect(entries.first?.appName == "Some Tool")

        outcome.value = .init(kind: .copiedOnly, detail: "password field", isSecureTarget: true)
        await orch.process(samples: Self.speech, sampleRate: 16_000, target: target)
        #expect(try store.read().count == 1)
    }

    @MainActor
    @Test("the paste gets the press-time target, its style and the Return policy")
    func pasteRequestCarriesTarget() async throws {
        let request = Box<PasteRequest?>(nil)
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello there")), primary: nil, fallback: nil,
            detector: ContextDetector(defaults: ["com.apple.Terminal": .light], userOverrides: []),
            paste: { request.value = $0; return .pasted() }, history: nil
        )
        let target = DictationTarget(frontmostPID: 4242, bundleID: "com.apple.Terminal", appName: "Terminal")
        await orch.process(samples: Self.speech, sampleRate: 16_000, target: target, allowsReturn: false)
        #expect(request.value?.target == target)
        #expect(request.value?.mode == .light)
        #expect(request.value?.allowsReturn == false)
    }
}

@Suite("HUD session scoping")
struct HUDSessionTests {
    @MainActor
    @Test("an earlier run's stages can't replace a newer recording")
    func staleStagesDropped() {
        let hud = HUDViewModel()
        let first = UUID()
        let second = UUID()
        hud.follow(first, showing: .recording)
        hud.update(.transcribing, session: first)
        hud.follow(second, showing: .recording)
        hud.update(.pasted(words: 3), session: first)
        hud.update(.cleaning(provider: "Groq"), session: first)
        #expect(hud.stage == .recording)
        hud.update(.transcribing, session: second)
        #expect(hud.stage == .transcribing)
    }

    @MainActor
    @Test("handing the HUD back to an earlier run shows its stages again")
    func followEarlierRun() {
        let hud = HUDViewModel()
        let first = UUID()
        hud.follow(UUID(), showing: .recording, forcesVisible: true)
        #expect(hud.forcesVisible)
        hud.follow(first, showing: .cleaning(provider: "Groq"))
        #expect(!hud.forcesVisible)
        hud.update(.pasted(words: 2), session: first)
        #expect(hud.stage == .pasted(words: 2))
    }

    @Test("an earlier copied-only notice says so only while its text is still on the clipboard")
    func deferredCopyNotices() {
        let copied = (text: "Earlier dictation: Copied to clipboard — no text field was focused", copied: true)
        let replaced = "Earlier dictation wasn't pasted — the clipboard now holds the newer one"
        // A newer copy replaced it.
        #expect(AppDelegate.folding([copied], into: .copiedOnly(message: "Copied"), historyOn: true)
            == .copiedOnly(message: "Copied · \(replaced) (see History)"))
        #expect(AppDelegate.folding([copied, copied], into: .idle, historyOn: false)
            == .copiedOnly(message: "\(replaced) · \(copied.text)"))
        // A paste puts the clipboard back; an error leaves it alone.
        #expect(AppDelegate.folding([copied], into: .pasted(words: 2), historyOn: false)
            == .pasted(words: 2, note: copied.text))
        #expect(AppDelegate.folding([copied, (text: "Mic unavailable", copied: false)], into: .idle, historyOn: false)
            == .error(message: "\(copied.text) · Mic unavailable"))
        #expect(AppDelegate.folding([copied], into: .transcribing, historyOn: false) == nil)
    }
}
