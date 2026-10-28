import Foundation

enum CleanupOutputGuard {
    static func unwrapTags(_ text: String) -> String {
        // Reasoning models emit <think>…</think> before the answer, and that reasoning often
        // mentions our tags; drop it before looking for the cleaned block.
        var result = text.replacingOccurrences(of: #"(?is)<think>.*?</think>"#, with: "", options: .regularExpression)
        if let close = result.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            result = String(result[close.upperBound...]) // reasoning opened before our output
        }
        if let open = result.range(of: "<think>", options: .caseInsensitive) {
            result = String(result[..<open.lowerBound]) // unterminated reasoning: nothing after it is an answer
        }

        // Prefer the last complete <cleaned>…</cleaned> block. With the assistant prefill the
        // opening tag is ours, so the reply may be just "text</cleaned>".
        let close = result.range(of: "</cleaned>", options: [.caseInsensitive, .backwards])
        let open = result.range(
            of: "<cleaned>", options: [.caseInsensitive, .backwards],
            range: result.startIndex..<(close?.lowerBound ?? result.endIndex)
        )
        if let open, let close {
            result = String(result[open.upperBound..<close.lowerBound])
        } else if let open {
            result = String(result[open.upperBound...])
        } else if let firstClose = result.range(of: "</cleaned>", options: .caseInsensitive) {
            result = String(result[..<firstClose.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the candidate when it reads as a cleanup of `original`, or nil when the model
    /// answered, obeyed, summarized, or embellished the dictation instead.
    static func sanitize(candidate: String, original: String, mode: CleanupMode, vocabulary: [String] = []) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return nil }
        guard !leaksProtocolTags(trimmed, original: originalTrimmed) else { return nil }
        guard !looksLikeAssistantReply(trimmed, original: originalTrimmed, mode: mode) else { return nil }
        guard !isOverExpanded(candidate: trimmed, relativeTo: originalTrimmed, mode: mode) else { return nil }
        let keeps = mode == .code
            ? codeKeepsContent(candidate: trimmed, original: originalTrimmed)
            : keepsContent(candidate: trimmed, original: originalTrimmed, mode: mode, vocabulary: vocabulary)
        guard keeps else { return nil }
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

    private static func leaksProtocolTags(_ text: String, original: String) -> Bool {
        let lower = text.lowercased()
        let source = original.lowercased()
        return ["<think", "</think", "<cleaned", "</cleaned", "<transcript", "</transcript", "<context", "</context"]
            .contains { lower.contains($0) && !source.contains($0) }
    }

    private static func looksLikeAssistantReply(_ text: String, original: String, mode: CleanupMode) -> Bool {
        let lower = normalizePunctuation(text).lowercased()
        // The model is told to drop leading fillers, so "um sure…" legitimately becomes "Sure…".
        let spokenStart = droppingLeadingDiscourse(normalizePunctuation(original).lowercased())
        let source = normalizePunctuation(original).lowercased()
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
            "here is the cleaned text",
        ]
        if bannedPrefixes.contains(where: { startsWithPhrase(lower, $0) && !startsWithPhrase(spokenStart, $0) }) {
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
        if bannedPhrases.contains(where: { lower.contains($0) && !source.contains($0) }) {
            return true
        }

        if mode == .code {
            return lower.contains("```")
        }

        return false
    }

    private static func startsWithPhrase(_ text: String, _ phrase: String) -> Bool {
        guard text.hasPrefix(phrase) else { return false }
        guard let next = text.dropFirst(phrase.count).first else { return true }
        return !next.isLetter
    }

    private static func droppingLeadingDiscourse(_ text: String) -> String {
        var rest = Substring(text)
        while true {
            rest = rest.drop(while: { $0.isWhitespace || $0.isPunctuation })
            let word = rest.prefix(while: { $0.isLetter })
            guard !word.isEmpty, leadingDiscourse.contains(String(word)) else { return String(rest) }
            rest = rest.dropFirst(word.count)
        }
    }

    private static func isOverExpanded(candidate: String, relativeTo original: String, mode: CleanupMode) -> Bool {
        // Unspaced scripts have no whitespace words to count, so compare letters there.
        let size: (String) -> Int = isMostlyUnspaced(original)
            ? { $0.filter(\.isLetter).count }
            : { $0.split(whereSeparator: \.isWhitespace).count }
        let originalWords = max(size(original), 1)
        let candidateWords = size(candidate)

        if mode == .code {
            return candidateWords > originalWords * 2
        }

        return candidateWords > originalWords * 3
    }

    // MARK: - Content checks

    private static let stopwords: Set<String> = [
        "the","a","an","is","are","was","were","be","been","being",
        "to","of","in","on","at","for","with","by","from","as","into","about",
        "and","or","but","if","so","than","then","because",
        "i","you","we","they","he","she","it","me","us","them","him","her",
        "my","your","our","their","his","its",
        "this","that","these","those","there","here",
        "do","does","did","done","doing",
        "have","has","had","having",
        "will","would","can","could","should","may","might","must",
        "not","no","yes","just","really","very","also",
    ]

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "mhm"]
    private static let leadingDiscourse: Set<String> = fillers.union(["so", "well", "okay", "ok", "yeah", "oh", "like", "and", "alright"])
    private static let interrogatives: Set<String> = ["what", "why", "how", "when", "where", "who", "whom", "whose", "which"]
    /// Spoken commands and spelled-out symbols a correct cleanup turns into punctuation.
    private static let commandWords: Set<String> = [
        "comma", "period", "colon", "semicolon", "question", "mark", "exclamation", "point",
        "new", "line", "paragraph", "percent", "dot", "scratch", "bullet", "checkbox", "heading", "title",
    ]
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
        "million", "first", "second", "third", "fourth", "fifth", "half", "quarter",
    ]
    /// Matches through the last spoken correction in lowercased text.
    private static let throughLastCorrection = #"(?s)^.*\b(?:scratch that|no wait|wait no|oh wait|never mind|nevermind|or rather|i mean)\b"#
    /// The word after an opening interrogative that makes it a question ("what is…", "what time…").
    private static let questionFollowers: Set<String> = [
        "is", "are", "was", "were", "do", "does", "did", "can", "could", "should", "would", "will",
        "time", "about", "much", "many", "long", "often",
    ]
    /// The word after an opening interrogative that makes it a statement ("what we discussed…").
    private static let subjectPronouns: Set<String> = ["i", "we", "you", "they", "he", "she", "it"]

    private static func keepsContent(candidate: String, original: String, mode: CleanupMode, vocabulary: [String]) -> Bool {
        let lowerOriginal = original.lowercased()
        // A spoken correction ("scratch that") legitimately deletes what came before it, so only
        // what follows the last one has to survive as a question.
        let lastCorrection = lowerOriginal.range(of: throughLastCorrection, options: .regularExpression)
        let corrected = lastCorrection != nil
        let tail = lastCorrection.map { String(lowerOriginal[$0.upperBound...]) } ?? lowerOriginal
        // A marker with nothing after it replaces nothing: "What's the capital of France? Never mind." still asks.
        let asked = contentTokens(words(tail)).count >= 2 ? tail : lowerOriginal

        // Questions stay questions: STT engines punctuate them, so a "?" that vanishes means the model answered.
        let isQuestionMark: (Character) -> Bool = { $0 == "?" || $0 == "\u{FF1F}" } // ？ in CJK text
        if asked.contains(where: isQuestionMark) && !candidate.contains(where: isQuestionMark) { return false }
        // A question corrected into a statement ("…of France? I mean, of Germany.") must not grow an answer.
        let retractedQuestion = !asked.contains(where: isQuestionMark) && lowerOriginal.contains(where: isQuestionMark)

        let (minRecall, maxNovelty, lengthFloor): (Double, Double, Double)
        switch mode {
        case .light, .prompt: (minRecall, maxNovelty, lengthFloor) = (0.8, 0.25, 0.7)
        case .prose, .chat, .code: (minRecall, maxNovelty, lengthFloor) = (0.6, 0.3, 0.5)
        case .email, .notes: (minRecall, maxNovelty, lengthFloor) = (0.5, 0.4, 0.5)
        }

        if isMostlyUnspaced(original) {
            // Characters keep far more of a cleanup than content words do (no stopwords to drop).
            return unspacedKeepsContent(
                candidate: candidate, original: original,
                minRecall: corrected ? 0.4 : max(minRecall, 0.75), maxNovelty: maxNovelty
            )
        }

        let originalWords = words(original)
        let candidateWords = words(candidate)
        let originalSet = Set(originalWords)
        let candidateSet = Set(candidateWords)

        // An opening interrogative is the question itself; a cleanup never drops it. "What we
        // discussed…" is a statement, though, which email and notes may restructure.
        let askedWords = words(asked)
        if let leadIndex = askedWords.firstIndex(where: { !fillers.contains($0) }),
           interrogatives.contains(askedWords[leadIndex]), !candidateSet.contains(askedWords[leadIndex]) {
            let next = askedWords.dropFirst(leadIndex + 1).first ?? ""
            let firstStop = asked.first(where: { ".!?".contains($0) })
            let asks = firstStop == "?" || (firstStop == nil && askedWords.count <= 12) || questionFollowers.contains(next)
            if asks && !subjectPronouns.contains(next) { return false }
        }

        // Length floor: a cleanup drops fillers, not half the dictation. A spoken correction
        // legitimately deletes the phrase before it.
        let spokenWords = originalWords.filter { !fillers.contains($0) && !commandWords.contains($0) }.count
        if Double(candidateWords.count) < Double(spokenWords) * (corrected ? 0.25 : lengthFloor) { return false }

        let vocab = Set(vocabulary.flatMap { words($0) })
        let originalHasNumbers = originalWords.contains(where: isNumeric)
        let candidateHasNumbers = candidateWords.contains(where: isNumeric)

        // Novelty: content the model added. Answers bring their own nouns ("Paris", "3rd century").
        let candidateTokens = contentTokens(candidateWords)
        let novel = candidateTokens.filter { token in
            if vocab.contains(token) { return false }
            if isNumeric(token) { return !originalHasNumbers } // "twenty five" → "25"
            return !matches(token, in: originalSet)
        }
        // One new word is a homophone fix ("their" → "they're"); recall and the checks above catch one-word answers.
        if novel.count >= 2, Double(novel.count) / Double(candidateTokens.count) > maxNovelty { return false }
        if retractedQuestion && !novel.isEmpty { return false } // "The capital of Germany is Berlin."

        // Recall: how much of what was said survives.
        let recallable = contentTokens(originalWords).filter { !commandWords.contains($0) }
        guard recallable.count >= 3 else {
            // Too little content to measure recall; at least don't let a two-word dictation grow a paragraph.
            return candidateWords.count <= originalWords.count + 3
        }
        let kept = recallable.filter { token in
            isNumeric(token) ? candidateHasNumbers || candidateSet.contains(token) : matches(token, in: candidateSet)
        }
        return Double(kept.count) / Double(recallable.count) >= (corrected ? min(minRecall, 0.4) : minRecall)
    }

    /// Code mode reshapes words into identifiers ("get user name" → getUserName), so test each
    /// dictated word as a substring of the output instead of as a token.
    private static func codeKeepsContent(candidate: String, original: String) -> Bool {
        let haystack = candidate.lowercased()
        let tokens = original.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && !spokenSymbols.contains($0) }
        guard tokens.count >= 2 else { return true }
        let kept = tokens.filter { token in
            haystack.contains(token) || digitForms[token].map { haystack.contains($0) } == true
        }
        return Double(kept.count) / Double(tokens.count) >= 0.6
    }

