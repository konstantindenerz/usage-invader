import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let actions: AppActions
    private let item: NSStatusItem
    private let menu = NSMenu()
    private lazy var popover: NSPopover = makePopover()

    init(store: UsageStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        // Left click: usage panel as popover. Right / ctrl click: the menu.
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateButton()
        observeStore()
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            popover.performClose(nil)
            item.menu = menu
            sender.performClick(nil)   // opens the menu attached above
            item.menu = nil            // detach again so the next left click shows the panel
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(from: sender)
        }
    }

    // MARK: Popover (the expanded panel, also available while the overlay is hidden)

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentViewController = NSHostingController(rootView: MenuBarPanel(store: store))
        return p
    }

    private func showPopover(from button: NSStatusBarButton) {
        // The store's request budget decides whether this actually asks the API.
        Task { await store.refresh() }
        popover.contentSize = NSSize(width: Layout.expandedWidth,
                                     height: Layout.expandedContentHeight(store.snapshots))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Status button

    /// Lowest REMAINING percent across all visible accounts (used-up model limits skipped).
    private var lowestRemaining: Double? {
        store.snapshots.compactMap(\.meters.headlineRemaining).min()
    }

    private func updateButton() {
        guard let button = item.button else { return }
        button.image = Self.invaderIcon
        button.imagePosition = .imageLeading
        if let r = lowestRemaining {
            button.attributedTitle = NSAttributedString(
                string: " \(Int(r.rounded()))%",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)])
        } else {
            button.title = ""
        }
        button.toolTip = "Usage Invader"
    }

    private func observeStore() {
        withObservationTracking {
            _ = store.snapshots
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateButton()
                if self.popover.isShown {
                    self.popover.contentSize = NSSize(width: Layout.expandedWidth,
                                                      height: Layout.expandedContentHeight(self.store.snapshots))
                }
                self.observeStore()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for i in buildItems() { menu.addItem(i) }
    }

    /// Fresh standalone menu (used for the overlay's context menu).
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for i in buildItems() { menu.addItem(i) }
        return menu
    }

    private func buildItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        if store.snapshots.isEmpty {
            let empty = NSMenuItem(title: store.isRefreshing ? "Loading…" : "No accounts found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        }
        for snap in store.snapshots {
            var parts = [snap.account.label.uppercased()]
            parts += snap.meters.map { "\($0.label) \(Int($0.remaining.rounded()))% left" }
            var line = parts.joined(separator: " · ")
            if let hint = statusHint(snap.status) { line += "  (\(hint))" }
            let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            row.attributedTitle = NSAttributedString(string: line, attributes: [.font: mono])
            row.isEnabled = false
            items.append(row)
        }
        if let last = store.lastRefresh {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            let row = NSMenuItem(title: "Updated \(f.localizedString(for: last, relativeTo: Date()))", action: nil, keyEquivalent: "")
            row.isEnabled = false
            items.append(row)
        }

        items.append(.separator())
        items.append(make("Refresh now", #selector(refreshNow), key: "r"))
        items.append(make(actions.isOverlayHidden() ? "Show overlay" : "Hide overlay", #selector(toggleOverlay)))

        let scan = make("Scanlines", #selector(toggleScanlines))
        scan.state = AppSettings.shared.scanlines ? .on : .off
        items.append(scan)

        let fit = make("Fit to free margin", #selector(toggleFitMargin))
        fit.state = actions.isFitMargin() ? .on : .off
        fit.toolTip = "Shrink the collapsed strip to the gap between your windows and the screen edge"
        items.append(fit)

        items.append(styleMenuItem())
        items.append(screenMenuItem())
        items.append(make("Settings…", #selector(openSettings), key: ","))

        let login = make("Launch at login", #selector(toggleLaunchAtLogin))
        if Self.isAppBundle {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            login.isEnabled = false
            login.toolTip = "Only available when running from UsageInvader.app"
        }
        items.append(login)

        items.append(make("Add account…", #selector(addAccount)))
        items.append(.separator())
        items.append(make("Quit Usage Invader", #selector(quit), key: "q"))
        return items
    }

    private func styleMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for style in StripStyle.allCases {
            let i = make(style.title, #selector(selectStyle(_:)))
            i.representedObject = style.rawValue
            i.state = AppSettings.shared.stripStyle == style ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    private func screenMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Screen", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = actions.selectedScreenName()
        let auto = make("Main display (menu bar)", #selector(selectScreen(_:)))
        auto.representedObject = nil
        auto.state = current == nil ? .on : .off
        sub.addItem(auto)
        for s in NSScreen.screens {
            let i = make(s.localizedName, #selector(selectScreen(_:)))
            i.representedObject = s.localizedName
            i.state = current == s.localizedName ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    private func statusHint(_ s: AccountStatus) -> String? {
        switch s {
        case .ok: return nil
        case .loading: return "loading"
        case .tokenExpired: return "token expired — run claude"
        case .offline: return "offline"
        case .rateLimited: return "rate limited"
        case .error(let m): return "error: \(m)"
        }
    }

    private func make(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = true
        return i
    }

    /// The collapsed strip's alien as a crisp template image for the menu bar.
    static let invaderIcon: NSImage = {
        let rows = InvaderArt.alien[0]
        let px: CGFloat = 2
        let size = NSSize(width: CGFloat(rows[0].count) * px, height: CGFloat(rows.count) * px)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() where ch == "X" {
                    NSRect(x: CGFloat(c) * px, y: CGFloat(r) * px, width: px, height: px).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Usage Invader"
        return img
    }()

    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: Actions

    @objc private func refreshNow() { actions.refresh() }
    @objc private func toggleOverlay() { actions.toggleOverlay() }
    @objc private func toggleScanlines() { AppSettings.shared.scanlines.toggle() }
    @objc private func toggleFitMargin() { actions.toggleFitMargin() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func selectScreen(_ sender: NSMenuItem) { actions.selectScreen(sender.representedObject as? String) }
    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = StripStyle(rawValue: raw) else { return }
        AppSettings.shared.stripStyle = style
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Launch at login failed"
            alert.informativeText = "\(error.localizedDescription)\n\nIf macOS asks for approval, enable Usage Invader under System Settings → General → Login Items."
            alert.runModal()
        }
    }

    static let addAccountCommand = "CLAUDE_CONFIG_DIR=~/.claude-<name> claude"

    @objc private func addAccount() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add an account"
        alert.informativeText = """
        Each account lives in its own config directory. In a terminal run:

            \(Self.addAccountCommand)

        then type /login. The new keychain entry is picked up automatically on the next refresh.

        Tip: add an alias to your shell, e.g.
            alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
        """
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.addAccountCommand, forType: .string)
        }
    }
}

/// Expanded usage panel shown from the menu bar item.
private struct MenuBarPanel: View {
    let store: UsageStore
    var body: some View {
        ExpandedPanel(store: store)
            .frame(width: Layout.expandedWidth, height: Layout.expandedContentHeight(store.snapshots), alignment: .top)
            .background(Theme.bg)
    }
}
