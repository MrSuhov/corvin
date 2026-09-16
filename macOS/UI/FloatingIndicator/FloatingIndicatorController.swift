import AppKit
import SwiftUI
import Combine

@MainActor
final class FloatingIndicatorController {
    private var panel: NSPanel?
    private let sessionManager: SessionManager
    private let callRecorder: CallRecorder
    private var sessionState: SessionState = .idle
    private var showsCall = false
    /// A fade-out in flight; its completion must not hide new content.
    private var isHiding = false
    private var cancellables = Set<AnyCancellable>()

    init(sessionManager: SessionManager, callRecorder: CallRecorder) {
        self.sessionManager = sessionManager
        self.callRecorder = callRecorder

        callRecorder.$state
            .map { $0 != .idle }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func updateState(_ state: SessionState) {
        sessionState = state
        refresh()
    }

    /// Dictation has the pill while it runs; a call recording gets it back once
    /// dictation is idle again.
    private func refresh() {
        if sessionState != .idle {
            showsCall = false
            show(FloatingIndicatorView(state: sessionState, sessionManager: sessionManager), width: 200)
        } else if callRecorder.state != .idle {
            // The call view observes the recorder itself; rebuilding it would
            // only reset it.
            guard !showsCall || panel?.isVisible != true else { return }
            showsCall = true
            show(CallIndicatorView(recorder: callRecorder), width: CallIndicatorView.width)
        } else {
            showsCall = false
            hidePanel()
        }
    }

    private func show<Content: View>(_ view: Content, width: CGFloat) {
        if panel == nil {
            createPanel()
        }

        guard let panel = panel else { return }

        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(NSSize(width: width, height: 44))

        positionPanel(panel)

        // Cancels a fade-out in flight: without this the panel would be left
        // visible but transparent, and the fade's completion would order it
        // out from under the new content.
        isHiding = false
        if panel.isVisible {
            panel.animator().alphaValue = 1
        } else {
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
        isHiding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.isHiding == true else { return }
            self?.isHiding = false
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
