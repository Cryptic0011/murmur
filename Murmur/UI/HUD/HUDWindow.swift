import AppKit
import SwiftUI
import Combine

@MainActor
final class HUDWindow {
    private let panel: NSPanel
    private let viewModel: HUDViewModel
    private var observer: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var cancellable: AnyCancellable?
    private var partialCancellable: AnyCancellable?
    /// A hide's fade-out completion must not order the panel out if a show
    /// happened while the animation ran (rapid paste → next dictation).
    private var visibilityGeneration = 0

    init(viewModel: HUDViewModel) {
        self.viewModel = viewModel
        let host = NSHostingController(rootView: HUDView(vm: viewModel))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
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

        // SwiftUI resizes the panel after stage/partial-text changes land, so
        // recenter on the actual size, not the stale one at publish time.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reposition() } }

        cancellable = viewModel.$stage.sink { [weak self, weak viewModel] _ in
            DispatchQueue.main.async {
                guard let self, let viewModel else { return }
                self.reposition()
                self.setVisible(viewModel.isVisible)
            }
        }

        // The capsule widens when live preview text arrives — keep it centered.
        partialCancellable = viewModel.$partialText
            .map(\.isEmpty)
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reposition() }
            }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o) }
    }

    func setVisible(_ visible: Bool) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        if visible {
            reposition()
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
                }
            })
        }
    }

    private func reposition() {
        // NSScreen.main follows the key window, which a nonactivating background
        // panel app rarely owns — center on the screen the user is actually on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 60
        )
        panel.setFrameOrigin(origin)
    }
}
