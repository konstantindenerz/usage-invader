// 260pt terminal panel shown on hover ("Mechanoonna" theme).
import SwiftUI

struct ExpandedPanel: View {
    let store: UsageStore
    @Environment(\.pixelNow) private var fixedNow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: Layout.Expanded.header, alignment: .center)
            PixelDivider(color: Theme.overlay)

            if store.snapshots.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.snapshots.enumerated()), id: \.element.id) { i, snap in
                        if i > 0 { PixelDivider(color: Theme.overlay.opacity(0.7), dot: 2, gap: 2) }
                        AccountBlock(snapshot: snap, index: i + 1, lineBase: 2 + i * 6)
                            .padding(.vertical, Layout.Expanded.accountPadding)
                    }
                }
            }

            Spacer(minLength: 0)
            PixelDivider(color: Theme.overlay)
            footer
                .frame(height: Layout.Expanded.footer)
        }
        .padding(.horizontal, Layout.Expanded.hPad)
        .foregroundStyle(Theme.sand)
        .compositingGroup()
        .warmGlow(intensity: 0.7)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            TypeOn(text: "AGENTS", charInterval: 0.025)
                .font(.pixel(16))
                .foregroundStyle(Theme.cream)
            Blink(period: 0.53) { on in
                Rectangle().fill(Theme.sand)
                    .frame(width: 7, height: 12)
                    .opacity(on ? 0.9 : 0)
            }
            .padding(.leading, 3)
            Text("v0.1")
                .font(.pixel(8))
                .foregroundStyle(Theme.dim)
                .padding(.leading, 6)
                .padding(.top, 4)
            Spacer(minLength: 4)
            Heartbeat(active: store.isRefreshing)
        }
    }

    // MARK: empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            TypeOn(text: "NO ACCOUNTS", delay: 0.15)
                .font(.pixel(16))
                .foregroundStyle(Theme.cream)
            HStack(spacing: 0) {
                Text("> ").foregroundStyle(Theme.dim)
                TypeOn(text: "claude /login", delay: 0.35).foregroundStyle(Theme.amberHi)
            }
            .font(.pixel(8))
            TypeOn(text: "SCANNING KEYCHAIN...", delay: 0.55)
                .font(.pixel(8))
                .foregroundStyle(Theme.dim)
        }
        .padding(.vertical, 16)
    }

    // MARK: footer

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            HStack(spacing: 0) {
                Text(store.isRefreshing ? "SYNCING..." : "SYNC \(PixelFormat.ago(store.lastRefresh, now: fixedNow ?? ctx.date))")
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text("\(store.snapshots.count) ACCT")
                    .foregroundStyle(Theme.dim)
            }
            .font(.pixel(8))
        }
    }
}

// MARK: - Pill

/// tmux-style rounded pill. Inactive: OVERLAY bg, index DIM, text SAND.
/// Active: ACCENT bg, CREAM text — the only red pill on screen.
struct Pill: View {
    var text: String
    var index: String? = nil
    var active: Bool = false
    var dimmed: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let index {
                Text(index).foregroundStyle(active ? Theme.cream.opacity(0.7) : Theme.dim)
            }
            Text(text).foregroundStyle(active ? Theme.cream : (dimmed ? Theme.muted : Theme.sand))
        }
        .font(.pixel(8))
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(active ? Theme.accent : Theme.overlay.opacity(dimmed ? 0.6 : 1)))
    }
}

// MARK: - Account

private struct AccountBlock: View {
    let snapshot: AccountSnapshot
    let index: Int
    let lineBase: Int

    private var stale: Bool { snapshot.isStale }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                HStack(spacing: 0) {
                    Text("> ").foregroundStyle(Theme.dim)
                    TypeOn(text: snapshot.account.label.uppercased(), delay: Double(lineBase) * 0.04)
                        .foregroundStyle(stale ? Theme.muted : Theme.fgLight)
                }
                .font(.pixel(8))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                Pill(text: (snapshot.account.plan ?? snapshot.account.tag).uppercased(),
                     index: "\(index)", dimmed: stale)
            }

            StatusLine(status: snapshot.status)

            ForEach(snapshot.meters) { m in
                MeterRow(meter: m, stale: stale)
            }

            if let extra = snapshot.extraUsage, extra.isEnabled, let line = extraLine(extra) {
                Text(line)
                    .font(.pixel(8))
                    .foregroundStyle(Theme.dim)
                    .padding(.leading, Layout.Expanded.labelWidth)
            }
        }
    }

    private func extraLine(_ e: ExtraUsage) -> String? {
        let cur = (e.currency ?? "USD") == "USD" ? "$" : ((e.currency ?? "") + " ")
        if let used = e.usedCredits, let limit = e.monthlyLimit {
            return "XTRA \(cur)\(Int(used.rounded()))/\(cur)\(Int(limit.rounded()))"
        }
        if let u = e.utilization { return "XTRA \(Int(u.rounded()))%" }
        return nil
    }
}

private struct StatusLine: View {
    let status: AccountStatus

