import Foundation

struct BuiltInCleanupProvider: CleanupProvider {
    let displayName = "Built-in rules only"
    func clean(text: String, mode: CleanupMode, context: CleanupContext) async throws -> String {
        LocalCleanup.clean(text, mode: mode)
    }
}

enum LocalCleanup {
    static let displayName = "Local cleanup"

    static func clean(_ text: String, mode: CleanupMode) -> String {
        let normalized = normalizeWhitespace(in: text)
        guard !normalized.isEmpty else { return "" }

        var result = normalized
        result = stripCorrectionPrefix(in: result, mode: mode)
        result = removeFillers(in: result, mode: mode)
        result = replaceSpokenTokens(in: result, mode: mode)
        result = normalizeCommonPatterns(in: result, mode: mode)
        // Keep "new line"/"new paragraph" breaks in every prose mode, not just notes and email.
        result = mode == .code
            ? normalizeWhitespace(in: result)
            : normalizeStructuredWhitespace(in: result)

        switch mode {
        case .prose, .light, .chat, .prompt:
            result = polishSentence(result)
        case .notes:
            result = formatMarkdownNotes(result)
        case .email:
            result = formatEmail(polishSentence(result))
        case .code:
            result = polishCode(result)
        }

        return result
    }

    private static func normalizeWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeStructuredWhitespace(in text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCorrectionPrefix(in text: String, mode: CleanupMode) -> String {
        guard mode != .code else { return text }
        // Only explicit, word-bounded correction phrases ("no waiting list" is not "no wait").
        // Bare "i mean" is common mid-sentence filler, and "never mind"/"or rather" are ordinary
        // phrases ("never mind the cost", "for rather simple designs"), so those two count only
        // after a pause (comma or period). "no wait" is also a noun phrase ("there was no wait
        // at the DMV", "no wait time"), so it doesn't count after "was"/"with"… or before "at"/"time"….
        let marker = #"\b(?:scratch that|wait no|oh wait|wait i mean)\b(?:,?\s*i mean\b)?|(?<!\b(?:was|is|be|been|had|has|have|with|there['’]?s|zero|little|almost) )\bno wait\b(?!\s+(?:time|times|list|period|at|for|in|on)\b)(?:,?\s*i mean\b)?"#
        // Stacked markers ("no wait, scratch that") are one correction. Matched one at a time, the
        // later marker looks like it opens a sentence and retracts the unrelated sentence before it.
        let pattern = #"(?i)(?:\#(marker)|[,.]\s*\b(?:never mind|or rather)\b)[,.]?\s*(?:(?:\#(marker)|\b(?:never mind|or rather)\b)[,.]?\s*)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        // Where the last sentence in `head` starts: after ".!?" and a space, never inside "9.99",
        // "github.com", or "...", nor after a title ("Dr. Kim") or a mid-sentence "p.m.". Indices are
        // shared with the string `head` was sliced from.
        // ponytail: titles, "e.g." and dotted abbreviations only; "etc.", "no.", and "Inc." end sentences as often as not.
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "mt", "ft", "vs", "e.g", "i.e"]
        let sentenceStart: (Substring) -> String.Index = { head in
            var index = head.endIndex
            while index > head.startIndex {
                let previous = head.index(before: index)
                if index < head.endIndex, head[index].isWhitespace, ".!?".contains(head[previous]) {
                    let wordStart = head[..<previous].lastIndex(where: \.isWhitespace).map { head.index(after: $0) } ?? head.startIndex
                    let word = head[wordStart..<previous].lowercased()
                    // "3 p.m. tomorrow", "the U.S. next week": a dotted abbreviation before a lowercase word is mid-sentence.
                    let continues = word.last?.isLetter == true && word.contains(".")
                        && head[index...].first(where: { !$0.isWhitespace })?.isLowercase == true
                    if head[previous] != "." || !(abbreviations.contains(word) || continues) { return index }
                }
                index = previous
            }
            return head.startIndex
        }

        var result = text
        // Ranges always come from `result` itself — never from a lowercased copy, whose indices
        // drift on expanding case mappings ("İ") and trap. First marker first: a later one that
        // opens a sentence takes the sentence before it, and that may hold an earlier marker
        // ("Monday. No wait, Tuesday. No wait, Wednesday.").
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            // Drop only the clause being corrected: back to the previous sentence end, not the whole dictation.
            var clauseStart = sentenceStart(result[..<range.lowerBound])
            // A marker that opens a sentence ("Send it to John. No wait, …") corrects the sentence before it.
            if clauseStart > result.startIndex, result[clauseStart..<range.lowerBound].allSatisfy(\.isWhitespace) {
                clauseStart = sentenceStart(result[..<result.index(before: clauseStart)])
            }
            let kept = result[..<clauseStart].trimmingCharacters(in: .whitespaces)
            let rest = String(result[range.upperBound...].drop(while: { $0.isWhitespace || ",.;:".contains($0) }))
                .trimmingCharacters(in: .whitespaces) // keep a trailing ? or !

            if rest.isEmpty {
                // "…scratch that" at the very end: drop the last sentence, but never the whole dictation.
                guard !kept.isEmpty else { return result }
                result = kept
            } else {
                result = kept.isEmpty ? rest : kept + " " + capitalizeFirstLetter(rest)
            }
        }
        return result
    }

    private static func removeFillers(in text: String, mode: CleanupMode) -> String {
        // "uh huh" before "uh+", or "uh huh" leaves a stray "huh".
        let words: [String]
        let phrases: [String]
        switch mode {
        case .code:
            words = [#"um+"#, #"uh+"#, #"hmm+"#]
            phrases = []
        case .light, .prompt:
            words = [#"uh huh"#, #"um+"#, #"uh+"#, #"hmm+"#]
            phrases = []
        case .prose, .email, .chat, .notes:
            words = [#"uh huh"#, #"um+"#, #"uh+"#, #"hmm+"#]
            phrases = [#",\s*you know\s*,"#, #",\s*i mean\s*,"#]
        }

        var result = text
        for word in words {
            // Take the filler's own trailing comma with it: "Um, I think" → "I think".
            result = result.replacingOccurrences(
                of: #"\b\#(word)\b[,;]?"#, with: "", options: [.regularExpression, .caseInsensitive]
            )
        }
        for phrase in phrases {
            result = result.replacingOccurrences(of: phrase, with: "", options: [.regularExpression, .caseInsensitive])
        }

        return result
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)             // "the  period": word lookbehinds see one space
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,;:])(?:\s*[,;:])+"#, with: "$1", options: .regularExpression) // "So,, I"
            .replacingOccurrences(of: #"[,;:]\s*([.!?])"#, with: "$1", options: .regularExpression)       // "think,."
            .replacingOccurrences(of: #"^[\s,;:]+"#, with: "", options: .regularExpression)               // ", I think"
    }

    private static func replaceSpokenTokens(in text: String, mode: CleanupMode) -> String {
        let replacements: [(String, String)]
        switch mode {
        case .code:
            replacements = [
                (#"\bopen paren\b"#, "("),
                (#"\bclose paren\b"#, ")"),
                (#"\bopen bracket\b"#, "["),
                (#"\bclose bracket\b"#, "]"),
                (#"\bopen brace\b"#, "{"),
                (#"\bclose brace\b"#, "}"),
                (#"\bdot\b"#, "."),
                (#"\bcomma\b"#, ","),
                (#"\bcolon\b"#, ":"),
                (#"\bsemicolon\b"#, ";"),
                (#"\bequals\b"#, "="),
                (#"\bunderscore\b"#, "_"),
                (#"\bslash\b"#, "/"),
                (#"\bbackslash\b"#, "\\"),
                (#"\bdash dash\b"#, "--"),
                (#"\bdash\b"#, "-"),
            ]
        case .light, .prose, .email, .chat, .notes, .prompt:
            // Punctuation words are ordinary nouns after a determiner ("a comma", "a new line of
            // products"). "period" and "colon" are also nouns by the word around them ("the trial
            // period ends", "colon cancer"), so those neighbours keep them as words.
            let determiners = "a|an|the|this|that|its|our|your|their|my|his|her"
            let notAfter = #"(?<!\b(?:\#(determiners)) )"#
            // At the end or before a line break "period" is the command ("have a great day period")
            // unless a determiner or one of these nouns comes right before it.
            let periodNouns = "\(determiners)|trial|grace|free|waiting|notice|billing|cooling|probation|reporting|time|test|sample"
            let atBreak = #"(?=\s*$|\s+new (?:line|paragraph)\b)"#
            // Mid-sentence it is mostly the noun ("during the enrollment period we…", "over the same
            // period, revenue…"), so it converts only with no determiner in the three words before
            // it, no time word right before it, and a word (not punctuation) right after it.
            let midPeriod = #"(?<!\b(?:\#(periodNouns)|review|transition|holiday|day|week|month|year|hour|minute|quarter) )(?<!\b(?:\#(determiners)) \S{1,20} (?:\S{1,20} )?)"#
            let notNounNext = #"(?!\s+(?:of|is|was|ends?|ended|starts?|started|lasts?|lasted|pain|cramps?|drama|piece|costume|style|furniture)\b)"#
            let wordNext = #"(?=\s+(?!new (?:line|paragraph)\b)[^\s,.;:!?])"#
            let notOrganNext = #"(?!\s+(?:cancer|health|polyps?|surgery|cleanse|screening|wall|lining)\b)"#
            replacements = [
                (#"(?<!\b(?:\#(periodNouns)) )\b(?:period|full stop)\b\#(atBreak)"#, "."),
                (#"\#(midPeriod)\b(?:period|full stop)\b\#(notNounNext)\#(wordNext)"#, "."),
                (#"\#(notAfter)\bcolon\b\#(notOrganNext)"#, ":"),
                (#"\#(notAfter)\bcomma\b"#, ","),
                (#"\#(notAfter)\bquestion mark\b"#, "?"),
                (#"\#(notAfter)\bexclamation (?:point|mark)\b"#, "!"),
                (#"\#(notAfter)\bsemicolon\b"#, ";"),
                (#"\#(notAfter)\bnew paragraph\b"#, "\n\n"),
                (#"\#(notAfter)\bnew line\b"#, "\n"),
            ]
        }

        var result = text
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// Endings that make "X dot Y" a domain or file name ("example dot com", "readme dot md") rather
    /// than ordinary speech ("polka dot dress", "a dot on the map").
    private static let domainSuffixes = "com|org|net|edu|gov|io|dev|ai|app|co|me|us|uk|ca|de|info|biz|tv|md|txt|swift|js|ts|tsx|jsx|py|json|yml|yaml|html|css|sh|rb|rs|java|kt|cpp|pdf|png|jpg|jpeg|gif|csv|xml|toml|plist|log|zip"
    private static let unitWords = "percent|times|minutes?|hours?|days?|weeks?|months?|years?|items?|steps?|people|copies|emails?|messages?"
    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static func normalizeCommonPatterns(in text: String, mode: CleanupMode) -> String {
        var result = text

        // A spoken address only ("jane at example dot com"), joined before the domain join below:
        // "start at 9.99" or "read more at github.com" is already literal text, not an address.
        // The left word must not be ordinary speech ("the docs at apple dot com", "sign in at
        // example dot com", "it's at…"); a dotted local part ("john dot smith at…") joins whole.
        // ponytail: "info" stays joinable ("info at acme dot com"), so "more info at…" still joins.
        let notLocalPart = "a|an|the|this|that|it|is|me|us|you|him|her|them|we|they|i|look|looking|docs|doc|home|work|school|here|there|site|website|page|link|everyone|back|out|up|now|be|are|was|were|meet|see|find|go|stuff|in|on|to|for|of|from|by|with|and|or|into|onto|over|available|online|live|post|posted|more|sold|listed|hosted|signed|logged"
        result = replaceMatches(
            in: result,
            pattern: #"(?i)(?<!['’])\b(?!(?:\#(notLocalPart))\b)[a-z0-9._%+-]*[a-z][a-z0-9._%+-]*(?:\s+dot\s+[a-z0-9_-]+)*\s+at\s+[a-z0-9-]+(?:\s+dot\s+[a-z0-9-]+)*\s+dot\s+(?:\#(domainSuffixes))\b"#
        ) { match in
            match.replacingOccurrences(of: #"\s+at\s+"#, with: "@", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: [.regularExpression, .caseInsensitive])
        }
        result = replaceMatches(
            in: result,
            pattern: #"(?i)\b(?!(?:a|an|the|this|that|and|or|of|in|on|at|to|is|it)\b)[a-z0-9-]+(?:\s+dot\s+[a-z0-9-]+)*\s+dot\s+(?:\#(domainSuffixes))\b"#
        ) { match in
            match.replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: [.regularExpression, .caseInsensitive])
        }

        if mode != .code {
            // Whole number phrases before a unit: "twenty five percent" → 25%, "two hundred percent" → 200%.
            let numberWord = #"(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|a(?=[\s-]+hundred))"#
            result = replaceMatches(
                in: result,
                pattern: #"(?i)\b(\#(numberWord)(?:[\s-]+\#(numberWord))*)\s+(\#(unitWords))\b"#
            ) { match in
                guard let unitStart = match.range(of: #"\s+\S+$"#, options: .regularExpression) else { return match }
                let phrase = String(match[..<unitStart.lowerBound])
                let unit = match[unitStart].trimmingCharacters(in: .whitespaces)
                let isPercent = unit.lowercased() == "percent"
                // "one day we'll go", "one of us": a lone "one" before a unit is usually idiom.
                guard let value = parseNumber(phrase), isPercent || phrase.lowercased() != "one" else { return match }
                return isPercent ? "\(value)%" : "\(value) \(unit)"
            }
        }

        return result
    }

    /// "twenty five" → 25, "two hundred" → 200, "a hundred" → 100; nil for anything else.
    private static func parseNumber(_ phrase: String) -> Int? {
        let words = phrase.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        var index = 0
        var value = 0
        if index < words.count, let ten = tens[words[index]] {
            value = ten
            index += 1
            if index < words.count, let one = ones[words[index]], (1...9).contains(one) {
                value += one
                index += 1
            }
        } else if index < words.count, let one = ones[words[index]] {
            value = one
            index += 1
        } else if index < words.count, words[index] == "a" {
            index += 1
        }
        if index < words.count, words[index] == "hundred" {
            value = max(value, 1) * 100
            index += 1
        }
        return index == words.count && index > 0 && !(words.first == "a" && value == 0) ? value : nil
    }

    private static func replaceMatches(in text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }

    /// Polishes each line. Paragraph ends get terminal punctuation; a single line break ("new
    /// line": lists, chat) doesn't.
    private static func polishSentence(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.indices.map { index in
            polishLine(lines[index], terminate: index == lines.count - 1 || lines[index + 1].isEmpty)
        }.joined(separator: "\n")
    }

    private static func polishLine(_ text: String, terminate: Bool = true) -> String {
        // No space is inserted after "." or ":": that would split domains, file names, decimals,
        // times, and abbreviations ("github.com", "README.md", "3.5", "10:30", "e.g.").
        var result = text
            .replacingOccurrences(of: #"([,;!?])(?=[A-Za-z])"#, with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard !result.isEmpty else { return "" }

        // A leading email, domain, file name, or path keeps its case ("github.com is down").
        let firstToken = String(result.prefix(while: { !$0.isWhitespace }))
        let isLiteral = firstToken.contains("@") || firstToken.contains("/")
            || firstToken.range(of: #"^[a-z0-9-]+(?:\.[a-z0-9-]+)+[.,;:!?]?$"#, options: .regularExpression) != nil
        if !isLiteral {
            result = capitalizeFirstLetter(result)
        }

        if terminate, let last = result.last, !".!?;:)".contains(last) {
            result.append(".")
        }

        // Standalone "i" only — not "i.e.", "i.txt", or a path segment; a sentence-ending "i." counts.
        result = result.replacingOccurrences(of: #"(?<![\w./-])i(?![\w/-]|\.\w)"#, with: "I", options: .regularExpression)
        return result
    }

    private static func formatEmail(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        if let formatted = formatExistingGreeting(in: normalized) {
            return formatted
        }

        if let formatted = formatDirectAddress(in: normalized) {
            return formatted
        }

        return normalized
    }

    private static func formatMarkdownNotes(_ text: String) -> String {
        let lines = normalizeStructuredWhitespace(in: text)
            .components(separatedBy: .newlines)
        // In a one-line note, "Title insurance is due" and "Checked the logs" are sentences. Bare
        // keywords are structure only when the note was dictated line by line or the keyword is set
        // off with a colon or comma; "bullet point" and "checkbox" are unambiguous. "done" always
        // needs the colon or comma.
        let structured = lines.filter { !$0.isEmpty }.count > 1
        let separator = structured ? #"[:,]?\s+"# : #"[:,]\s*"#

        let formatted = lines.map { rawLine -> String in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return "" }

            if let heading = markdownCapture(line, pattern: #"(?i)^(?:heading|section)\#(separator)(.+)$"#) {
                return "## \(markdownHeading(heading))"
            }

            if let title = markdownCapture(line, pattern: #"(?i)^title\#(separator)(.+)$"#) {
                return "# \(markdownHeading(title))"
            }

            if let item = markdownCapture(line, pattern: #"(?i)^bullet point[:,]?\s+(.+)$"#)
                ?? markdownCapture(line, pattern: #"(?i)^(?:bullet|list item)\#(separator)(.+)$"#) {
                return "- \(markdownListItem(item))"
            }

            if let item = markdownCapture(line, pattern: #"(?i)^(?:checkbox|check box)[:,]?\s+(.+)$"#)
                ?? markdownCapture(line, pattern: #"(?i)^(?:todo|to do)\#(separator)(.+)$"#) {
                return "- [ ] \(markdownListItem(item))"
            }

            if let item = markdownCapture(line, pattern: #"(?i)^(?:done|completed|checked)[:,]\s*(.+)$"#) {
                return "- [x] \(markdownListItem(item))"
            }

            if line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                return line
            }

            return polishLine(line)
        }

        return formatted
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdownCapture(_ text: String, pattern: String) -> String? {
        guard let match = firstMatch(in: text, pattern: pattern) else { return nil }
        return captured(match, index: 1, in: text)
    }

    private static func markdownHeading(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else { return trimmed }
        return capitalizeFirstLetter(trimmed)
    }

    private static func markdownListItem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else { return trimmed }
        return polishLine(trimmed)
    }

    private static func formatExistingGreeting(in text: String) -> String? {
        let punctuationPattern = #"(?is)^(hi|hello|hey|dear)\s+([a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,2})\s*[,.;:!-]\s*(.+)$"#
        if let match = firstMatch(in: text, pattern: punctuationPattern),
           let greeting = captured(match, index: 1, in: text),
           let name = captured(match, index: 2, in: text),
           let body = captured(match, index: 3, in: text),
           isLikelyName(String(name.prefix(while: { !$0.isWhitespace }))) {
            return emailGreeting(greeting, name: name, body: body)
        }

        let naturalPattern = #"(?is)^(hi|hello|hey)\s+([a-z][a-z.'-]*)\s+(.+)$"#
        if let match = firstMatch(in: text, pattern: naturalPattern),
           let greeting = captured(match, index: 1, in: text),
           let name = captured(match, index: 2, in: text),
           let body = captured(match, index: 3, in: text),
           isLikelyName(name) {
            return emailGreeting(greeting, name: name, body: body)
        }

        return nil
    }

    private static func formatDirectAddress(in text: String) -> String? {
        // A bare name only counts as an address when the speaker set it off with a comma
        // ("Jordan, can you…") — never "Tomorrow we will ship" or "Sorry I missed your call".
        let pattern = #"(?is)^([a-z][a-z.'-]{1,}),\s+(can|could|would|will|please|just|i|we|thank|thanks|hope)\b(.+)$"#
        guard let match = firstMatch(in: text, pattern: pattern),
              let name = captured(match, index: 1, in: text),
              let bodyStart = captured(match, index: 2, in: text),
              let bodyRest = captured(match, index: 3, in: text),
              isLikelyName(name)
        else { return nil }

        return emailGreeting("Hi", name: name, body: "\(bodyStart)\(bodyRest)")
    }

    /// Keeps the greeting the speaker chose ("Dear Professor Jones," stays formal).
    private static func emailGreeting(_ greeting: String, name: String, body: String) -> String {
        let salutation = greeting.prefix(1).uppercased() + greeting.dropFirst().lowercased()
        let cleanName = titleCasedName(name)
        let cleanBody = capitalizeFirstLetter(
            trimLeadingPunctuation(
                body
                    .replacingOccurrences(of: #"\n+"#, with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        return cleanBody.isEmpty ? "\(salutation) \(cleanName)," : "\(salutation) \(cleanName),\n\n\(cleanBody)"
    }

    private static func trimLeadingPunctuation(_ value: String) -> String {
        String(value.drop(while: { $0.isWhitespace || ",.;:!-".contains($0) }))
    }

    private static let notNames: Set<String> = [
        "also", "and", "but", "can", "could", "dear", "hello", "hey", "hi", "if", "just", "please", "so",
        "thank", "thanks", "the", "this", "will", "would", "i", "i'm", "we", "you", "he", "she", "they",
        "it", "me", "us", "them", "my", "our", "today", "tomorrow", "yesterday", "tonight", "sorry",
        "honestly", "actually", "okay", "ok", "yes", "no", "yeah", "maybe", "then", "now", "unfortunately",
        "hopefully", "basically", "anyway", "well", "sure", "great", "good", "perfect", "quick", "again",
        // Sentence adverbs and discourse markers are set off with a comma just like a name ("However, I…").
        // ponytail: a blocklist, not name detection; an unlisted adverb still reads as a name.
        "however", "first", "firstly", "second", "secondly", "third", "next", "last", "lastly", "finally",
        "otherwise", "alright", "right", "look", "listen", "meanwhile", "overall", "personally", "additionally",
        "besides", "instead", "plus", "still", "though", "regardless", "anyways", "oh", "fine", "cool", "awesome",
        "nice", "thankfully", "luckily", "fortunately", "frankly", "seriously", "obviously", "clearly",
        "apparently", "ideally", "similarly", "likewise", "therefore", "furthermore", "moreover", "incidentally",
    ]

    private static func isLikelyName(_ value: String) -> Bool {
        !notNames.contains(value.lowercased())
    }

    /// Capitalizes each part's first letter without lowercasing the rest ("McDonald" survives).
    private static func titleCasedName(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { capitalizeFirstLetter(String($0)) }
            .joined(separator: " ")
    }

    private static func capitalizeFirstLetter(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private static func firstMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }

    private static func captured(_ match: NSTextCheckingResult, index: Int, in text: String) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[range])
    }

    private static let shellCommands: Set<String> = [
        "cd", "ls", "cp", "mv", "rm", "cat", "open", "mkdir", "rmdir", "touch", "ln", "git", "npm", "npx",
        "yarn", "pnpm", "bun", "swift", "python", "python3", "node", "vim", "nvim", "code", "less", "head",
        "tail", "grep", "find", "chmod", "chown", "ssh", "scp", "curl", "wget", "brew", "make", "sudo",
        "echo", "source", "export", "docker", "kubectl", "tar", "unzip", "du", "df", "xcodebuild", "xcrun",
        "cargo", "pip", "pip3", "which", "man",
    ]

    private static func polishCode(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactingPatterns: [(String, String)] = [
            (#"\(\s+"#, "("),
            (#"\s+\)"#, ")"),
            (#"\[\s+"#, "["),
            (#"\s+\]"#, "]"),
            (#"\{\s+"#, "{"),
            (#"\s+\}"#, "}"),
            (#"\s*_\s*"#, "_"),
            (#"\.\s+(?=\.)"#, "."),                          // ". ." → ".."
            // A flag attaches to its name, never to the previous argument: "ls - la" → "ls -la".
            (#"(^|\s)(--?)\s+(?=[A-Za-z0-9])"#, "$1$2"),
            // Separators attach to what follows: "/ usr" → "/usr", ". bar" → ".bar".
            (#"([./\\])\s+(?=[A-Za-z0-9_~$])"#, "$1"),
        ]

        for (pattern, replacement) in compactingPatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        return result
            .components(separatedBy: "\n")
            .map(attachSeparators)
            .joined(separator: "\n")
    }

    /// "self .view" → "self.view", "/usr /local" → "/usr/local", but a space after a shell command
    /// or flag separates arguments ("cd /usr", "ls -la /tmp"), and "./src", "../src", or a lone "."
    /// start a new argument ("git add .").
    private static func attachSeparators(in line: String) -> String {
        var tokens: [String] = []
        for token in line.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let chars = Array(token)
            if let previous = tokens.last,
               chars.count > 1, "./\\".contains(chars[0]),
               chars[1].isLetter || chars[1].isNumber || chars[1] == "_",
               !shellCommands.contains(previous.lowercased()), !previous.hasPrefix("-") {
                tokens[tokens.count - 1] = previous + token
            } else {
                tokens.append(token)
            }
        }
        return tokens.joined(separator: " ")
    }
}
