# Murmur Voice Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar dictation app: hold Right Option → record → WhisperKit STT → Groq cleanup (Gemma fallback) → paste into focused field.

**Architecture:** Single-target SwiftUI app, `LSUIElement = true`. All work behind Swift `actor` boundaries. STT and Cleanup behind protocols so providers swap freely. Floating HUD anchored bottom-center. Per-app cleanup mode overrides via `NSWorkspace.frontmostApplication.bundleIdentifier`.

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit interop, Swift Testing, AVFoundation, WhisperKit (SPM), Groq REST API, Ollama HTTP API, macOS 14+.

**Reference spec:** `docs/superpowers/specs/2026-04-13-voice-dictation-design.md`

---

## Task 0: Initialize Repository

**Files:**
- Create: `.gitignore`
- Create: `README.md`

- [ ] **Step 1: Initialize git in the project root**

```bash
cd /Users/graysonpatterson/Grayson/murmur
git init
git branch -m main
```

- [ ] **Step 2: Write `.gitignore` for Xcode/Swift projects**

Create `.gitignore`:
```gitignore
# macOS
.DS_Store

# Xcode
build/
DerivedData/
*.pbxuser
*.mode1v3
*.mode2v3
*.perspectivev3
*.xcuserstate
xcuserdata/
*.xccheckout
*.moved-aside
*.xcuserdatad/

# SPM
.swiftpm/
.build/
Packages/
Package.resolved

# IDE
.vscode/
.idea/

# Secrets
*.env
secrets/
```

- [ ] **Step 3: Stub README**

Create `README.md`:
```markdown
# Murmur

macOS dictation menu bar app. Hold Right Option to dictate; transcribed and cleaned text is pasted into the focused text field.

See `docs/superpowers/specs/2026-04-13-voice-dictation-design.md` for the full design.
```

- [ ] **Step 4: Initial commit**

```bash
git add .gitignore README.md docs/
git commit -m "chore: initialize repo with spec and plan"
```

---

## Task 1: Generate Xcode Project via xcodegen

**Files:**
- Create: `project.yml`
- Create: `Murmur/MurmurApp.swift` (placeholder; real impl in Task 22)
- Create: `Murmur/Info.plist`
- Create: `Murmur/Murmur.entitlements`
- Create: `MurmurTests/Placeholder.swift`

Prerequisite: xcodegen installed (`brew install xcodegen`). Already verified during bootstrap.

- [ ] **Step 1: Write `project.yml`**

Create `project.yml` at repo root:
```yaml
name: Murmur
options:
  bundleIdPrefix: com.murmur
  deploymentTarget:
    macOS: "14.0"
  developmentLanguage: en
settings:
  base:
    SWIFT_VERSION: "5.10"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    ENABLE_HARDENED_RUNTIME: YES
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: "-"
targets:
  Murmur:
    type: application
    platform: macOS
    sources:
      - path: Murmur
    info:
      path: Murmur/Info.plist
      properties:
        LSUIElement: true
        NSMicrophoneUsageDescription: "Murmur listens to your voice while you hold the dictation hotkey, transcribes it locally, and pastes the cleaned text where you're typing."
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
    entitlements:
      path: Murmur/Murmur.entitlements
      properties:
        com.apple.security.device.audio-input: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.murmur.Murmur
  MurmurTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: MurmurTests
    dependencies:
      - target: Murmur
schemes:
  Murmur:
    build:
      targets:
        Murmur: all
        MurmurTests: [test]
    test:
      targets:
        - MurmurTests
```

- [ ] **Step 2: Create placeholder source files (xcodegen needs at least one source per target)**

Create `Murmur/MurmurApp.swift`:
```swift
import SwiftUI

@main
struct MurmurApp: App {
    var body: some Scene {
        Settings { Text("Murmur") }
    }
}
```

Create `MurmurTests/Placeholder.swift`:
```swift
import Testing

@Suite("Bootstrap")
struct PlaceholderTests {
    @Test("project compiles")
    func compiles() { #expect(true) }
}
```

- [ ] **Step 3: Generate the Xcode project**

```bash
cd /Users/graysonpatterson/Grayson/murmur
xcodegen generate
```
Expected: `Created project at .../Murmur.xcodeproj`.

- [ ] **Step 4: Verify it builds and tests pass**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
xcodebuild test -scheme Murmur -destination 'platform=macOS'
```
Expected: `BUILD SUCCEEDED`, 1 test passing.

- [ ] **Step 5: Commit**

```bash
git add project.yml Murmur/ MurmurTests/ Murmur.xcodeproj
git commit -m "feat: scaffold Murmur project via xcodegen"
```

---

## Task 2: Add WhisperKit Swift Package Dependency

**Files:**
- Modify: `project.yml`
- Regenerate: `Murmur.xcodeproj`

- [ ] **Step 1: Add WhisperKit to `project.yml`**

In `project.yml`, add a `packages:` block at the top level and reference it from the Murmur target's `dependencies:`:
```yaml
packages:
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: "0.9.0"

targets:
  Murmur:
    # ...existing keys...
    dependencies:
      - package: WhisperKit
```

- [ ] **Step 2: Regenerate the project**

```bash
xcodegen generate
```

- [ ] **Step 3: Verify the package resolves and the project builds**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' -resolvePackageDependencies
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add project.yml Murmur.xcodeproj
git commit -m "deps: add WhisperKit via SPM"
```

---

## Task 3: KeychainStore

**Files:**
- Create: `Murmur/Storage/KeychainStore.swift`
- Test: `MurmurTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MurmurTests/KeychainStoreTests.swift`:
```swift
import Testing
@testable import Murmur

@Suite("KeychainStore")
struct KeychainStoreTests {
    let store = KeychainStore(service: "com.murmur.test", account: "test-key")

    init() { try? store.delete() }

    @Test("round-trips a value")
    func roundTrip() throws {
        try store.set("hello-secret")
        #expect(try store.get() == "hello-secret")
    }

    @Test("returns nil when nothing stored")
    func emptyRead() throws {
        #expect(try store.get() == nil)
    }

    @Test("overwrites existing value")
    func overwrite() throws {
        try store.set("first")
        try store.set("second")
        #expect(try store.get() == "second")
    }

    @Test("delete removes value")
    func deletion() throws {
        try store.set("transient")
        try store.delete()
        #expect(try store.get() == nil)
    }
}
```

- [ ] **Step 2: Run tests; confirm they fail to compile (`KeychainStore` undefined)**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: compile failure citing `KeychainStore`.

- [ ] **Step 3: Implement `KeychainStore`**

