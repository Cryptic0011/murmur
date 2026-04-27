import SwiftUI
import Combine

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var stage: DictationStage = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0

    private var timer: Timer?
    private var startTime: Date?

    func update(_ stage: DictationStage) {
        self.stage = stage
        switch stage {
        case .recording:
            startTime = Date()
            elapsed = 0
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
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if case .recording = self.stage { return } // overtaken
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
