import SwiftUI

struct HUDView: View {
    @ObservedObject var vm: HUDViewModel

    var body: some View {
        ZStack {
            content
        }
            .frame(width: width, height: 36)
            .background(Color.black, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 6)
            .animation(.easeInOut(duration: 0.18), value: stageKey)
    }

    private var width: CGFloat {
        switch vm.stage {
        case .idle: return 0
        case .recording: return 140
        case .loadingModel: return 280
        case .transcribing: return 150
        case .cleaning: return 170
        case .pasted: return 150
        case .copiedOnly(let message): return max(220, min(340, CGFloat(message.count * 6)))
        case .error: return 240
        }
    }

    private var stageKey: String {
        switch vm.stage {
        case .idle: return "idle"
        case .recording: return "rec"
        case .loadingModel: return "load"
        case .transcribing: return "stt"
        case .cleaning(let p): return "clean-\(p)"
        case .pasted: return "pasted"
        case .copiedOnly(let message): return "copied-\(message)"
        case .error: return "error"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.stage {
        case .idle:
            EmptyView()
        case .recording:
            Waveform(level: vm.level)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(height: 18)
                .padding(.horizontal, 22)
        case .loadingModel:
            inlineLabel(spinner: true, text: "Downloading model…")
        case .transcribing:
            inlineLabel(spinner: true, text: "Transcribing")
        case .cleaning(let p):
            inlineLabel(spinner: true, text: "Polishing • \(p)")
        case .pasted(let w):
            inlineLabel(symbol: "checkmark", color: .white, text: "\(w) word\(w == 1 ? "" : "s")")
        case .copiedOnly(let message):
            inlineLabel(symbol: "doc.on.clipboard", color: .white, text: message)
        case .error(let m):
            inlineLabel(symbol: "exclamationmark", color: .red, text: m)
        }
    }

    @ViewBuilder
    private func inlineLabel(spinner: Bool = false, symbol: String? = nil, color: Color = .white, text: String) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.white)
            } else if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Animated waveform — bars bounce live with the audio level and idle-pulse
/// when there's no signal, so the user always sees motion while recording.
private struct Waveform: View {
    let level: Float
    @State private var phase: Double = 0
    private let bars = 16

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 2.5, height: barHeight(for: i, in: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .task {
            while !Task.isCancelled {
                phase += 0.18
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func barHeight(for index: Int, in maxHeight: CGFloat) -> CGFloat {
        let center = Double(bars - 1) / 2.0
        let dist = abs(Double(index) - center) / center  // 0 at center, 1 at edges
        let envelope = 1.0 - pow(dist, 1.6)              // taller in the middle
        let wave = sin(phase * 2 + Double(index) * 0.55) // animated wiggle
        let live = Double(max(level, 0.09))              // live audio level (with a conversational-speech floor)
        let normalized = (0.35 + 0.65 * (0.5 + 0.5 * wave)) * envelope * live
        let h = max(4, CGFloat(normalized) * maxHeight * 3.4)
        return min(h, maxHeight)
    }

}