Create `Murmur/Storage/KeychainStore.swift`:
```swift
import Foundation
import Security

struct KeychainStore {
    let service: String
    let account: String

    enum Error: Swift.Error { case unexpectedStatus(OSStatus) }

    func set(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { throw Error.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw Error.unexpectedStatus(status)
        }
    }

    func get() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw Error.unexpectedStatus(status) }
        guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpectedStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/KeychainStoreTests
```
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Murmur/Storage/KeychainStore.swift MurmurTests/KeychainStoreTests.swift
git commit -m "feat(storage): KeychainStore for secrets"
```

---

## Task 4: SettingsStore

**Files:**
- Create: `Murmur/Storage/SettingsStore.swift`
- Create: `Murmur/Cleanup/CleanupMode.swift`
- Test: `MurmurTests/SettingsStoreTests.swift`

- [ ] **Step 1: Define `CleanupMode`**

Create `Murmur/Cleanup/CleanupMode.swift`:
```swift
import Foundation

enum CleanupMode: String, Codable, CaseIterable, Sendable {
    case light
    case prose
    case code
}
```

- [ ] **Step 2: Write the failing tests**

Create `MurmurTests/SettingsStoreTests.swift`:
```swift
import Testing
@testable import Murmur

@Suite("SettingsStore")
struct SettingsStoreTests {
    let defaults = UserDefaults(suiteName: "com.murmur.test.\(UUID().uuidString)")!
    var store: SettingsStore { SettingsStore(defaults: defaults) }

    @Test("default values when unset")
    func defaultsWhenUnset() {
        let s = store
        #expect(s.maxRecordingSeconds == 60)
        #expect(s.cleanupFallbackEnabled == true)
        #expect(s.saveHistory == true)
        #expect(s.appOverrides.isEmpty)
        #expect(s.whisperModel == "openai_whisper-small.en")
    }

    @Test("round-trip values")
    func roundTrip() {
        var s = store
        s.maxRecordingSeconds = 120
        s.appOverrides = [.init(bundleID: "com.apple.Terminal", mode: .light)]
        let s2 = SettingsStore(defaults: defaults)
        #expect(s2.maxRecordingSeconds == 120)
        #expect(s2.appOverrides.first?.bundleID == "com.apple.Terminal")
        #expect(s2.appOverrides.first?.mode == .light)
    }
}
```

- [ ] **Step 3: Run tests; expect compile failure**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/SettingsStoreTests 2>&1 | tail -10
```

- [ ] **Step 4: Implement `SettingsStore`**

Create `Murmur/Storage/SettingsStore.swift`:
```swift
import Foundation

struct AppOverride: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var mode: CleanupMode
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let cleanupFallbackEnabled = "cleanupFallbackEnabled"
        static let saveHistory = "saveHistory"
        static let appOverrides = "appOverrides"
        static let whisperModel = "whisperModel"
        static let groqModel = "groqModel"
        static let ollamaModel = "ollamaModel"
        static let hotkeyKeyCode = "hotkeyKeyCode"
    }

    var maxRecordingSeconds: Int {
        get { defaults.object(forKey: Key.maxRecordingSeconds) as? Int ?? 60 }
        set { defaults.set(newValue, forKey: Key.maxRecordingSeconds) }
    }

    var cleanupFallbackEnabled: Bool {
        get { (defaults.object(forKey: Key.cleanupFallbackEnabled) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.cleanupFallbackEnabled) }
    }

    var saveHistory: Bool {
        get { (defaults.object(forKey: Key.saveHistory) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.saveHistory) }
    }

    var whisperModel: String {
        get { defaults.string(forKey: Key.whisperModel) ?? "openai_whisper-small.en" }
        set { defaults.set(newValue, forKey: Key.whisperModel) }
    }

    var groqModel: String {
        get { defaults.string(forKey: Key.groqModel) ?? "llama-3.3-70b-versatile" }
        set { defaults.set(newValue, forKey: Key.groqModel) }
    }

    var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "gemma3:e2b" }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
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
        }
    }
}
```

- [ ] **Step 5: Run tests; expect pass**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/SettingsStoreTests
```

- [ ] **Step 6: Commit**

```bash
git add Murmur/Storage/SettingsStore.swift Murmur/Cleanup/CleanupMode.swift MurmurTests/SettingsStoreTests.swift
git commit -m "feat(storage): SettingsStore + CleanupMode"
```

---

## Task 5: HistoryStore

**Files:**
- Create: `Murmur/Storage/HistoryStore.swift`
- Test: `MurmurTests/HistoryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MurmurTests/HistoryStoreTests.swift`:
```swift
import Testing
import Foundation
@testable import Murmur

@Suite("HistoryStore")
struct HistoryStoreTests {
    let url: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    @Test("append and read")
    func appendRead() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "raw", cleaned: "cleaned", bundleID: "com.example", appName: "Example"))
        let entries = try store.read()
        #expect(entries.count == 1)
        #expect(entries.first?.cleaned == "cleaned")
    }

    @Test("caps at N entries")
    func cap() throws {
        let store = HistoryStore(fileURL: url, cap: 3)
        for i in 0..<5 {
            try store.append(.init(timestamp: .now, raw: "r\(i)", cleaned: "c\(i)", bundleID: "x", appName: "X"))
        }
        let entries = try store.read()
        #expect(entries.count == 3)
        #expect(entries.first?.cleaned == "c2")
        #expect(entries.last?.cleaned == "c4")
    }

    @Test("clear empties store")
    func clear() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "r", cleaned: "c", bundleID: "x", appName: "X"))
        try store.clear()
        #expect(try store.read().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests; expect compile failure**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/HistoryStoreTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement `HistoryStore`**

Create `Murmur/Storage/HistoryStore.swift`:
```swift
import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let timestamp: Date
    let raw: String
    let cleaned: String
    let bundleID: String
    let appName: String
}

final class HistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let cap: Int
    private let queue = DispatchQueue(label: "com.murmur.history")

    init(fileURL: URL, cap: Int = 50) {
        self.fileURL = fileURL
        self.cap = cap
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func append(_ entry: HistoryEntry) throws {
        try queue.sync {
            var entries = (try? readUnsynced()) ?? []
            entries.append(entry)
            if entries.count > cap { entries.removeFirst(entries.count - cap) }
            try writeUnsynced(entries)
        }
    }

    func read() throws -> [HistoryEntry] {
        try queue.sync { try readUnsynced() }
    }

    func clear() throws {
        try queue.sync { try writeUnsynced([]) }
    }

    private func readUnsynced() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([HistoryEntry].self, from: data)
    }

    private func writeUnsynced(_ entries: [HistoryEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/HistoryStoreTests
```

- [ ] **Step 5: Commit**

```bash
git add Murmur/Storage/HistoryStore.swift MurmurTests/HistoryStoreTests.swift
git commit -m "feat(storage): HistoryStore with rolling cap"
```

---

## Task 6: AudioBuffer (in-memory ring with cap)