    var body: some View {
        switch status {
        case .ok:
            EmptyView()
        case .loading:
            Blink(period: 0.4) { on in
                Text("BOOTING" + (on ? "..." : ".  ")).font(.pixel(8)).foregroundStyle(Theme.muted)
            }
        case .tokenExpired:
            HStack(spacing: 0) {
                Text("TOKEN EXPIRED ").foregroundStyle(Theme.amberHi)
                Text("> ").foregroundStyle(Theme.dim)
                Text("run claude").foregroundStyle(Theme.sand)
            }
            .font(.pixel(8))
        case .offline:
            Blink(period: 1.0) { on in
                Text("NO SIGNAL").font(.pixel(8)).foregroundStyle(Theme.muted).opacity(on ? 1 : 0.45)
            }
        case .rateLimited:
            Text("THROTTLED // BACKING OFF").font(.pixel(8)).foregroundStyle(Theme.muted)
        case .error(let msg):
            Text("ERR " + msg.uppercased())
                .font(.pixel(8))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Theme.red)
        }
    }
}

// MARK: - Meter row

private struct MeterRow: View {
    let meter: Meter
    let stale: Bool

    private var level: AlarmLevel { stale ? .normal : AlarmLevel(percent: meter.percent, severity: meter.severity) }
    private var active: Bool { meter.isBinding && !stale }
    @Environment(\.pixelNow) private var fixedNow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                label
                    .frame(width: Layout.Expanded.labelWidth, alignment: .leading)
                PixelBar(percent: meter.percent, segments: Layout.Expanded.segments, direction: .horizontal,
                         blockLength: Layout.Expanded.block, thickness: 7, gap: 1, stale: stale,
                         severity: meter.severity, isActive: active,
                         paceMark: meter.expectedRemaining(now: fixedNow ?? Date()))
                Spacer(minLength: 4)
                percentText
            }
            .frame(height: 11)

            HStack(spacing: 0) {
                ResetLine(meter: meter, stale: stale)
                Spacer(minLength: 4)
                Text("LEFT").foregroundStyle(Theme.dim)
            }
            .font(.pixel(8))
            .padding(.leading, Layout.Expanded.labelWidth)
        }
        .opacity(stale ? 0.7 : 1)
    }

    /// Binding limit = red "active window" pill; others sit in the same slot, unboxed.
    @ViewBuilder private var label: some View {
        if active {
            Pill(text: meter.label, active: true)
                .offset(x: -5)
        } else {
            Text(meter.label)
                .font(.pixel(8))
                .fixedSize()
                .foregroundStyle(stale ? Theme.muted : Theme.sand)
        }
    }

    /// Quota LEFT (fuel-gauge semantics, matches the bar).
    @ViewBuilder private var percentText: some View {
        let text = PixelFormat.percent(meter.remaining)
        Group {
            switch level {
            case .overload:
                Blink(period: 0.35) { on in
                    Text(on ? "EMPTY" : text).foregroundStyle(on ? Theme.accent : Theme.red)
                }
            case .alarm:
                Text(text).foregroundStyle(Theme.accent)
            default:
                Text(text).foregroundStyle(stale ? Theme.dim
                    : active ? Theme.accent
                    : level == .warning ? Theme.amberBright : Theme.amberHi)
            }
        }
        .font(.pixel(8))
        .fixedSize()
    }
}

/// "RST 6D 23H · PACE +12" — or "DRY TUE 14:00" (red) when the meter runs out before reset.
/// Ticks every second inside the last hour, every 30s otherwise.
struct ResetLine: View {
    let meter: Meter
    var stale: Bool = false
    @Environment(\.pixelNow) private var fixedNow

    var body: some View {
        if let fixedNow {
            line(now: fixedNow)
        } else {
            let remaining = meter.resetsAt?.timeIntervalSinceNow ?? 3600
            TimelineView(.periodic(from: .now, by: remaining < 3600 ? 1 : 30)) { ctx in
                line(now: ctx.date)
            }
        }
    }

    private func line(now: Date) -> some View {
        HStack(spacing: 0) {
            if let reset = meter.resetsAt {
                Text(PixelFormat.countdown(reset.timeIntervalSince(now)))
                    .foregroundStyle(Theme.muted)
            }
            if !stale {
                if let dry = meter.projectedEmpty(now: now) {
                    Text(" · ").foregroundStyle(Theme.dim)
                    Text("DRY IN " + PixelFormat.duration(dry.timeIntervalSince(now))).foregroundStyle(Theme.accent)
                } else if let d = meter.paceDelta(now: now), let f = meter.elapsedFraction(now: now) {
                    let v = Int(d.rounded())
                    Text(" · PACE ").foregroundStyle(Theme.dim)
                    if f < 0.03 {
                        Text("+-0").foregroundStyle(Theme.dim)
                    } else {
                        Text(v >= 0 ? "+\(v)" : "-\(abs(v))")
                            .foregroundStyle(v < 0 ? Theme.accent : Theme.amber)
                    }
                }
            }
        }
        .fixedSize()
    }
}
