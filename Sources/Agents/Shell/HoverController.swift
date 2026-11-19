import AppKit
import QuartzCore

/// Expands the strip on hover and collapses it after a short grace delay.
/// The frame animation is right-anchored: maxX stays flush with the screen edge.
@MainActor
final class HoverController {
    private weak var panel: NSPanel?
    private let state: OverlayState
    private let frameProvider: (Bool) -> NSRect
    private var collapseWork: DispatchWorkItem?

    static let duration: TimeInterval = 0.22
    static let collapseDelay: TimeInterval = 0.3

    private(set) var isExpanded = false

    init(panel: NSPanel, state: OverlayState, frameProvider: @escaping (Bool) -> NSRect) {
        self.panel = panel
        self.state = state
        self.frameProvider = frameProvider
    }

    func mouseEntered() {
        collapseWork?.cancel()
        collapseWork = nil
        setExpanded(true)
    }

    func mouseExited() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Still inside (e.g. exit fired during a resize)? Stay open.
                if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) { return }
                self.setExpanded(false)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, let panel else { return }
        isExpanded = expanded
        // Flip content at the start in both directions: expanding reveals the detail
        // as the panel grows; collapsing swaps to the compact strip while it shrinks.
        state.isExpanded = expanded
        let target = frameProvider(expanded)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }
}
