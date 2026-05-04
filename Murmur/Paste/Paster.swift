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
        let murmurPasteboardChange = pb.changeCount

        guard let target = focusedEditableTarget() else {
            log.info("Paste fallback to clipboard: no editable focused element")
            return .copiedOnly("Copied to clipboard — no editable field was focused")
        }

        sendCmdV()
        log.info("Paste injected into focused element: \(target.description, privacy: .public)")

        try? await Task.sleep(nanoseconds: restoreDelay)
        guard pasteWasConfirmed(into: target, insertedText: text) else {
            log.info("Paste could not be confirmed; leaving dictated text on clipboard")
            return .copiedOnly("Paste attempted — text remains on clipboard for manual paste")
        }

        if pb.changeCount == murmurPasteboardChange {
            pb.clearContents()
            let restored: [NSPasteboardItem] = priorContents.map { dict in
                let it = NSPasteboardItem()
                for (type, data) in dict { it.setData(data, forType: type) }
                return it
            }
            if !restored.isEmpty { pb.writeObjects(restored) }
        }
        return .pasted(target.description)
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

    private struct PasteTarget {
        let element: AXUIElement
        let description: String
        let valueBeforePaste: String?
    }

    private func focusedEditableTarget() -> PasteTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard let editable = findEditableElement(startingAt: element, maxDepth: 4) else { return nil }
        let role = stringAttribute(kAXRoleAttribute, of: editable) ?? "Unknown"
        let subrole = stringAttribute(kAXSubroleAttribute, of: editable)
        let description: String
        if let subrole, !subrole.isEmpty {
            description = "\(role) • \(subrole)"
        } else {
            description = role
        }
        return PasteTarget(
            element: editable,
            description: description,
            valueBeforePaste: stringAttribute(kAXValueAttribute, of: editable)
        )
    }

    private func findEditableElement(startingAt element: AXUIElement, maxDepth: Int) -> AXUIElement? {
        let role = stringAttribute(kAXRoleAttribute, of: element) ?? "Unknown"
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        if isEditable(element, role: role, subrole: subrole) {
            return element
        }
        guard maxDepth > 0 else { return nil }

        let childAttributes = [
            kAXFocusedUIElementAttribute as String,
            kAXSelectedChildrenAttribute as String,
            kAXChildrenAttribute as String,
            "AXContents",
        ]
        for attribute in childAttributes {
            for child in elementsAttribute(attribute, of: element) {
                if let editable = findEditableElement(startingAt: child, maxDepth: maxDepth - 1) {
                    return editable
                }
            }
        }
        return nil
    }

    private func isEditable(_ element: AXUIElement, role: String, subrole: String?) -> Bool {
        if boolAttribute("AXProtectedContent", of: element) == true { return false }
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

    private func pasteWasConfirmed(into target: PasteTarget, insertedText text: String) -> Bool {
        guard let valueBeforePaste = target.valueBeforePaste,
              let valueAfterPaste = stringAttribute(kAXValueAttribute, of: target.element)
        else { return false }
        guard valueAfterPaste != valueBeforePaste else { return false }
        return valueAfterPaste.contains(text) || valueAfterPaste.count >= valueBeforePaste.count + min(text.count, 1)
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

    private func elementsAttribute(_ name: String, of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return [] }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }
        if let elements = value as? [AXUIElement] { return elements }
        if let objects = value as? [AnyObject] {
            return objects.compactMap { object in
                guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
                return object as! AXUIElement
            }
        }
        return []
    }
}
