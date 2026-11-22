// Always-visible strip, fully adaptive to its width
// (Layout.minCollapsedWidth ... Layout.collapsedWidth).
//  - < 40pt: no panel; one dark glass capsule per account ("instrument", see GaugeCapsule).
//  - ≥ 40pt: panel strip with pixel bars, lowest-left %, tag, status.
// Bars are fuel gauges (REMAINING) with a pace marker.
import SwiftUI

/// Density tier for the collapsed strip, picked from the live width.
enum StripMode: Equatable {
    /// ≥ 40pt: panel with all meters, lowest-left %, tag, status glyph.
    case full
    /// 22–40pt: glass capsule, tag + number.
    case compact
    /// 10–22pt: glass capsule, max 2 tubes, dot instead of tag.
    case slim

    /// No panel behind: capsules sit directly on the desktop.
    var floating: Bool { self != .full }

    init(width: CGFloat) {
        if width >= 40 { self = .full }
        else if width >= 22 { self = .compact }
        else { self = .slim }
    }
}

struct CollapsedStrip: View {
    let store: UsageStore
    @Environment(\.pixelNow) private var fixedNow

    /// Fixed height of one account block (instrument skin).
    static let block: CGFloat = 112
    static let emptyBlock: CGFloat = 60

    /// Height of the strip's content (accounts + dividers).
    static func contentHeight(_ snapshots: [AccountSnapshot]) -> CGFloat {
        guard !snapshots.isEmpty else { return emptyBlock }
        return CGFloat(snapshots.count) * block + CGFloat(snapshots.count - 1)
    }

    var body: some View {
        // Re-evaluate once a minute so pace markers creep along without any animation cost.
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = fixedNow ?? ctx.date
            GeometryReader { geo in
                let W = geo.size.width
                let mode = StripMode(width: W)

                VStack(spacing: 0) {
                    if store.snapshots.isEmpty {
                        emptyState(mode: mode, inner: W)
                            .frame(height: Self.emptyBlock)
                    } else {
                        ForEach(Array(store.snapshots.enumerated()), id: \.element.id) { i, snap in
                            if i > 0 {
                                PixelDivider(color: Theme.overlay, dot: 1, gap: 2)
                                    .padding(.horizontal, max(2, W * 0.18))
                            }
                            CollapsedAccount(snapshot: snap, mode: mode, innerWidth: W, now: now)
                                .frame(height: Self.block)
                        }
                    }
                }
                .frame(width: W, height: geo.size.height, alignment: .center)
                .animation(.easeOut(duration: 0.2), value: mode)
            }
        }
        .foregroundStyle(Theme.sand)
    }

    @ViewBuilder
    private func emptyState(mode: StripMode, inner: CGFloat) -> some View {
        VStack(spacing: 6) {
            if mode == .full {
                Text("NO").font(.pixel(8)).fixedSize()
                Text("ACCT").font(.pixel(8)).fixedSize()
            }
            Blink(period: 0.6) { on in
                Text("?").font(.pixel(8)).fixedSize().opacity(on ? 1 : 0.25)
            }
        }
        .foregroundStyle(Theme.dim)
    }
}

private struct CollapsedAccount: View {
    let snapshot: AccountSnapshot
    let mode: StripMode
    let innerWidth: CGFloat
    let now: Date

    private var stale: Bool { snapshot.isStale }
    private var level: AlarmLevel { stale ? .normal : AlarmLevel(percent: snapshot.peak) }

