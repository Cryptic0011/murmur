import SwiftUI
import AppKit

extension NSPasteboard {
    static func copyString(_ text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }
}

/// The one card look: translucent fill, hairline stroke, soft shadow — sized by
/// corner radius so every card variant stays a single source of truth.
struct CardChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 18
    var shadowRadius: CGFloat = 14
    var shadowY: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    }

    private var cardFill: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.white.opacity(0.075), Color.white.opacity(0.045)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(.ultraThinMaterial.opacity(0.78))
    }

    private var cardStroke: Color {
        colorScheme == .dark ? .white.opacity(0.1) : .white.opacity(0.55)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.24) : .black.opacity(0.06)
    }
}

extension Color {
    /// Subtle row/pill fill. Black-opacity fills vanish on dark backgrounds;
    /// the system label colour flips with the appearance.
    static let murmurRowFill = Color(nsColor: .quaternaryLabelColor).opacity(0.55)
}

extension View {
    func cardChrome(cornerRadius: CGFloat = 18, shadowRadius: CGFloat = 14, shadowY: CGFloat = 8) -> some View {
        modifier(CardChrome(cornerRadius: cornerRadius, shadowRadius: shadowRadius, shadowY: shadowY))
    }
}

struct MurmurBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backdropColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(primaryGlow)
                .blur(radius: colorScheme == .dark ? 150 : 120)
                .offset(x: 220, y: -180)
            Rectangle()
                .fill(secondaryGlow)
                .blur(radius: colorScheme == .dark ? 170 : 140)
                .offset(x: -260, y: 220)
            Rectangle()
                .fill(accentGlow)
                .blur(radius: colorScheme == .dark ? 180 : 150)
                .offset(x: 260, y: 260)
        }
        // Rasterize the three large blurs once per size/appearance change
        // instead of re-filtering them under every scroll and redraw.
        .drawingGroup()
        .ignoresSafeArea()
    }

    private var backdropColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.06, green: 0.08, blue: 0.11),
                Color(red: 0.09, green: 0.12, blue: 0.16),
                Color(red: 0.13, green: 0.16, blue: 0.15)
            ]
        }
        return [
            Color(red: 0.95, green: 0.92, blue: 0.85),
            Color(red: 0.89, green: 0.93, blue: 0.90),
            Color(red: 0.82, green: 0.87, blue: 0.90)
        ]
    }

    private var primaryGlow: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.27, blue: 0.36).opacity(0.34)
            : .white.opacity(0.22)
    }

    private var secondaryGlow: Color {
        colorScheme == .dark
            ? Color(red: 0.59, green: 0.34, blue: 0.18).opacity(0.28)
            : Color(red: 0.82, green: 0.53, blue: 0.32).opacity(0.22)
    }

    private var accentGlow: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.44, blue: 0.35).opacity(0.24)
            : Color(red: 0.77, green: 0.84, blue: 0.92).opacity(0.18)
    }
}

struct MurmurHeroCard: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .cardChrome(cornerRadius: 22, shadowRadius: 18, shadowY: 10)
    }
}

struct MurmurCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .cardChrome(cornerRadius: 18, shadowRadius: 14, shadowY: 8)
    }
}

struct MurmurMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardChrome(cornerRadius: 16, shadowRadius: 10, shadowY: 6)
    }
}

struct MurmurSidebarFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: SettingsStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(footerFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(footerStroke, lineWidth: 1)
        )
    }

    private var footerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.07)
    }

    private var footerStroke: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .white.opacity(0.28)
    }

    private var title: String {
        if setup.snapshot.isRunning { return "Preparing dependencies" }
        if setup.snapshot.hasAttention { return "Setup needs attention" }
        if settings.pauseHotkey { return "Hotkey paused" }
        if !runtimeHealth.snapshot.microphoneGranted { return "Microphone needed" }
        if !runtimeHealth.snapshot.accessibilityGranted { return "Accessibility needed" }
        return "Ready to dictate"
    }

    private var detail: String {
        if setup.snapshot.isRunning || setup.snapshot.hasAttention {
            return setup.snapshot.detail
        }
        if settings.pauseHotkey {
            return "Resume in General to start dictating again."
        }
        if !runtimeHealth.snapshot.microphoneGranted {
            return "Grant microphone access before Murmur can record speech."
        }
        if !runtimeHealth.snapshot.accessibilityGranted {
            return "Grant Accessibility so Murmur can monitor the hotkey and paste."
        }
        return settings.toggleMode
            ? "Tap \(runtimeHealth.snapshot.hotkeyLabel), speak, then tap again to paste."
            : "Hold \(runtimeHealth.snapshot.hotkeyLabel), speak, then release to paste."
    }
}
