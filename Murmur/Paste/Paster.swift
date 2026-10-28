import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

@MainActor
final class Paster {
    struct PasteOutcome: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case pasted
            case copiedOnly
        }

        let kind: Kind
        let detail: String
        /// A password field or secure input: keep this dictation out of history.
        var isSecureTarget = false

        static func pasted(_ detail: String = "Pasted into focused field") -> PasteOutcome {
            .init(kind: .pasted, detail: detail)
        }

        static func copiedOnly(_ detail: String) -> PasteOutcome {
            .init(kind: .copiedOnly, detail: detail)
        }
    }

    /// After Cmd-V, poll the target this often, up to confirmTimeout — Electron and
    /// web editors apply a paste a few frames late.
    private let confirmInterval: UInt64 = 100_000_000 // 100ms
    private let confirmTimeout: UInt64 = 600_000_000 // 600ms
    /// Extra wait before restoring the clipboard when the target can't confirm
    /// the paste (Electron/web/terminals) — apps that service Cmd-V lazily read
    /// the pasteboard late, and restoring too early pastes the old clipboard.
    private let unverifiedRestoreDelay: UInt64 = 800_000_000 // 800ms
    /// Caps every AX round-trip (default ~6 s) so a hung target app can't freeze
    /// Murmur's main thread — and with it the hotkey event tap.
    private static let axTimeout: Float = 0.4
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Clipboard managers never record or show it: possible passwords.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// How long a possible password left on the clipboard stays there.
    private static let sensitiveClipboardLifetime: Duration = .seconds(45)
    private static let switchedApps = PasteOutcome.copiedOnly(
        "Copied to clipboard — you switched apps before the text was ready"
    )
    /// Roles where Cmd-V can't insert text, so the dictation stays on the clipboard.
    /// Tables are left out on purpose: spreadsheets paste into the selected cell.
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXSlider", "AXIncrementor", "AXImage", "AXStaticText", "AXLink", "AXMenu",
        "AXMenuBar", "AXMenuBarItem", "AXMenuItem", "AXList", "AXOutline", "AXBrowser",
        "AXDisclosureTriangle", "AXScrollBar", "AXToolbar", "AXTabGroup", "AXColorWell",
        "AXDockItem",
    ]
    /// Containers that take a paste only through a field inside them, so a focus
    /// that stops on one means no field had it: a web page or pane with nothing
    /// focused, a mail list. A table that selects cells but not rows is a
    /// spreadsheet instead (a list's selected row reports its cells too).
    private static let containerRoles: Set<String> = ["AXWebArea", "AXGroup", "AXScrollArea", "AXTable"]
    private let log = Logger(subsystem: "com.murmur.app", category: "paste")
    /// Apps already asked to build their AX tree — Chromium/Electron only expose
    /// focused text fields to an assistive client that sets AXManualAccessibility.
    private var manualAccessibilityPIDs: Set<pid_t> = []

    /// - Parameters:
    ///   - expectedPID: the frontmost app when the dictation was aimed; if another
    ///     app is frontmost now, the text is only copied.
    ///   - expectedFocusPID: the app that had keyboard focus when the dictation was
    ///     aimed (ContextDetector.targetApplication); if focus is now in another
    ///     app — a Spotlight or Raycast panel doesn't change the frontmost app —
    ///     the text is only copied.
    ///   - smartInsertion: fit spacing/capitalization to the text before the caret.
    ///     nil lets Murmur's built-in app styles decide (off in code editors and
    ///     terminals, where "self." + "view" must not become "self. View").
    func paste(
        _ text: String, expectedPID: pid_t? = nil, expectedFocusPID: pid_t? = nil, smartInsertion: Bool? = nil
    ) async -> PasteOutcome {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let expectedPID, frontmost?.processIdentifier != expectedPID {
            log.info("Frontmost app changed since the dictation started; not pasting")
            Self.copy(text)
            return Self.switchedApps
        }
        // Secure input is system-wide: a password prompt or Secure Keyboard Entry in
        // the frontmost app, or a background app that leaked it. Synthetic Cmd-V still
        // lands either way; the frontmost case keeps the dictation out of history.
        let secureInput = IsSecureEventInputEnabled() && Self.secureInputHeldBy(frontmost?.processIdentifier)
        func finish(_ outcome: PasteOutcome) -> PasteOutcome {
            var outcome = outcome
            if secureInput { outcome.isSecureTarget = true }
            return outcome
        }
        // Without Accessibility the synthetic Cmd-V is dropped and nothing can be
        // read back, so a "paste" would silently lose the dictation.
        guard AXIsProcessTrusted() else {
            Self.copy(text, sensitive: secureInput)
            return finish(.copiedOnly("Copied to clipboard — Accessibility is off, so Murmur can't paste"))
        }
        // Off in code and terminal styles (App Overrides included).
        let smart = smartInsertion ?? !Self.isCodeOrTerminal(frontmost?.bundleIdentifier)

        // Decide before touching the clipboard: copy-only paths never snapshot.
        let element: AXUIElement?
        let description: String
        // Only a known text field's length/caret can prove a paste failed.
        let confirmable: Bool
        // AX showed a container with no field focused: Cmd-V may go nowhere.
        let maybeNowhere: Bool
        switch focusedTarget(frontmost: frontmost, allowsManualAccessibility: smart) {
        case .secure:
            Self.copy(text, sensitive: true)
            return .init(
                kind: .copiedOnly,
                detail: "Copied to clipboard for 45 s — Murmur doesn't paste into password fields",
                isSecureTarget: true
            )
        case .notText(let role):
            log.info("Paste fallback to clipboard: focused element is \(role, privacy: .public)")
            Self.copy(text, sensitive: secureInput)
            return finish(.copiedOnly("Copied to clipboard — no text field was focused"))
        case .text(let target, let role):
            element = target
            description = role
            confirmable = true
            maybeNowhere = false
        case .noField(let target, let role):
            element = target
            description = role
            confirmable = false
            maybeNowhere = true
        case .unknown(let target, let role):
            // No usable AX answer (custom-drawn terminals and editors, Java, VMs,
            // Murmur's own text fields, a busy app): Cmd-V lands wherever the app's
            // own focus is, unverified.
            element = target
            description = role
            confirmable = false
            maybeNowhere = false
        }
        if let expectedFocusPID, let element, let focusPID = Self.pid(of: element), focusPID != expectedFocusPID,
           // A WebKit2 page's elements live in its WebContent process, but their
           // window is the host app's.
           elementAttribute(kAXWindowAttribute, of: element).flatMap(Self.pid(of:)) != expectedFocusPID {
            log.info("Keyboard focus moved to another app since the dictation started; not pasting")
            Self.copy(text, sensitive: secureInput)
            return finish(Self.switchedApps)
        }

        var insertion = text
        if smart, let element, let before = textBeforeCaret(of: element, maxLength: 64) {
            insertion = SmartInsertion.adjust(text, before: before)
        }
        // Esc while the target was being read: nothing has been touched yet.
        guard !Task.isCancelled else { return finish(.copiedOnly("Cancelled — nothing was pasted")) }

        let signalsBeforePaste = confirmable ? element.flatMap(textSignals(of:)) : nil
        let pb = NSPasteboard.general
        let priorContents = Self.snapshot(pb)
        // Current host only: a transient paste buffer must not sync to the user's
        // iPhone/iPad over Universal Clipboard.
        _ = pb.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(insertion, forType: .string)
        Self.mark(item, sensitive: secureInput)
        pb.writeObjects([item])
        let murmurPasteboardChange = pb.changeCount

        sendCmdV()
        log.info("Paste injected into focused element: \(description, privacy: .public)")

        // From here every wait ignores cancellation: Esc must not restore the old
        // clipboard before the target app has read the pasteboard.
        switch await confirmPaste(into: element, before: signalsBeforePaste) {
        case .notPasted:
            log.info("Target unchanged; leaving dictated text on clipboard")
            if secureInput { Self.clearLater(pb, ifChangeCountStill: murmurPasteboardChange) }
            return finish(.copiedOnly("Paste attempted — text remains on clipboard for manual paste"))
        case .unverifiable where maybeNowhere && smart:
            // AX showed no field (a web page with nothing focused, a mail list):
            // Cmd-V may have gone nowhere, so keep the dictation on the clipboard
            // and don't claim a paste (or press Return after it).
            log.info("Unverified target; leaving dictated text on clipboard")
            if secureInput { Self.clearLater(pb, ifChangeCountStill: murmurPasteboardChange) }
            return finish(.copiedOnly("Pasted without confirmation — text also left on the clipboard"))
        case .unverifiable:
            // A known text field, an app whose focus AX can't see, or a code
            // editor/terminal (they take Cmd-V wherever their focus is, and Murmur
            // leaves their AX tree off — see focusedTarget): Cmd-V almost certainly
            // landed; restore the user's clipboard after a grace period for lazy
            // pasteboard readers.
            // ponytail: a code editor's file tree can still swallow one unseen;
            // telling it apart needs the AX tree VS Code reacts to.
            await Self.sleepIgnoringCancellation(nanoseconds: unverifiedRestoreDelay)
        case .confirmed:
            break
        }

        Self.restore(priorContents, to: pb, ifChangeCountStill: murmurPasteboardChange)
        return finish(secureInput ? .pasted("Pasted — secure input is on, so it's kept out of history") : .pasted(description))
    }

    /// Whether the app holding secure input is the frontmost one (or can't be told):
    /// password managers and other background apps sometimes leak it for hours.
    private static func secureInputHeldBy(_ frontmostPID: pid_t?) -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let holder = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, holder > 0 else {
            return true
        }
        return holder == frontmostPID
    }

    /// Every item and type on the pasteboard, to put back after the paste.
    static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { dict[type] = d }
            }
            return dict.isEmpty ? nil : dict
        } ?? []
    }

    /// Puts the snapshot back — unless something else (the user) wrote to the
    /// pasteboard since Murmur's paste buffer.
    static func restore(
        _ priorContents: [[NSPasteboard.PasteboardType: Data]],
        to pb: NSPasteboard,
        ifChangeCountStill murmurPasteboardChange: Int
    ) {
        guard pb.changeCount == murmurPasteboardChange else { return }
        // The user's own clipboard keeps syncing over Universal Clipboard; only
        // concealed or transient contents (a password manager's copy) stay on this Mac.
        let sensitive = priorContents.contains { $0[concealedType] != nil || $0[transientType] != nil }
        _ = sensitive ? pb.prepareForNewContents(with: .currentHostOnly) : pb.clearContents()
        let restored: [NSPasteboardItem] = priorContents.map { dict in
            let it = NSPasteboardItem()
            for (type, data) in dict { it.setData(data, forType: type) }
            return it
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }

    /// - Parameter sensitive: possibly a password — kept off other devices, hidden
    ///   from clipboard managers and cleared after sensitiveClipboardLifetime.
    private static func copy(_ text: String, sensitive: Bool = false) {
        let pb = NSPasteboard.general
        _ = sensitive ? pb.prepareForNewContents(with: .currentHostOnly) : pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        mark(item, sensitive: sensitive)
        pb.writeObjects([item])
        if sensitive { clearLater(pb, ifChangeCountStill: pb.changeCount) }
    }

    private static func mark(_ item: NSPasteboardItem, sensitive: Bool) {
        item.setString("Murmur", forType: transientType)
        if sensitive { item.setString("Murmur", forType: concealedType) }
    }

    /// Takes a possible password off the clipboard later, unless something was
    /// copied since.
    private static func clearLater(_ pb: NSPasteboard, ifChangeCountStill change: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: sensitiveClipboardLifetime)
            if pb.changeCount == change { pb.clearContents() }
        }
    }

    private static func isCodeOrTerminal(_ bundleID: String?) -> Bool {
        guard let mode = bundleID.flatMap({ ContextDetector.builtinDefaults[$0] }) else { return false }
        return mode == .code || mode == .light
    }

    /// Text right before the caret in the focused field (up to maxLength), for
    /// cleanup context. nil when it can't be read — never the end of the document.
    /// - Parameter allowsManualAccessibility: the target's style, App Overrides
    ///   included, isn't code or terminal (see focusedTarget); nil uses the
    ///   built-in styles.
    func focusedFieldText(maxLength: Int = 600, allowsManualAccessibility: Bool? = nil) -> String? {
        guard !IsSecureEventInputEnabled() else { return nil }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let allows = allowsManualAccessibility ?? !Self.isCodeOrTerminal(frontmost?.bundleIdentifier)
        switch focusedTarget(frontmost: frontmost, allowsManualAccessibility: allows) {
        case .text(let element, _), .noField(let element, _), .unknown(let element?, _):
            guard let text = textBeforeCaret(of: element, maxLength: maxLength), !text.isEmpty else { return nil }
            return text
        default:
            return nil
        }
    }

    /// At hotkey press when no focusedFieldText read runs (Built-in cleanup): an
    /// app whose focus shows no field yet (Electron before its AX tree exists) is
    /// asked to build its tree while the user speaks, so the paste sees the field.
    func prepareFocusedTarget(allowsManualAccessibility: Bool) {
        guard allowsManualAccessibility, !IsSecureEventInputEnabled() else { return }
        _ = focusedTarget(frontmost: NSWorkspace.shared.frontmostApplication, allowsManualAccessibility: true)
    }

    /// Press Return in the focused app — used for auto-send after a paste.
    func pressReturn() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Return), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        // Explicitly no modifiers: a still-held Shift/Option/Cmd would turn auto-send
        // into Shift-Return (a newline) or Cmd-Return.
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func sendCmdV() {
        let key = Self.pasteKeyCode()
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// The key that types "v" with Command held in the current layout: plain Dvorak
    /// moves it (ANSI V would send Cmd-K), "Dvorak – QWERTY ⌘" keeps it. Layouts
    /// with no Latin "v" fall back to ANSI V, which macOS maps for key equivalents.
    static func pasteKeyCode() -> CGKeyCode {
        let ansiV = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansiV }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return ansiV }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())

        func character(for keyCode: CGKeyCode) -> String? {
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), commandState, keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }

        if character(for: ansiV) == "v" { return ansiV }
        return (CGKeyCode(0)..<128).first { character(for: $0) == "v" } ?? ansiV
    }

    // MARK: - Accessibility

    private enum FocusedTarget {
        case text(AXUIElement, String)
        case secure
        /// AX positively reports a focused element that can't take text.
        case notText(String)
        /// AX shows a container with no field focused (containerRoles): Cmd-V may go nowhere.
        case noField(AXUIElement, String)
        /// No usable answer (no element, a window, a custom-drawn view): Cmd-V lands
        /// wherever the app's own focus is. The element may still expose a caret.
        case unknown(AXUIElement?, String)
    }

    /// - Parameter allowsManualAccessibility: may ask the app to build its AX tree
    ///   when no field is visible. Off in code and terminal styles: in VS Code-style
    ///   Electron editors AXManualAccessibility switches on Screen Reader Optimized
    ///   mode (no word wrap, sound cues) until they restart.
    private func focusedTarget(frontmost: NSRunningApplication?, allowsManualAccessibility: Bool) -> FocusedTarget {
        guard let frontmost else { return .unknown(nil, "Unverified target") }
        // Murmur's own window (Try Murmur): never AX-query ourselves from the main
        // thread — the request would wait on this very thread. AppKit knows locally.
        if frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return NSApp.keyWindow?.firstResponder is NSText ? .unknown(nil, "Murmur text field") : .notText("Murmur")
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeout)
        // Finder only takes text in its rename/search fields; Cmd-V elsewhere (the
        // desktop, a file list) silently drops the dictation.
        let isFinder = frontmost.bundleIdentifier == "com.apple.finder"

        guard var element = elementAttribute(kAXFocusedUIElementAttribute, of: systemWide) else {
            if isFinder { return .notText("Finder") }
            if allowsManualAccessibility { enableManualAccessibility(pid: frontmost.processIdentifier) }
            return .unknown(nil, "Unverified target")
        }
        var role = stringAttribute(kAXRoleAttribute, of: element) ?? "Unknown"
        var subrole = stringAttribute(kAXSubroleAttribute, of: element)
        var editable = isEditable(element, role: role, subrole: subrole)
        // A focused container (web area, group) may point one or two hops further
        // at the real focus. Never walk children: that is thousands of IPC calls.
        var hops = 0
        while !editable, hops < 2,
              let inner = elementAttribute(kAXFocusedUIElementAttribute, of: element),
              !CFEqual(inner, element) {
            element = inner
            role = stringAttribute(kAXRoleAttribute, of: element) ?? "Unknown"
            subrole = stringAttribute(kAXSubroleAttribute, of: element)
            editable = isEditable(element, role: role, subrole: subrole)
            hops += 1
        }

        let description = subrole.map { $0.isEmpty ? role : "\(role) • \($0)" } ?? role
        if subrole == kAXSecureTextFieldSubrole { return .secure }
        if editable { return .text(element, description) }
        if isFinder || Self.nonTextRoles.contains(role) { return .notText(description) }
        // Only when no field was found (Electron shows a bare web area or group
        // until asked): the next read can then see it.
        if allowsManualAccessibility {
            enableManualAccessibility(pid: Self.pid(of: element) ?? frontmost.processIdentifier)
        }
        if Self.containerRoles.contains(role), role != kAXTableRole || !selectsCellsOnly(element) {
            return .noField(element, description)
        }
        return .unknown(element, description)
    }

    private func selectsCellsOnly(_ table: AXUIElement) -> Bool {
        func count(_ attribute: String) -> Int {
            var count: CFIndex = 0
            return AXUIElementGetAttributeValueCount(table, attribute as CFString, &count) == .success ? count : 0
        }
        return count(kAXSelectedCellsAttribute) > 0 && count(kAXSelectedRowsAttribute) == 0
    }

    private func enableManualAccessibility(pid: pid_t) {
        guard manualAccessibilityPIDs.insert(pid).inserted else { return }
        // Every VS Code-family editor ships this file, forks Murmur doesn't list too
        // (Positron, Trae, Kiro, Antigravity): the attribute would switch them into
        // Screen Reader Optimized mode whatever their style.
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL,
           FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/app/product.json").path) {
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        // Already on (a screen reader, another assistive app): leave it alone.
        guard boolAttribute("AXManualAccessibility", of: app) != true else { return }
        // Not AXEnhancedUserInterface — that one breaks window animations in Chrome.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func isEditable(_ element: AXUIElement, role: String, subrole: String?) -> Bool {
        let directRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextView"]
        if directRoles.contains(role) { return true }
        if subrole == "AXContentEditable" || subrole == "AXTextField" { return true }
        if boolAttribute("AXEditable", of: element) == true { return true }
        // A whole-page editable WebKit document (Mail compose, designMode) reports
        // none of the above; only its settable value tells it from a read-only page.
        if role == "AXWebArea" {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue { return true }
        }
        return false
    }

    /// Up to maxLength characters ending at the caret (or selection start); "" at
    /// the start of the field, nil when the field exposes no caret.
    private func textBeforeCaret(of element: AXUIElement, maxLength: Int) -> String? {
        guard let selection = rangeAttribute(kAXSelectedTextRangeAttribute, of: element),
              selection.location >= 0
        else { return nil }
        let start = max(0, selection.location - maxLength)
        var range = CFRange(location: start, length: selection.location - start)
        guard range.length > 0 else { return "" }
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            var value: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
            ) == .success, let text = value as? String {
                return text
            }
        }
        // No range API: read the value itself, but never copy a whole big document.
        guard let count = intAttribute(kAXNumberOfCharactersAttribute, of: element), count <= 20_000,
              let value = stringAttribute(kAXValueAttribute, of: element)
        else { return nil }
        let utf16 = Array(value.utf16) // AX ranges count UTF-16 units
        guard selection.location <= utf16.count else { return nil }
        return String(decoding: utf16[start..<selection.location], as: UTF16.self)
    }

    private enum PasteConfirmation {
        case confirmed
        case notPasted
        /// The target exposes no length or caret (web areas, Electron, terminals) —
        /// absence of evidence, not evidence the paste failed.
        case unverifiable
    }

    /// Length and caret, not the value: confirming a paste must not copy the
    /// whole document out of Xcode or a browser.
    private struct TextSignals: Equatable {
        let characterCount: Int?
        let selectionLocation: Int?
        let selectionLength: Int?
    }

    private func textSignals(of element: AXUIElement) -> TextSignals? {
        let count = intAttribute(kAXNumberOfCharactersAttribute, of: element)
        let selection = rangeAttribute(kAXSelectedTextRangeAttribute, of: element)
        guard count != nil || selection != nil else { return nil }
        return TextSignals(
            characterCount: count, selectionLocation: selection?.location, selectionLength: selection?.length
        )
    }

    private func confirmPaste(into element: AXUIElement?, before: TextSignals?) async -> PasteConfirmation {
        guard let element, let before else { return .unverifiable }
        var waited: UInt64 = 0
        while waited < confirmTimeout {
            await Self.sleepIgnoringCancellation(nanoseconds: confirmInterval)
            waited += confirmInterval
            guard let after = textSignals(of: element) else { return .unverifiable }
            if after != before { return .confirmed }
        }
        return .notPasted
    }

    /// Task.sleep returns at once in a cancelled task; this one always elapses.
    private static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        await Task.detached { _ = try? await Task.sleep(nanoseconds: nanoseconds) }.value
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func intAttribute(_ name: String, of element: AXUIElement) -> Int? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Int
    }

    private func rangeAttribute(_ name: String, of element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
