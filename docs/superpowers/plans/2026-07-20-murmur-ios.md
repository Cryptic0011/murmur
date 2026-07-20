# Murmur iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhone dictation app with an Action-Button-assignable "Toggle Recording" shortcut and a custom keyboard, transcribing on-device with Parakeet.

**Architecture:** A separate XcodeGen-generated `ios/MurmurIOS.xcodeproj` (same repo, own folder) with two targets: the SwiftUI app (owns mic + Parakeet engine, reusing `Murmur/STT/ParakeetProvider.swift` et al. by file reference) and a keyboard extension (no mic/model — deep-links to the app to record, inserts the transcript from an App Group on return). An in-app App Intent provides the Action Button toggle: first press starts recording, second press stops and returns the transcript to the Shortcut.

**Tech Stack:** Swift 6 / SwiftUI, iOS 17+, FluidAudio ≥0.12.4 (Parakeet TDT CoreML), AppIntents, XcodeGen (already installed at `/opt/homebrew/bin/xcodegen`).

## Global Constraints

- Deployment target: iOS 17.0. Spec: `docs/superpowers/specs/2026-07-20-murmur-ios-design.md`.
- App bundle id `com.murmur.MurmurIOS`, keyboard `com.murmur.MurmurIOS.keyboard`, App Group `group.com.murmur.Murmur` (both targets).
- FluidAudio pinned `from: "0.12.4"` (matches the macOS project).
- Shared macOS sources are referenced, never copied: `Murmur/STT/TranscriptionProvider.swift`, `Murmur/STT/ParakeetProvider.swift`, `Murmur/Audio/SilenceTrimmer.swift`.
- All new iOS code lives under `ios/`. Never modify `Murmur.xcodeproj` or `Murmur/` sources.
- Build checks compile without signing: `CODE_SIGNING_ALLOWED=NO`. Device installs happen in Xcode (Task 8).
- v1 inserts the raw Parakeet transcript — no cleanup/formatting pipeline.
- URL scheme: `murmur://dictate` starts recording (matches macOS `murmur://` conventions).

---

### Task 1: XcodeGen project scaffold

**Files:**
- Create: `ios/project.yml`
- Create: `ios/MurmurIOS/MurmurIOSApp.swift`
- Create: `ios/MurmurIOS/MurmurIOS.entitlements`
- Create: `ios/MurmurKeyboard/KeyboardViewController.swift` (stub)
- Create: `ios/MurmurKeyboard/MurmurKeyboard.entitlements`
- Create: `ios/.gitignore`

**Interfaces:**
- Produces: a generated `ios/MurmurIOS.xcodeproj` with scheme `MurmurIOS`; later tasks add files under `ios/MurmurIOS/` and `ios/MurmurIOSTests/` and re-run `xcodegen`.

- [ ] **Step 1: Write `ios/project.yml`**

```yaml
name: MurmurIOS
options:
  deploymentTarget:
    iOS: "17.0"
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    from: "0.12.4"
targets:
  MurmurIOS:
    type: application
    platform: iOS
    sources:
      - path: MurmurIOS
      - path: ../Murmur/STT/TranscriptionProvider.swift
      - path: ../Murmur/STT/ParakeetProvider.swift
      - path: ../Murmur/Audio/SilenceTrimmer.swift
    dependencies:
      - package: FluidAudio
      - target: MurmurKeyboard
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.murmur.MurmurIOS
      CODE_SIGN_ENTITLEMENTS: MurmurIOS/MurmurIOS.entitlements
      INFOPLIST_KEY_NSMicrophoneUsageDescription: "Murmur records audio to transcribe your dictation on-device."
      SWIFT_VERSION: "6.0"
    info:
      path: MurmurIOS/Info.plist
      properties:
        UILaunchScreen: {}
        CFBundleDisplayName: Murmur
        CFBundleURLTypes:
          - CFBundleURLSchemes: [murmur]
  MurmurKeyboard:
    type: app-extension
    platform: iOS
    sources: [MurmurKeyboard]
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.murmur.MurmurIOS.keyboard
      CODE_SIGN_ENTITLEMENTS: MurmurKeyboard/MurmurKeyboard.entitlements
      SWIFT_VERSION: "6.0"
    info:
      path: MurmurKeyboard/Info.plist
      properties:
        CFBundleDisplayName: Murmur Keyboard
        NSExtension:
          NSExtensionPointIdentifier: com.apple.keyboard-service
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).KeyboardViewController
          NSExtensionAttributes:
            IsASCIICapable: false
            PrefersRightToLeft: false
            PrimaryLanguage: en-US
            RequestsOpenAccess: true
  MurmurIOSTests:
    type: bundle.unit-test
    platform: iOS
    sources: [MurmurIOSTests]
    dependencies:
      - target: MurmurIOS
schemes:
  MurmurIOS:
    build:
      targets: { MurmurIOS: all }
    test:
      targets: [MurmurIOSTests]
```

