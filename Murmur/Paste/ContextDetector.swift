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
        "ru.keepcoder.Telegram": .chat,
        "com.apple.Notes": .notes,
        "md.obsidian": .notes,
        "com.openai.chat": .prompt,
        "com.anthropic.claudefordesktop": .prompt,
        "com.apple.Terminal": .light,
        "com.googlecode.iterm2": .light,
        "com.mitchellh.ghostty": .light,
        "org.alacritty": .light,
        "net.kovidgoyal.kitty": .light,
        "com.github.wez.wezterm": .light,
        "dev.warp.Warp-Stable": .light,
        "com.apple.dt.Xcode": .code,
        "com.sublimetext.4": .code,
        "com.microsoft.VSCode": .code,
        "com.microsoft.VSCodeInsiders": .code,
        "com.vscodium": .code,
        "com.exafunction.windsurf": .code,
        "com.todesktop.230313mzl4w4u92": .code,
        "dev.zed.Zed": .code,
    ]

    func mode(for bundleID: String?) -> CleanupMode {
        guard let bundleID else { return .prose }
        if let user = userOverrides.first(where: { $0.bundleID == bundleID }) { return user.mode }
        return defaults[bundleID] ?? .prose
    }

    @MainActor
    func currentMode() -> CleanupMode {
        mode(for: Self.targetApplication()?.bundleIdentifier)
    }

    /// The app dictation is aimed at. The AX focused application, because
    /// non-activating panels (Spotlight, Raycast, Alfred) take keyboard focus
    /// without becoming frontmost; else the frontmost app. When Murmur itself is
    /// frontmost (Settings' Try Murmur, a murmur:// link that activated it), the
    /// app whose window sits right behind Murmur's.
    @MainActor
    static func targetApplication() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ownPID
        else { return applicationBehindOwnWindows(ownPID: ownPID) }

        // The focused application, not element: no lookup inside the target's
        // view tree, and the timeout caps a hung app.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.4)
        var value: AnyObject?
        var pid: pid_t = 0
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
           AXUIElementGetPid(value as! AXUIElement, &pid) == .success,
           pid != ownPID,
           let focused = NSRunningApplication(processIdentifier: pid) {
            return focused
        }
        return frontmost
    }

    @MainActor
    private static func applicationBehindOwnWindows(ownPID: pid_t) -> NSRunningApplication? {
        // Front-to-back; layer 0 skips the menu bar, Dock and floating panels.
        // Owner PIDs need no Screen Recording permission (window titles would).
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }
}
