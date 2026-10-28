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

    @Test("keeps conversational phrases that were dictated, but rejects added assistant commentary")
    func dictatedPhrases() {
        for text in [
            "Sure, send the updated estimate to Jordan tomorrow.",
            "Let me know when the staging deployment is ready.",
            "Send the updated estimate if you want to review it today.",
            "If you'd like, send the project report to Jordan tomorrow."
        ] {
            #expect(CleanupOutputGuard.sanitize(candidate: text, original: text, mode: .prose) == text)
        }
        #expect(CleanupOutputGuard.sanitize(
            candidate: "Send the updated estimate tomorrow. Let me know if you want more help.",
            original: "send the updated estimate tomorrow", mode: .prose
        ) == nil)
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

    @Test("rejects answers to dictated questions in every prose mode")
    func rejectsAnswers() {
        for mode in [CleanupMode.light, .prose, .chat, .email, .notes, .prompt] {
            #expect(CleanupOutputGuard.sanitize(
                candidate: "The capital of France is Paris.", original: "what is the capital of france", mode: mode
            ) == nil)
            #expect(CleanupOutputGuard.sanitize(
                candidate: "The capital of France is Paris, and it was founded in the 3rd century BC.",
                original: "can you tell me what the capital of france is and when it was founded", mode: mode
            ) == nil)
            #expect(CleanupOutputGuard.sanitize(candidate: "It's 3:42 PM.", original: "what time is it", mode: mode) == nil)
        }
        #expect(CleanupOutputGuard.sanitize(candidate: "Hola.", original: "translate hello to spanish", mode: .prose) == nil)
        #expect(CleanupOutputGuard.sanitize(
            candidate: "Why did the chicken cross the road? To get to the other side.",
            original: "tell me a joke about chickens", mode: .prose
        ) == nil)
    }

    @Test("a dictated question must stay a question")
    func keepsQuestions() {
        #expect(CleanupOutputGuard.sanitize(
            candidate: "The meeting starts at three.", original: "When does the meeting start?", mode: .prose
        ) == nil)
        #expect(CleanupOutputGuard.sanitize(
            candidate: "When does the meeting start?", original: "when does the meeting start?", mode: .prose
        ) == "When does the meeting start?")
        #expect(CleanupOutputGuard.sanitize(
            candidate: "What is the capital of France?", original: "what is the capital of france", mode: .prose
        ) == "What is the capital of France?")
    }

    @Test("rejects outputs that drop much of the dictation")
    func rejectsDroppedContent() {
        let original = "okay so I think we should probably move the launch to next week because the build is not ready yet"
        #expect(CleanupOutputGuard.sanitize(candidate: "Move the launch to next week.", original: original, mode: .light) == nil)
        #expect(CleanupOutputGuard.sanitize(candidate: "Move the launch to next week.", original: original, mode: .prose) == nil)
        #expect(CleanupOutputGuard.sanitize(
            candidate: "Latency is better; roll out Monday.",
            original: "so um I was looking at the dashboard this morning and uh the latency numbers look much better after the cache change and I think we should roll it out to everyone on monday",
            mode: .chat
        ) == nil)
    }

    @Test("accepts real cleanups")
    func acceptsGoodCleanups() {
        let cases: [(candidate: String, original: String, mode: CleanupMode)] = [
            ("Okay, so I think we should probably move the launch to next week because the build is not ready yet.",
             "okay so um I think we should probably move the launch to next week because the build is not ready yet", .light),
            ("So I was looking at the dashboard this morning and the latency numbers look much better after the cache change. I think we should roll it out to everyone on Monday.",
             "so um I was looking at the dashboard this morning and uh the latency numbers look much better after the cache change and I think we should roll it out to everyone on monday", .prose),
            ("We grew 25% this quarter across all 3 regions.", "we grew twenty five percent this quarter across all three regions", .prose),
            ("Hi Jordan,\n\nCan you send me the updated proposal by Friday? Thanks.",
             "hi jordan comma can you send me the updated proposal by friday thanks", .email),
            ("What I was thinking is we could move standup to 10:30.", "what I was thinking is we could move standup to ten thirty", .prose),
            ("They're going to the store.", "their going to the store", .prose),
            ("Send it Friday.", "send it tomorrow scratch that send it friday", .light),
            ("# Project plan\n## Next steps\n- Confirm scope\n- [ ] Send recap",
             "title project plan new line heading next steps new line bullet point confirm scope new line checkbox send recap", .notes),
        ]
        for c in cases {
            #expect(CleanupOutputGuard.sanitize(candidate: c.candidate, original: c.original, mode: c.mode) == c.candidate)
        }
    }

    @Test("vocabulary spellings are not counted as added content")
    func vocabularyIsNotNovel() {
        #expect(CleanupOutputGuard.sanitize(
            candidate: "We deployed the Murmur build to GroqCloud yesterday.",
            original: "we deployed the murmer build to grok cloud yesterday",
            mode: .prose, vocabulary: ["Murmur", "GroqCloud"]
        ) == "We deployed the Murmur build to GroqCloud yesterday.")
    }

    @Test("a leading filler doesn't make a dictated opener look like an assistant reply")
    func fillerBeforeBannedPrefix() {
        let cases: [(String, String)] = [
            ("Absolutely, we should ship it today.", "um absolutely we should ship it today"),
            ("Here's the plan for tomorrow: ship it.", "uh here's the plan for tomorrow ship it"),
            ("Here's the plan for Monday: we ship the build and then review metrics.",
             "so here's the plan for monday we ship the build and then review metrics"),
            ("Sure, I can do Thursday at noon if that works for everyone.",
             "um sure I can do thursday at noon if that works for everyone"),
        ]
        for (candidate, original) in cases {
            #expect(CleanupOutputGuard.sanitize(candidate: candidate, original: original, mode: .prose) == candidate)
        }
        #expect(CleanupOutputGuard.sanitize(
            candidate: "Sure! I can do Thursday at noon if that works for everyone.",
            original: "I can do thursday at noon if that works for everyone", mode: .chat
        ) == nil)
    }

    @Test("code mode rejects descriptions rewritten as commands")
    func codeContent() {
        #expect(CleanupOutputGuard.sanitize(candidate: "rm -rf temp", original: "delete the temp folder please", mode: .code) == nil)
        #expect(CleanupOutputGuard.sanitize(candidate: "git commit --amend", original: "git commit dash dash amend", mode: .code)
                == "git commit --amend")
        #expect(CleanupOutputGuard.sanitize(candidate: "getUserName()", original: "get user name open paren close paren", mode: .code)
                == "getUserName()")
        #expect(CleanupOutputGuard.sanitize(candidate: "let x = 5", original: "let x equals five", mode: .code) == "let x = 5")
        #expect(CleanupOutputGuard.sanitize(
            candidate: "if (x > 0) { return x }",
            original: "if left paren x greater than zero right paren left brace return x right brace", mode: .code
        ) == "if (x > 0) { return x }")
        #expect(CleanupOutputGuard.sanitize(
            candidate: "MAX_RETRIES = 10\nBASE_DELAY = 500",
            original: "constant all caps max retries equals ten and constant all caps base delay equals five hundred", mode: .code
        ) == "MAX_RETRIES = 10\nBASE_DELAY = 500")
    }

    @Test("a spoken correction or a 'what we…' statement may drop the opening question")
    func correctionsAndStatements() {
        let cases: [(candidate: String, original: String, mode: CleanupMode)] = [
            ("Let's just meet on Wednesday at the usual place.",
             "Should we meet on Tuesday? No wait, let's just meet on Wednesday at the usual place.", .prose),
            ("Let's do the review on Thursday afternoon with the whole team.",
             "How about, no wait, let's do the review on Thursday afternoon with the whole team.", .prose),
            ("Discussed today: the budget, the timeline, the hiring plan, and the office move.",
             "what we discussed today was the budget the timeline the hiring plan and the office move", .notes),
        ]
        for c in cases {
            #expect(CleanupOutputGuard.sanitize(candidate: c.candidate, original: c.original, mode: c.mode) == c.candidate)
        }
        // The corrected question is still a question.
        #expect(CleanupOutputGuard.sanitize(candidate: "Y is a letter.", original: "What is X? scratch that, what is Y?", mode: .prose) == nil)
    }

    @Test("a correction after a question doesn't let an answer through")
    func correctionAfterQuestion() {
        let answers: [(candidate: String, original: String)] = [
            ("The capital of France is Paris.", "What's the capital of France? Never mind."),
            ("The speed of light in a vacuum is approximately 299,792,458 kilometers per second.",
             "What is the speed of light in a vacuum measured in kilometers per second? Oh wait."),
            ("Leap years have 366 days.", "How many days are in a leap year? Scratch that."),
            ("The capital of Germany is Berlin.", "What is the capital of France? I mean, the capital of Germany."),
        ]
        for mode in [CleanupMode.prose, .chat] {
            for a in answers {
                #expect(CleanupOutputGuard.sanitize(candidate: a.candidate, original: a.original, mode: mode) == nil)
            }
        }
    }

    @Test("unspaced scripts compare characters, so added punctuation and dropped fillers pass")
    func unspacedScripts() {
        let cases: [(candidate: String, original: String)] = [
            ("我今天去商店买了很多东西，然后回家了。", "我今天去商店买了很多东西然后回家了"),
            ("今日はいい天気ですね。でも明日は雨が降るらしいです。", "今日はいい天気ですねでも明日は雨が降るらしいです"),
            ("วันนี้อากาศดีมาก แต่พรุ่งนี้ฝนจะตก", "วันนี้อากาศดีมากแต่พรุ่งนี้ฝนจะตก"),
            ("我觉得这个方案很好，我们明天开始吧。", "嗯我觉得那个这个方案很好我们明天开始吧"),
            ("明日の会議は三時からです。よろしくお願いします。", "えーと明日の会議は三時からですよろしくお願いします"),
        ]
        for c in cases {
            #expect(CleanupOutputGuard.sanitize(candidate: c.candidate, original: c.original, mode: .prose) == c.candidate)
        }
        #expect(CleanupOutputGuard.sanitize(candidate: "法国的首都是巴黎。", original: "你能告诉我法国的首都是什么吗", mode: .prose) == nil)
        #expect(CleanupOutputGuard.sanitize(
            candidate: "我今天去商店买了很多东西，然后回家了。还有什么我可以帮你的吗？",
            original: "我今天去商店买了很多东西然后回家了", mode: .prose
        ) == nil)
    }

    @Test("unwrapping skips reasoning and prefers the last complete block")
    func unwrapTags() {
        #expect(CleanupOutputGuard.unwrapTags(
            "<think>The user wants me to wrap output in <cleaned> tags.</think>\n<cleaned>So I was thinking.</cleaned>"
        ) == "So I was thinking.")
        #expect(CleanupOutputGuard.unwrapTags("So I was thinking.</cleaned>") == "So I was thinking.")
        #expect(CleanupOutputGuard.unwrapTags("reasoning about <cleaned></think><cleaned>Hello.</cleaned>") == "Hello.")
        #expect(CleanupOutputGuard.unwrapTags("<think>reasoning about <cleaned> tags") == "")
        #expect(CleanupOutputGuard.unwrapTags("<cleaned>draft</cleaned> <cleaned>Final.</cleaned>") == "Final.")
        #expect(CleanupOutputGuard.unwrapTags("<cleaned>Hello there") == "Hello there")
    }

    @Test("leftover protocol tags are rejected")
    func rejectsLeakedTags() {
        #expect(CleanupOutputGuard.sanitize(candidate: "Hello </cleaned> world", original: "hello world", mode: .prose) == nil)
        #expect(CleanupOutputGuard.sanitize(candidate: "<think>hmm</think> Hello world", original: "hello world", mode: .prose) == nil)
    }
}
