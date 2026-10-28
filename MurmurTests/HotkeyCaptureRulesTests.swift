import AppKit
import Carbon.HIToolbox
import Testing
@testable import Murmur

@Suite("Hotkey capture rules")
struct HotkeyCaptureRulesTests {
    private func reason(_ key: Int, _ modifiers: NSEvent.ModifierFlags) -> String? {
        HotkeyCaptureRules.rejectionReason(for: HotkeyShortcut(keyCode: UInt16(key), modifiers: modifiers))
    }

    @Test("core edit, app and window commands are refused")
    func systemCommands() {
        #expect(reason(kVK_ANSI_V, .command) != nil)
        #expect(reason(kVK_ANSI_C, .command) != nil)
        #expect(reason(kVK_ANSI_X, .command) != nil)
        #expect(reason(kVK_ANSI_Z, [.command, .shift]) != nil)
        #expect(reason(kVK_ANSI_Q, .command) != nil)
        #expect(reason(kVK_ANSI_W, .command) != nil)
        #expect(reason(kVK_Tab, .command) != nil)
        #expect(reason(kVK_Space, .command) != nil)
        #expect(reason(kVK_ANSI_4, [.command, .shift]) != nil)
        #expect(reason(kVK_Space, .control) != nil)              // input source
        #expect(reason(kVK_Space, [.control, .command]) != nil)  // emoji picker
        #expect(reason(kVK_Space, [.option, .command]) != nil)   // Finder search
        #expect(reason(kVK_Tab, .control) != nil)
        #expect(reason(kVK_ANSI_Q, [.control, .command]) != nil) // lock screen
    }

    @Test("shift or option plus a key would type text")
    func typingKeys() {
        #expect(reason(kVK_ANSI_A, .shift) != nil)
        #expect(reason(kVK_ANSI_E, .option) != nil)
        #expect(reason(kVK_Space, .option) != nil)
        #expect(reason(kVK_Return, .shift) != nil)
        #expect(reason(kVK_LeftArrow, .option) != nil)
    }

    @Test("free combinations are accepted")
    func allowed() {
        #expect(reason(kVK_Space, [.control, .option]) == nil)
        #expect(reason(kVK_ANSI_D, [.command, .shift]) == nil)
        #expect(reason(kVK_ANSI_J, .command) == nil)
        #expect(reason(kVK_ANSI_M, [.control, .option]) == nil)
        #expect(reason(kVK_F5, .option) == nil)
        #expect(reason(kVK_F13, .shift) == nil)
    }

    @Test("modifier-only shortcuts are not judged here")
    func modifierOnly() {
        #expect(HotkeyCaptureRules.rejectionReason(for: HotkeyShortcut(modifiers: .command)) == nil)
        #expect(HotkeyCaptureRules.rejectionReason(for: .default) == nil)
    }
}
