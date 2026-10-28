import Foundation

struct ReplacementRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var find: String
    var replace: String
}

/// User-defined find→replace rules applied to transcripts ("murmer" → "Murmur").
enum TextReplacer {
    /// Case-insensitive replacement of each rule in order. Word boundaries are enforced
    /// where the pattern starts/ends with a word character, so "murmer" won't touch "murmering".
    /// Safe to apply more than once: text that already reads as the replacement is left as the
    /// replacement, so "react" → "React.js" never grows into "React.js.js".
    static func apply(_ rules: [ReplacementRule], to text: String) -> String {
        var result = text
        for rule in rules {
            let find = rule.find.trimmingCharacters(in: .whitespaces)
            guard !find.isEmpty else { continue }
            var pattern = NSRegularExpression.escapedPattern(for: find)
            if let first = find.first, first.isLetter || first.isNumber {
                pattern = "\\b" + pattern
            }
            if let last = find.last, last.isLetter || last.isNumber {
                pattern += "\\b"
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }

            let source = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { continue }
            let existing = occurrences(of: rule.replace, in: source)

            // A match inside an existing (any-case) occurrence of the replacement normalizes that
            // occurrence instead of nesting another replacement inside it.
            var edits: [(range: NSRange, text: String)] = []
            for match in matches {
                let edit: (range: NSRange, text: String)
                if let occurrence = existing.first(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    edit = (occurrence, rule.replace)
                } else {
                    edit = (match.range, cased(rule.replace, like: source.substring(with: match.range),
                                               atSentenceStart: startsSentence(at: match.range.location, in: source)))
                }
                if let previous = edits.last, NSIntersectionRange(previous.range, edit.range).length > 0 { continue }
                edits.append(edit)
            }

            let output = NSMutableString(string: result)
            for edit in edits.reversed() {
                output.replaceCharacters(in: edit.range, with: edit.text)
            }
            result = output as String
        }
        return result
    }

    /// An all-lowercase replacement follows the speaker's capitalized first letter ("Gonna" →
    /// "Going to", "Brb" → "Be right back."); a replacement with deliberate casing ("iOS",
    /// "Murmur") or a literal snippet (an email, URL, path, or domain) is kept verbatim.
    private static func cased(_ replacement: String, like matched: String, atSentenceStart: Bool) -> String {
        // Speech-to-text writes acronyms ("BRB", "ASAP") in capitals anywhere, so an all-caps
        // match only signals a capital where a sentence begins.
        let acronym = matched.count > 1 && matched == matched.uppercased()
        guard replacement == replacement.lowercased(),
              !replacement.contains("@"), !replacement.contains("/"),
              replacement.range(of: #"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#, options: .regularExpression) == nil,
              matched.first?.isUppercase == true,
              !acronym || atSentenceStart,
              let first = replacement.first
        else { return replacement }
        return first.uppercased() + replacement.dropFirst()
    }

    private static func startsSentence(at location: Int, in text: NSString) -> Bool {
        let before = text.substring(to: location).trimmingCharacters(in: .whitespaces)
        guard let last = before.last else { return true }
        return ".!?\n".contains(last)
    }

    private static func occurrences(of needle: String, in haystack: NSString) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var location = 0
        while location < haystack.length {
            let found = haystack.range(
                of: needle, options: .caseInsensitive,
                range: NSRange(location: location, length: haystack.length - location)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            location = found.location + found.length
        }
        return ranges
    }
}
