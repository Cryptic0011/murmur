import AppKit

/// Fuzzy-corrects transcript words against the user's dictionary terms, so
/// "murmer" becomes "Murmur" without needing an explicit replacement rule.
enum VocabularyCorrector {
    /// Replaces tokens that are within edit distance 1 of a single-word
    /// vocabulary term (and share its first letter) with the exact term.
    /// Deliberately conservative: short words and multi-word terms are left
    /// to the LLM glossary and replacement rules, and real words are never
    /// fuzzy-corrected ("clause" stays "clause" next to "Claude").
    /// - Parameter isDictionaryWord: whether a lowercased token is an ordinary word.
    static func apply(
        _ vocabulary: [String],
        to text: String,
        isDictionaryWord: (String) -> Bool = VocabularyCorrector.isSystemDictionaryWord
    ) -> String {
        let terms = vocabulary.filter { $0.count >= 4 && !$0.contains(" ") }.map(Term.init)
        guard !terms.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var token = ""

        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" {
                token.append(ch)
            } else {
                result += correction(for: token, in: terms, isDictionaryWord: isDictionaryWord) ?? token
                token = ""
                result.append(ch)
            }
        }
        result += correction(for: token, in: terms, isDictionaryWord: isDictionaryWord) ?? token
        return result
    }

    /// The system spell checker's verdict. Main-thread callers only (the dictation pipeline is @MainActor).
    static func isSystemDictionaryWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    private struct Term {
        let spelling: String
        let lower: String
        let length: Int
        /// Internal capitals or digits (iOS, GitHub, H264) mark a deliberate spelling worth
        /// enforcing even where the word is also ordinary English.
        let isDistinctive: Bool

        init(_ spelling: String) {
            self.spelling = spelling
            lower = spelling.lowercased()
            length = spelling.count
            isDistinctive = spelling.dropFirst().contains(where: \.isUppercase) || spelling.contains(where: \.isNumber)
        }
    }

    private static func correction(for token: String, in terms: [Term], isDictionaryWord: (String) -> Bool) -> String? {
        guard token.count >= 4 else { return nil }
        let lowerToken = token.lowercased()

        // An exact (case-insensitive) match wins over any fuzzy one, wherever it sits in the list.
        if let exact = terms.first(where: { $0.lower == lowerToken }) {
            guard token != exact.spelling else { return nil }
            // Plain Title-case terms that are also real words ("Will", "Mark", "Swift") keep the speaker's casing.
            if !exact.isDistinctive && isDictionaryWord(lowerToken) { return nil }
            return exact.spelling
        }

        // Distance-1 matching on 4-letter words corrects real English
        // words ("grow" → "Groq"); require 5+ letters for fuzzy matches.
        guard token.count >= 5 else { return nil }
        let candidates = terms.filter { term in
            term.length >= 5
                && abs(term.length - token.count) <= 1
                && term.lower.first == lowerToken.first
                && editDistanceIsAtMostOne(lowerToken, term.lower)
        }
        // Ambiguous (near two different terms) or a real word ("murmurs", "clause"): leave it.
        guard let match = candidates.first,
              Set(candidates.map(\.lower)).count == 1,
              !isDictionaryWord(lowerToken)
        else { return nil }
        return match.spelling
    }

    /// True when the strings differ by at most one substitution, insertion, or deletion.
    static func editDistanceIsAtMostOne(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count == y.count { i += 1; j += 1 }        // substitution
            else if x.count > y.count { i += 1 }            // deletion from a
            else { j += 1 }                                 // insertion into a
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }
}
