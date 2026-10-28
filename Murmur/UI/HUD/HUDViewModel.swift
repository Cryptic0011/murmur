import AppKit
import SwiftUI
import Combine

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var stage: DictationStage = .idle
    @Published var level: Float = 0
    /// Confirmed transcript-so-far from streaming chunks, shown live while recording.
    @Published var partialText: String = ""
    /// Show the HUD even with "Show HUD" off: a murmur:// session must always be visible.
    @Published private(set) var forcesVisible = false

    /// The dictation the HUD follows. Stages tagged with any other session are dropped,
    /// so an earlier dictation finishing can't replace (or hide) a newer recording.
    private(set) var session: UUID?
    /// Invalidates any pending auto-dismiss when a newer stage arrives — otherwise
    /// a result's dismissal fires mid-way through the next dictation.
    private var dismissGeneration = 0

    /// Shows `stage` — unless it is tagged with a session the HUD isn't following.
    func update(_ stage: DictationStage, session: UUID? = nil) {
        if let session, session != self.session { return }
        show(stage)
    }

    /// Follows `session` from now on (a new recording, a retry, or an earlier dictation
    /// still processing after the newest one was discarded) and shows `stage` for it.
    func follow(_ session: UUID?, showing stage: DictationStage, forcesVisible: Bool = false) {
        self.session = session
        self.forcesVisible = forcesVisible
        show(stage)
    }

    private func show(_ stage: DictationStage) {
        self.stage = stage
        dismissGeneration += 1
        let lingers: UInt64
        switch stage {
        case .recording:
            partialText = ""
            announce("Recording")
            return
        case .pasted(let words, let note):
            announce("Pasted \(words) word\(words == 1 ? "" : "s")" + (note.map { ". \($0)" } ?? ""))
            lingers = note == nil ? 1_500_000_000 : 3_000_000_000
        case .copiedOnly(let message), .error(let message):
            announce(message)
            lingers = 3_000_000_000 // long enough to read a two-line message
        case .idle, .loadingModel, .transcribing, .cleaning:
            return
        }
        let generation = dismissGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: lingers)
            guard generation == self.dismissGeneration else { return } // overtaken
            self.forcesVisible = false
            self.stage = .idle
        }
    }

    /// VoiceOver users can't see the HUD; speak the moments that matter.
    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    var isVisible: Bool {
        if case .idle = stage { return false } else { return true }
    }
}
