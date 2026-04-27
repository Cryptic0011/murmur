import Foundation

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
        result = mode == .notes || mode == .email
            ? normalizeStructuredWhitespace(in: result)
            : normalizeWhitespace(in: result)

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
        let markers = [
            "scratch that",
            "never mind",
            "no wait",
            "oh wait",
            "wait no",
            "wait i mean",
            "i mean",
            "or rather",
        ]

        let lower = text.lowercased()
        var latestCut: String.Index?

        for marker in markers {
            guard let range = lower.range(of: marker, options: .backwards) else { continue }
            if let current = latestCut {
                if range.upperBound > current { latestCut = range.upperBound }
            } else {
                latestCut = range.upperBound
            }
        }

        guard let cutIndex = latestCut else { return text }
        let suffix = text[cutIndex...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return suffix.isEmpty ? text : suffix
    }

    private static func removeFillers(in text: String, mode: CleanupMode) -> String {
        let patterns: [String]
        switch mode {
        case .code:
            patterns = [
                #"\bum+\b"#,
                #"\buh+\b"#,
                #"\bhmm+\b"#,
            ]
        case .light, .prompt:
            patterns = [
                #"\bum+\b"#,
                #"\buh+\b"#,
                #"\buh huh\b"#,
                #"\bhmm+\b"#,
            ]
        case .prose, .email, .chat, .notes:
            patterns = [
                #"\bum+\b"#,
                #"\buh+\b"#,
                #"\buh huh\b"#,
                #"\bhmm+\b"#,
                #",\s*you know\s*,"#,
                #",\s*i mean\s*,"#,
            ]
        }

        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        result = result.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        return result
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
            replacements = [
                (#"\bcomma\b"#, ","),
                (#"\bperiod\b"#, "."),
                (#"\bquestion mark\b"#, "?"),
                (#"\bexclamation (?:point|mark)\b"#, "!"),
                (#"\bcolon\b"#, ":"),
                (#"\bsemicolon\b"#, ";"),
                (#"\bnew line\b"#, "\n"),
                (#"\bnew paragraph\b"#, "\n\n"),
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

    private static func normalizeCommonPatterns(in text: String, mode: CleanupMode) -> String {
        var result = text

        result = result.replacingOccurrences(
            of: #"\b([A-Z0-9._%+-]+)\s+at\s+([A-Z0-9.-]+)\s+dot\s+([A-Z]{2,})\b"#,
            with: "$1@$2.$3",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: #"\b([A-Z0-9-]+)\s+dot\s+([A-Z0-9.-]+)\b"#,
            with: "$1.$2",
            options: [.regularExpression, .caseInsensitive]
        )

        if mode != .code {
            for (word, digit) in [
                ("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"),
                ("five", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"), ("nine", "9"), ("ten", "10"),
            ] {
                result = result.replacingOccurrences(
                    of: #"(?i)\b\#(word)\b(?=\s+(percent|times|minutes?|hours?|days?|weeks?|months?|years?|items?|steps?|people|copies|emails?|messages?))"#,
                    with: digit,
                    options: .regularExpression
                )
            }

            let tens: [String: String] = [
                "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50",
                "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
            ]

            for (word, number) in tens {
                result = result.replacingOccurrences(
                    of: #"(?i)\b\#(word)\s+percent\b"#,
                    with: "\(number)%",
                    options: .regularExpression
                )
            }

            result = result.replacingOccurrences(
                of: #"(?i)\b(one\s+)?hundred percent\b"#,
                with: "100%",
                options: .regularExpression
            )
        }

        return result
    }

    private static func polishSentence(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: #"([,.;:!?])([A-Za-z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else { return "" }

        let first = result.prefix(1).uppercased()
        result = first + result.dropFirst()

        if let last = result.last, !".!?;:)".contains(last) {
            result.append(".")
        }

        result = result.replacingOccurrences(
            of: #"([A-Z0-9._%+-]+@[A-Z0-9.-]+)\.\s+([A-Z]{2,})"#,
            with: "$1.$2",
            options: [.regularExpression, .caseInsensitive]
        )

        result = result.replacingOccurrences(of: #"\bi\b"#, with: "I", options: [.regularExpression, .caseInsensitive])
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

        let formatted = lines.map { rawLine -> String in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return "" }

            if let heading = markdownCapture(line, pattern: #"(?i)^(?:heading|section)\s+(.+)$"#) {
                return "## \(markdownHeading(heading))"
            }

            if let title = markdownCapture(line, pattern: #"(?i)^title\s+(.+)$"#) {
                return "# \(markdownHeading(title))"
            }

            if let item = markdownCapture(line, pattern: #"(?i)^(?:bullet point|bullet|list item)\s+(.+)$"#) {
                return "- \(markdownListItem(item))"
            }

            if let item = markdownCapture(line, pattern: #"(?i)^(?:checkbox|check box|todo|to do)\s+(.+)$"#) {
                return "- [ ] \(markdownListItem(item))"
            }

            if let item = markdownCapture(line, pattern: #"(?i)^(?:done|completed|checked)\s+(.+)$"#) {
                return "- [x] \(markdownListItem(item))"
            }

            if line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                return line
            }

            return polishSentence(line)
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
        return polishSentence(trimmed)
    }

    private static func formatExistingGreeting(in text: String) -> String? {
        let punctuationPattern = #"(?i)^(hi|hello|hey|dear)\s+([a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,2})\s*[,.;:!-]\s*(.+)$"#
        if let match = firstMatch(in: text, pattern: punctuationPattern),
           let name = captured(match, index: 2, in: text),
           let body = captured(match, index: 3, in: text) {
            return emailGreeting(name: name, body: body)
        }

        let naturalPattern = #"(?i)^(hi|hello|hey)\s+([a-z][a-z.'-]*)\s+(.+)$"#
        if let match = firstMatch(in: text, pattern: naturalPattern),
           let name = captured(match, index: 2, in: text),
           let body = captured(match, index: 3, in: text) {
            return emailGreeting(name: name, body: body)
        }

        return nil
    }

    private static func formatDirectAddress(in text: String) -> String? {
        let pattern = #"(?i)^([a-z][a-z.'-]{1,})\s*,?\s+(can|could|would|will|please|just|i|we|thank|thanks)\b(.+)$"#
        guard let match = firstMatch(in: text, pattern: pattern),
              let name = captured(match, index: 1, in: text),
              let bodyStart = captured(match, index: 2, in: text),
              let bodyRest = captured(match, index: 3, in: text),
              isLikelyName(name)
        else { return nil }

        return emailGreeting(name: name, body: "\(bodyStart)\(bodyRest)")
    }

    private static func emailGreeting(name: String, body: String) -> String {
        let cleanName = titleCasedName(name)
        let cleanBody = capitalizeFirstLetter(
            trimLeadingPunctuation(
                body
                    .replacingOccurrences(of: #"\n+"#, with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        return cleanBody.isEmpty ? "Hi \(cleanName)," : "Hi \(cleanName),\n\n\(cleanBody)"
    }

    private static func trimLeadingPunctuation(_ value: String) -> String {
        String(value.drop(while: { $0.isWhitespace || ",.;:!-".contains($0) }))
    }

    private static func isLikelyName(_ value: String) -> Bool {
        let lower = value.lowercased()
        let blocked = Set([
            "also", "and", "but", "can", "could", "dear", "hello", "hey", "hi", "i",
            "if", "just", "please", "so", "thank", "thanks", "the", "this", "we",
            "will", "would", "you",
        ])
        return !blocked.contains(lower)
    }

    private static func titleCasedName(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { part in
                let lower = part.lowercased()
                guard let first = lower.first else { return "" }
                return first.uppercased() + lower.dropFirst()
            }
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
            (#"\s*\.\s*"#, "."),
            (#"\s*/\s*"#, "/"),
            (#"\s*\\\s*"#, "\\"),
            (#"\s*--\s*(?=[A-Za-z0-9])"#, "--"),
        ]

        for (pattern, replacement) in compactingPatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        return result
    }
}
