import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)? // Escape during recording

    private var globalKeyMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    private var localKeyMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var isHeld = false
    private var shortcut: HotkeyShortcut = .default

    func configure(shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
    }

    func start() {
        stop()

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
            return event
        }
    }

    func stop() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = globalKeyUpMonitor { NSEvent.removeMonitor(m); globalKeyUpMonitor = nil }
        if let m = globalModifierMonitor { NSEvent.removeMonitor(m); globalModifierMonitor = nil }
        if let m = localModifierMonitor { NSEvent.removeMonitor(m); localModifierMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = localKeyUpMonitor { NSEvent.removeMonitor(m); localKeyUpMonitor = nil }
        isHeld = false
    }

    private func handleFlags(_ event: NSEvent) {
        let modifiers = MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags)

        if shortcut.isModifierOnly {
            if let keyCode = shortcut.keyCode,
               event.keyCode != keyCode,
               !isHeld
            {
                return
            }
            let pressed = shortcut.hasModifiers && modifiers.isSuperset(of: shortcut.modifierFlags)
            if pressed && !isHeld {
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

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            handleEscape()
            return
        }

        guard let keyCode = shortcut.keyCode else { return }
        let modifiers = MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags)
        guard event.keyCode == keyCode else { return }
        guard modifiers.isSuperset(of: shortcut.modifierFlags) else { return }
        guard !isHeld else { return }

        isHeld = true
        onPress?()
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard let keyCode = shortcut.keyCode else { return }
        guard isHeld, event.keyCode == keyCode else { return }
        isHeld = false
        onRelease?()
    }

    private func handleEscape() {
        guard isHeld else { return }
        isHeld = false
        onCancel?()
    }
}
