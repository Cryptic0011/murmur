import AppKit
import ApplicationServices
import AVFoundation

enum AccessibilityHelper {
    static func hasAccess(prompt: Bool = false) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}

/// Permission buttons that always lead somewhere. Once access was denied (or the
/// Accessibility prompt was already shown once), macOS shows no dialog again and
/// the request silently returns — so fall back to the right System Settings pane.
@MainActor
enum PermissionHelper {
    static func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in AppServices.runtimeHealth.refreshNow() }
            }
        case .authorized:
            AppServices.runtimeHealth.refreshNow()
        default:
            openPrivacyPane("Privacy_Microphone")
        }
    }

    static func requestAccessibility() {
        guard !AccessibilityHelper.hasAccess(prompt: true) else {
            AppServices.runtimeHealth.refreshNow()
            return
        }
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
