import AppKit
import SwiftUI
import Combine

@MainActor
final class HUDWindow {
    private let panel: NSPanel
    private let viewModel: HUDViewModel
    private var observer: NSObjectProtocol?
    private var cancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    /// A hide's fade-out completion must not order the panel out if a show
    /// happened while the animation ran (rapid paste → next dictation).
    private var visibilityGeneration = 0
    /// The display chosen when the dictation started. Kept until the HUD hides so
    /// the capsule never hops screens when the mouse crosses displays mid-session.
    private var lockedScreen: NSScreen?

    init(viewModel: HUDViewModel) {
        self.viewModel = viewModel
        let host = NSHostingController(rootView: HUDView(vm: viewModel))
        // The panel stays a fixed transparent rect and the capsule sizes itself
        // inside it. Letting SwiftUI resize the window clipped the shadow, chopped
        // shrink animations, hid the fade-out and re-centred a frame late.
        host.sizingOptions = []
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: HUDView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.setContentSize(HUDView.panelSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // .fullScreenAuxiliary lets the HUD appear over full-screen apps — the
        // primary dictation surface for many users.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .transient, .fullScreenAuxiliary,
        ]
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        self.panel = panel

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reposition() } }

        cancellable = viewModel.$stage.sink { [weak self, weak viewModel] stage in
            DispatchQueue.main.async {
                guard let self, let viewModel else { return }
                // A new dictation picks its display afresh; later stages keep it.
                if case .recording = stage { self.lockedScreen = nil }
                self.setVisible(viewModel.isVisible)
            }
        }

        settingsCancellable = NotificationCenter.default.publisher(for: .settingsStoreDidChange)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setVisible(self.viewModel.isVisible)
                }
            }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    func setVisible(_ visible: Bool) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        if visible && (AppServices.settings.showHUD || viewModel.forcesVisible) {
            if lockedScreen == nil { reposition() }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.visibilityGeneration == generation else { return }
                    self.panel.orderOut(nil)
                    self.lockedScreen = nil
                }
            })
        }
    }

    private func reposition() {
        if let locked = lockedScreen, !NSScreen.screens.contains(locked) { lockedScreen = nil }
        // NSScreen.main follows the key window, which a nonactivating background
        // panel app rarely owns — use the screen the user is on when dictation starts.
        // ponytail: mouse screen; the focused window's screen (via AX) would suit
        // keyboard-only users better.
        let mouse = NSEvent.mouseLocation
        let screen = lockedScreen
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        lockedScreen = screen
        let frame = screen.visibleFrame
        // Capsule bottom sits 60pt above the visible frame, as before the panel
        // grew transparent margins.
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - HUDView.panelSize.width / 2,
            y: frame.minY + 60 - HUDView.bottomMargin
        ))
    }
}