- [ ] **Step 2: Write both entitlements files (identical content)**

`ios/MurmurIOS/MurmurIOS.entitlements` and `ios/MurmurKeyboard/MurmurKeyboard.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.murmur.Murmur</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Write minimal app + keyboard stub**

`ios/MurmurIOS/MurmurIOSApp.swift`:

```swift
import SwiftUI

@main
struct MurmurIOSApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Murmur")
        }
    }
}
```

`ios/MurmurKeyboard/KeyboardViewController.swift`:

```swift
import UIKit

final class KeyboardViewController: UIInputViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
    }
}
```

Also create an empty tests dir with a placeholder so the target compiles: `ios/MurmurIOSTests/PlaceholderTests.swift`:

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testTruth() { XCTAssertTrue(true) }
}
```

`ios/.gitignore`:

```
MurmurIOS.xcodeproj
```

- [ ] **Step 4: Generate and build**

```bash
cd /Users/graysonpatterson/Grayson/murmur/ios && xcodegen generate
xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **` (first run resolves FluidAudio, takes a few minutes).

- [ ] **Step 5: Commit**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios docs && git commit -m "feat(ios): XcodeGen scaffold with app, keyboard, and test targets"
```

---

### Task 2: TranscriptHandoff (App Group) — TDD

**Files:**
- Create: `ios/MurmurIOS/TranscriptHandoff.swift`
- Test: `ios/MurmurIOSTests/TranscriptHandoffTests.swift` (replaces `PlaceholderTests.swift` — delete it)

**Interfaces:**
- Produces: `enum TranscriptHandoff { static func post(_ text: String, defaults: UserDefaults, now: Date = Date()); static func take(defaults: UserDefaults, now: Date = Date()) -> String? }`. Callers use `TranscriptHandoff.appGroup` (`UserDefaults(suiteName: "group.com.murmur.Murmur")!`). `take` returns nil and clears if empty or older than 60s.

- [ ] **Step 1: Write the failing test**

`ios/MurmurIOSTests/TranscriptHandoffTests.swift`:

```swift
import XCTest
@testable import MurmurIOS

