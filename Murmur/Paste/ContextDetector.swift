import AppKit

struct ContextDetector: Sendable {
    let defaults: [String: CleanupMode]
    let userOverrides: [AppOverride]

    static let builtinDefaults: [String: CleanupMode] = [
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.apple.MobileSMS": .chat,
        "com.tinyspeck.slackmacgap": .chat,
        "com.microsoft.teams2": .chat,
        "com.hnc.Discord": .chat,
        "com.apple.Notes": .notes,
        "com.openai.chat": .prompt,
        "com.anthropic.claudefordesktop": .prompt,
        "com.apple.Terminal": .light,
        "com.googlecode.iterm2": .light,
        "com.mitchellh.ghostty": .light,
        "org.alacritty": .light,
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "dev.zed.Zed": .code,
    ]

    func mode(for bundleID: String?) -> CleanupMode {
        guard let bundleID else { return .prose }
        if let user = userOverrides.first(where: { $0.bundleID == bundleID }) { return user.mode }
        return defaults[bundleID] ?? .prose
    }

    @MainActor
    func currentMode() -> CleanupMode {
        mode(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
