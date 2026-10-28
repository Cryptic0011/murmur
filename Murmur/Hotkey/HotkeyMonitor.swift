import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// A modifier-only hotkey turned out to be part of a chord (Cmd-C, Option-L
    /// for "@" right after the press, or a slow shortcut released soon after):
    /// discard the recording silently — no pipeline, no error, no sound.
    var onAbort: (() -> Void)?
    /// Escape pressed anywhere — fired unconditionally; the receiver decides
    /// whether anything (recording, transcription) is active to cancel.
    var onCancel: (() -> Void)?
    /// Asked synchronously on Escape, before onCancel: return true while a
    /// recording or pipeline is active so the Escape (and its key-up) is consumed
    /// instead of also closing a dialog or leaving insert mode in the focused app.
    var hasCancellableWork: (() -> Bool)?
    /// When paused, events pass through untouched and nothing fires.
    var paused = false

    // Primary path: CGEventTap — can consume the hotkey keystroke so it never
    // leaks into the focused app. Requires Accessibility.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Fallback path: local NSEvent monitors — they only see Murmur's own windows.
    // Global key monitors need the same Accessibility trust as the tap, so they
    // would receive nothing; the Overview "Blocked" state covers this case.
    private var monitors: [Any] = []

    private var isHeld = false
    /// A key this soon after a modifier-only press makes it a chord; later keys
    /// (Cmd-Tab, an arrow or Page Down mid-dictation) leave the recording running.
    private static let chordWindow: TimeInterval = 0.5
    /// The press event's own time, so a main-thread stall in onPress (its AX
    /// read, the HUD's first window) can't stretch a fast Cmd-C past the window.
    private var heldSince: TimeInterval = 0
    /// A key came after the chord window during this hold.
    private var chordedLate = false
    /// With a key after the chord window, a hold this long is a dictation the key
    /// interrupted (Cmd-Tab mid-sentence); a shorter one was a slow shortcut (Cmd
    /// held a moment, then C) and ends like a chord.
    private static let chordedDictationMinimum: TimeInterval = 1.5
    /// Injectable clock for tests, and for events without a time.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The Escape key-down was consumed, so its repeats and key-up must be too.
    private var swallowingEscape = false
    private var shortcut: HotkeyShortcut = .default

    func configure(shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
    }

    func start() {
        stop()
        if !startEventTap() {
            startMonitorFallback()
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        isHeld = false
        chordedLate = false
        swallowingEscape = false
    }

    // MARK: - Event tap

    private func startEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // The run loop source lives on the main run loop, so this is main-thread.
                return MainActor.assumeIsolated {
                    monitor.handleTapEvent(type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            var reenabled = false
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                reenabled = CGEvent.tapIsEnabled(tap: eventTap)
                if !reenabled {
                    // Re-enable failed — Accessibility was likely revoked. Drop to
                    // the local-monitor fallback instead of going silently dead.
                    // Deferred: don't tear down the tap from inside its own callback.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.stop()
                        self.startMonitorFallback()
                    }
                }
            }
            // Only a working tap will deliver the real release later.
            handleTapReenabled(hotkeyStillDown: reenabled && isShortcutPhysicallyDown())
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            handleFlags(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: Self.normalizedModifiers(from: event.flags),
                timestamp: Self.time(of: event)
            )
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let swallow = handleKeyDown(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: Self.normalizedModifiers(from: event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                timestamp: Self.time(of: event)
            )
            return swallow ? nil : Unmanaged.passUnretained(event)
        case .keyUp:
            let swallow = handleKeyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            return swallow ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The event's own time: NSEvent turns it into seconds since boot, the clock now()
    /// reads. nil for a synthetic event posted without one (timestamp 0), which would
    /// otherwise read as long before the press and end the hold as a chord.
    private static func time(of event: CGEvent) -> TimeInterval? {
        event.timestamp == 0 ? nil : NSEvent(cgEvent: event)?.timestamp
    }

    private static func normalizedModifiers(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        // Device-independent modifier bits are shared between CGEventFlags and NSEvent.
        MurmurHotkeyCatalog.normalizedModifiers(from: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
    }

    /// Hardware state, read after a tap timeout: events delivered while the tap
    /// was disabled are lost, so ask the HID system whether the hotkey is still held.
    private func isShortcutPhysicallyDown() -> Bool {
        let modifiersDown = Self.normalizedModifiers(from: CGEventSource.flagsState(.hidSystemState))
            .isSuperset(of: shortcut.modifierFlags)
        guard let keyCode = shortcut.keyCode else { return shortcut.hasModifiers && modifiersDown }
        return modifiersDown && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }

    // MARK: - NSEvent fallback

    private func startMonitorFallback() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let swallowed = self.handleKeyDown(
                keyCode: event.keyCode,
                modifiers: MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags),
                isRepeat: event.isARepeat,
                timestamp: event.timestamp
            )
            return swallowed ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyUp(keyCode: event.keyCode) ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(
                keyCode: event.keyCode,
                modifiers: MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags),
                timestamp: event.timestamp
            )
            return event
        } as Any)
    }

    // MARK: - Shared shortcut logic (internal for tests)

    /// - Parameter timestamp: when the event happened (seconds since boot); nil: now.
    func handleFlags(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval? = nil) {
        if shortcut.isModifierOnly {
            if let shortcutKeyCode = shortcut.keyCode,
               keyCode != shortcutKeyCode,
               !isHeld
            {
                return
            }
            let pressed = shortcut.hasModifiers && modifiers.isSuperset(of: shortcut.modifierFlags)
            if pressed && !isHeld {
                guard !paused else { return }
                isHeld = true
                heldSince = timestamp ?? now()
                onPress?()
            } else if !pressed && isHeld {
                endHold(at: timestamp)
            }
            return
        }

        if isHeld && !modifiers.isSuperset(of: shortcut.modifierFlags) {
            isHeld = false
            onRelease?()
        }
    }

    /// Returns true when the event should be consumed (the hotkey, or an Escape
    /// that cancelled something).
    func handleKeyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool, timestamp: TimeInterval? = nil
    ) -> Bool {
        if keyCode == UInt16(kVK_Escape) {
            return handleEscapeDown(modifiers: modifiers, isRepeat: isRepeat)
        }
        if shortcut.isModifierOnly {
            // A real key right after the modifier went down means it was a chord,
            // not a dictation. The key itself always reaches the app.
            // ponytail: keys only — a modifier-click (Cmd-click a link) still
            // records; add mouse-down to the tap mask if that shows up.
            if isHeld, !MurmurHotkeyCatalog.isModifierKeyCode(keyCode) {
                if (timestamp ?? now()) - heldSince < Self.chordWindow {
                    isHeld = false
                    // Unwired receivers still get the hold ended, never a stuck recording.
                    if let onAbort { onAbort() } else { onRelease?() }
                } else {
                    chordedLate = true
                }
            }
            return false
        }
        guard !paused else { return false }
        guard let shortcutKeyCode = shortcut.keyCode, keyCode == shortcutKeyCode else { return false }
        guard modifiers.isSuperset(of: shortcut.modifierFlags) else { return false }
        if isRepeat { return isHeld } // swallow autorepeat of the held hotkey
        guard !isHeld else { return true }

        isHeld = true
        onPress?()
        return true
    }

    /// Returns true when the event was the hotkey release (or a consumed
    /// Escape's key-up) and should be consumed.
    func handleKeyUp(keyCode: UInt16) -> Bool {
        if keyCode == UInt16(kVK_Escape), swallowingEscape {
            swallowingEscape = false
            return true
        }
        guard let shortcutKeyCode = shortcut.keyCode else { return false }
        guard isHeld, keyCode == shortcutKeyCode else { return false }
        isHeld = false
        onRelease?()
        return true
    }

    /// After a tap timeout: the key-up that would have ended a hold may have been
    /// dropped, so release unless the hotkey is still physically down.
    func handleTapReenabled(hotkeyStillDown: Bool) {
        swallowingEscape = false
        guard isHeld, !hotkeyStillDown else { return }
        endHold()
    }

    /// Ends a hold; a short one with a late key (only a modifier-only hold gets
    /// one) was a slow shortcut, not a dictation.
    /// ponytail: hold length only — a quick phrase cut off by Cmd-Tab within
    /// chordedDictationMinimum is dropped; the receiver could check for speech.
    private func endHold(at timestamp: TimeInterval? = nil) {
        isHeld = false
        let slowShortcut = chordedLate && (timestamp ?? now()) - heldSince < Self.chordedDictationMinimum
        chordedLate = false
        // Unwired receivers still get the hold ended, never a stuck recording.
        if slowShortcut, let onAbort { onAbort() } else { onRelease?() }
    }

    private func handleEscapeDown(modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        if isRepeat { return swallowingEscape }
        // Decide before onCancel — the receiver tears its state down asynchronously.
        // Never eat Cmd-Esc / Cmd-Opt-Esc (Force Quit).
        swallowingEscape = !modifiers.contains(.command) && (hasCancellableWork?() ?? false)
        onCancel?()
        return swallowingEscape
    }
}
