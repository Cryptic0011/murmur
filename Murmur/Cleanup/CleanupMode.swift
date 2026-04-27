import Foundation

enum CleanupMode: String, Codable, CaseIterable, Sendable {
    case light
    case prose
    case email
    case chat
    case notes
    case prompt
    case code

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .prose: return "Prose"
        case .email: return "Email"
        case .chat: return "Chat"
        case .notes: return "Notes"
        case .prompt: return "Prompt"
        case .code: return "Code"
        }
    }
}
