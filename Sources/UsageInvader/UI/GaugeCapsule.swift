// Narrow-strip "instrument" (inside the shared notch): per account
// solid fuel tubes (remaining quota), a pace marker, the lowest-left number and a tag/dot.
import SwiftUI

// MARK: - Tube

/// One solid vertical fuel tube. Fill = REMAINING, bottom → top, with fine pixel cuts,
/// a warm head pixel, an optional pace hairline and red "debt" between fill and marker.
struct TubeGauge: View, Animatable {
    /// 0...100 left.
    var remaining: Double
    var length: CGFloat
    var thickness: CGFloat
    /// ≤10% left or binding -> red.
    var hot: Bool = false
    var stale: Bool = false
    /// Expected remaining at an even burn (0...100), nil = no marker.
    var paceMark: Double? = nil

    var animatableData: Double {
        get { remaining }
        set { remaining = newValue }
    }

    static let cutPitch: CGFloat = 3
    static let cut: CGFloat = 0.5

    var behind: Bool { !stale && (paceMark.map { remaining < $0 - 0.5 } ?? false) }
    private var empty: Bool { !stale && remaining <= 0.01 }

    var body: some View {
        Blink(period: 0.5, enabled: empty) { on in
            canvas(emptyPulse: on)
        }
        .frame(width: thickness, height: length)
        .overlay(alignment: .top) { head }
    }

    private func canvas(emptyPulse: Bool) -> some View {
        let r = min(max(remaining, 0), 100)
        let hot = hot, stale = stale, behind = behind, empty = empty, paceMark = paceMark
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            let corner = min(1, w / 2)
            let track = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: corner)
            ctx.fill(track, with: .color(empty && emptyPulse ? Theme.red.opacity(0.45) : Theme.bg2))

            let fillH = (h * CGFloat(r / 100)).rounded()
            let top = h - fillH

            // Debt: where the fuel should still be.
            if behind, let m = paceMark {
                let markY = h - h * CGFloat(m / 100)
                if markY < top {
                    ctx.fill(Path(CGRect(x: 0, y: markY, width: w, height: top - markY)),
                             with: .color(Theme.accent.opacity(0.25)))
                }
            }

            if fillH > 0 {
                let rect = CGRect(x: 0, y: top, width: w, height: fillH)
                let fill = Path(roundedRect: rect, cornerRadius: corner)
                if stale {
                    ctx.fill(fill, with: .color(Theme.dim))
                } else if hot {
                    ctx.fill(fill, with: .linearGradient(Gradient(colors: [Theme.red, Theme.accent]),
                                                          startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: 0, y: 0)))
                } else {
                    ctx.fill(fill, with: .linearGradient(Gradient(colors: [Theme.amber, Theme.amberHi]),
                                                          startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: 0, y: 0)))
                }
            }

            // Pixel cuts (through track and fuel alike) for the segmented-tube look.
            var cuts = Path()
            var y = h - Self.cutPitch
            while y > 0.5 {
                cuts.addRect(CGRect(x: 0, y: y, width: w, height: Self.cut))
                y -= Self.cutPitch
            }
            ctx.fill(cuts, with: .color(Theme.bg.opacity(0.85)))

            // Pace hairline.
            if let m = paceMark, !stale, m > 0.5, m < 99.5 {
                let markY = (h - h * CGFloat(m / 100)).rounded() - 0.5
                ctx.fill(Path(CGRect(x: 0, y: markY, width: w, height: 1)),
                         with: .color(behind ? Theme.amberBright : Theme.cream))
            }
        }
    }

    /// Warm-glowing head pixel on top of the fuel. Breathes only when burning too fast.
    @ViewBuilder private var head: some View {
        let r = min(max(remaining, 0), 100)
        if !stale && r > 0.5 {
            let fillH = (length * CGFloat(r / 100)).rounded()
            let color = hot ? Theme.lightest : Theme.amberBright
            Blink(period: 1.6, enabled: behind) { on in
                Rectangle()
                    .fill(color)
                    .frame(width: thickness, height: 1.5)
                    .opacity(on ? 1 : 0.45)
                    .animation(.easeInOut(duration: 1.6), value: on)
            }
            .shadow(color: (hot ? Theme.accent : Theme.amberHi).opacity(0.9), radius: 1.5)
            .shadow(color: (hot ? Theme.accent : Theme.amberHi).opacity(0.45), radius: 4)
            .offset(y: length - fillH)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Pixel ∞

/// 7×3 pixel infinity: shown instead of "100" when the tank is full.
struct PixelInfinity: View {
    var color: Color = Theme.amberHi
    var px: CGFloat = 1

    private static let rows = [
        ".##.##.",
        "#..#..#",
        ".##.##.",
    ]

    var body: some View {
        Canvas { ctx, _ in
            for (y, row) in Self.rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)),
                             with: .color(color))
                }
            }
        }
        .frame(width: 7 * px, height: 3 * px)
    }
}

