import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Shared hover state so the SwiftUI root re-renders when the shell toggles expansion.
@MainActor
@Observable
final class OverlayState {
    var isExpanded = false
}

/// Tiny wrapper so `OverlayRootView` observes `OverlayState`.
struct OverlayContainerView: View {
    let store: UsageStore
    let state: OverlayState
    var body: some View {
        OverlayRootView(store: store, isExpanded: state.isExpanded)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// Borderless, non-activating, always-on-top strip panel.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Root NSView of the panel: hosts the SwiftUI view and owns the hover tracking area.
final class TrackingContainerView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { debugLog("mouseEntered"); onEnter?() }
    override func mouseExited(with event: NSEvent) { debugLog("mouseExited"); onExit?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel: positioning, re-layout on screen/data changes, hide/show, context menu.
@MainActor
final class OverlayController {
    private let store: UsageStore
    private let state = OverlayState()
    private let panel: OverlayPanel
    private let container: TrackingContainerView
    private var hover: HoverController!
    private let menuProvider: () -> NSMenu
    private var eventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var marginTimer: Timer?
    /// Current collapsed width (fitted to the free margin right of the user's windows).
    private var collapsedWidth: CGFloat = Layout.collapsedWidth

    private static let hiddenKey = "overlayHidden"
    private static let screenKey = "overlayScreen"
    private static let fitMarginKey = "fitMargin"

    /// Shrink the collapsed strip to the free gap between the right-most window and the edge.
    private(set) var fitMargin: Bool {
        didSet { UserDefaults.standard.set(fitMargin, forKey: Self.fitMarginKey) }
    }

    private(set) var isHidden: Bool {
        didSet { UserDefaults.standard.set(isHidden, forKey: Self.hiddenKey) }
    }
    /// `localizedName` of the chosen screen; nil = screen with the menu bar.
    private(set) var preferredScreenName: String? {
        didSet { UserDefaults.standard.set(preferredScreenName, forKey: Self.screenKey) }
    }

    init(store: UsageStore, menuProvider: @escaping () -> NSMenu) {
        self.store = store
        self.menuProvider = menuProvider
        self.isHidden = UserDefaults.standard.bool(forKey: Self.hiddenKey)
        self.preferredScreenName = UserDefaults.standard.string(forKey: Self.screenKey)
        self.fitMargin = UserDefaults.standard.object(forKey: Self.fitMarginKey) as? Bool ?? false

        let initial = NSRect(x: 0, y: 0, width: Layout.collapsedWidth, height: 200)
        panel = OverlayPanel(contentRect: initial)
        container = TrackingContainerView(frame: initial)
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: OverlayContainerView(store: store, state: state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // The panel frame is driven by the shell, not by SwiftUI's ideal size.
        hosting.sizingOptions = []
        container.addSubview(hosting)
        panel.contentView = container

        hover = HoverController(panel: panel, state: state, frameProvider: { [weak self] expanded in
            guard let self else { return .zero }
            // Collapsing: re-measure first so we land on the current free margin.
            if !expanded { self.collapsedWidth = self.measureCollapsedWidth() }
            return self.targetFrame(expanded: expanded)
        })
        container.onEnter = { [weak self] in self?.hover.mouseEntered() }
        container.onExit = { [weak self] in self?.hover.mouseExited() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }

        // Right-click or Option-click on the strip → app menu.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let isContext = event.type == .rightMouseDown
                || event.modifierFlags.contains(.option)
                || event.modifierFlags.contains(.control)
            guard isContext else { return event }
            self.showContextMenu(at: event.locationInWindow)
            return nil
        }

        observeLayoutInputs()
        startMarginTracking()
    }

    // MARK: Visibility

    func show() {
        relayout()
        if isHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    func toggleHidden() {
        isHidden.toggle()
        show()
    }

    func toggleFitMargin() {
        fitMargin.toggle()
        updateCollapsedWidth(animated: true)
    }

    func selectScreen(named name: String?) {
        preferredScreenName = name
        relayout()
    }

    // MARK: Layout

    var screen: NSScreen? {
        if let name = preferredScreenName,
           let s = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return s
        }
        // screens[0] is always the one carrying the menu bar.
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// Same height collapsed and expanded; only the width animates.
    private var preferredHeight: CGFloat { Layout.height(for: store.snapshots) }

    func targetFrame(expanded: Bool) -> NSRect {
        guard let screen else { return panel.frame }
        let vf = screen.visibleFrame
        let width = expanded ? Layout.expandedWidth : collapsedWidth
        let height = max(40, min(preferredHeight, vf.height - 40))
        let edge = FreeMarginTracker.edgeX(of: screen)
        return NSRect(x: edge - width,
                      y: (vf.midY - height / 2).rounded(),
                      width: width,
                      height: height.rounded())
    }

    func relayout() {
        collapsedWidth = measureCollapsedWidth()
        debugLog("relayout → \(targetFrame(expanded: hover.isExpanded)) screen=\(screen?.frame ?? .zero)")
        panel.setFrame(targetFrame(expanded: hover.isExpanded), display: true)
    }

    private func observeLayoutInputs() {
        withObservationTracking {
            _ = store.snapshots
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.relayout()
                self?.observeLayoutInputs()
            }
        }
    }

    // MARK: Free-margin fitting

    private func measureCollapsedWidth() -> CGFloat {
        guard fitMargin, let screen else { return Layout.collapsedWidth }
        let f = targetFrame(expanded: false)
        return FreeMarginTracker.collapsedWidth(on: screen, verticalBand: f.minY...f.maxY)
    }

    /// Re-measures the free margin; animates the strip width when it changed (collapsed only).
    func updateCollapsedWidth(animated: Bool) {
        guard !hover.isExpanded else { return }
        let w = measureCollapsedWidth()
        guard w != collapsedWidth else { return }
        debugLog("collapsed width \(collapsedWidth) → \(w)")
        collapsedWidth = w
        let target = targetFrame(expanded: false)
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func startMarginTracking() {
        // Cheap poll: window bounds only, every 1.5s, skipped while expanded/hidden.
        marginTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHidden, !self.hover.isExpanded else { return }
                self.updateCollapsedWidth(animated: true)
            }
        }
        marginTimer?.tolerance = 0.3
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateCollapsedWidth(animated: true)
                    // Windows may still be moving (space switch animation) — check again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated { self?.updateCollapsedWidth(animated: true) }
                    }
                }
            })
        }
    }

    // MARK: Menu

    private func showContextMenu(at point: NSPoint) {
        let menu = menuProvider()
        menu.popUp(positioning: nil, at: point, in: container)
    }
}

/// Hover/layout tracing, enabled with AGENTS_DEBUG=1.
func debugLog(_ msg: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AGENTS_DEBUG"] != nil else { return }
    FileHandle.standardError.write("[\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100)))] \(msg())\n".data(using: .utf8)!)
}
