import Testing
@testable import Murmur

@Suite("LocalCleanup")
struct LocalCleanupTests {
    @Test("removes fillers and spoken punctuation in prose")
    func proseCleanup() {
        let cleaned = LocalCleanup.clean("um hello comma i mean hello question mark", mode: .prose)
        #expect(cleaned == "Hello?")
    }

    @Test("normalizes email and percentages")
    func commonPatterns() {
        let cleaned = LocalCleanup.clean("send it to jane at example dot com it is fifty percent done", mode: .light)
        #expect(cleaned.contains("jane@example.com"))
        #expect(cleaned.contains("50%"))
    }

    @Test("email mode formats explicit greetings with a blank line")
    func emailExplicitGreeting() {
        let cleaned = LocalCleanup.clean("hi jordan can you send the updated proposal", mode: .email)
        #expect(cleaned == "Hi Jordan,\n\nCan you send the updated proposal.")
    }

    @Test("email mode formats direct address with a blank line")
    func emailDirectAddress() {
        let cleaned = LocalCleanup.clean("jordan comma please send the updated proposal", mode: .email)
        #expect(cleaned == "Hi Jordan,\n\nPlease send the updated proposal.")
    }

    @Test("notes mode formats dictated markdown structure")
    func notesMarkdownStructure() {
        let cleaned = LocalCleanup.clean(
            "title project plan new line heading next steps new line bullet point confirm scope new line checkbox send recap",
            mode: .notes
        )
        #expect(cleaned == """
        # Project plan
        ## Next steps
        - Confirm scope.
        - [ ] Send recap.
        """)
    }

    @Test("keeps code mode conservative but maps symbols")
    func codeCleanup() {
        let cleaned = LocalCleanup.clean("open paren foo underscore bar close paren dash dash help", mode: .code)
        #expect(cleaned.contains("( foo_bar )") || cleaned.contains("(foo_bar)"))
        #expect(cleaned.contains("-- help") || cleaned.contains("--help"))
    }
}