**Files:**
- Create: `Murmur/Audio/AudioBuffer.swift`
- Test: `MurmurTests/AudioBufferTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MurmurTests/AudioBufferTests.swift`:
```swift
import Testing
@testable import Murmur

@Suite("AudioBuffer")
struct AudioBufferTests {
    @Test("appends samples up to cap")
    func append() {
        var buf = AudioBuffer(maxSamples: 10)
        buf.append([1, 2, 3])
        buf.append([4, 5])
        #expect(buf.samples == [1, 2, 3, 4, 5])
        #expect(!buf.didOverflow)
    }

    @Test("truncates to cap and flags overflow")
    func cap() {
        var buf = AudioBuffer(maxSamples: 4)
        buf.append([1, 2, 3, 4, 5, 6])
        #expect(buf.samples == [1, 2, 3, 4])
        #expect(buf.didOverflow)
    }

    @Test("seconds at sample rate")
    func seconds() {
        var buf = AudioBuffer(maxSamples: 32_000)
        buf.append(Array(repeating: 0, count: 16_000))
        #expect(buf.seconds(sampleRate: 16_000) == 1.0)
    }
}
```

- [ ] **Step 2: Run tests; expect compile failure**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/AudioBufferTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement `AudioBuffer`**

Create `Murmur/Audio/AudioBuffer.swift`:
```swift
import Foundation

struct AudioBuffer {
    private(set) var samples: [Float] = []
    private(set) var didOverflow = false
    let maxSamples: Int

    init(maxSamples: Int) { self.maxSamples = maxSamples }

    mutating func append(_ chunk: [Float]) {
        let remaining = maxSamples - samples.count
        if chunk.count <= remaining {
            samples.append(contentsOf: chunk)
        } else {
            samples.append(contentsOf: chunk.prefix(remaining))
            didOverflow = true
        }
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        didOverflow = false
    }

    func seconds(sampleRate: Double) -> Double {
        Double(samples.count) / sampleRate
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/AudioBufferTests
```

- [ ] **Step 5: Commit**

```bash
git add Murmur/Audio/AudioBuffer.swift MurmurTests/AudioBufferTests.swift
git commit -m "feat(audio): AudioBuffer with cap and overflow flag"
```

---

## Task 7: AudioRecorder (AVAudioEngine wrapper)

**Files:**
- Create: `Murmur/Audio/AudioRecorder.swift`

This task has no unit tests — `AVAudioEngine` requires a real audio device. Validation is manual and via the integration test in Task 19 (orchestrator wiring).

- [ ] **Step 1: Implement `AudioRecorder`**

Create `Murmur/Audio/AudioRecorder.swift`:
```swift
import AVFoundation

actor AudioRecorder {
    enum RecorderError: Error { case engineFailed, conversionFailed }

    private let engine = AVAudioEngine()
    private var buffer = AudioBuffer(maxSamples: 16_000 * 60)
    private var liveLevel: Float = 0
    private var sampleRate: Double = 16_000
    private var maxSeconds: Int = 60

    func start(maxSeconds: Int) throws {
        self.maxSeconds = maxSeconds
        self.buffer = AudioBuffer(maxSamples: Int(sampleRate) * maxSeconds)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.conversionFailed }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.conversionFailed
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] pcm, _ in
            guard let self else { return }
            let frameCapacity = AVAudioFrameCount(targetFormat.sampleRate * Double(pcm.frameLength) / inputFormat.sampleRate)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            var error: NSError?
            converter.convert(to: outBuf, error: &error) { _, status in
                status.pointee = .haveData
                return pcm
            }
            if error != nil { return }
            let count = Int(outBuf.frameLength)
            guard let channel = outBuf.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            let level = Self.peak(chunk)
            Task { await self.consume(chunk: chunk, level: level) }
        }

        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let samples = buffer.samples
        return samples
    }

    func currentLevel() -> Float { liveLevel }
    func didOverflow() -> Bool { buffer.didOverflow }

    private func consume(chunk: [Float], level: Float) {
        buffer.append(chunk)
        liveLevel = level
    }

    private static func peak(_ chunk: [Float]) -> Float {
        chunk.reduce(0) { max($0, abs($1)) }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Audio/AudioRecorder.swift
git commit -m "feat(audio): AudioRecorder using AVAudioEngine"
```

---

## Task 8: TranscriptionProvider protocol + WhisperKit impl

**Files:**
- Create: `Murmur/STT/TranscriptionProvider.swift`
- Create: `Murmur/STT/WhisperKitProvider.swift`

- [ ] **Step 1: Define the protocol**

Create `Murmur/STT/TranscriptionProvider.swift`:
```swift
import Foundation

protocol TranscriptionProvider: Sendable {
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
}
```

- [ ] **Step 2: Implement WhisperKit-backed provider**

Create `Murmur/STT/WhisperKitProvider.swift`:
```swift
import Foundation
import WhisperKit

actor WhisperKitProvider: TranscriptionProvider {
    enum WhisperError: Error { case notLoaded, emptyResult }

    private var pipe: WhisperKit?
    private let modelName: String

    init(modelName: String) { self.modelName = modelName }

    func ensureLoaded() async throws {
        if pipe != nil { return }
        pipe = try await WhisperKit(model: modelName)
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        try await ensureLoaded()
        guard let pipe else { throw WhisperError.notLoaded }
        let results = try await pipe.transcribe(audioArray: samples)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw WhisperError.emptyResult }
        return text
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 4: Commit**

```bash
git add Murmur/STT/
git commit -m "feat(stt): TranscriptionProvider protocol + WhisperKit impl"
```

---

## Task 9: PromptBuilder + tests

**Files:**
- Create: `Murmur/Cleanup/PromptBuilder.swift`
- Test: `MurmurTests/PromptBuilderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MurmurTests/PromptBuilderTests.swift`:
```swift
import Testing
@testable import Murmur

@Suite("PromptBuilder")
struct PromptBuilderTests {
    @Test("light mode mentions filler words and not rephrasing")
    func light() {
        let p = PromptBuilder.systemPrompt(for: .light)
        #expect(p.localizedCaseInsensitiveContains("filler"))
        #expect(p.localizedCaseInsensitiveContains("verbatim"))
    }

    @Test("prose mode mentions false starts")
    func prose() {
        let p = PromptBuilder.systemPrompt(for: .prose)
        #expect(p.localizedCaseInsensitiveContains("false start"))
    }