final class TranscriptHandoffTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "test.handoff")!
        defaults.removePersistentDomain(forName: "test.handoff")
    }

    func testPostThenTakeReturnsTextOnceAndClears() {
        TranscriptHandoff.post("hello world", defaults: defaults)
        XCTAssertEqual(TranscriptHandoff.take(defaults: defaults), "hello world")
        XCTAssertNil(TranscriptHandoff.take(defaults: defaults))
    }

    func testStaleTranscriptIsDiscarded() {
        let old = Date(timeIntervalSinceNow: -61)
        TranscriptHandoff.post("stale", defaults: defaults, now: old)
        XCTAssertNil(TranscriptHandoff.take(defaults: defaults))
    }

    func testFreshBoundaryIsAccepted() {
        let recent = Date(timeIntervalSinceNow: -59)
        TranscriptHandoff.post("fresh", defaults: defaults, now: recent)
        XCTAssertEqual(TranscriptHandoff.take(defaults: defaults), "fresh")
    }

    func testEmptyTextIsNeverReturned() {
        TranscriptHandoff.post("", defaults: defaults)
        XCTAssertNil(TranscriptHandoff.take(defaults: defaults))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/graysonpatterson/Grayson/murmur/ios && rm MurmurIOSTests/PlaceholderTests.swift && xcodegen generate
xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -20
```

Expected: build FAILS with "cannot find 'TranscriptHandoff' in scope". (If no iPhone 17 Pro simulator exists, list with `xcrun simctl list devices available` and use any iOS 17+ device name.)

- [ ] **Step 3: Implement**

`ios/MurmurIOS/TranscriptHandoff.swift`:

```swift
import Foundation

/// Passes the finished transcript from the app to the keyboard extension via
/// the shared App Group. One-shot: `take` clears what it returns.
enum TranscriptHandoff {
    static let appGroup = UserDefaults(suiteName: "group.com.murmur.Murmur")!
    private static let textKey = "handoff.text"
    private static let dateKey = "handoff.date"
    private static let maxAge: TimeInterval = 60

    static func post(_ text: String, defaults: UserDefaults = appGroup, now: Date = Date()) {
        defaults.set(text, forKey: textKey)
        defaults.set(now.timeIntervalSince1970, forKey: dateKey)
    }

    static func take(defaults: UserDefaults = appGroup, now: Date = Date()) -> String? {
        defer {
            defaults.removeObject(forKey: textKey)
            defaults.removeObject(forKey: dateKey)
        }
        guard let text = defaults.string(forKey: textKey), !text.isEmpty else { return nil }
        let posted = Date(timeIntervalSince1970: defaults.double(forKey: dateKey))
        guard now.timeIntervalSince(posted) <= maxAge else { return nil }
        return text
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Same `xcodebuild ... test` command. Expected: `** TEST SUCCEEDED **` with 4 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios && git commit -m "feat(ios): App Group transcript handoff with staleness guard"
```

---

### Task 3: IOSAudioRecorder

The macOS `AudioRecorder` is 400 lines of CoreAudio device management that doesn't apply to iOS; this is the minimal AVAudioSession equivalent producing the same output format `ParakeetProvider.transcribe` needs: 16kHz mono `[Float]`.

**Files:**
- Create: `ios/MurmurIOS/IOSAudioRecorder.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `actor IOSAudioRecorder { func start() async throws; func stop() -> [Float]; func level() -> Float }`. Samples are 16kHz mono Float32 in [-1, 1]. `start` throws `RecorderError.permissionDenied` if mic access is refused.

- [ ] **Step 1: Implement**

`ios/MurmurIOS/IOSAudioRecorder.swift`:

```swift
import AVFoundation

actor IOSAudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case permissionDenied
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access denied. Enable it in Settings → Murmur."
            case .conversionFailed: return "Audio conversion setup failed."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var liveLevel: Float = 0
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RecorderError.permissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        samples.removeAll(keepingCapacity: true)
        liveLevel = 0
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.conversionFailed
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let ratio = 16_000.0 / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let self,
                  let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let ch = out.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            Task { await self.append(chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return samples
    }

    func level() -> Float { liveLevel }

    private func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
        if !chunk.isEmpty {
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            liveLevel = min(1, rms / 0.18)
        }
    }
}
```

- [ ] **Step 2: Build check**

```bash
cd /Users/graysonpatterson/Grayson/murmur/ios && xcodegen generate && xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. (No unit test — real mic behavior is verified on-device in Task 8; the pure logic here is format plumbing that fails loudly at build/runtime.)

- [ ] **Step 3: Commit**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios && git commit -m "feat(ios): AVAudioSession recorder producing 16kHz mono Float samples"
```

---

### Task 4: DictationController

**Files:**
- Create: `ios/MurmurIOS/DictationController.swift`

**Interfaces:**
- Consumes: `IOSAudioRecorder` (Task 3), `ParakeetProvider(modelVersion: "v3")` + `SilenceTrimmer.trim` (shared sources), `TranscriptHandoff.post` (Task 2).
- Produces: `@MainActor final class DictationController: ObservableObject` singleton `DictationController.shared` with `@Published var state: DictationState` (`.idle`, `.loadingModel`, `.recording`, `.transcribing`), `@Published var lastError: String?`, `@Published var history: [String]`, `func warmUp() async`, `func start() async`, `func stop() async -> String?`, `func toggle() async -> String?`. `stop()` transcribes, posts to `TranscriptHandoff`, copies to `UIPasteboard.general`, prepends to `history`, returns the text (nil on failure/empty).

- [ ] **Step 1: Implement**

`ios/MurmurIOS/DictationController.swift`:

```swift
import SwiftUI

enum DictationState: Equatable { case idle, loadingModel, recording, transcribing }

@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published var state: DictationState = .idle
    @Published var lastError: String?
    @Published var history: [String] = (UserDefaults.standard.stringArray(forKey: "history") ?? [])

    private let recorder = IOSAudioRecorder()
    private let provider = ParakeetProvider(modelVersion: "v3")
    var modelReady: Bool {
        get async { await provider.isLoaded() }
    }

    /// Downloads + loads Parakeet (first launch: ~1GB from Hugging Face).
    func warmUp() async {
        guard state == .idle else { return }
        state = .loadingModel
        await provider.warmUp()
        state = .idle
    }

    func start() async {
        guard state == .idle || state == .loadingModel else { return }
        lastError = nil
        do {
            try await recorder.start()
            state = .recording
        } catch {
            lastError = error.localizedDescription
            state = .idle
        }
    }

    func stop() async -> String? {
        guard state == .recording else { return nil }
        state = .transcribing
        let raw = await recorder.stop()
        defer { state = .idle }
        let samples = SilenceTrimmer.trim(samples: raw, sampleRate: 16_000)
        guard !samples.isEmpty else {
            lastError = "No speech detected."
            return nil
        }
        do {
            let text = try await provider.transcribe(samples: samples, sampleRate: 16_000)
            TranscriptHandoff.post(text)
            UIPasteboard.general.string = text
            history.insert(text, at: 0)
            history = Array(history.prefix(50))
            UserDefaults.standard.set(history, forKey: "history")
            return text
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func toggle() async -> String? {
        if state == .recording { return await stop() }
        await start()
        return nil
    }
}
```

Note: `SilenceTrimmer.trim(samples:sampleRate:threshold:padSeconds:)` (in `Murmur/Audio/SilenceTrimmer.swift`) returns `[]` when the whole recording is below the silence threshold — hence the empty guard above; `ParakeetProvider.transcribe` must never receive empty samples.

- [ ] **Step 2: Build check**

```bash
cd /Users/graysonpatterson/Grayson/murmur/ios && xcodegen generate && xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios && git commit -m "feat(ios): dictation controller wiring recorder, Parakeet, and handoff"
```

---

### Task 5: App UI + deep link

**Files:**
- Modify: `ios/MurmurIOS/MurmurIOSApp.swift` (full rewrite below)
- Create: `ios/MurmurIOS/RecordingView.swift`

**Interfaces:**
- Consumes: `DictationController.shared` (Task 4).
- Produces: `murmur://dictate` deep link → starts recording immediately. Root view hosts setup/recording/history.

- [ ] **Step 1: Rewrite `ios/MurmurIOS/MurmurIOSApp.swift`**

```swift
import SwiftUI

@main
struct MurmurIOSApp: App {
    @StateObject private var controller = DictationController.shared

    var body: some Scene {
        WindowGroup {
            RecordingView()
                .environmentObject(controller)
                .task { await controller.warmUp() }
                .onOpenURL { url in
                    guard url.host == "dictate" || url.path == "dictate" else { return }
                    Task { await controller.start() }
                }
        }
    }
}
```

- [ ] **Step 2: Write `ios/MurmurIOS/RecordingView.swift`**

```swift
import SwiftUI

struct RecordingView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                switch controller.state {
                case .loadingModel:
                    ProgressView("Downloading Parakeet model (~1 GB)…\nKeep the app open.")
                        .multilineTextAlignment(.center)
                case .transcribing:
                    ProgressView("Transcribing…")
                case .idle, .recording:
                    micButton
                }
                if let error = controller.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
                if controller.state == .idle, let latest = controller.history.first {
                    VStack(spacing: 8) {
                        Text(latest).font(.callout).lineLimit(4)
                            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        Text("Copied — tap ‹ Murmur (top left) to go back and insert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                Spacer()
                NavigationLink("History") { historyList }
            }
            .navigationTitle("Murmur")
        }
    }

    private var micButton: some View {
        Button {
            Task { _ = await controller.toggle() }
        } label: {
            Image(systemName: controller.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(controller.state == .recording ? .red : .accentColor)
                .symbolEffect(.pulse, isActive: controller.state == .recording)
        }
    }

    private var historyList: some View {
        List(Array(controller.history.enumerated()), id: \.offset) { _, text in
            Text(text).textSelection(.enabled)
        }
        .navigationTitle("History")
    }
}
```

- [ ] **Step 3: Build check** (same `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` as Task 4, expected `** BUILD SUCCEEDED **`)

- [ ] **Step 4: Commit**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios && git commit -m "feat(ios): recording UI, model setup screen, history, murmur:// deep link"
```

---

### Task 6: Toggle Recording intent + AppShortcutsProvider

**Files:**
- Create: `ios/MurmurIOS/ToggleRecordingIntent.swift`

**Interfaces:**
- Consumes: `DictationController.shared.toggle() async -> String?` (Task 4).
- Produces: "Toggle Recording" action in Shortcuts/Action Button picker. First press → app opens, recording starts, intent returns `""`. Second press → recording stops, intent returns the transcript string.

- [ ] **Step 1: Implement**

`ios/MurmurIOS/ToggleRecordingIntent.swift`:

```swift
import AppIntents

struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Recording"
    static let description = IntentDescription(
        "Starts dictation; run again to stop and get the transcribed text.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = await DictationController.shared.toggle()
        return .result(value: text ?? "")
    }
}

struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Toggle \(.applicationName) recording"],
            shortTitle: "Toggle Recording",
            systemImageName: "mic.fill")
    }
}
```

- [ ] **Step 2: Build check** (same command, expected `** BUILD SUCCEEDED **`)

- [ ] **Step 3: Commit**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios && git commit -m "feat(ios): Toggle Recording app intent for Action Button shortcuts"
```

