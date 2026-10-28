import SwiftUI

/// Shared microphone-test loop used by GeneralTab and TryMurmurTab.
@MainActor
final class MicTestController: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false

    private let recorder = AudioRecorder()
    private var task: Task<Void, Never>?
    /// Bumped by every start()/stop(); a test task only touches state while it's current.
    private var generation = 0

    func toggle(preferredDeviceUID: String?, avoidBluetoothInput: Bool = false) {
        isRunning ? stop() : start(preferredDeviceUID: preferredDeviceUID, avoidBluetoothInput: avoidBluetoothInput)
    }

    func start(preferredDeviceUID: String?, avoidBluetoothInput: Bool = false) {
        task?.cancel()
        generation &+= 1
        let generation = generation
        error = nil
        level = 0
        isRunning = true

        let recorder = recorder
        // The task is the only owner of recorder.stop: its session token keeps a late
        // stop from ending the test that replaced it.
        task = Task { @MainActor [weak self] in
            var session: AudioRecorder.Session?
            do {
                session = try await recorder.start(
                    maxSeconds: 0,
                    preferredDeviceUID: preferredDeviceUID,
                    avoidBluetoothInput: avoidBluetoothInput,
                    meterOnly: true
                )
                while !Task.isCancelled {
                    guard await recorder.isCapturing() else {
                        self?.fail("Microphone stopped delivering audio.", generation: generation)
                        break
                    }
                    let level = await recorder.currentLevel()
                    guard let self, self.generation == generation else { break }
                    self.level = level
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch {
                self?.fail("Could not start microphone test: \(error.localizedDescription)", generation: generation)
            }
            if let session { _ = await recorder.stop(session: session) }
            guard let self, self.generation == generation else { return }
            self.isRunning = false
            self.level = 0
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        isRunning = false
        level = 0
    }

    private func fail(_ message: String, generation: Int) {
        guard self.generation == generation else { return }
        error = message
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
        .accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
    }
}
