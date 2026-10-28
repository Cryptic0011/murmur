import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Murmur

@MainActor
private final class HotkeyEvents {
    var log: [String] = []
    var cancellable = false

    func attach(to monitor: HotkeyMonitor) {
        monitor.onPress = { [unowned self] in log.append("press") }
        monitor.onRelease = { [unowned self] in log.append("release") }
        monitor.onAbort = { [unowned self] in log.append("abort") }
        monitor.onCancel = { [unowned self] in log.append("cancel") }
        monitor.hasCancellableWork = { [unowned self] in cancellable }
    }
}

@Suite("Hotkey state machine")
@MainActor
struct HotkeyStateTests {
    private let rightOption = UInt16(kVK_RightOption)
    private let leftOption = UInt16(kVK_Option)
    private let escape = UInt16(kVK_Escape)
    private let keyL = UInt16(kVK_ANSI_L)
    private let space = UInt16(kVK_Space)

    private func monitor(_ shortcut: HotkeyShortcut = .default) -> (HotkeyMonitor, HotkeyEvents) {
        let monitor = HotkeyMonitor()
        monitor.configure(shortcut: shortcut)
        let events = HotkeyEvents()
        events.attach(to: monitor)
        return (monitor, events)
    }

    @Test("modifier-only hotkey: press and release")
    func modifierPressRelease() {
        let (m, e) = monitor()
        m.handleFlags(keyCode: rightOption, modifiers: .option)
        m.handleFlags(keyCode: rightOption, modifiers: [])
        #expect(e.log == ["press", "release"])
    }

    @Test("the other side of the modifier does not trigger")
    func otherSideIgnored() {
        let (m, e) = monitor()
        m.handleFlags(keyCode: leftOption, modifiers: .option)
        m.handleFlags(keyCode: leftOption, modifiers: [])
        #expect(e.log.isEmpty)
    }

    @Test("a key pressed while the modifier is held aborts silently and passes through")
    func chordAborts() {
        let (m, e) = monitor()
        m.handleFlags(keyCode: rightOption, modifiers: .option)
        let swallowed = m.handleKeyDown(keyCode: keyL, modifiers: .option, isRepeat: false)
        _ = m.handleKeyDown(keyCode: keyL, modifiers: .option, isRepeat: false)
        m.handleFlags(keyCode: rightOption, modifiers: [])
        #expect(swallowed == false)
        #expect(e.log == ["press", "abort"])
    }

    @Test("a key pressed well into a hold leaves the dictation running")
    func lateKeyKeepsHold() {
        let (m, e) = monitor()
        var clock: TimeInterval = 100
        m.now = { clock }
        m.handleFlags(keyCode: rightOption, modifiers: .option)
        clock += 2
        #expect(m.handleKeyDown(keyCode: keyL, modifiers: .option, isRepeat: false) == false)
        m.handleFlags(keyCode: rightOption, modifiers: [])
        #expect(e.log == ["press", "release"])
    }

    @Test("chords are timed by event time, and a late key ends only a short hold as a chord")
    func chordTiming() {
        let (m, e) = monitor()
        m.now = { 500 } // the main thread is running late: long past every event below
        // A fast chord whose key-down waited in the queue.
        m.handleFlags(keyCode: rightOption, modifiers: .option, timestamp: 100)
        _ = m.handleKeyDown(keyCode: keyL, modifiers: .option, isRepeat: false, timestamp: 100.3)
        m.handleFlags(keyCode: rightOption, modifiers: [], timestamp: 100.5)
        // A slow shortcut: the key after the window, released soon after.
        m.handleFlags(keyCode: rightOption, modifiers: .option, timestamp: 101)
        _ = m.handleKeyDown(keyCode: keyL, modifiers: .option, isRepeat: false, timestamp: 101.8)
        m.handleFlags(keyCode: rightOption, modifiers: [], timestamp: 102)
        // A key mid-dictation: the dictation goes on.
        m.handleFlags(keyCode: rightOption, modifiers: .option, timestamp: 103)
        _ = m.handleKeyDown(keyCode: keyL, modifiers: .option, isRepeat: false, timestamp: 104)
        m.handleFlags(keyCode: rightOption, modifiers: [], timestamp: 106)
        #expect(e.log == ["press", "abort", "press", "abort", "press", "release"])
    }

    @Test("typing without the hotkey held does nothing")
    func typingIgnored() {
        let (m, e) = monitor()
        #expect(m.handleKeyDown(keyCode: keyL, modifiers: [], isRepeat: false) == false)
        #expect(m.handleKeyUp(keyCode: keyL) == false)
        #expect(e.log.isEmpty)
    }

