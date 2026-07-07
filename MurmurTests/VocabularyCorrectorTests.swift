import Testing
@testable import Murmur

@Suite("VocabularyCorrector")
struct VocabularyCorrectorTests {
    let vocabulary = ["Murmur", "WhisperKit", "Groq"]

    @Test("one-letter misspelling is corrected")
    func nearMiss() {
        #expect(VocabularyCorrector.apply(vocabulary, to: "open murmer settings")
                == "open Murmur settings")
        #expect(VocabularyCorrector.apply(vocabulary, to: "using whisperkid locally")
                == "using WhisperKit locally")
    }

    @Test("casing is normalized to the dictionary spelling")
    func casing() {
        #expect(VocabularyCorrector.apply(vocabulary, to: "murmur is running") == "Murmur is running")
    }

    @Test("unrelated and distant words are untouched")
    func noFalsePositives() {
        // "member" is distance 2 from "murmur"; "Grayson" shares no term.
        let text = "the member Grayson murmured softly"
        #expect(VocabularyCorrector.apply(vocabulary, to: text) == text)
    }

    @Test("short terms and multi-word terms are skipped")
    func skipsRiskyTerms() {
        #expect(VocabularyCorrector.apply(["Groq"], to: "the grow lamp") == "the grow lamp")
        #expect(VocabularyCorrector.apply(["Claude Code"], to: "claude cod") == "claude cod")
    }

    @Test("punctuation and boundaries are preserved")
    func punctuation() {
        #expect(VocabularyCorrector.apply(vocabulary, to: "Is murmer, running?")
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
