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
            let template = rule.replace
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
            result = result.replacingOccurrences(
                of: pattern,
                with: template,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }
}
