import Testing
@testable import Murmur

@Suite("CleanupOutputGuard")
struct CleanupOutputGuardTests {
    @Test("rejects assistant style reply")
    func rejectsAssistantReply() {
        let sanitized = CleanupOutputGuard.sanitize(
            candidate: "Sure, here's the cleaned text: Hello, world.",
            original: "hello world",
            mode: .prose
        )
        #expect(sanitized == nil)
    }

    @Test("rejects over-expanded output")
    func rejectsExpansion() {
        let sanitized = CleanupOutputGuard.sanitize(
            candidate: "Hello world. This means you are greeting the audience in a friendly and professional tone.",
            original: "hello world",
            mode: .prose
        )
        #expect(sanitized == nil)
    }

    @Test("keeps direct cleaned output")
    func acceptsDirectCleanup() {
        let sanitized = CleanupOutputGuard.sanitize(
            candidate: "Hello, world.",
            original: "hello world",
            mode: .prose
        )
        #expect(sanitized == "Hello, world.")
    }
}
