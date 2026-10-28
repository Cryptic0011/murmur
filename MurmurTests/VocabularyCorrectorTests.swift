import Testing
@testable import Murmur

@Suite("VocabularyCorrector")
struct VocabularyCorrectorTests {
    let vocabulary = ["Murmur", "WhisperKit", "Groq"]
    /// Deterministic stand-in for the system spell checker.
    private static let knownWords: Set<String> = ["clause", "will", "mark", "murmur", "murmurs", "jenny", "member"]

    private func apply(_ vocabulary: [String], to text: String) -> String {
        VocabularyCorrector.apply(vocabulary, to: text, isDictionaryWord: { Self.knownWords.contains($0) })
    }

    @Test("one-letter misspelling is corrected")
    func nearMiss() {
        #expect(apply(vocabulary, to: "open murmer settings")
                == "open Murmur settings")
        #expect(apply(vocabulary, to: "using whisperkid locally")
                == "using WhisperKit locally")
    }

    @Test("casing is enforced for distinctive or non-dictionary terms only")
    func casing() {
        #expect(apply(vocabulary, to: "whisperkit is running") == "WhisperKit is running")
        #expect(apply(vocabulary, to: "groq is fast") == "Groq is fast")
        // "murmur" is an ordinary word; a plain Title-case term doesn't override it.
        #expect(apply(vocabulary, to: "murmur is running") == "murmur is running")
        #expect(apply(["Will", "Mark"], to: "I will mark it done") == "I will mark it done")
    }

    @Test("an exact match wins over an earlier fuzzy match")
    func exactBeatsFuzzy() {
        #expect(VocabularyCorrector.apply(["Jenna", "Jenny"], to: "jenny said hi", isDictionaryWord: { _ in false })
                == "Jenny said hi")
    }

    @Test("real words and ambiguous near-misses are not fuzzy-corrected")
    func realWordsAndAmbiguity() {
        #expect(apply(["Claude"], to: "this clause in the contract") == "this clause in the contract")
        #expect(apply(["Murmur"], to: "murmurs are great") == "murmurs are great")
        #expect(VocabularyCorrector.apply(["Jenna", "Jenni"], to: "jennx said hi", isDictionaryWord: { _ in false })
                == "jennx said hi")
    }

    @Test("unrelated and distant words are untouched")
    func noFalsePositives() {
        // "member" is distance 2 from "murmur"; "Grayson" shares no term.
        let text = "the member Grayson murmured softly"
        #expect(apply(vocabulary, to: text) == text)
    }

    @Test("short terms and multi-word terms are skipped")
    func skipsRiskyTerms() {
        #expect(apply(["Groq"], to: "the grow lamp") == "the grow lamp")
        #expect(apply(["Claude Code"], to: "claude cod") == "claude cod")
    }

    @Test("punctuation and boundaries are preserved")
    func punctuation() {
        #expect(apply(vocabulary, to: "Is murmer, running?")
                == "Is Murmur, running?")
    }

    @Test("edit distance helper")
    func editDistance() {
        #expect(VocabularyCorrector.editDistanceIsAtMostOne("murmur", "murmer"))
        #expect(VocabularyCorrector.editDistanceIsAtMostOne("murmur", "murmu"))
        #expect(VocabularyCorrector.editDistanceIsAtMostOne("murmur", "murmurs"))
        #expect(!VocabularyCorrector.editDistanceIsAtMostOne("murmur", "member"))
        #expect(!VocabularyCorrector.editDistanceIsAtMostOne("murmur", "murm"))
    }
}