    private static let spokenSymbols: Set<String> = [
        "dot", "dash", "hyphen", "slash", "backslash", "equals", "equal", "plus", "minus", "star", "asterisk",
        "paren", "parens", "parenthesis", "bracket", "brackets", "brace", "braces", "curly", "open", "close",
        "underscore", "colon", "semicolon", "comma", "quote", "quotes", "backtick", "tick", "pipe", "ampersand",
        "hash", "pound", "dollar", "percent", "caret", "tilde", "at", "sign", "greater", "less", "than", "arrow",
        "period", "question", "exclamation", "mark", "point", "bang", "angle", "new", "line", "space", "tab",
        "double", "single", "um", "uh",
        // Spoken casing and operator words a correct conversion also drops ("all caps max retries" → MAX_RETRIES).
        "left", "right", "lparen", "rparen", "camel", "snake", "pascal", "kebab", "case", "all", "caps", "upper",
        "uppercase", "lower", "lowercase", "constant", "and", "or", "not", "to", "divided", "by", "times", "mod",
        "modulo", "triple", "fat",
    ]
    private static let digitForms: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    private static func words(_ text: String) -> [String] {
        normalizePunctuation(text).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Chinese, Japanese, and Thai put no spaces between words.
    private static func isMostlyUnspaced(_ text: String) -> Bool {
        // ponytail: Han, kana, and Thai only; Lao, Khmer, and Myanmar fall back to word checks.
        let letters = text.unicodeScalars.filter(\.properties.isAlphabetic)
        let unspaced = letters.filter {
            $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) || (0x0E00...0x0E7F).contains($0.value)
        }
        return unspaced.count * 2 > letters.count
    }

