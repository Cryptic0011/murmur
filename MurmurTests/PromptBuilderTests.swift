import Testing
@testable import Murmur

@Suite("PromptBuilder")
struct PromptBuilderTests {
    @Test("light mode mentions filler words and not rephrasing")
    func light() {
        let p = PromptBuilder.systemPrompt(for: .light)
        #expect(p.localizedCaseInsensitiveContains("filler"))
        #expect(p.localizedCaseInsensitiveContains("verbatim"))
        #expect(p.localizedCaseInsensitiveContains("not a chat assistant"))
    }

    @Test("prose mode mentions false starts")
    func prose() {
        let p = PromptBuilder.systemPrompt(for: .prose)
        #expect(p.localizedCaseInsensitiveContains("false start"))
        #expect(p.localizedCaseInsensitiveContains("MUST NOT answer"))
    }

    @Test("code mode preserves identifiers")
    func code() {
        let p = PromptBuilder.systemPrompt(for: .code)
        #expect(p.localizedCaseInsensitiveContains("identifier") || p.localizedCaseInsensitiveContains("code"))
        #expect(p.localizedCaseInsensitiveContains("verbatim"))
        #expect(p.localizedCaseInsensitiveContains("code fences"))
    }

    @Test("vocabulary terms are listed in the prompt")
    func vocabulary() {
        let context = CleanupContext(vocabulary: ["Murmur", "Groq", "WhisperKit"])
        let p = PromptBuilder.systemPrompt(for: .prose, context: context)
        #expect(p.contains("Murmur, Groq, WhisperKit"))
        #expect(p.localizedCaseInsensitiveContains("glossary"))
    }

    @Test("field context is embedded with guardrails")
    func fieldContext() {
        let context = CleanupContext(fieldText: "Hi team, quick update:")
        let p = PromptBuilder.systemPrompt(for: .email, context: context)
        #expect(p.contains("<field>\nHi team, quick update:\n</field>"))
        #expect(p.localizedCaseInsensitiveContains("Do NOT repeat"))
    }

    @Test("empty context adds nothing")
    func emptyContext() {
        #expect(PromptBuilder.systemPrompt(for: .prose, context: .none) == PromptBuilder.systemPrompt(for: .prose))
        #expect(!PromptBuilder.systemPrompt(for: .prose).contains("<field>"))
        #expect(!PromptBuilder.systemPrompt(for: .prose).localizedCaseInsensitiveContains("glossary"))
    }

    @Test("profile modes describe their target style")
    func profileModes() {
        #expect(PromptBuilder.systemPrompt(for: .email).localizedCaseInsensitiveContains("email"))
        #expect(PromptBuilder.systemPrompt(for: .email).localizedCaseInsensitiveContains("Hi Jordan"))
        #expect(PromptBuilder.systemPrompt(for: .email).localizedCaseInsensitiveContains("blank line"))
        #expect(PromptBuilder.systemPrompt(for: .chat).localizedCaseInsensitiveContains("chat message"))
        #expect(PromptBuilder.systemPrompt(for: .notes).localizedCaseInsensitiveContains("notes"))
        #expect(PromptBuilder.systemPrompt(for: .notes).localizedCaseInsensitiveContains("source Markdown"))
        #expect(PromptBuilder.systemPrompt(for: .notes).localizedCaseInsensitiveContains("checklists"))
        #expect(PromptBuilder.systemPrompt(for: .prompt).localizedCaseInsensitiveContains("prompt"))
    }
}