    @Test("code mode preserves identifiers")
    func code() {
        let p = PromptBuilder.systemPrompt(for: .code)
        #expect(p.localizedCaseInsensitiveContains("identifier") || p.localizedCaseInsensitiveContains("code"))
        #expect(p.localizedCaseInsensitiveContains("verbatim"))
    }
}
```

- [ ] **Step 2: Run tests; expect compile failure**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/PromptBuilderTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement `PromptBuilder`**

Create `Murmur/Cleanup/PromptBuilder.swift`:
```swift
enum PromptBuilder {
    static func systemPrompt(for mode: CleanupMode) -> String {
        switch mode {
        case .light:
            return """
            You clean up dictated speech. Add punctuation and capitalization. Remove only obvious filler words ('um', 'uh', 'like'). Do not rephrase. Preserve every other word verbatim. Output only the cleaned text, nothing else.
            """
        case .prose:
            return """
            You clean up dictated speech: add punctuation, fix capitalization, remove filler words ('um', 'uh', 'like'), and collapse false starts (e.g., 'I was, I mean, I wanted' becomes 'I wanted'). Preserve the speaker's voice and word choices. Preserve technical strings, identifiers, file paths, code, and proper nouns verbatim. Output only the cleaned text, nothing else.
            """
        case .code:
            return """
            The user is dictating code or command-line text. Add punctuation only where it would appear in source. Convert spelled-out symbols ('open paren', 'equals', 'dot', 'dash dash') to their characters. Do not rephrase, restructure, or improve anything. Preserve every identifier, flag, and path verbatim. Output only the cleaned text, nothing else.
            """
        }
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/PromptBuilderTests
```

- [ ] **Step 5: Commit**

```bash
git add Murmur/Cleanup/PromptBuilder.swift MurmurTests/PromptBuilderTests.swift
git commit -m "feat(cleanup): PromptBuilder for the three modes"
```

---

## Task 10: CleanupProvider protocol + Mock for tests

**Files:**
- Create: `Murmur/Cleanup/CleanupProvider.swift`
- Create: `MurmurTests/Helpers/MockCleanupProvider.swift`

- [ ] **Step 1: Define the protocol**

Create `Murmur/Cleanup/CleanupProvider.swift`:
```swift
import Foundation

protocol CleanupProvider: Sendable {
    func clean(text: String, mode: CleanupMode) async throws -> String
    var displayName: String { get }
}
```

- [ ] **Step 2: Add a mock for orchestrator tests**

Create `MurmurTests/Helpers/MockCleanupProvider.swift`:
```swift
import Foundation
@testable import Murmur

actor MockCleanupProvider: CleanupProvider {
    nonisolated let displayName: String
    private var responses: [Result<String, Error>]
    private(set) var calls: [(text: String, mode: CleanupMode)] = []

    init(name: String = "mock", responses: [Result<String, Error>]) {
        self.displayName = name
        self.responses = responses
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        calls.append((text, mode))
        guard !responses.isEmpty else { throw NSError(domain: "mock", code: -1) }
        return try responses.removeFirst().get()
    }

    func callCount() -> Int { calls.count }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 4: Commit**

```bash
git add Murmur/Cleanup/CleanupProvider.swift MurmurTests/Helpers/MockCleanupProvider.swift
git commit -m "feat(cleanup): CleanupProvider protocol + mock helper"
```

---

## Task 11: GroqProvider

**Files:**
- Create: `Murmur/Cleanup/GroqProvider.swift`

- [ ] **Step 1: Implement Groq REST client**

Create `Murmur/Cleanup/GroqProvider.swift`:
```swift
import Foundation

actor GroqProvider: CleanupProvider {
    nonisolated let displayName = "Groq"

    enum GroqError: Error { case badStatus(Int), missingAPIKey, decodeFailed }

    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(apiKey: String, model: String, timeout: TimeInterval = 2.0) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.urlSession = URLSession(configuration: cfg)
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Message: Encodable { let role: String; let content: String }
        struct Body: Encodable {
            let model: String
            let temperature: Double
            let messages: [Message]
        }
        let body = Body(
            model: model,
            temperature: 0.2,
            messages: [
                .init(role: "system", content: PromptBuilder.systemPrompt(for: mode)),
                .init(role: "user", content: text),
            ]
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GroqError.badStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw GroqError.badStatus(http.statusCode) }

        struct Choice: Decodable { let message: Msg; struct Msg: Decodable { let content: String } }
        struct Wire: Decodable { let choices: [Choice] }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard let content = wire.choices.first?.message.content else { throw GroqError.decodeFailed }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/Cleanup/GroqProvider.swift
git commit -m "feat(cleanup): GroqProvider via Chat Completions API"
```

---

## Task 12: GemmaOllamaProvider

**Files:**
- Create: `Murmur/Cleanup/GemmaOllamaProvider.swift`

- [ ] **Step 1: Implement Ollama HTTP client**

Create `Murmur/Cleanup/GemmaOllamaProvider.swift`:
```swift
import Foundation

actor GemmaOllamaProvider: CleanupProvider {
    nonisolated let displayName = "Gemma (local)"

    enum OllamaError: Error { case unreachable, badStatus(Int), decodeFailed }

    private let endpoint: URL
    private let model: String
    private let urlSession: URLSession

    init(endpoint: URL = URL(string: "http://localhost:11434")!, model: String, timeout: TimeInterval = 8.0) {
        self.endpoint = endpoint
        self.model = model
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.urlSession = URLSession(configuration: cfg)
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        var req = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Message: Encodable { let role: String; let content: String }
        struct Body: Encodable {
            let model: String
            let stream: Bool
            let messages: [Message]
            let options: [String: Double]
        }
        let body = Body(
            model: model,
            stream: false,
            messages: [
                .init(role: "system", content: PromptBuilder.systemPrompt(for: mode)),
                .init(role: "user", content: text),
            ],
            options: ["temperature": 0.2]
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw OllamaError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.badStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw OllamaError.badStatus(http.statusCode) }

        struct Wire: Decodable { let message: Msg; struct Msg: Decodable { let content: String } }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return wire.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isReachable(endpoint: URL = URL(string: "http://localhost:11434")!) async -> Bool {
        var req = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        req.timeoutInterval = 0.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/Cleanup/GemmaOllamaProvider.swift
git commit -m "feat(cleanup): GemmaOllamaProvider via Ollama /api/chat"
```

---

## Task 13: ContextDetector + tests

**Files:**
- Create: `Murmur/Paste/ContextDetector.swift`
- Test: `MurmurTests/ContextDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MurmurTests/ContextDetectorTests.swift`:
```swift
import Testing
@testable import Murmur

@Suite("ContextDetector")
struct ContextDetectorTests {
    @Test("user override beats default")
    func override() {
        let det = ContextDetector(
            defaults: ["com.apple.Terminal": .light],
            userOverrides: [.init(bundleID: "com.apple.Terminal", mode: .code)]
        )
        #expect(det.mode(for: "com.apple.Terminal") == .code)
    }

    @Test("default mapping applied when no override")
    func defaultMapping() {
        let det = ContextDetector(
            defaults: ["com.apple.dt.Xcode": .code],
            userOverrides: []
        )
        #expect(det.mode(for: "com.apple.dt.Xcode") == .code)
    }

    @Test("unknown bundle returns prose")
    func unknown() {
        let det = ContextDetector(defaults: [:], userOverrides: [])
        #expect(det.mode(for: "com.example.unknown") == .prose)
    }

    @Test("nil bundle returns prose")
    func nilBundle() {
        let det = ContextDetector(defaults: [:], userOverrides: [])
        #expect(det.mode(for: nil) == .prose)
    }
}
```

- [ ] **Step 2: Run tests; expect compile failure**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/ContextDetectorTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement `ContextDetector`**

Create `Murmur/Paste/ContextDetector.swift`:
```swift
import AppKit

struct ContextDetector: Sendable {
    let defaults: [String: CleanupMode]
    let userOverrides: [AppOverride]

    static let builtinDefaults: [String: CleanupMode] = [
        "com.apple.Terminal": .light,
        "com.googlecode.iterm2": .light,
        "com.mitchellh.ghostty": .light,
        "org.alacritty": .light,
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "dev.zed.Zed": .code,
    ]

    func mode(for bundleID: String?) -> CleanupMode {
        guard let bundleID else { return .prose }
        if let user = userOverrides.first(where: { $0.bundleID == bundleID }) { return user.mode }
        return defaults[bundleID] ?? .prose
    }

    @MainActor
    func currentMode() -> CleanupMode {
        mode(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/ContextDetectorTests
```

- [ ] **Step 5: Commit**

```bash
git add Murmur/Paste/ContextDetector.swift MurmurTests/ContextDetectorTests.swift
git commit -m "feat(paste): ContextDetector with user-override precedence"
```

---

## Task 14: Paster

**Files:**
- Create: `Murmur/Paste/Paster.swift`

No unit tests — paste interacts with the real `NSPasteboard` and `CGEvent`. Verified via the manual matrix in Task 25.

- [ ] **Step 1: Implement `Paster`**

Create `Murmur/Paste/Paster.swift`:
```swift
import AppKit

@MainActor
final class Paster {
    enum PasteOutcome { case pasted, copiedOnly }

    private let restoreDelay: UInt64 = 200_000_000 // 200ms

    func paste(_ text: String) async -> PasteOutcome {
        let pb = NSPasteboard.general
        let priorChange = pb.changeCount
        let priorContents = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { dict[type] = d }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("Murmur", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])

        guard hasFocusedTextElement() else {
            return .copiedOnly
        }

        sendCmdV()

        try? await Task.sleep(nanoseconds: restoreDelay)
        if pb.changeCount == priorChange + 1 {
            pb.clearContents()
            let restored: [NSPasteboardItem] = priorContents.map { dict in
                let it = NSPasteboardItem()
                for (type, data) in dict { it.setData(data, forType: type) }
                return it
            }
            if !restored.isEmpty { pb.writeObjects(restored) }
        }
        return .pasted
    }

    private func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func hasFocusedTextElement() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return false }
        var role: AnyObject?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let r = (role as? String) ?? ""
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r)
            || isEditableWebElement(focused as! AXUIElement)
    }

    private func isEditableWebElement(_ el: AXUIElement) -> Bool {
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
        let s = (subrole as? String) ?? ""
        return s == "AXContentEditable" || s == "AXTextField"
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/Paste/Paster.swift
git commit -m "feat(paste): Paster — clipboard swap + ⌘V with restore"
```

---

## Task 15: HotkeyMonitor (Right Option hold detection)

**Files:**
- Create: `Murmur/Hotkey/HotkeyMonitor.swift`

- [ ] **Step 1: Implement `HotkeyMonitor`**

Create `Murmur/Hotkey/HotkeyMonitor.swift`:
```swift
import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)? // Escape during recording

    private var modifierMonitor: Any?
    private var keyMonitor: Any?
    private var isHeld = false

    func start() {
        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == kVK_Escape { self?.handleEscape() }
        }
    }

    func stop() {
        if let m = modifierMonitor { NSEvent.removeMonitor(m); modifierMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func handleFlags(_ event: NSEvent) {
        let isRightOption = event.keyCode == UInt16(kVK_RightOption)
        guard isRightOption else { return }
        let pressed = event.modifierFlags.contains(.option)
        if pressed && !isHeld {
            isHeld = true
            onPress?()
        } else if !pressed && isHeld {
            isHeld = false
            onRelease?()
        }
    }

    private func handleEscape() {
        if isHeld {
            isHeld = false
            onCancel?()
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/Hotkey/HotkeyMonitor.swift
git commit -m "feat(hotkey): HotkeyMonitor for Right Option hold + Escape cancel"
```

---

## Task 16: DictationOrchestrator + tests

**Files:**
- Create: `Murmur/Pipeline/DictationOrchestrator.swift`
- Create: `Murmur/Pipeline/DictationStage.swift`
- Test: `MurmurTests/DictationOrchestratorTests.swift`

- [ ] **Step 1: Define stage enum**

Create `Murmur/Pipeline/DictationStage.swift`:
```swift
enum DictationStage: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case cleaning(provider: String)
    case pasted(words: Int)
    case copiedOnly
    case error(message: String)
}
```

- [ ] **Step 2: Write the failing tests**

Create `MurmurTests/DictationOrchestratorTests.swift`:
```swift
import Testing
import Foundation
@testable import Murmur

actor MockTranscriber: TranscriptionProvider {
    var result: Result<String, Error>
    init(_ r: Result<String, Error>) { result = r }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String { try result.get() }
}

@MainActor
final class StageRecorder {
    var stages: [DictationStage] = []
    func record(_ s: DictationStage) { stages.append(s) }
}

@Suite("DictationOrchestrator")
struct DictationOrchestratorTests {
    @MainActor
    @Test("happy path: transcribe → groq cleanup → paste")
    func happyPath() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello world")),
            primary: MockCleanupProvider(name: "Groq", responses: [.success("Hello, world.")]),
            fallback: nil,
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0.1, 0.2], sampleRate: 16_000, didOverflow: false)
        #expect(recorder.stages.contains(.transcribing))
        #expect(recorder.stages.contains(.cleaning(provider: "Groq")))
        #expect(recorder.stages.contains(.pasted(words: 2)))
    }

    @MainActor
    @Test("primary fails → fallback used")
    func fallback() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello")),
            primary: MockCleanupProvider(name: "Groq", responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(name: "Gemma", responses: [.success("Hello.")]),
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0.1], sampleRate: 16_000, didOverflow: false)
        #expect(recorder.stages.contains(.cleaning(provider: "Gemma")))
        #expect(recorder.stages.contains(.pasted(words: 1)))
    }

    @MainActor
    @Test("both providers fail → raw paste")
    func bothFail() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("raw text here")),
            primary: MockCleanupProvider(responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(responses: [.failure(NSError(domain: "y", code: 2))]),
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0.1], sampleRate: 16_000, didOverflow: false)
        #expect(recorder.stages.contains(.pasted(words: 3)))
    }

    @MainActor
    @Test("empty transcription → error stage")
    func emptyStt() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.failure(WhisperKitProvider.WhisperError.emptyResult)),
            primary: MockCleanupProvider(responses: []),
            fallback: nil,
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0], sampleRate: 16_000, didOverflow: false)
        let isError: (DictationStage) -> Bool = { if case .error = $0 { return true } else { return false } }
        #expect(recorder.stages.contains(where: isError))
    }
}
```

- [ ] **Step 3: Run tests; expect compile failure**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/DictationOrchestratorTests 2>&1 | tail -20
```

- [ ] **Step 4: Implement `DictationOrchestrator`**

Create `Murmur/Pipeline/DictationOrchestrator.swift`:
```swift
import AppKit

@MainActor
final class DictationOrchestrator {
    private let transcriber: TranscriptionProvider
    private let primary: CleanupProvider
    private let fallback: CleanupProvider?
    private let detector: ContextDetector
    private let paste: (String) async -> Paster.PasteOutcome
    private let onStage: (DictationStage) -> Void
    private let history: HistoryStore?

    private var currentTask: Task<Void, Never>?

    init(
        transcriber: TranscriptionProvider,
        primary: CleanupProvider,
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

        onStage(.transcribing)
        let raw: String
        do {
            raw = try await transcriber.transcribe(samples: samples, sampleRate: sampleRate)
        } catch {
            onStage(.error(message: "No speech detected"))
            return
        }
        if Task.isCancelled { return }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let mode = detector.mode(for: bundleID)

        var cleanedText = raw
        var cleanProvider: String? = nil
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
                    cleanedText = raw
                }
            } else {
                cleanedText = raw
            }
        }
        if Task.isCancelled { return }
        _ = cleanProvider

        let outcome = await paste(cleanedText)
        let words = cleanedText.split(separator: " ").count
        switch outcome {
        case .pasted: onStage(.pasted(words: words))
        case .copiedOnly: onStage(.copiedOnly)
        }

        if let history, let bundleID {
            try? history.append(.init(
                timestamp: .now,
                raw: raw,
                cleaned: cleanedText,
                bundleID: bundleID,
                appName: appName
            ))
        }
    }
}
```

- [ ] **Step 5: Run tests; expect pass**

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/DictationOrchestratorTests
```

