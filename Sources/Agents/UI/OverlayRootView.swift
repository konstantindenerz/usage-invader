// Root view of the overlay panel plus Layout and Fonts.
import SwiftUI

/// Root content of the overlay panel. The shell animates the panel frame; this view
/// lays out for both widths (Layout.collapsedWidth / Layout.expandedWidth), right-aligned.
struct OverlayRootView: View {
    let store: UsageStore
    /// Driven by the shell's hover controller.
    var isExpanded: Bool

    @Environment(\.pixelStill) private var still
    @Environment(\.stripStyleOverride) private var styleOverride
    private var style: StripStyle { styleOverride ?? AppSettings.shared.stripStyle }

    /// Dynamic-Island-like height morph between the collapsed strip and the expanded panel.
    static let morph = Animation.spring(response: 0.3, dampingFraction: 0.85)

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let snaps = store.snapshots
            let stripW = min(W, Layout.collapsedWidth)
            let collapsedH = Layout.collapsedContentHeight(snaps, width: stripW, style: style)
            let expandedH = Layout.expandedContentHeight(snaps)
            let f = NotchShape.flare(width: W)
            let rL = min(Theme.cornerRadius, isExpanded ? W / 3 : W / 2)
            let bodyH = min(max(0, geo.size.height - 2 * f), isExpanded ? expandedH : collapsedH)

            notch(W: W, f: f, rL: rL, stripW: stripW, collapsedH: collapsedH, expandedH: expandedH)
                .frame(width: W, height: bodyH + 2 * f)
                .clipShape(NotchShape(flare: f, leftRadius: rL))
                .overlay { NotchEdge(flare: f, leftRadius: rL) }
                // vertically centered in the (taller) window; the shell centers the window.
                .frame(width: W, height: geo.size.height, alignment: .center)
        }
        .animation(Self.morph, value: isExpanded)
    }

    @ViewBuilder
    private func notch(W: CGFloat, f: CGFloat, rL: CGFloat, stripW: CGFloat,
                       collapsedH: CGFloat, expandedH: CGFloat) -> some View {
        let settings = AppSettings.shared
        ZStack {
            // Live: BG at 72% over a behind-window blur (ghostty style). Stills can't capture
            // the blur, so they use a denser fill to approximate it.
            if !still {
                BackdropBlur(flare: f, leftRadius: rL)
            }
            Rectangle().fill(Theme.bg.opacity(still ? 0.9 : Theme.backgroundOpacity))
            TubeShading()
        }
        // Both faces are pinned to the trailing (screen) edge and vertically centered, so while
        // the shell animates the width and the notch springs its height, the flares track them.
        .overlay(alignment: .trailing) {
            Group {
                switch style {
                case .invader: InvaderStrip(store: store)
                case .instrument: CollapsedStrip(store: store)
                }
            }
            .padding(.vertical, Layout.collapsedPadding(width: stripW))
            .frame(width: stripW, height: collapsedH)
            .modifier(GlitchModifier(amount: isExpanded ? 1 : 0))
            .allowsHitTesting(!isExpanded)
        }
        .overlay(alignment: .trailing) {
            if isExpanded {
                ExpandedPanel(store: store)
                    .frame(width: Layout.expandedWidth, height: expandedH)
                    .transition(.glitch)
            }
        }
        .overlay {
            // Scanlines only on the expanded panel: on the strip they shimmer against the 4pt rows.
            if settings.scanlines { Scanlines().opacity(isExpanded ? 1 : 0) }
        }
    }
}

enum Layout {
    static let collapsedWidth: CGFloat = 34
    /// Narrowest collapsed strip the UI supports (fits the gap next to app windows).
    static let minCollapsedWidth: CGFloat = 10
    static let expandedWidth: CGFloat = 260

    /// Largest notch flare (expanded width); the window reserves it above and below the body.
    static let maxFlare: CGFloat = 8

