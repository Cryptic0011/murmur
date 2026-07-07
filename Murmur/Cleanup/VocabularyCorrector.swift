import Foundation

/// Fuzzy-corrects transcript words against the user's dictionary terms, so
/// "murmer" becomes "Murmur" without needing an explicit replacement rule.
enum VocabularyCorrector {
    /// Replaces tokens that are within edit distance 1 of a single-word
    /// vocabulary term (and share its first letter) with the exact term.
    /// Deliberately conservative: short words and multi-word terms are left
    /// to the LLM glossary and replacement rules.
    static func apply(_ vocabulary: [String], to text: String) -> String {
        let terms = vocabulary.filter { $0.count >= 4 && !$0.contains(" ") }
        guard !terms.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var token = ""

        func flush() {
            guard !token.isEmpty else { return }
            result += correction(for: token, in: terms) ?? token
            token = ""
        }

        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" {
                token.append(ch)
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return result
    }

    private static func correction(for token: String, in terms: [String]) -> String? {
        guard token.count >= 4 else { return nil }
        let lowerToken = token.lowercased()
        for term in terms {
            let lowerTerm = term.lowercased()
            if lowerToken == lowerTerm {
                // Same word, possibly wrong casing — enforce the dictionary spelling.
                return token == term ? nil : term
            }
            // Distance-1 matching on 4-letter words corrects real English
            // words ("grow" → "Groq"); require 5+ letters for fuzzy matches.
            guard term.count >= 5, token.count >= 5,
                  abs(term.count - token.count) <= 1,
                  lowerToken.first == lowerTerm.first,
                  editDistanceIsAtMostOne(lowerToken, lowerTerm)
            else { continue }
            return term
        }
        return nil
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
