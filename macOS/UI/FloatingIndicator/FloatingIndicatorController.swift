import AppKit
import SwiftUI
import Combine

class FloatingIndicatorController {
    private var panel: NSPanel?
    private let sessionManager: SessionManager
    private var cancellables = Set<AnyCancellable>()

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func updateState(_ state: SessionState) {
        switch state {
        case .idle:
            hidePanel()
        case .recording, .transcribing, .done, .error, .inserting:
            showPanel(for: state)
        }
    }

    private func showPanel(for state: SessionState) {
        if panel == nil {
            createPanel()
        }

        guard let panel = panel else { return }

        let hostingView = NSHostingView(rootView: FloatingIndicatorView(state: state, sessionManager: sessionManager))
        panel.contentView = hostingView

        positionPanel(panel)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hidePanel() {
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.nonactivatingPanel, .hudWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let position = UserDefaults.standard.string(forKey: "indicatorPosition") ?? "bottomCenter"
        let padding: CGFloat = 20
        let frame = screen.visibleFrame
        let size = panel.frame.size

        var origin: NSPoint
        switch position {
        case "bottomLeft":
            origin = NSPoint(x: frame.minX + padding, y: frame.minY + padding)
        case "topLeft":
            origin = NSPoint(x: frame.minX + padding, y: frame.maxY - size.height - padding)
        case "topRight":
            origin = NSPoint(x: frame.maxX - size.width - padding, y: frame.maxY - size.height - padding)
        case "bottomCenter":
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + padding)
        default: // bottomRight
            origin = NSPoint(x: frame.maxX - size.width - padding, y: frame.minY + padding)
        }

        panel.setFrameOrigin(origin)
    }
}