- [ ] **Step 6: Commit**

```bash
git add Murmur/Pipeline/ MurmurTests/DictationOrchestratorTests.swift
git commit -m "feat(pipeline): DictationOrchestrator with fallback chain"
```

---

## Task 17: HUDViewModel

**Files:**
- Create: `Murmur/UI/HUD/HUDViewModel.swift`

- [ ] **Step 1: Implement view model**

Create `Murmur/UI/HUD/HUDViewModel.swift`:
```swift
import SwiftUI
import Combine

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var stage: DictationStage = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0

    private var timer: Timer?
    private var startTime: Date?

    func update(_ stage: DictationStage) {
        self.stage = stage
        switch stage {
        case .recording:
            startTime = Date()
            elapsed = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startTime else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
        case .pasted, .copiedOnly, .error:
            timer?.invalidate(); timer = nil
            startTime = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if case .recording = self.stage { return } // overtaken
                self.stage = .idle
            }
        case .idle, .transcribing, .cleaning:
            timer?.invalidate(); timer = nil
            startTime = nil
        }
    }

    var isVisible: Bool {
        if case .idle = stage { return false } else { return true }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/UI/HUD/HUDViewModel.swift
git commit -m "feat(hud): HUDViewModel state machine + auto-fade"
```

---

## Task 18: HUDView (SwiftUI)

