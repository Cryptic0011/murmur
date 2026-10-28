import XCTest
@testable import Murmur

final class TextReplacerTests: XCTestCase {
    func testCaseInsensitiveWholeWordReplace() {
        let rules = [ReplacementRule(find: "murmer", replace: "Murmur")]
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "Open murmer and Murmer settings"),
            "Open Murmur and Murmur settings"
        )
    }

    func testDoesNotReplaceInsideLargerWords() {
        let rules = [ReplacementRule(find: "murmer", replace: "Murmur")]
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "murmering along"),
            "murmering along"
        )
    }

    func testDollarAndBackslashInReplacementAreLiteral() {
        let rules = [ReplacementRule(find: "five bucks", replace: "$5 \\ change")]
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "give me five bucks"),
            "give me $5 \\ change"
        )
    }

    func testEmptyFindIsIgnored() {
        let rules = [ReplacementRule(find: "  ", replace: "x")]
        XCTAssertEqual(TextReplacer.apply(rules, to: "hello"), "hello")
    }

    func testRulesApplyInOrder() {
        let rules = [
            ReplacementRule(find: "grok", replace: "Groq"),
            ReplacementRule(find: "Groq cloud", replace: "GroqCloud"),
        ]
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "use grok cloud"),
            "use GroqCloud"
        )
    }

    func testRegexMetacharactersInFindAreLiteral() {
        let rules = [ReplacementRule(find: "c++", replace: "C++")]
        // "+" is not a word character, so no trailing boundary — but the pattern
        // itself must be escaped, not treated as regex.
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "I write c++ daily"),
            "I write C++ daily"
        )
    }

    func testDotInFindDoesNotMatchArbitraryCharacters() {
        let rules = [ReplacementRule(find: "node.js", replace: "Node.js")]
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "deploy node.js now"),
            "deploy Node.js now"
        )
        // An unescaped "." would also match "nodexjs".
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "deploy nodexjs now"),
            "deploy nodexjs now"
        )
    }

    func testPunctuationAdjacentWordsReplace() {
        let rules = [ReplacementRule(find: "supa base", replace: "Supabase")]
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "Check supa base, then deploy."),
            "Check Supabase, then deploy."
        )
    }

    func testApplyingTwiceIsSafeWhenReplacementContainsFind() {
        let rules = [ReplacementRule(find: "react", replace: "React.js")]
        let once = TextReplacer.apply(rules, to: "use react today")
        XCTAssertEqual(once, "use React.js today")
        XCTAssertEqual(TextReplacer.apply(rules, to: once), once)
        // An existing any-case occurrence is normalized, not nested.
        XCTAssertEqual(TextReplacer.apply(rules, to: "use react.js today"), "use React.js today")

        let app = [ReplacementRule(find: "app", replace: "Murmur app")]
        XCTAssertEqual(TextReplacer.apply(app, to: TextReplacer.apply(app, to: "open the app")), "open the Murmur app")
    }

    func testLowercaseReplacementFollowsSpokenCapitalization() {
        let rules = [ReplacementRule(find: "gonna", replace: "going to")]
        XCTAssertEqual(
            TextReplacer.apply(rules, to: "Gonna ship it, gonna test it"),
            "Going to ship it, going to test it"
        )
        // Sentence punctuation inside an expansion doesn't make it a literal snippet.
        let brb = [ReplacementRule(find: "brb", replace: "be right back.")]
        XCTAssertEqual(TextReplacer.apply(brb, to: "Hold on. BRB"), "Hold on. Be right back.")
        // Speech-to-text capitalizes acronyms anywhere; mid-sentence that isn't a capital.
        XCTAssertEqual(TextReplacer.apply(brb, to: "ok BRB"), "ok be right back.")
        XCTAssertEqual(
            TextReplacer.apply([ReplacementRule(find: "asap", replace: "as soon as possible")], to: "send it ASAP"),
            "send it as soon as possible"
        )
    }

    func testDeliberateCasingIsKeptVerbatim() {
        let rules = [ReplacementRule(find: "ios", replace: "iOS")]
        XCTAssertEqual(TextReplacer.apply(rules, to: "Ios and ios"), "iOS and iOS")
    }

    func testLiteralSnippetIsKeptVerbatimAtSentenceStart() {
        let rules = [ReplacementRule(find: "my email", replace: "jane.doe@example.com")]
        XCTAssertEqual(TextReplacer.apply(rules, to: "My email is below"), "jane.doe@example.com is below")
    }
}
