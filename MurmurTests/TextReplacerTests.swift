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
}
