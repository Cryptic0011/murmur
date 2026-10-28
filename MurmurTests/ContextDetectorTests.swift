import Foundation
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

    @Test("built-in app profiles cover common writing contexts")
    func builtinProfiles() {
        #expect(ContextDetector.builtinDefaults["com.apple.mail"] == .email)
        #expect(ContextDetector.builtinDefaults["com.tinyspeck.slackmacgap"] == .chat)
        #expect(ContextDetector.builtinDefaults["com.apple.Notes"] == .notes)
        #expect(ContextDetector.builtinDefaults["md.obsidian"] == .notes)
        #expect(ContextDetector.builtinDefaults["ru.keepcoder.Telegram"] == .chat)
        #expect(ContextDetector.builtinDefaults["com.todesktop.230313mzl4w4u92"] == .code)
        // Code style also keeps Murmur from flipping these into screen-reader mode.
        #expect(ContextDetector.builtinDefaults["com.exafunction.windsurf"] == .code)
        // Custom-drawn: AX shows no field, and no smart spacing in a shell.
        #expect(ContextDetector.builtinDefaults["net.kovidgoyal.kitty"] == .light)
        #expect(ContextDetector.builtinDefaults["com.openai.chat"] == .prompt)
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

    @MainActor
    @Test("the dictation target is never Murmur itself")
    func targetSkipsMurmur() {
        let pid = ContextDetector.targetApplication()?.processIdentifier
        #expect(pid != ProcessInfo.processInfo.processIdentifier)
    }
}