    var body: some View {
        Group {
            if mode.floating {
                GaugeCapsule(snapshot: snapshot, meters: visibleMeters, width: max(8, innerWidth - 2),
                             slim: mode == .slim, now: now)
                    .transition(.opacity)
            } else {
                panelFace.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: ≥ 40pt panel face

    private var panelFace: some View {
        let meters = visibleMeters
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: meters.count >= 4 ? 2 : 3) {
                if meters.isEmpty {
                    PixelBar(percent: 100, segments: Layout.Collapsed.segments, direction: .vertical,
                             blockLength: 3, thickness: 5, stale: true)
                } else {
                    ForEach(meters) { m in
                        PixelBar(percent: m.percent, segments: Layout.Collapsed.segments,
                                 direction: .vertical, blockLength: 3, thickness: meters.count >= 4 ? 4 : 5,
                                 stale: stale, severity: m.severity, isActive: m.isBinding && !stale,
                                 paceMark: m.expectedRemaining(now: now))
                    }
                }
            }
            .frame(height: Layout.Collapsed.barHeight, alignment: .bottom)

            lowestLabel
            Text(snapshot.account.tag)
                .font(.pixel(8, bold: true))
                .fixedSize()
                .foregroundStyle(stale ? Theme.dim : Theme.sand)
            statusGlyph
        }
        .compositingGroup()
        .warmGlow(intensity: 0.6)
    }

    // MARK: meter selection

    /// Full mode shows up to 4; capsules keep WEEK + the most critical other meter (max 2 when slim).
    private var visibleMeters: [Meter] {
        let all = snapshot.meters
        let maxBars: Int
        switch mode {
        case .full: maxBars = innerWidth >= 36 ? 4 : 3
        case .compact: maxBars = innerWidth >= 28 ? 3 : 2
        case .slim: maxBars = innerWidth < 9 ? 1 : 2
        }
        guard all.count > maxBars else { return all }

        var picked: [String] = []
        if maxBars > 1, let week = all.first(where: { $0.id == "weekly_all" }) { picked.append(week.id) }
        for m in all.sorted(by: { $0.percent > $1.percent }) where picked.count < maxBars {
            if !picked.contains(m.id) { picked.append(m.id) }
        }
        return all.filter { picked.contains($0.id) } // keep original order for stability
    }

    // MARK: labels (panel face)

    @ViewBuilder private var lowestLabel: some View {
        let lowest = snapshot.meters.headlineRemaining ?? 0
        Group {
            if snapshot.meters.isEmpty {
                Text("--").font(.pixel(8)).foregroundStyle(Theme.dim)
            } else if lowest >= 99.5 && !stale {
                PixelInfinity(color: Theme.amberHi, px: 1.5).padding(.vertical, 1)
            } else {
                let text = "\(Int(lowest.rounded()))"
                switch level {
                case .overload:
                    Blink(period: 0.35) { on in
                        Text("0")
                            .font(.pixel(8))
                            .padding(.horizontal, 3)
                            .foregroundStyle(on ? Theme.cream : Theme.accent)
                            .background(Capsule().fill(on ? Theme.accent : .clear))
                    }
                case .alarm:
                    Text(text).font(.pixel(8)).foregroundStyle(Theme.accent)
                default:
                    Text(text).font(.pixel(8))
                        .foregroundStyle(stale ? Theme.dim : (level == .warning ? Theme.amberBright : Theme.amberHi))
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var statusGlyph: some View {
        Group {
            switch snapshot.status {
            case .ok: EmptyView()
            case .loading:
                Blink(period: 0.4) { on in Text("...").font(.pixel(8)).opacity(on ? 1 : 0.3) }
            case .tokenExpired:
                Blink(period: 0.8) { on in
                    Text("EXP").font(.pixel(8)).foregroundStyle(Theme.amberHi.opacity(on ? 0.95 : 0.4))
                }
            case .offline: Text("OFF").font(.pixel(8)).foregroundStyle(Theme.muted)
            case .rateLimited: Text("429").font(.pixel(8)).foregroundStyle(Theme.muted)
            case .error: Text("ERR").font(.pixel(8)).foregroundStyle(Theme.red)
            }
        }
        .fixedSize()
    }
}

/// Tiny pixel heartbeat. Blinks while refreshing, otherwise a dim steady pip.
struct Heartbeat: View {
    var active: Bool
    var size: CGFloat = 4
    var body: some View {
        Blink(period: 0.25, enabled: active) { on in
            Rectangle()
                .fill(active ? (on ? Theme.amberHi : Theme.overlay) : Theme.overlay)
                .frame(width: size, height: size)
        }
    }
}

/// Dark legibility halo for marks sitting directly on the desktop.
struct FloatHalo: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: Theme.bg.opacity(0.6), radius: 0.6)
                .shadow(color: Theme.bg.opacity(0.35), radius: 2)
        } else {
            content
        }
    }
}