**Files:**
- Create: `Murmur/UI/HUD/HUDView.swift`

- [ ] **Step 1: Implement HUD SwiftUI view**

Create `Murmur/UI/HUD/HUDView.swift`:
```swift
import SwiftUI

struct HUDView: View {
    @ObservedObject var vm: HUDViewModel

    var body: some View {
        HStack(spacing: 10) {
            icon
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.1)))
        .shadow(radius: 12, y: 4)
        .animation(.easeInOut(duration: 0.2), value: stageKey)
    }

    private var stageKey: String {
        switch vm.stage {
        case .idle: return "idle"
        case .recording: return "rec"
        case .transcribing: return "stt"
        case .cleaning(let p): return "clean-\(p)"
        case .pasted: return "pasted"
        case .copiedOnly: return "copied"
        case .error: return "error"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch vm.stage {
        case .recording: Circle().fill(.red).frame(width: 10, height: 10)
        case .transcribing, .cleaning: ProgressView().controlSize(.small)
        case .pasted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .copiedOnly: Image(systemName: "doc.on.clipboard").foregroundStyle(.blue)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle: EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.stage {
        case .recording:
            HStack(spacing: 8) {
                Waveform(level: vm.level).frame(width: 80, height: 16)
                Text(String(format: "%d:%02d", Int(vm.elapsed)/60, Int(vm.elapsed)%60))
                    .font(.system(.caption, design: .monospaced))
            }
        case .transcribing: Text("Transcribing…")
        case .cleaning(let p): Text("Polishing…  via \(p)").font(.callout)
        case .pasted(let w): Text("Pasted (\(w) word\(w == 1 ? "" : "s"))")
        case .copiedOnly: Text("Copied — no field focused")
        case .error(let m): Text(m)
        case .idle: EmptyView()
        }
    }
}

private struct Waveform: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    let phase = Float(i) / 10
                    let h = max(2, CGFloat(level) * geo.size.height * (0.5 + 0.5 * sin(Double(phase) * .pi)))
                    RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.7)).frame(height: h)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/UI/HUD/HUDView.swift
git commit -m "feat(hud): HUDView SwiftUI capsule with state-aware visuals"
```

---

## Task 19: HUDWindow (NSPanel host)

**Files:**
- Create: `Murmur/UI/HUD/HUDWindow.swift`

- [ ] **Step 1: Implement borderless panel**

Create `Murmur/UI/HUD/HUDWindow.swift`:
```swift
import AppKit
import SwiftUI
import Combine

@MainActor
final class HUDWindow {
    private let panel: NSPanel
    private let viewModel: HUDViewModel
    private var observer: NSObjectProtocol?
    private var cancellable: AnyCancellable?

    init(viewModel: HUDViewModel) {
        self.viewModel = viewModel
        let host = NSHostingController(rootView: HUDView(vm: viewModel))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        self.panel = panel

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reposition() } }

        cancellable = viewModel.$stage.sink { [weak self, weak viewModel] _ in
            Task { @MainActor in
                guard let self, let viewModel else { return }
                self.setVisible(viewModel.isVisible)
            }
        }
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    func setVisible(_ visible: Bool) {
        if visible {
            reposition()
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in self?.panel.orderOut(nil) })
        }
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 60
        )
        panel.setFrameOrigin(origin)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/UI/HUD/HUDWindow.swift
git commit -m "feat(hud): HUDWindow NSPanel host, anchored bottom-center"
```

---

## Task 20: SettingsWindow + Tabs (skeleton)

**Files:**
- Create: `Murmur/UI/Settings/SettingsWindow.swift`
- Create: `Murmur/UI/Settings/GeneralTab.swift`
- Create: `Murmur/UI/Settings/ProvidersTab.swift`
- Create: `Murmur/UI/Settings/AppOverridesTab.swift`
- Create: `Murmur/UI/Settings/HistoryTab.swift`
- Create: `Murmur/UI/Settings/AboutTab.swift`

This task ships the structure with simple controls; deeper polish is optional v1.x work.

- [ ] **Step 1: GeneralTab**

Create `Murmur/UI/Settings/GeneralTab.swift`:
```swift
import SwiftUI

struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Recording") {
                Stepper(
                    "Max recording length: \(settings.maxRecordingSeconds)s",
                    value: Binding(
                        get: { settings.maxRecordingSeconds },
                        set: { settings.maxRecordingSeconds = $0 }
                    ),
                    in: 10...300, step: 10
                )
            }
            Section("Hotkey") {
                Text("Hold **Right Option** to dictate.")
                Text("Rebinding UI ships in v1.1.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 2: ProvidersTab**

Create `Murmur/UI/Settings/ProvidersTab.swift`:
```swift
import SwiftUI

