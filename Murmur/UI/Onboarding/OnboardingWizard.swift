import AppKit
import AVFoundation
import SwiftUI

/// First-launch wizard: permissions → cleanup choice → try it.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let settings: SettingsStore
    private let onFinish: () -> Void

    init(settings: SettingsStore, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.onFinish = onFinish
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            settings: settings,
            runtimeHealth: AppServices.runtimeHealth,
            finish: { [weak self] in self?.window?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Murmur"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 540))
        window.center()
        window.delegate = closeDelegate
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing with ⌘W or the close button still completes onboarding —
    // re-showing the wizard every launch would punish skipping it.
    private lazy var closeDelegate = CloseDelegate { [weak self] in
        self?.window = nil
        self?.onFinish()
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}

private struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    let finish: () -> Void

    @State private var step = 0
    @State private var chosePrivate = true
    @State private var groqKey = ""
    @State private var hasSavedGroqKey = false
    @State private var groqKeyError: String?

    /// Groq cleanup without a key fails every dictation, so step 2 collects one.
    private var needsGroqKey: Bool {
        !chosePrivate && !hasSavedGroqKey && groqKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: permissionsStep
                case 1: cleanupStep
                default: tryItStep
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 540, height: 540)
        .onAppear { runtimeHealth.refreshNow() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(["Welcome to Murmur", "Choose your cleanup", "You're ready"][min(step, 2)])
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(["Speak anywhere your cursor is — Murmur types clean text for you.",
                  "After transcribing, an AI pass fixes punctuation and filler words.",
                  "That's the whole setup. Here's how to dictate."][min(step, 2)])
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    // MARK: Step 1 — permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Murmur needs two permissions. Your voice is processed on this Mac unless you pick a cloud provider.")
                .font(.system(size: 13, weight: .medium, design: .rounded))

            permissionRow(
                title: "Microphone",
                detail: "To hear your dictation.",
                granted: runtimeHealth.snapshot.microphoneGranted
            ) {
                PermissionHelper.requestMicrophone()
            }

            permissionRow(
                title: "Accessibility",
                detail: "To paste the finished text where you're typing.",
                granted: runtimeHealth.snapshot.accessibilityGranted
            ) {
                PermissionHelper.requestAccessibility()
            }

            if !runtimeHealth.snapshot.accessibilityGranted {
                Text("Murmur opens Accessibility in System Settings → Privacy & Security. Flip the switch next to Murmur, then come back — no restart needed. Already on but not detected? Remove Murmur from the list with −, then add it again.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Grants land while System Settings is frontmost; RuntimeHealthStore's own
        // 1.5 s permission poll flips the checkmarks. A second loop calling
        // refreshNow() here reset its Ollama probe throttle every second.
    }

    private func permissionRow(
        title: String, detail: String, granted: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Grant \(title) access")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.murmurRowFill))
        .accessibilityElement(children: .contain)
    }

    // MARK: Step 2 — cleanup choice

    private var cleanupStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            choiceCard(
                selected: chosePrivate,
                title: "Private — on this Mac",
                badge: "Recommended",
                detail: CleanupProviderOption.appleIntelligenceUsable
                    ? "Uses Apple Intelligence. Nothing to install, nothing leaves your Mac."
                    : "Uses the free Ollama app — install it from ollama.com, and Murmur downloads a small model automatically."
            ) { chosePrivate = true }

            choiceCard(
                selected: !chosePrivate,
                title: "Fast — Groq cloud",
                badge: nil,
                detail: "Snappier cleanup via Groq's free API. Needs a free key from console.groq.com."
            ) { chosePrivate = false }

            if !chosePrivate {
                groqKeyField
            }

            Text("Short dictations are cleaned instantly on-device either way, and you can change this anytime in Settings → Providers.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            hasSavedGroqKey = !((try? KeychainStore.groqAPIKey.get()) ?? "").isEmpty
        }
    }

    private var groqKeyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(hasSavedGroqKey ? "Groq key saved — paste to replace" : "Paste your Groq API key", text: $groqKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Groq API key")
                Button("Get a Free Key") { AppServices.setup.openGroqKeys() }
            }
            if let groqKeyError {
                Text(groqKeyError)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
            } else if needsGroqKey {
                Text("Paste a key to continue, or choose Private.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Saves a pasted key (trimmed — console copies often carry a newline).
    /// Returns false when the Keychain write failed and onboarding must not advance.
    private func saveGroqKey() -> Bool {
        let trimmed = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hasSavedGroqKey }
        do {
            try KeychainStore.groqAPIKey.set(trimmed)
            AppServices.apiKeys.reload() // a replaced key must not stay cached
            hasSavedGroqKey = true
            groqKeyError = nil
            return true
        } catch {
            groqKeyError = "Couldn't save the key to Keychain: \(error.localizedDescription)"
            return false
        }
    }

    private func choiceCard(
        selected: Bool, title: String, badge: String?, detail: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.murmurRowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Step 3 — try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Label(runtimeHealth.snapshot.hotkeyLabel, systemImage: "keyboard")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.murmurRowFill))
                Text(settings.toggleMode
                     ? "Tap to start, speak, tap again to paste."
                     : "Hold it down, speak, release to paste.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }

            VStack(alignment: .leading, spacing: 8) {
                tipRow(symbol: "1.circle.fill", text: "Click into any text field — Notes, Mail, a browser.")
                tipRow(symbol: "2.circle.fill", text: "Use the hotkey and just talk. Fillers like “um” are removed for you.")
                tipRow(symbol: "3.circle.fill", text: "Your cleaned words appear where the cursor is.")
            }

            Text("Prefer a dry run first? Finish opens a test area where you can dictate without pasting anywhere.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func tipRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            Text("\(step + 1) of 3")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Button(step == 2 ? "Finish" : "Continue") {
                if step == 1 {
                    // Key first: the provider write rebuilds the pipeline, which reads it.
                    if !chosePrivate, !saveGroqKey() { return }
                    settings.primaryCleanupProvider = chosePrivate
                        ? (CleanupProviderOption.appleIntelligenceUsable ? .appleFoundationModels : .ollamaLocal)
                        : .groqAPI
                }
                if step == 2 {
                    finish()
                } else {
                    step += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(step == 1 && needsGroqKey)
        }
        .padding(20)
    }
}
