import SwiftUI

struct HUDView: View {
    @ObservedObject var vm: HUDViewModel

    var body: some View {
        ZStack {
            content
                .id(transitionKey)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92)),
                    removal: .opacity
                ))
        }
        .frame(width: width, height: 38)
        .background {
            // Dark glass: system blur behind a black tint so the capsule picks
            // up whatever is behind it instead of reading as a flat sticker.
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.black.opacity(0.5))
            }
            .compositingGroup()
        }
        .overlay {
            // Rim light: brighter on top, faint mid, slight bottom catch.
            Capsule().strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.30), location: 0),
                        .init(color: .white.opacity(0.07), location: 0.45),
                        .init(color: .white.opacity(0.14), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(0.30), radius: 20, x: 0, y: 10)
        .shadow(color: .black.opacity(0.22), radius: 5, x: 0, y: 2)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: stageKey)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: vm.partialText.isEmpty)
    }

    private var width: CGFloat {
        switch vm.stage {
        case .idle: return 0
        case .recording: return vm.partialText.isEmpty ? 176 : 460
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

    /// Coarse stage family for insert/remove transitions — unlike `stageKey`
    /// it must NOT change on progress ticks, or the pop-in replays every tick.
    private var transitionKey: String {
        switch vm.stage {
        case .idle: return "idle"
        case .recording: return "rec"
        case .loadingModel: return "load"
        case .transcribing: return "stt"
        case .cleaning: return "clean"
        case .pasted: return "pasted"
        case .copiedOnly: return "copied"
        case .error: return "error"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.stage {
        case .idle:
            EmptyView()
        case .recording:
            HStack(spacing: 12) {
                Waveform(level: vm.level)
                    .frame(width: vm.partialText.isEmpty ? 94 : 50,
                           height: vm.partialText.isEmpty ? 20 : 16)

                if !vm.partialText.isEmpty {
                    Text(vm.partialText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head) // keep the latest words visible
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .layoutPriority(1)
                }

                timerText
            }
            .padding(.horizontal, vm.partialText.isEmpty ? 18 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .loadingModel:
            inlineLabel(spinner: true, text: "Downloading model…")
        case .transcribing:
            inlineLabel(spinner: true, text: "Transcribing")
        case .cleaning(let p):
            inlineLabel(spinner: true, text: "Polishing • \(p)")
        case .pasted(let w):
            inlineLabel(symbol: "checkmark.circle.fill",
                        color: Color(red: 0.36, green: 0.9, blue: 0.55),
                        text: "\(w) word\(w == 1 ? "" : "s")")
        case .copiedOnly(let message):
            inlineLabel(symbol: "doc.on.clipboard", color: .white.opacity(0.85), text: message)
        case .error(let m):
            inlineLabel(symbol: "exclamationmark.triangle.fill",
                        color: Color(red: 1.0, green: 0.45, blue: 0.4),
                        text: m)
        }
    }

    private var timerText: some View {
        Text(Self.format(vm.elapsed))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
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
                    .font(.system(size: 13, weight: .semibold))
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
/// The raw level is low-passed so bars breathe instead of twitching, and two
/// out-of-phase sines keep the motion organic rather than metronomic.
private struct Waveform: View {
    let level: Float
    @State private var phase: Double = 0
    @State private var smoothed: Double = 0.12
    private let bars = 18

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.white, .white.opacity(0.65)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 2.5, height: barHeight(for: i, in: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .center)
            .compositingGroup()
            .shadow(color: .white.opacity(0.25), radius: 3)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .onChange(of: level) { _, new in
            smoothed += (Double(new) - smoothed) * 0.3
        }
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
        let wave = 0.6 * sin(phase * 2 + Double(index) * 0.55)
                 + 0.4 * sin(phase * 3.3 + Double(index) * 1.15 + 1.7)
        let live = max(smoothed, 0.09)                   // conversational-speech floor
        let normalized = (0.35 + 0.65 * (0.5 + 0.5 * wave)) * envelope * live
        let h = max(4, CGFloat(normalized) * maxHeight * 3.4)
        return min(h, maxHeight)
    }
}
