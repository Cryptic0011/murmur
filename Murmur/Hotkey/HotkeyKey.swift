import AppKit
import Carbon.HIToolbox

struct HotkeyShortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16?
    var command: Bool
    var control: Bool
    var option: Bool
    var shift: Bool

    init(keyCode: UInt16? = nil, modifiers: NSEvent.ModifierFlags = []) {
        let normalized = MurmurHotkeyCatalog.normalizedModifiers(from: modifiers)
        self.keyCode = keyCode
        self.command = normalized.contains(.command)
        self.control = normalized.contains(.control)
        self.option = normalized.contains(.option)
        self.shift = normalized.contains(.shift)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if control { flags.insert(.control) }
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        return flags
    }

    var isModifierOnly: Bool { keyCode == nil || keyCode.map(MurmurHotkeyCatalog.isModifierKeyCode) == true }
    var hasModifiers: Bool { !modifierFlags.isEmpty }

    static let `default` = HotkeyShortcut(keyCode: UInt16(kVK_RightOption), modifiers: .option)
}

struct MurmurHotkeyOption: Identifiable, Hashable, Sendable {
    let shortcut: HotkeyShortcut
    let label: String
    let symbol: String

    var id: String { label }
}

enum MurmurHotkeyCatalog {
    static let supportedOptions: [MurmurHotkeyOption] = [
        .init(shortcut: HotkeyShortcut(keyCode: UInt16(kVK_RightOption), modifiers: .option), label: "Right Option", symbol: "option"),
        .init(shortcut: HotkeyShortcut(modifiers: .control), label: "Control", symbol: "control"),
        .init(shortcut: HotkeyShortcut(modifiers: .command), label: "Command", symbol: "command"),
        .init(shortcut: HotkeyShortcut(modifiers: .shift), label: "Shift", symbol: "shift"),
    ]

    static func normalizedModifiers(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .control, .option, .shift])
    }

    static func option(for shortcut: HotkeyShortcut) -> MurmurHotkeyOption? {
        supportedOptions.first { $0.shortcut == shortcut }
    }

    static func label(for shortcut: HotkeyShortcut) -> String {
        if let option = option(for: shortcut) {
            return option.label
        }

        let modifierLabels: [String] = [
            shortcut.control ? "Control" : nil,
            shortcut.option ? "Option" : nil,
            shortcut.shift ? "Shift" : nil,
            shortcut.command ? "Command" : nil,
        ].compactMap { $0 }

        let keyLabel = shortcut.keyCode.flatMap(label(forKeyCode:))
        let parts = modifierLabels + [keyLabel].compactMap { $0 }
        return parts.isEmpty ? "Unassigned" : parts.joined(separator: " + ")
    }

    static func label(forKeyCode keyCode: UInt16) -> String? {
        keyLabels[keyCode]
    }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func legacyShortcut(for keyCode: UInt16) -> HotkeyShortcut? {
        switch keyCode {
        case UInt16(kVK_RightOption):
            return HotkeyShortcut(keyCode: UInt16(kVK_RightOption), modifiers: .option)
        case UInt16(kVK_Option):
            return HotkeyShortcut(keyCode: UInt16(kVK_Option), modifiers: .option)
        case UInt16(kVK_RightControl), UInt16(kVK_Control):
            return HotkeyShortcut(keyCode: keyCode, modifiers: .control)
        case UInt16(kVK_RightCommand), UInt16(kVK_Command):
            return HotkeyShortcut(keyCode: keyCode, modifiers: .command)
        case UInt16(kVK_RightShift), UInt16(kVK_Shift):
            return HotkeyShortcut(keyCode: keyCode, modifiers: .shift)
        default:
            return nil
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),
        UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),
        UInt16(kVK_RightShift),
        UInt16(kVK_Option),
        UInt16(kVK_RightOption),
        UInt16(kVK_Control),
        UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),
        UInt16(kVK_Function),
    ]

    private static let keyLabels: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A",
        UInt16(kVK_ANSI_B): "B",
        UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D",
        UInt16(kVK_ANSI_E): "E",
        UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G",
        UInt16(kVK_ANSI_H): "H",
        UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J",
        UInt16(kVK_ANSI_K): "K",
        UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M",
        UInt16(kVK_ANSI_N): "N",
        UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P",
        UInt16(kVK_ANSI_Q): "Q",
        UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S",
        UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V",
        UInt16(kVK_ANSI_W): "W",
        UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y",
        UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0",
        UInt16(kVK_ANSI_1): "1",
        UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4",
        UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6",
        UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_ANSI_Minus): "-",
        UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "Return",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Forward Delete",
        UInt16(kVK_Escape): "Escape",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_LeftArrow): "Left Arrow",
        UInt16(kVK_RightArrow): "Right Arrow",
        UInt16(kVK_UpArrow): "Up Arrow",
        UInt16(kVK_DownArrow): "Down Arrow",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13",
        UInt16(kVK_F14): "F14",
        UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17",
        UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19",
        UInt16(kVK_F20): "F20",
    ]
}
