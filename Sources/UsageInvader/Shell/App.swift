import AppKit
import SwiftUI

@main
struct UsageInvaderMain {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--dump") {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var code: Int32 = 0
            Task.detached { code = await DumpCommand.run(); sem.signal() }
            sem.wait()
            exit(code)
        }

        if let i = args.firstIndex(of: "--snapshot") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write("usage: UsageInvader --snapshot <path.png>\n".data(using: .utf8)!)
                exit(2)
            }
            let path = (args[i + 1] as NSString).expandingTildeInPath
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                Fonts.register()
                SnapshotRenderer.render(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }

        if let i = args.firstIndex(of: "--readme-shots") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write("usage: UsageInvader --readme-shots <dir>\n".data(using: .utf8)!)
                exit(2)
            }
            let path = (args[i + 1] as NSString).expandingTildeInPath
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                SnapshotRenderer.renderReadmeShots(to: URL(fileURLWithPath: path, isDirectory: true))
            }
            exit(0)
        }

        if args.contains("--diag") {
            // Prints where the resource bundle resolved and whether the pixel font registered.
            MainActor.assumeIsolated {
                print("bundle: \(Bundle.main.bundlePath)")
                print("resources: \(Bundle.module.bundlePath)")
                print("pixel font: \(Fonts.available ? "registered" : "MISSING (fallback monospaced)")")
                if let screen = NSScreen.screens.first {
                    let vf = screen.visibleFrame
                    let band = (vf.midY - 150)...(vf.midY + 150)
                    let m = FreeMarginTracker.freeMargin(on: screen, verticalBand: band)
                    print("free margin: \(m.map { "\($0)pt" } ?? "no window") → collapsed width \(FreeMarginTracker.collapsedWidth(on: screen, verticalBand: band))pt")
                }
            }
            exit(0)
        }

        let demo = args.contains("--demo")
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate(demo: demo)
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            // Keep the delegate alive for the lifetime of the process.
            AppDelegate.retained = delegate
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var retained: AppDelegate?

    let isDemo: Bool
    private(set) var store: UsageStore!
    private var overlay: OverlayController!
    private var menuBar: MenuBarController!
    private var settingsWindow: SettingsWindowController?

    init(demo: Bool) {
        self.isDemo = demo
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        store = UsageStore(demo: isDemo)
        if !isDemo { store.start() }

        let actions = AppActions(
            refresh: { [weak self] in self?.refresh() },
            toggleOverlay: { [weak self] in self?.overlay.toggleHidden() },
            isOverlayHidden: { [weak self] in self?.overlay.isHidden ?? false },
            openSettings: { [weak self] in self?.openSettings() },
            selectScreen: { [weak self] name in self?.overlay.selectScreen(named: name) },
            selectedScreenName: { [weak self] in self?.overlay.preferredScreenName },
            toggleFitMargin: { [weak self] in self?.overlay.toggleFitMargin() },
            isFitMargin: { [weak self] in self?.overlay.fitMargin ?? false }
        )
        menuBar = MenuBarController(store: store, actions: actions)
        overlay = OverlayController(store: store, menuProvider: { [weak self] in
            self?.menuBar.makeMenu() ?? NSMenu()
        })
        overlay.show()
    }

    func refresh() {
        guard !isDemo else { return }
        // Explicit "Refresh now": only the short manual gap applies.
        Task { await store.refresh(force: true) }
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, onChange: { [weak self] kind in
                guard let self, !self.isDemo else { return }
                if kind == .pollInterval { self.store.stop(); self.store.start() }
                Task { await self.store.refresh() }
            })
        }
        settingsWindow?.present()
    }
}

/// Callbacks the menu (status item + overlay context menu) uses.
@MainActor
struct AppActions {
    var refresh: () -> Void
    var toggleOverlay: () -> Void
    var isOverlayHidden: () -> Bool
    var openSettings: () -> Void
    var selectScreen: (String?) -> Void
    var selectedScreenName: () -> String?
    var toggleFitMargin: () -> Void
    var isFitMargin: () -> Bool
}
