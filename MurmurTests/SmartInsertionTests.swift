import Testing
@testable import Murmur

@Suite("SmartInsertion")
struct SmartInsertionTests {
    @Test("unreadable caret context leaves the text alone")
    func unreadable() {
        #expect(SmartInsertion.adjust("hello there.", before: nil) == "hello there.")
    }

    @Test("field start capitalizes")
    func fieldStart() {
        #expect(SmartInsertion.adjust("hello there.", before: "") == "Hello there.")
        #expect(SmartInsertion.adjust("hello there.", before: "  ") == "Hello there.")
    }

    @Test("after a word: leading space, capitalization kept")
    func afterWord() {
        #expect(SmartInsertion.adjust("World is big.", before: "Hello") == " World is big.")
    }

    @Test("after a sentence end: space and capital")
    func afterSentence() {
        #expect(SmartInsertion.adjust("next one.", before: "Done.") == " Next one.")
        #expect(SmartInsertion.adjust("next one.", before: "Done? ") == "Next one.")
    }

    @Test("no double space")
    func noDoubleSpace() {
        #expect(SmartInsertion.adjust(" world", before: "Hello ") == "world")
        #expect(SmartInsertion.adjust("And more.", before: "Hello, ") == "and more.")
    }

    @Test("mid-sentence function word is lowercased")
    func midSentenceLowercase() {
        #expect(SmartInsertion.adjust("The milk was gone.", before: "I went to the store and") == " the milk was gone.")
        #expect(SmartInsertion.adjust("We left early.", before: "Yesterday,") == " we left early.")
    }

    @Test("names, acronyms and I keep their capitals")
    func keepsProperCapitals() {
        #expect(SmartInsertion.adjust("John said hi.", before: "and then") == " John said hi.")
        #expect(SmartInsertion.adjust("I left.", before: "and then") == " I left.")
        #expect(SmartInsertion.adjust("THE END", before: "and then") == " THE END")
        #expect(SmartInsertion.adjust("iPhone rocks.", before: "") == "iPhone rocks.")
    }

    @Test("a line break starts a new sentence")
    func afterNewline() {
        #expect(SmartInsertion.adjust("the plan is set.", before: "Dear John,\n") == "The plan is set.")
    }

    @Test("no space after an opening bracket, quote or mention")
    func openers() {
        #expect(SmartInsertion.adjust("see below", before: "(") == "see below")
        #expect(SmartInsertion.adjust("Hello", before: "He said \"") == "Hello")
        #expect(SmartInsertion.adjust("john", before: "@") == "john")
    }

    @Test("space after a closing quote or bracket")
    func closers() {
        #expect(SmartInsertion.adjust("and left", before: "\"Hello\"") == " and left")
        #expect(SmartInsertion.adjust("and left", before: "(twice)") == " and left")
    }

    @Test("currency, quotes and brackets open a word; closers don't hide a sentence end")
    func wordOpenersAndClosedSentences() {
        #expect(SmartInsertion.adjust("$300 for the roof.", before: "Total") == " $300 for the roof.")
        #expect(SmartInsertion.adjust("\"Hello\"", before: "He said") == " \"Hello\"")
        #expect(SmartInsertion.adjust("then he left", before: "He said \"Stop.\"") == " Then he left")
        #expect(SmartInsertion.adjust("then", before: "(See above.)") == " Then")
        #expect(SmartInsertion.adjust("'s car", before: "John") == "'s car")
    }

    @Test("punctuation-led text attaches directly")
    func punctuationFirst() {
        #expect(SmartInsertion.adjust(", and then", before: "word") == ", and then")
    }

    @Test("CJK and Thai join without spaces")
    func unspacedScripts() {
        #expect(SmartInsertion.adjust("世界", before: "你好") == "世界")
        #expect(SmartInsertion.adjust("hello", before: "你好") == "hello")
    }
}
