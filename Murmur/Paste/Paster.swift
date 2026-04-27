import AppKit
import ApplicationServices
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

        static func pasted(_ detail: String = "Pasted into focused field") -> PasteOutcome {
            .init(kind: .pasted, detail: detail)
        }

        static func copiedOnly(_ detail: String) -> PasteOutcome {
            .init(kind: .copiedOnly, detail: detail)
        }
    }

    private let restoreDelay: UInt64 = 200_000_000 // 200ms
    private let log = Logger(subsystem: "com.murmur.app", category: "paste")

    func paste(_ text: String) async -> PasteOutcome {
        let pb = NSPasteboard.general
        let priorChange = pb.changeCount
        let priorContents = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { dict[type] = d }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("Murmur", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])

        guard let target = focusedEditableElementDescription() else {
            log.info("Paste fallback to clipboard: no editable focused element")
            return .copiedOnly("Copied to clipboard — no editable field was focused")
        }

        sendCmdV()
        log.info("Paste injected into focused element: \(target, privacy: .public)")

        try? await Task.sleep(nanoseconds: restoreDelay)
        if pb.changeCount == priorChange + 1 {
            pb.clearContents()
            let restored: [NSPasteboardItem] = priorContents.map { dict in
                let it = NSPasteboardItem()
                for (type, data) in dict { it.setData(data, forType: type) }
                return it
            }
            if !restored.isEmpty { pb.writeObjects(restored) }
        }
        return .pasted(target)
    }

    private func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func focusedEditableElementDescription() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute, of: element) ?? "Unknown"
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        guard isEditable(element, role: role, subrole: subrole) else { return nil }
        if let subrole, !subrole.isEmpty {
            return "\(role) • \(subrole)"
        }
        return role
    }

    private func isEditable(_ element: AXUIElement, role: String, subrole: String?) -> Bool {
        let directRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextView"]
        if directRoles.contains(role) { return true }
        if subrole == "AXContentEditable" || subrole == "AXTextField" { return true }
        if boolAttribute("AXEditable", of: element) == true { return true }
        if role == "AXWebArea" || role == "AXGroup" {
            if boolAttribute(kAXFocusedAttribute, of: element) == true,
               boolAttribute(kAXEnabledAttribute, of: element) != false {
                return subrole == "AXContentEditable" || boolAttribute("AXEditable", of: element) == true
            }
        }
        return false
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
}