    /// In an unspaced script a whole clause reads as one "word", so an added comma or a dropped
    /// filler would make it novel. Compare characters instead: how many of the original's survive
    /// in order (longest common subsequence), and how many the candidate adds.
    private static func unspacedKeepsContent(candidate: String, original: String, minRecall: Double, maxNovelty: Double) -> Bool {
        let letters: (String) -> [UInt32] = { text in
            text.lowercased().unicodeScalars
                .filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                .map(\.value)
        }
        let source = letters(original)
        let output = letters(candidate)
        guard !source.isEmpty, !output.isEmpty else { return false }
        var row = [Int](repeating: 0, count: output.count + 1)
        for scalar in source {
            var diagonal = 0
            for index in output.indices {
                let above = row[index + 1]
                row[index + 1] = scalar == output[index] ? diagonal + 1 : max(above, row[index])
                diagonal = above
            }
        }
        let common = Double(row[output.count])
        return common / Double(source.count) >= minRecall
            && (Double(output.count) - common) / Double(output.count) <= maxNovelty
    }

    private static func contentTokens(_ words: [String]) -> Set<String> {
        Set(words.filter { ($0.count > 2 && !stopwords.contains($0)) || $0.contains(where: \.isNumber) })
    }

    private static func isNumeric(_ token: String) -> Bool {
        token.contains(where: \.isNumber) || numberWords.contains(token)
    }

    /// Exact, or the same word give or take a suffix or one typo ("estimate"/"estimates", "murmer"/"murmur").
    private static func matches(_ token: String, in pool: Set<String>) -> Bool {
        if pool.contains(token) { return true }
        guard token.count >= 4 else { return false }
        return pool.contains { other in
            guard other.count >= 4 else { return false }
            let (short, long) = other.count < token.count ? (other, token) : (token, other)
            return (long.hasPrefix(short) && long.count - short.count <= 3)
                || VocabularyCorrector.editDistanceIsAtMostOne(token, other)
        }
    }
}