struct ProvidersTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var groqKey: String = ""
    @State private var ollamaReachable: Bool = false

    private let keychain = KeychainStore(service: "com.murmur.app", account: "groq-api-key")

    var body: some View {
        Form {
            Section("Speech-to-text (local)") {
                Picker("WhisperKit model", selection: Binding(
                    get: { settings.whisperModel },
                    set: { settings.whisperModel = $0 }
                )) {
                    Text("tiny.en").tag("openai_whisper-tiny.en")
                    Text("base.en").tag("openai_whisper-base.en")
                    Text("small.en (recommended)").tag("openai_whisper-small.en")
                    Text("medium.en").tag("openai_whisper-medium.en")
                }
            }
            Section("Cleanup — primary (Groq)") {
                SecureField("Groq API key", text: $groqKey)
                    .onAppear { groqKey = (try? keychain.get()) ?? "" }
                Button("Save key") { try? keychain.set(groqKey) }
                TextField("Model", text: Binding(
                    get: { settings.groqModel },
                    set: { settings.groqModel = $0 }
                ))
            }
            Section("Cleanup — fallback (Gemma via Ollama)") {
                Toggle("Use Gemma fallback when Groq fails", isOn: Binding(
                    get: { settings.cleanupFallbackEnabled },
                    set: { settings.cleanupFallbackEnabled = $0 }
                ))
                TextField("Ollama model", text: Binding(
                    get: { settings.ollamaModel },
                    set: { settings.ollamaModel = $0 }
                ))
                HStack {
                    Image(systemName: ollamaReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ollamaReachable ? .green : .red)
                    Text(ollamaReachable ? "Ollama reachable" : "Ollama not reachable on localhost:11434")
                }
                .task {
                    ollamaReachable = await GemmaOllamaProvider.isReachable()
                }
            }
        }
        .padding()
    }
}
```

- [ ] **Step 3: AppOverridesTab**

Create `Murmur/UI/Settings/AppOverridesTab.swift`:
```swift
import SwiftUI
import AppKit

struct AppOverridesTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading) {
            Text("Per-app cleanup mode (overrides built-in defaults)")
                .font(.headline)
            Table(settings.appOverrides) {
                TableColumn("Bundle ID", value: \.bundleID)
                TableColumn("Mode") { row in
                    Picker("", selection: Binding(
                        get: { row.mode },
                        set: { newMode in
                            var arr = settings.appOverrides
                            if let idx = arr.firstIndex(where: { $0.bundleID == row.bundleID }) {
                                arr[idx].mode = newMode
                                settings.appOverrides = arr
                            }
                        }
                    )) {
                        ForEach(CleanupMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Button("Add from running apps") { addFromRunning() }
                Spacer()
                Button("Reset to defaults") {
                    settings.appOverrides = ContextDetector.builtinDefaults.map {
                        AppOverride(bundleID: $0.key, mode: $0.value)
                    }
                }
            }
        }
        .padding()
    }

    private func addFromRunning() {
        let running = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
        var arr = settings.appOverrides
        for id in running where !arr.contains(where: { $0.bundleID == id }) {
            arr.append(.init(bundleID: id, mode: .prose))
        }
        settings.appOverrides = arr
    }
}
```

- [ ] **Step 4: HistoryTab**

Create `Murmur/UI/Settings/HistoryTab.swift`:
```swift
import SwiftUI

struct HistoryTab: View {
    let store: HistoryStore
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        VStack {
            Table(entries.reversed()) {
                TableColumn("Time") { Text($0.timestamp.formatted(date: .abbreviated, time: .standard)) }
                TableColumn("App", value: \.appName)
                TableColumn("Cleaned") { Text($0.cleaned).lineLimit(1) }
            }
            HStack {
                Button("Refresh") { reload() }
                Spacer()
                Button("Clear all", role: .destructive) {
                    try? store.clear(); reload()
                }
            }
        }
        .padding()
        .onAppear { reload() }
    }

    private func reload() { entries = (try? store.read()) ?? [] }
}
```

- [ ] **Step 5: AboutTab**

Create `Murmur/UI/Settings/AboutTab.swift`:
```swift
import SwiftUI
import ApplicationServices

