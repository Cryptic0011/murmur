import AppKit
import SwiftUI
import Combine

@MainActor
final class HUDWindow {
    private let panel: NSPanel
    private let viewModel: HUDViewModel
    private var observer: NSObjectProtocol?
    private var cancellable: AnyCancellable?

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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        self.panel = panel

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reposition() } }

        cancellable = viewModel.$stage.sink { [weak self, weak viewModel] _ in
            DispatchQueue.main.async {
                guard let self, let viewModel else { return }
                self.reposition()
                self.setVisible(viewModel.isVisible)
            }
        }
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    func setVisible(_ visible: Bool) {
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
            }, completionHandler: { [weak self] in self?.panel.orderOut(nil) })
        }
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 60
        )
        panel.setFrameOrigin(origin)
    }
}
