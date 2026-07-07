import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Escape pressed anywhere — fired unconditionally; the receiver decides
    /// whether anything (recording, transcription) is active to cancel.
    var onCancel: (() -> Void)?
    /// When paused, events pass through untouched and nothing fires.
    var paused = false

    // Primary path: CGEventTap — can consume the hotkey keystroke so it never
    // leaks into the focused app. Requires Accessibility.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Fallback path: NSEvent monitors — observe-only (keystroke leaks), used
    // until Accessibility is granted.
    private var monitors: [Any] = []

    private var isHeld = false
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
            // The key-up that would have ended a hold was never delivered.
            if isHeld {
                isHeld = false
                onRelease?()
            }
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                if !CGEvent.tapIsEnabled(tap: eventTap) {
                    // Re-enable failed — Accessibility was likely revoked. Drop to
                    // the observe-only fallback instead of going silently dead.
                    // Deferred: don't tear down the tap from inside its own callback.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.stop()
                        self.startMonitorFallback()
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            handleFlags(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: Self.normalizedModifiers(from: event.flags)
            )
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == UInt16(kVK_Escape) {
                onCancel?()
                return Unmanaged.passUnretained(event)
            }
            let swallow = handleKeyDown(
                keyCode: keyCode,
                modifiers: Self.normalizedModifiers(from: event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
            return swallow ? nil : Unmanaged.passUnretained(event)
        case .keyUp:
            let swallow = handleKeyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            return swallow ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static func normalizedModifiers(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        // Device-independent modifier bits are shared between CGEventFlags and NSEvent.
        MurmurHotkeyCatalog.normalizedModifiers(from: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
    }

    // MARK: - NSEvent fallback

    private func startMonitorFallback() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.fallbackKeyDown(event)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: { [weak self] event in
            _ = self?.handleKeyUp(keyCode: event.keyCode)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(
                keyCode: event.keyCode,
                modifiers: MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags)
            )
        }) { monitors.append(m) }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.onCancel?()
                return event
            }
            let swallowed = self.handleKeyDown(
                keyCode: event.keyCode,
                modifiers: MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags),
                isRepeat: event.isARepeat
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
                modifiers: MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags)
            )
            return event
        } as Any)
    }

    private func fallbackKeyDown(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        _ = handleKeyDown(
            keyCode: event.keyCode,
            modifiers: MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags),
            isRepeat: event.isARepeat
        )
    }

    // MARK: - Shared shortcut logic

    private func handleFlags(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
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
                onPress?()
            } else if !pressed && isHeld {
                isHeld = false
                onRelease?()
            }
            return
        }

        if isHeld && !modifiers.isSuperset(of: shortcut.modifierFlags) {
            isHeld = false
            onRelease?()
        }
    }

    /// Returns true when the event was the hotkey and should be consumed.
    private func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard !paused else { return false }
        guard let shortcutKeyCode = shortcut.keyCode, keyCode == shortcutKeyCode else { return false }
        guard modifiers.isSuperset(of: shortcut.modifierFlags) else { return false }
        if isRepeat { return isHeld } // swallow autorepeat of the held hotkey
        guard !isHeld else { return true }

        isHeld = true
        onPress?()
        return true
    }

    /// Returns true when the event was the hotkey release and should be consumed.
    private func handleKeyUp(keyCode: UInt16) -> Bool {
        guard let shortcutKeyCode = shortcut.keyCode else { return false }
        guard isHeld, keyCode == shortcutKeyCode else { return false }
        isHeld = false
        onRelease?()
        return true
    }
}
