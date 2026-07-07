import SwiftUI
import Combine

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var stage: DictationStage = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    /// Confirmed transcript-so-far from streaming chunks, shown live while recording.
    @Published var partialText: String = ""

    private var timer: Timer?
    private var startTime: Date?
    /// Invalidates any pending auto-dismiss when a newer stage arrives — otherwise
    /// a result's 1.5s dismissal fires mid-way through the next dictation.
    private var dismissGeneration = 0

    func update(_ stage: DictationStage) {
        self.stage = stage
        dismissGeneration += 1
        switch stage {
        case .recording:
            startTime = Date()
            elapsed = 0
            partialText = ""
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startTime else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
        case .pasted, .copiedOnly, .error:
            timer?.invalidate(); timer = nil
            startTime = nil
            let generation = dismissGeneration
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard generation == self.dismissGeneration else { return } // overtaken
                self.stage = .idle
            }
        case .idle, .loadingModel, .transcribing, .cleaning:
            timer?.invalidate(); timer = nil
            startTime = nil
        }
    }

    var isVisible: Bool {
        if case .idle = stage { return false } else { return true }
    }
}
