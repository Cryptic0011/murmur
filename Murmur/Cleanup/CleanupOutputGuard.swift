import Foundation

enum CleanupOutputGuard {
    static func unwrapTags(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let openRange = result.range(of: "<cleaned>", options: .caseInsensitive) {
            result = String(result[openRange.upperBound...])
        }
        if let closeRange = result.range(of: "</cleaned>", options: .caseInsensitive) {
            result = String(result[..<closeRange.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitize(candidate: String, original: String, mode: CleanupMode) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return nil }
        guard !looksLikeAssistantReply(trimmed, mode: mode) else { return nil }
        guard !isOverExpanded(candidate: trimmed, relativeTo: originalTrimmed, mode: mode) else { return nil }
        guard sharesContent(candidate: trimmed, original: originalTrimmed, mode: mode) else { return nil }
        return normalizePunctuation(trimmed)
    }

    static func normalizePunctuation(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("\u{2018}", "'"),   // ‘
            ("\u{2019}", "'"),   // ’
            ("\u{201A}", "'"),   // ‚
            ("\u{201B}", "'"),   // ‛
            ("\u{201C}", "\""),  // “
            ("\u{201D}", "\""),  // ”
            ("\u{201E}", "\""),  // „
            ("\u{201F}", "\""),  // ‟
            ("\u{2013}", "-"),   // – en dash
            ("\u{2014}", "-"),   // — em dash
            ("\u{2026}", "..."), // …
            ("\u{00A0}", " "),   // non-breaking space
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    private static func looksLikeAssistantReply(_ text: String, mode: CleanupMode) -> Bool {
        let lower = text.lowercased()
        let bannedPrefixes = [
            "sure",
            "here's",
            "here is",
            "certainly",
            "absolutely",
            "of course",
            "i can help",
            "i'd be happy",
            "the cleaned text is",
            "cleaned text:",
            "revised text:",
            "here’s the cleaned text",
            "here is the cleaned text",
        ]
        if bannedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let bannedPhrases = [
            "let me know",
            "if you'd like",
            "if you want",
            "i hope this helps",
            "as an ai",
            "i cleaned up",
            "i've cleaned up",
            "explanation:",
        ]
        if bannedPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        if mode == .code {
            return lower.contains("```")
        }

        return false
    }

    private static func isOverExpanded(candidate: String, relativeTo original: String, mode: CleanupMode) -> Bool {
        let originalWords = max(original.split(whereSeparator: \.isWhitespace).count, 1)
        let candidateWords = candidate.split(whereSeparator: \.isWhitespace).count

        if mode == .code {
            return candidateWords > originalWords * 2
        }

        return candidateWords > originalWords * 3
    }

    private static let stopwords: Set<String> = [
        "the","a","an","is","are","was","were","be","been","being",
        "to","of","in","on","at","for","with","by","from","as","into","about",
        "and","or","but","if","so","than","then","because",
        "i","you","we","they","he","she","it","me","us","them","him","her",
        "my","your","our","their","his","its",
        "this","that","these","those",
        "do","does","did","done","doing",
        "have","has","had","having",
        "will","would","can","could","should","may","might","must",
        "not","no","yes",
    ]

    private static func contentTokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let split = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var tokens: Set<String> = []
        for slice in split {
            let token = String(slice)
            guard token.count > 2, !stopwords.contains(token) else { continue }
            tokens.insert(token)
        }
        return tokens
    }

    private static func sharesContent(candidate: String, original: String, mode: CleanupMode) -> Bool {
        if mode == .code { return true }

        let originalTokens = contentTokens(original)
        guard originalTokens.count >= 3 else { return true }

        let candidateTokens = contentTokens(candidate)
        let overlap = originalTokens.intersection(candidateTokens).count
        let ratio = Double(overlap) / Double(originalTokens.count)
        return ratio >= 0.5
    }
}