---

### Task 7: Keyboard extension

**Files:**
- Modify: `ios/MurmurKeyboard/KeyboardViewController.swift` (full rewrite below)
- Modify: `ios/project.yml` — add the two shared files to the keyboard target's `sources` list: `MurmurKeyboard` needs `TranscriptHandoff`, so change its `sources` to:

```yaml
    sources:
      - path: MurmurKeyboard
      - path: MurmurIOS/TranscriptHandoff.swift
```

**Interfaces:**
- Consumes: `TranscriptHandoff.take()` (Task 2), `murmur://dictate` deep link (Task 5).
- Produces: keyboard with mic / globe / space / delete / return keys. Mic opens the app; on keyboard reappearance any fresh transcript is inserted via `textDocumentProxy.insertText`.

- [ ] **Step 1: Rewrite `ios/MurmurKeyboard/KeyboardViewController.swift`**

```swift
import UIKit

final class KeyboardViewController: UIInputViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let mic = makeKey(symbol: "mic.fill", action: #selector(didTapMic))
        mic.tintColor = .systemRed
        let globe = makeKey(symbol: "globe", action: #selector(handleInputModeList(from:with:)))
        let space = makeKey(title: "space", action: #selector(didTapSpace))
        let delete = makeKey(symbol: "delete.left", action: #selector(didTapDelete))
        let ret = makeKey(symbol: "return", action: #selector(didTapReturn))

        let row = UIStackView(arrangedSubviews: [globe, delete, mic, space, ret])
        row.distribution = .fillEqually
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Returning from a bounce-to-app dictation: insert the fresh transcript.
        if let text = TranscriptHandoff.take() {
            textDocumentProxy.insertText(text)
        }
    }

    @objc private func didTapMic() { openContainerApp(URL(string: "murmur://dictate")!) }
    @objc private func didTapSpace() { textDocumentProxy.insertText(" ") }
    @objc private func didTapDelete() { textDocumentProxy.deleteBackward() }
    @objc private func didTapReturn() { textDocumentProxy.insertText("\n") }

    /// Keyboard extensions have no UIApplication.open; walking the responder
    /// chain to perform openURL: is the standard workaround (same one the
    /// commercial dictation keyboards use).
    private func openContainerApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = Selector(("openURL:"))
        while let r = responder {
            if r.responds(to: selector), !(r is UIViewController) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
    }

    private func makeKey(symbol: String? = nil, title: String? = nil, action: Selector) -> UIButton {
        var config = UIButton.Configuration.gray()
        if let symbol { config.image = UIImage(systemName: symbol) }
        if let title { config.title = title }
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        if action == #selector(handleInputModeList(from:with:)) {
            button.addTarget(self, action: action, for: .allTouchEvents)
        } else {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        return button
    }
}
```

