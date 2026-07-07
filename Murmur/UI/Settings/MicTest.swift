import SwiftUI

/// Shared microphone-test loop used by GeneralTab and TryMurmurTab.
@MainActor
final class MicTestController: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false

    private let recorder = AudioRecorder()
    private var task: Task<Void, Never>?

    func toggle(preferredDeviceUID: String?) {
        isRunning ? stop() : start(preferredDeviceUID: preferredDeviceUID)
    }

    func start(preferredDeviceUID: String?) {
        stop()
        error = nil
        level = 0
        isRunning = true

        let recorder = recorder
        task = Task { @MainActor in
            do {
                try await recorder.start(maxSeconds: 30, preferredDeviceUID: preferredDeviceUID)
                while !Task.isCancelled {
                    level = await recorder.currentLevel()
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch {
                self.error = "Could not start microphone test: \(error.localizedDescription)"
            }
            _ = await recorder.stop()
            level = 0
            isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let recorder = recorder
        Task { @MainActor [weak self] in
            _ = await recorder.stop()
            self?.level = 0
            self?.isRunning = false
        }
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool
    var width: CGFloat = 180

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.08))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(active ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: max(8, proxy.size.width * CGFloat(min(max(level, 0), 1))))
            }
        }
        .frame(width: width, height: 10)
        .accessibilityLabel("Microphone input level")
    }
}