    @Test("paused blocks the press")
    func pausedBlocksPress() {
        let (m, e) = monitor()
        m.paused = true
        m.handleFlags(keyCode: rightOption, modifiers: .option)
        m.handleFlags(keyCode: rightOption, modifiers: [])
        #expect(e.log.isEmpty)
    }

    @Test("key shortcut: swallows press, autorepeat and release")
    func keyShortcut() {
        let (m, e) = monitor(HotkeyShortcut(keyCode: space, modifiers: [.control, .option]))
        #expect(m.handleKeyDown(keyCode: space, modifiers: [.control, .option], isRepeat: false))
        #expect(m.handleKeyDown(keyCode: space, modifiers: [.control, .option], isRepeat: true))
        #expect(m.handleKeyUp(keyCode: space))
        #expect(e.log == ["press", "release"])
    }

    @Test("key shortcut: lifting a modifier before the key ends the hold")
    func modifierLiftedFirst() {
        let (m, e) = monitor(HotkeyShortcut(keyCode: space, modifiers: [.control, .option]))
        _ = m.handleKeyDown(keyCode: space, modifiers: [.control, .option], isRepeat: false)
        m.handleFlags(keyCode: UInt16(kVK_Control), modifiers: .option)
        #expect(m.handleKeyUp(keyCode: space) == false)
        #expect(e.log == ["press", "release"])
    }

    @Test("Escape is consumed, with its repeats and key-up, only while work is active")
    func escapeSwallowedWhenActive() {
        let (m, e) = monitor()
        e.cancellable = true
        #expect(m.handleKeyDown(keyCode: escape, modifiers: [], isRepeat: false))
        #expect(m.handleKeyDown(keyCode: escape, modifiers: [], isRepeat: true))
        #expect(m.handleKeyUp(keyCode: escape))
        e.cancellable = false
        #expect(m.handleKeyDown(keyCode: escape, modifiers: [], isRepeat: false) == false)
        #expect(m.handleKeyUp(keyCode: escape) == false)
        #expect(e.log == ["cancel", "cancel"])
    }

    @Test("Cmd-Escape is never consumed")
    func commandEscapePassesThrough() {
        let (m, e) = monitor()
        e.cancellable = true
        #expect(m.handleKeyDown(keyCode: escape, modifiers: [.command, .option], isRepeat: false) == false)
        #expect(m.handleKeyUp(keyCode: escape) == false)
    }

    @Test("tap timeout releases only when the hotkey is physically up")
    func tapTimeout() {
        let (m, e) = monitor()
        m.handleFlags(keyCode: rightOption, modifiers: .option)
        m.handleTapReenabled(hotkeyStillDown: true)
        #expect(e.log == ["press"])
        m.handleTapReenabled(hotkeyStillDown: false)
        #expect(e.log == ["press", "release"])
    }

    @Test("saved side-agnostic presets stay side-agnostic and fire on either key")
    func legacySideAgnosticDecode() throws {
        func decode(_ json: String) throws -> HotkeyShortcut {
            try JSONDecoder().decode(HotkeyShortcut.self, from: Data(json.utf8))
        }
        let command = try decode(#"{"command":true,"control":false,"option":false,"shift":false}"#)
        let control = try decode(#"{"command":false,"control":true,"option":false,"shift":false}"#)
        let shift = try decode(#"{"command":false,"control":false,"option":false,"shift":true}"#)
        #expect(command == HotkeyShortcut(modifiers: .command))
        #expect(control == HotkeyShortcut(modifiers: .control))
        #expect(shift == HotkeyShortcut(modifiers: .shift))
        #expect(MurmurHotkeyCatalog.label(for: command) == "Command")

        let (m, e) = monitor(command)
        m.handleFlags(keyCode: UInt16(kVK_Command), modifiers: .command)
        m.handleFlags(keyCode: UInt16(kVK_Command), modifiers: [])
        #expect(e.log == ["press", "release"])
    }

    @Test("custom shortcuts round-trip unchanged")
    func customRoundTrip() throws {
        let custom = HotkeyShortcut(keyCode: space, modifiers: [.control, .option])
        let decoded = try JSONDecoder().decode(HotkeyShortcut.self, from: JSONEncoder().encode(custom))
        #expect(decoded == custom)
        let multi = HotkeyShortcut(modifiers: [.control, .option])
        let decodedMulti = try JSONDecoder().decode(HotkeyShortcut.self, from: JSONEncoder().encode(multi))
        #expect(decodedMulti == multi)
    }

    @Test("every preset is side-specific")
    func presetsAreSideSpecific() {
        #expect(MurmurHotkeyCatalog.supportedOptions.allSatisfy { $0.shortcut.keyCode != nil })
    }
}
