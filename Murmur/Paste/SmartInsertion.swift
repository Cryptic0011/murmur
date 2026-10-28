import Foundation

/// Fits dictated text onto what's already before the caret: a separating space
/// after a word, no double space, a capital at a sentence or field start, and a
/// lowercase function word when dictating into the middle of a sentence.
enum SmartInsertion {
    static func adjust(_ text: String, before: String?) -> String {
        guard let before else { return text }
        var result = Substring(text)
        if let last = before.last, last == " " || last == "\t" {
            result = result.drop { $0 == " " || $0 == "\t" }
        }
        guard let first = result.first else { return text }

        let previous = before.last { !$0.isWhitespace }
        let trailingWhitespace = before.reversed().prefix { $0.isWhitespace }
        // `Stop."` and `(See above.)` end a sentence too: look past closers.
        let sentenceEnd = before.reversed().first { !$0.isWhitespace && !closers.contains($0) }
        let startsSentence = sentenceEnd.map { sentenceTerminators.contains($0) } ?? true
            || trailingWhitespace.contains { $0.isNewline }

        let word = result.prefix { $0.isLetter }
        if let initial = word.first {
            let rest = word.dropFirst()
            if startsSentence {
                // "iPhone", "eBay": leave mixed-case words alone.
                if word.allSatisfy(\.isLowercase) {
                    result = Substring(initial.uppercased()) + result.dropFirst()
                }
            } else if let previous, previous.isLowercase || previous == ",",
                      initial.isUppercase, rest.allSatisfy(\.isLowercase),
                      functionWords.contains(word.lowercased()) {
                result = Substring(initial.lowercased()) + result.dropFirst()
            }
        }

        if let last = before.last, !last.isWhitespace,
           startsWord(first),
           joinsWithSpace(last, after: before.dropLast().last),
           !isUnspacedScript(last), !isUnspacedScript(first) {
            return " " + String(result)
        }
        return String(result)
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "”", "’", "»"]

    /// Dictated text that opens a new word: "$300", "(see", "“Hello”", an emoji.
    /// Not the straight apostrophe, so "John" + "'s" stays joined.
    private static func startsWord(_ first: Character) -> Bool {
        if first.isLetter || first.isNumber || "([{\"“«‘".contains(first) { return true }
        guard let scalar = first.unicodeScalars.first else { return false }
        return scalar.properties.generalCategory == .currencySymbol || scalar.properties.isEmojiPresentation
    }

    // ponytail: a fixed list of short function words is the only lowercasing —
    // names, acronyms and "I" keep the cleanup's capitalization; extend the list
    // rather than guessing at proper nouns.
    private static let functionWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "to", "of", "in", "on", "at", "by",
        "for", "with", "from", "as", "if", "then", "than", "that", "this", "which",
        "who", "when", "while", "because", "is", "are", "was", "were", "it", "we",
        "you", "they", "he", "she", "not", "my", "your", "our", "their",
    ]

    /// A word, clause/sentence punctuation or a closing bracket wants a space
    /// before the next word; an opening bracket, "@", "#", "/" or "-" doesn't.
    private static func joinsWithSpace(_ last: Character, after previous: Character?) -> Bool {
        if last.isLetter || last.isNumber { return true }
        if ".,;:!?…)]}”’»%".contains(last) { return true }
        // A straight quote right after text closes it; after a space it opens.
        if last == "\"" || last == "'" { return previous.map { !$0.isWhitespace } ?? false }
        return false
    }

    // ponytail: CJK and Thai are the scripts written without spaces between words.
    private static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isIdeographic
            || (0x3040...0x30FF).contains(scalar.value) // Hiragana, Katakana
            || (0x0E00...0x0E7F).contains(scalar.value) // Thai
    }
}
