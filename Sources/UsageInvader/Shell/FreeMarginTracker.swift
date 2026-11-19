import AppKit
import CoreGraphics

/// Measures the free horizontal gap between the right-most normal app window and the
/// screen's right edge, so the collapsed strip never overlaps the user's windows.
/// Uses only window *bounds* from CGWindowList (no Screen Recording permission needed).
enum FreeMarginTracker {
    /// Lower bound for the collapsed strip.
    static var minWidth: CGFloat { Layout.minCollapsedWidth }

    /// Right edge the panel is anchored to. `visibleFrame.maxX` equals `frame.maxX` unless the
    /// Dock sits on the right, in which case we anchor next to the Dock.
    static func edgeX(of screen: NSScreen) -> CGFloat { screen.visibleFrame.maxX }

    /// Free gap (points) between the right-most overlapping window and `edgeX`, or nil when
    /// no window overlaps the given vertical band on this screen.
    static func freeMargin(on screen: NSScreen, verticalBand: ClosedRange<CGFloat>) -> CGFloat? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let edge = edgeX(of: screen)
        var rightmost: CGFloat?

        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  cg.width > 50, cg.height > 50
            else { continue }
            // CG global coords are top-left based on the primary screen → Cocoa bottom-left.
            let r = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            guard r.intersects(screen.frame), r.minX < edge,
                  r.maxY > verticalBand.lowerBound, r.minY < verticalBand.upperBound
            else { continue }
            rightmost = max(rightmost ?? -.infinity, r.maxX)
        }
        guard let rightmost else { return nil }
        return max(0, edge - rightmost)
    }

    /// Width for the collapsed strip: the free margin clamped to [minWidth, Layout.collapsedWidth].
    static func collapsedWidth(on screen: NSScreen, verticalBand: ClosedRange<CGFloat>) -> CGFloat {
        guard let margin = freeMargin(on: screen, verticalBand: verticalBand) else {
            return Layout.collapsedWidth
        }
        return min(Layout.collapsedWidth, max(minWidth, margin.rounded(.down)))
    }
}