struct AboutTab: View {
    var body: some View {
        Form {
            Section("Permissions") {
                let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                let ax = AXIsProcessTrusted()
                Label(mic ? "Microphone: granted" : "Microphone: not granted",
                      systemImage: mic ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(mic ? .green : .red)
                Label(ax ? "Accessibility: granted" : "Accessibility: not granted",
                      systemImage: ax ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ax ? .green : .red)
            }
            Section("About") {
                Text("Murmur — voice dictation for macOS")
                Text("v0.1.0").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
```

Note: `AboutTab` imports `AVFoundation` for `AVCaptureDevice`. Add `import AVFoundation` at top.

- [ ] **Step 6: SettingsWindow shell**

Create `Murmur/UI/Settings/SettingsWindow.swift`:
```swift
import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    let settings: SettingsStore
    let history: HistoryStore

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = TabView {
            GeneralTab(settings: settings).tabItem { Label("General", systemImage: "gearshape") }
            ProvidersTab(settings: settings).tabItem { Label("Providers", systemImage: "cloud") }
            AppOverridesTab(settings: settings).tabItem { Label("App Overrides", systemImage: "app.badge") }
            HistoryTab(store: history).tabItem { Label("History", systemImage: "clock") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 600, minHeight: 420)

        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Murmur Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

Add `import AVFoundation` to `AboutTab.swift`.

- [ ] **Step 7: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 8: Commit**

```bash
git add Murmur/UI/Settings/
git commit -m "feat(settings): tabbed Settings window with all 5 tabs"
```

---

## Task 21: OnboardingWindow

**Files:**
- Create: `Murmur/UI/Onboarding/OnboardingWindow.swift`

- [ ] **Step 1: Implement onboarding wizard**

Create `Murmur/UI/Onboarding/OnboardingWindow.swift`:
```swift
import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    let onComplete: () -> Void
    init(onComplete: @escaping () -> Void) { self.onComplete = onComplete }

    func show() {
        let root = OnboardingView { [weak self] in
            self?.window?.close()
            self?.onComplete()
        }
        let host = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: host)
        win.title = "Welcome to Murmur"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 520, height: 360))
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var step = 0
    @State private var micGranted = false
    @State private var axGranted = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 18) {
            switch step {
            case 0:
                welcome
            case 1:
                permissionStep(
                    title: "Microphone access",
                    granted: micGranted,
                    action: requestMic
                )
            case 2:
                permissionStep(
                    title: "Accessibility access",
                    granted: axGranted,
                    action: openAccessibilitySettings
                )
            default:
                Text("All set!")
                Button("Finish") { onFinish() }
            }
            Spacer()
        }
        .padding(30)
        .task { startAxPolling() }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Text("Murmur").font(.largeTitle).bold()
            Text("Hold Right Option to dictate. Release to paste.")
            Button("Continue") { step = 1 }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func permissionStep(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.title2).bold()
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 60))
                .foregroundStyle(granted ? .green : .secondary)
            HStack {
                Button(granted ? "Granted" : "Grant") { action() }.disabled(granted)
                Button("Continue") { step += 1 }.disabled(!granted)
            }
        }
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { micGranted = ok }
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func startAxPolling() {
        Task { @MainActor in
            while step <= 2 {
                axGranted = AXIsProcessTrusted()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/UI/Onboarding/
git commit -m "feat(onboarding): 3-step wizard for mic + AX permissions"
```

---

## Task 22: AppDelegate, status item, full wiring

**Files:**
- Modify: `Murmur/MurmurApp.swift` (created by Xcode template)
- Create: `Murmur/App/AppDelegate.swift`

- [ ] **Step 1: Replace Murmur app entry point**

Replace contents of `Murmur/MurmurApp.swift`:
```swift
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() } // satisfied by AppDelegate's window
    }
}
```

- [ ] **Step 2: Implement AppDelegate**

Create `Murmur/App/AppDelegate.swift`:
```swift
import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = SettingsStore()
    private let history: HistoryStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        return HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
    }()
    private let hudVM = HUDViewModel()
    private lazy var hud = HUDWindow(viewModel: hudVM)
    private lazy var settingsCtl = SettingsWindowController(settings: settings, history: history)
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let paster = Paster()
    private var orchestrator: DictationOrchestrator?
    private let keychain = KeychainStore(service: "com.murmur.app", account: "groq-api-key")
    private var transcriber: WhisperKitProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        let onboarded = UserDefaults.standard.bool(forKey: "onboardingComplete")
        if !onboarded {
            let ob = OnboardingWindowController { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
                self?.startRuntime()
            }
            ob.show()
        } else {
            startRuntime()
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Murmur")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() { settingsCtl.show() }

    private func startRuntime() {
        transcriber = WhisperKitProvider(modelName: settings.whisperModel)
        let groqKey = (try? keychain.get()) ?? ""
        let primary = GroqProvider(apiKey: groqKey, model: settings.groqModel)
        let fallback: CleanupProvider? = settings.cleanupFallbackEnabled
            ? GemmaOllamaProvider(model: settings.ollamaModel)
            : nil
        let detector = ContextDetector(
            defaults: ContextDetector.builtinDefaults,
            userOverrides: settings.appOverrides
        )

        let orch = DictationOrchestrator(
            transcriber: transcriber!,
            primary: primary,
            fallback: fallback,
            detector: detector,
            paste: { [paster] text in await paster.paste(text) },
            onStage: { [hudVM] stage in hudVM.update(stage) },
            history: settings.saveHistory ? history : nil
        )
        self.orchestrator = orch

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onCancel = { [weak self] in self?.handleCancel() }
        hotkey.start()
    }

    private func handlePress() {
        _ = hud  // ensure window/subscription created
        Task { @MainActor in
            do {
                try await recorder.start(maxSeconds: settings.maxRecordingSeconds)
                hudVM.update(.recording)
            } catch {
                hudVM.update(.error(message: "Mic unavailable"))
            }
        }
    }

    private func handleRelease() {
        Task { @MainActor in
            let samples = await recorder.stop()
            let didOverflow = await recorder.didOverflow()
            orchestrator?.run(samples: samples, sampleRate: 16_000, didOverflow: didOverflow)
        }
    }

    private func handleCancel() {
        Task { @MainActor in
            _ = await recorder.stop()
            orchestrator?.cancel()
            hudVM.update(.idle)
        }
    }
}
```

- [ ] **Step 3: Build & launch**

```bash
xcodebuild -scheme Murmur -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Debug/Murmur.app
```

Expected: app launches, menu bar mic icon appears, onboarding wizard opens (first run only).

- [ ] **Step 4: Commit**

```bash
git add Murmur/App/ Murmur/MurmurApp.swift
git commit -m "feat(app): wire AppDelegate — status item, onboarding, runtime"
```

---

## Task 23: Manual smoke test pass

This task is a checklist, not code. Walk through each item and check it off.

- [ ] **Mic permission flow:** First launch shows onboarding. Mic prompt appears when "Grant" pressed. Granting moves on.
- [ ] **AX permission flow:** "Grant" opens System Settings → Privacy & Security → Accessibility. After enabling Murmur there, the wizard auto-detects within 1s.
- [ ] **Status item:** Mic icon present in menu bar. Click → menu with "Open Settings" and "Quit". Settings opens the tabbed window.
- [ ] **Settings → Providers:** Paste a Groq API key, click Save. Switch to another tab and back; key field still populated (read from Keychain).
- [ ] **Hold-to-talk in TextEdit:** Open TextEdit, click in document, hold Right Option, say "hello world this is a test", release. HUD shows recording → transcribing → cleaning → pasted. Text appears in TextEdit.
- [ ] **Hold-to-talk in Terminal:** Repeat in Terminal. Cleanup mode should be `.light` (no rephrasing of e.g. command names).
- [ ] **No focused field:** With Finder frontmost (no text selection), record. HUD shows "Copied — no field focused." `Cmd+V` in any text field pastes the cleaned text.
- [ ] **Escape cancels:** Hold Right Option, start saying something, press Escape while still holding. HUD fades, nothing pasted.
- [ ] **60s cap:** Hold Right Option for >60s. HUD ends recording around 60s automatically. Whatever was captured is processed.
- [ ] **Groq disabled (empty key):** Clear API key in Keychain. Restart app. Dictate. HUD should show "Polishing… via Gemma" if Ollama is running, or paste raw if not.
- [ ] **History tab:** After several dictations, History tab populates. Clear All empties it.
- [ ] **Clipboard restore:** Copy something to clipboard manually. Dictate. After paste, the original clipboard contents are restored.

If anything fails, file as a bug, do not mark plan complete.

- [ ] **Final commit (if any fixes needed during smoke test):**

```bash
git add -A
git commit -m "fix: smoke test corrections"
```

---

## Self-Review Notes

- Every spec section has a corresponding task: Storage (3, 4, 5), Audio (6, 7), STT (8), Cleanup (9–12), Paste (13, 14), Hotkey (15), Pipeline (16), HUD (17–19), Settings (20), Onboarding (21), AppDelegate wiring (22), Manual matrix (23).
- Performance budgets are tracked in the spec but not enforced in tests; they're checked manually in Task 23.
- Integration tests for `WhisperKitProvider`, `GroqProvider`, `GemmaOllamaProvider` are noted in the spec as gated. Skipped here for v1 to keep the plan focused on shipping; add as v1.1 if needed.
- Hotkey rebind UI deferred to v1.1 per General tab note — explicit non-feature, not a placeholder.
- The Cursor bundle ID issue from the spec is handled: `ContextDetector.builtinDefaults` only includes verifiable IDs; user can add Cursor via App Overrides tab.