// MARK: - Capsule per account

struct GaugeCapsule: View {
    let snapshot: AccountSnapshot
    let meters: [Meter]
    let width: CGFloat
    let slim: Bool
    let now: Date

    static let tubeLength: CGFloat = 64

    private var stale: Bool { snapshot.isStale }
    private var hPad: CGFloat { slim ? 2 : 4 }
    private var gap: CGFloat { slim ? 1 : 2 }
    private var topPad: CGFloat { max(5, min(8, width / 2 - 1)) }

    private var thickness: CGFloat {
        let n = CGFloat(max(1, meters.count))
        return min(6, max(2, floor((width - 2 * hPad - gap * (n - 1)) / n)))
    }

    /// Lowest remaining across visible meters.
    private var lowest: Double { meters.map(\.remaining).min() ?? 0 }
    private var level: AlarmLevel { stale ? .normal : AlarmLevel(percent: 100 - lowest) }
    /// Meter that is furthest behind pace (drives the capsule notch).
    private var worstPace: Meter? {
        meters.filter { $0.paceDelta(now: now) != nil }
            .min { ($0.paceDelta(now: now) ?? 0) < ($1.paceDelta(now: now) ?? 0) }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: gap) {
                if meters.isEmpty {
                    TubeGauge(remaining: 0, length: Self.tubeLength, thickness: thickness, stale: true)
                } else {
                    ForEach(meters) { m in
                        TubeGauge(remaining: m.remaining, length: Self.tubeLength, thickness: thickness,
                                  hot: !stale && (m.remaining <= 10 || m.isBinding),
                                  stale: stale, paceMark: m.expectedRemaining(now: now))
                    }
                }
            }
            .padding(.top, topPad)

            if width >= 12 { number }
            marker
                .padding(.bottom, topPad - 1)
        }
        .frame(width: width)
        .overlay(alignment: .topLeading) { notch }
        .animation(.easeOut(duration: 0.6), value: meters.map(\.percent))
    }

    // MARK: parts

    @ViewBuilder private var number: some View {
        if meters.isEmpty {
            Text("--").font(.pixel(8)).foregroundStyle(Theme.dim).fixedSize()
        } else if lowest >= 99.5 {
            PixelInfinity(color: stale ? Theme.dim : Theme.amberHi)
                .padding(.vertical, 2)
        } else {
            let text = "\(Int(lowest.rounded()))"
            Group {
                switch level {
                case .overload:
                    Blink(period: 0.35) { on in
                        Text("0").foregroundStyle(on ? Theme.accent : Theme.red.opacity(0.5))
                    }
                case .alarm:
                    Text(text).foregroundStyle(Theme.accent)
                default:
                    Text(text).foregroundStyle(stale ? Theme.dim : (level == .warning ? Theme.amberBright : Theme.amberHi))
                }
            }
            .font(.pixel(8))
            .fixedSize()
        }
    }

    /// 2-letter tag when there's room (~26pt strip), otherwise a 3px account dot; status pip below.
    @ViewBuilder private var marker: some View {
        VStack(spacing: 3) {
            if width >= 22 {
                Text(snapshot.account.tag)
                    .font(.pixel(8))
                    .fixedSize()
                    .foregroundStyle(stale ? Theme.muted : Theme.sand)
            } else {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(stale ? Theme.dim : Theme.sand.opacity(0.85))
                    .frame(width: 3, height: 3)
            }
            statusPip
        }
    }

    @ViewBuilder private var statusPip: some View {
        switch snapshot.status {
        case .ok:
            EmptyView()
        case .tokenExpired, .loading:
            let expired = snapshot.status == .tokenExpired
            Blink(period: 0.8) { on in
                Rectangle()
                    .fill((expired ? Theme.amberHi : Theme.muted).opacity(on ? 0.95 : 0.3))
                    .frame(width: 2, height: 2)
            }
        case .offline, .rateLimited:
            Rectangle().fill(Theme.muted).frame(width: 2, height: 2)
        case .error:
            Rectangle().fill(Theme.red).frame(width: 2, height: 2)
        }
    }

    /// 2px notch protruding from the capsule's left edge at the pace level.
    @ViewBuilder private var notch: some View {
        if let m = worstPace, !stale, let mark = m.expectedRemaining(now: now), mark > 0.5, mark < 99.5 {
            let behind = (m.paceDelta(now: now) ?? 0) < -0.5
            let y = topPad + Self.tubeLength - (Self.tubeLength * CGFloat(mark / 100)).rounded() - 0.5
            Rectangle()
                .fill(behind ? Theme.amberBright : Theme.cream)
                .frame(width: 2, height: 1)
                .offset(x: -1.5, y: y)
                .shadow(color: Theme.bg.opacity(0.6), radius: 0.5)
        }
    }
}