- [ ] **Step 2: Build check**

```bash
cd /Users/graysonpatterson/Grayson/murmur/ios && xcodegen generate && xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. Also re-run unit tests (`xcodebuild ... test`): `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios && git commit -m "feat(ios): keyboard extension with bounce-to-app dictation key"
```

---

### Task 8: On-device setup + manual verification (user at the keyboard)

No code. The signing/team steps need the Xcode GUI and the physical iPhone; walk the user through:

- [ ] **Step 1: Signing.** Open `ios/MurmurIOS.xcodeproj` in Xcode → for **each** target (MurmurIOS, MurmurKeyboard): Signing & Capabilities → check "Automatically manage signing", pick the personal team. If the App Group shows a provisioning error, register `group.com.murmur.Murmur` when prompted. To persist team choice for regeneration, add `DEVELOPMENT_TEAM: <their team id>` under each target's `settings` in `project.yml` afterward.
- [ ] **Step 2: Run to iPhone.** Select the iPhone 17 Pro Max as destination → Run. First launch: allow mic, let the model download finish (progress screen), do one in-app dictation.
- [ ] **Step 3: Enable keyboard.** Settings → General → Keyboard → Keyboards → Add New Keyboard → Murmur Keyboard → then tap it and enable **Allow Full Access** (required for App Group reads).
- [ ] **Step 4: Keyboard round trip.** In Notes: globe → Murmur Keyboard → mic key → dictate in Murmur → stop → tap "‹" back link (top-left) → verify text inserts.
- [ ] **Step 5: Action Button.** Settings → Action Button → Shortcut → "Toggle Recording" (appears automatically via AppShortcutsProvider). Optionally build the Superwhisper-style wrapper in Shortcuts app: New Shortcut → "Toggle Recording" → If [Toggle Recording] [has any value] → Copy [Toggle Recording] to clipboard → Show notification [Toggle Recording] → assign that to the Action Button instead.
- [ ] **Step 6: Action Button round trip.** Press Action Button → dictate → press again (or tap stop) → verify notification + clipboard.
- [ ] **Step 7: Commit any `project.yml` team-id change.**

```bash
cd /Users/graysonpatterson/Grayson/murmur && git add ios && git commit -m "chore(ios): pin development team for regeneration"
```