    /// Preferred panel height for N accounts (shell uses this to size the panel).
    /// Pass the max meter count across accounts (worst case per account).
    static func height(accounts: Int, metersPerAccount: Int) -> CGFloat {
        let n = max(1, accounts)
        let m = max(1, metersPerAccount)
        let account = expandedAccountHeight(meters: m, hasStatus: true, hasExtra: true)
        let expanded = expandedFrame(body: CGFloat(n) * account)
        let collapsed = max(CGFloat(n) * ceil(InvaderGeo.maxHeight) + CGFloat(n - 1),
                            CGFloat(n) * CollapsedStrip.block + CGFloat(n - 1))
        return ceil(max(collapsed, expanded) + 2 * maxFlare)
    }

    /// Window height computed from the actual snapshots (preferred): the taller of the collapsed
    /// strip (at full 44pt width, either skin) and the expanded panel, plus room for both flares.
    static func height(for snapshots: [AccountSnapshot]) -> CGFloat {
        let collapsed = max(InvaderStrip.contentHeight(snapshots, width: collapsedWidth),
                            CollapsedStrip.contentHeight(snapshots))
            + 2 * collapsedPadding(width: collapsedWidth)
        return ceil(max(collapsed, expandedContentHeight(snapshots)) + 2 * maxFlare)
    }

    /// Collapsed notch body height for the given strip width and skin.
    static func collapsedContentHeight(_ snapshots: [AccountSnapshot], width: CGFloat, style: StripStyle) -> CGFloat {
        let content: CGFloat
        switch style {
        case .invader: content = InvaderStrip.contentHeight(snapshots, width: width)
        case .instrument: content = CollapsedStrip.contentHeight(snapshots)
        }
        return content + 2 * collapsedPadding(width: width)
    }

    /// Breathing room between the collapsed content and the notch body's top/bottom edge.
    static func collapsedPadding(width: CGFloat) -> CGFloat {
        width < 26 ? 6 : 10
    }

    /// Expanded panel body height.
    static func expandedContentHeight(_ snapshots: [AccountSnapshot]) -> CGFloat {
        guard !snapshots.isEmpty else { return expandedFrame(body: 90) }
        let body = snapshots.reduce(CGFloat(0)) { sum, s in
            sum + expandedAccountHeight(
                meters: s.meters.count,
                hasStatus: s.status != .ok,
                hasExtra: s.extraUsage.map { $0.isEnabled && ($0.usedCredits != nil || $0.utilization != nil) } ?? false)
        }
        return expandedFrame(body: body)
    }

    private static func expandedAccountHeight(meters: Int, hasStatus: Bool, hasExtra: Bool) -> CGFloat {
        // padding + title line, then (spacing + row) for each optional line / meter.
        var h = 2 * Expanded.accountPadding + 14
        if hasStatus { h += 15 }
        h += CGFloat(meters) * 29
        if hasExtra { h += 15 }
        return h + 1 // divider
    }

    private static func expandedFrame(body: CGFloat) -> CGFloat {
        ceil(max(Expanded.header + 1 + body + 1 + Expanded.footer + 4, 140))
    }

    enum Collapsed {
        static let segments = 16
        /// segments * (3 + 1) - 1
        static let barHeight: CGFloat = 63
    }

    enum Expanded {
        static let header: CGFloat = 30
        static let footer: CGFloat = 22
        static let hPad: CGFloat = 12
        static let accountPadding: CGFloat = 8
        static let labelWidth: CGFloat = 42
        static let segments = 26
        static let block: CGFloat = 5
    }
}

// MARK: - Previews

#Preview("Collapsed") {
    OverlayRootView(store: UsageStore(demo: true), isExpanded: false)
        .frame(width: Layout.collapsedWidth, height: Layout.height(accounts: 2, metersPerAccount: 3))
        .padding(20)
        .background(Color(white: 0.12))
}

#Preview("Expanded") {
    OverlayRootView(store: UsageStore(demo: true), isExpanded: true)
        .frame(width: Layout.expandedWidth, height: Layout.height(accounts: 2, metersPerAccount: 3))
        .padding(20)
        .background(Color(white: 0.12))
}

#Preview("Empty") {
    OverlayRootView(store: UsageStore(), isExpanded: true)
        .frame(width: Layout.expandedWidth, height: Layout.height(accounts: 0, metersPerAccount: 2))
        .padding(20)
        .background(Color(white: 0.12))
}
