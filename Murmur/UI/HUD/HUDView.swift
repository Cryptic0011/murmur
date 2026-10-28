import SwiftUI

struct HUDView: View {
    @ObservedObject var vm: HUDViewModel
    /// Last progress/result stage, kept on screen while the panel fades out —
    /// collapsing to nothing at `.idle` made the fade invisible.
    @State private var lingering: DictationStage = .idle

    /// The panel never resizes: the capsule sizes itself inside this fixed,
    /// transparent, click-through rect, and the margins leave the drop shadow room.
    static let panelSize = CGSize(width: 600, height: 120)
    static let sideMargin: CGFloat = 30
    /// Gap between the capsule's bottom edge and the panel's bottom edge.
    static let bottomMargin: CGFloat = 30

    private var stage: DictationStage {
        if case .idle = vm.stage { return lingering }
        return vm.stage
    }

    var body: some View {
        Group {
            if case .idle = stage {
                Color.clear
            } else {
                capsule
            }
        }
        .padding(.horizontal, Self.sideMargin)
        .padding(.top, 20)
        .padding(.bottom, Self.bottomMargin)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .bottom)
        .onChange(of: vm.stage) { _, new in
            switch new {
            case .idle: break
            // A cancelled recording should vanish, and the next session must get a
            // fresh recording view (its timer starts when the view is created).
            case .recording: lingering = .idle
            default: lingering = new
            }
        }
    }

    private var capsule: some View {
        ZStack {
            content
                .id(transitionKey)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92)),
                    removal: .opacity
                ))
        }
        .frame(width: fixedWidth, height: fixedWidth == nil ? nil : 38)
        .frame(minHeight: 38)
        .background {
            // Dark glass: system blur behind a black tint so the capsule picks
            // up whatever is behind it instead of reading as a flat sticker.
            // Shadows live on this static shape only, so the animating waveform
            // and text above never force them to be recomputed.
            ZStack {
                Self.shape.fill(.ultraThinMaterial)
                Self.shape.fill(Color.black.opacity(0.5))
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.30), radius: 20, x: 0, y: 10)
            .shadow(color: .black.opacity(0.22), radius: 5, x: 0, y: 2)
        }
        .overlay {
            // Rim light: brighter on top, faint mid, slight bottom catch.
            Self.shape.strokeBorder(
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
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: stageKey)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: vm.partialText.isEmpty)
        .accessibilityElement(children: .combine)
    }

    /// A capsule at the single-line height of 38; stays a rounded rect when an
    /// error wraps to two lines.
    private static let shape = RoundedRectangle(cornerRadius: 19, style: .circular)

    /// Fixed widths keep the live stages steady; nil lets the label size the
    /// capsule (up to the panel width, wrapping errors to two lines) so long
    /// provider names and error messages are never cut to a few words.
    private var fixedWidth: CGFloat? {
        switch stage {
        case .recording: return vm.partialText.isEmpty ? 176 : 460
        case .transcribing: return 150
        case .pasted(_, let note): return note == nil ? 150 : nil
        case .idle, .loadingModel, .cleaning, .copiedOnly, .error: return nil
        }
    }

    private var stageKey: String {
        switch stage {
        case .idle: return "idle"
        case .recording: return "rec"
        case .loadingModel: return "load"
        case .transcribing: return "stt"
        case .cleaning(let p): return "clean-\(p)"
        case .pasted: return "pasted"
        case .copiedOnly(let message): return "copied-\(message)"
        case .error(let message): return "error-\(message)"
        }
    }

    /// Coarse stage family for insert/remove transitions — unlike `stageKey`
    /// it must NOT change on progress ticks, or the pop-in replays every tick.
    private var transitionKey: String {
        switch stage {
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
        switch stage {
        case .idle:
            EmptyView()
        case .recording:
            RecordingContent(level: vm.level, partialText: vm.partialText)
        case .loadingModel:
            // Also shown for a cold load of a model already on disk, so don't
            // claim a download.
            inlineLabel(spinner: true, text: "Loading model…")
        case .transcribing:
            inlineLabel(spinner: true, text: "Transcribing")
        case .cleaning(let p):
            inlineLabel(spinner: true, text: "Polishing • \(p.replacingOccurrences(of: " (local)", with: ""))")
        case .pasted(let w, let note):
            inlineLabel(symbol: "checkmark.circle.fill",
                        color: Color(red: 0.36, green: 0.9, blue: 0.55),
                        text: "\(w) word\(w == 1 ? "" : "s")" + (note.map { " · \($0)" } ?? ""),
                        lines: note == nil ? 1 : 2)
        case .copiedOnly(let message):
            inlineLabel(symbol: "doc.on.clipboard", color: .white.opacity(0.85), text: message, lines: 2)
        case .error(let m):
            inlineLabel(symbol: "exclamationmark.triangle.fill",
                        color: Color(red: 1.0, green: 0.45, blue: 0.4),
                        text: m, lines: 2)
        }
    }

    @ViewBuilder
    private func inlineLabel(
        spinner: Bool = false, symbol: String? = nil, color: Color = .white, text: String, lines: Int = 1
    ) -> some View {
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
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, lines > 1 ? 8 : 0)
    }
}

/// Live recording row. Created fresh per dictation (the parent's `.id`), so its
/// start date is the session start and the clock needs no ticking publisher.
private struct RecordingContent: View {
    let level: Float
    let partialText: String
    @State private var start = Date()

    var body: some View {
        HStack(spacing: 12) {
            Waveform(level: level, start: start)
                .frame(width: partialText.isEmpty ? 94 : 50,
                       height: partialText.isEmpty ? 20 : 16)
                .accessibilityLabel("Recording")

            if !partialText.isEmpty {
                Text(partialText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.head) // keep the latest words visible
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .layoutPriority(1)
            }

            // The system advances this text itself, once a second.
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize()
        }
        .padding(.horizontal, partialText.isEmpty ? 18 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Animated waveform — bars bounce live with the audio level and idle-pulse
/// when there's no signal, so the user always sees motion while recording.
/// The raw level is low-passed so bars breathe instead of twitching, and two
/// out-of-phase sines keep the motion organic rather than metronomic.
/// One 24 fps timeline drives the motion and exists only while recording.
private struct Waveform: View {
    let level: Float
    let start: Date
    @State private var smoothed: Double = 0.12
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
            let phase = context.date.timeIntervalSince(start) * 5.4
            Canvas { ctx, size in
                // Fit bars to the actual frame — a fixed count overflows the
                // 50pt compact frame and bleeds into the transcript text.
                let bars = max(5, Int((size.width + barSpacing) / (barWidth + barSpacing)))
                let total = CGFloat(bars) * barWidth + CGFloat(bars - 1) * barSpacing
                var x = (size.width - total) / 2
                ctx.addFilter(.shadow(color: .white.opacity(0.25), radius: 3))
                for i in 0..<bars {
                    let h = barHeight(for: i, of: bars, in: size.height, phase: phase)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .linearGradient(
                            Gradient(colors: [.white, .white.opacity(0.65)]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                    x += barWidth + barSpacing
                }
            }
        }
        .onChange(of: level) { _, new in
            smoothed += (Double(new) - smoothed) * 0.3
        }
    }

    private func barHeight(for index: Int, of bars: Int, in maxHeight: CGFloat, phase: Double) -> CGFloat {
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
