// "INVADER" skin for the collapsed strip (default), living inside the shared notch
// (OverlayRootView draws the glass/notch; accounts are separated by a pixel divider),
// a one-eyed alien on top, "invasion" rows hanging down with % USED, a dashed danger line at the
// expected usage (pace), a cannon at the bottom and the lowest % LEFT in 3×5 pixel digits.
import SwiftUI

// MARK: - Bitmaps (original designs)

enum InvaderArt {
    static let alien: [[String]] = [
        ["X.......X",
         ".X.XXX.X.",
         "..XXXXX..",
         ".XX.E.XX.",
         "XXXXXXXXX",
         "X.X...X.X",
         "..X...X.."],
        ["X.......X",
         ".X.XXX.X.",
         "..XXXXX..",
         ".XX.E.XX.",
         "XXXXXXXXX",
         ".X.X.X.X.",
         "X.......X"],
    ]
    static let burst: [[String]] = [
        ["X...X...X",
         ".X..X..X.",
         "..X...X..",
         "XX..E..XX",
         "..X...X..",
         ".X..X..X.",
         "X...X...X"],
        [".........",
         "..X...X..",
         "...X.X...",
         ".X..E..X.",
         "...X.X...",
         "..X...X..",
         "........."],
    ]
    static let cannon = ["..X..", ".XXX.", "XXXXX"]
    static let digits: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"], "1": ["1", "1", "1", "1", "1"],
        "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "001", "001", "001"],
        "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
    ]

    static let redHot = Color(hex: 0xFF7A5C)
}

// MARK: - Geometry

struct InvaderGeo {
    let narrow: Bool
    let capX: CGFloat, capW: CGFloat
    let iw: CGFloat, ix: CGFloat
    let tw: CGFloat, tg: CGFloat
    let u: CGFloat
    let L: CGFloat
    let colX: [CGFloat]

    /// `columns`: number of meter columns (1 or 2).
    init(width W: CGFloat, columns: Int) {
        // Wide art needs a 22pt interior; below ~26pt strip width use the narrow (u = 1) art.
        narrow = W < 26
        // Flush with the screen edge: the notch background spans the full strip width.
        capX = 0
        capW = max(6, W)
        iw = narrow ? 9 : 22
        ix = capX + (capW - iw) / 2
        tw = narrow ? 4 : 7
        tg = narrow ? 1 : 4
        u = narrow ? 1 : 2
        L = 56   // 14 rows of 4pt
        if columns >= 2 {
            let c0 = ix + (iw - (2 * tw + tg)) / 2
            colX = [c0, c0 + tw + tg]
        } else {
            colX = [ix + (iw - tw) / 2]
        }
    }

    /// One spacing unit used everywhere: edge→alien, alien→rows, rows→cannon, cannon→digits, digits→edge.
    static let gap: CGFloat = 4
    /// The last invasion row carries a trailing 1pt row gap; subtract it so the visible gap below
    /// the rows matches the others.
    static let rowTail: CGFloat = 1
    /// Optical compensation: the heavy digits need a little more room below than the alien above.
    static let bottomExtra: CGFloat = 2

    var height: CGFloat {
        let G = Self.gap
        return G + 7 * u + G + (L - Self.rowTail) + G + 3 * u + G + 5 * u + G + Self.bottomExtra
    }
    /// Tallest capsule (wide art) — used by Layout so account blocks keep fixed y positions.
    static let maxHeight: CGFloat = InvaderGeo(width: Layout.collapsedWidth, columns: 2).height
}

// MARK: - Strip

struct InvaderStrip: View {
    let store: UsageStore
    @Environment(\.pixelNow) private var fixedNow

    /// Height of the strip's content (all accounts + dividers) at strip width `width`.
    static func contentHeight(_ snapshots: [AccountSnapshot], width: CGFloat) -> CGFloat {
        guard !snapshots.isEmpty else { return ceil(InvaderGeo(width: width, columns: 1).height) }
        let blocks = snapshots.reduce(CGFloat(0)) { sum, s in
            sum + ceil(InvaderGeo(width: width, columns: min(2, max(1, s.meters.count))).height)
        }
        return blocks + CGFloat(snapshots.count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            VStack(spacing: 0) {
                if store.snapshots.isEmpty {
                    InvaderCapsule(snapshot: nil, width: W, fixedNow: fixedNow)
                } else {
                    ForEach(Array(store.snapshots.enumerated()), id: \.element.id) { i, snap in
                        if i > 0 {
                            PixelDivider(color: Theme.overlay, dot: 1, gap: 2)
                                .padding(.horizontal, max(2, W * 0.18))
                        }
                        InvaderCapsule(snapshot: snap, width: W, fixedNow: fixedNow)
                    }
                }
            }
            .frame(width: W, height: geo.size.height, alignment: .center)
        }
    }
}

// MARK: - One account block

struct InvaderCapsule: View {
    /// nil = no accounts (alien dozes over empty tracks).
    let snapshot: AccountSnapshot?
    let width: CGFloat
    let fixedNow: Date?

    @Environment(\.pixelStill) private var still

    private var meters: [Meter] {
        guard let all = snapshot?.meters else { return [] }
        guard all.count > 2 else { return all }
        // WEEK + the most critical other meter.
        var picked: [String] = []
        if let week = all.first(where: { $0.id == "weekly_all" }) { picked.append(week.id) }
        for m in all.sorted(by: { $0.percent > $1.percent }) where picked.count < 2 {
            if !picked.contains(m.id) { picked.append(m.id) }
        }
        return all.filter { picked.contains($0.id) }
    }

    var body: some View {
        let ms = meters
        let g = InvaderGeo(width: width, columns: max(1, ms.count))
        let H = ceil(g.height)
        let stale = snapshot?.isStale ?? false
        let now0 = fixedNow ?? Date()
        let state = InvaderState(meters: ms, now: now0, stale: stale)
        // Low-rate clock: 0.7s leg swap when calm, ~0.14s only while angry/empty. Frame 0 in stills.
        let period = (state.angry || state.empty) ? 0.14 : 0.7

        Group {
            if still {
                canvas(g: g, H: H, meters: ms, t: 0, now: now0, stale: stale)
            } else {
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: period)) { ctx in
                    canvas(g: g, H: H, meters: ms, t: ctx.date.timeIntervalSinceReferenceDate,
                           now: fixedNow ?? ctx.date, stale: stale)
                }
            }
        }
        .frame(width: width, height: H)
    }

    private func canvas(g: InvaderGeo, H: CGFloat, meters: [Meter], t: Double, now: Date, stale: Bool) -> some View {
        Canvas { ctx, _ in
            InvaderPainter.draw(&ctx, g: g, H: H, meters: meters, t: t, now: now, stale: stale,
                                hasAccount: snapshot != nil)
        }
        .frame(width: width, height: H)
    }
}

/// Derived alarm state (shared by the strip and the painter).
struct InvaderState {
    let empty: Bool
    let debt: Bool
    let angry: Bool

    init(meters: [Meter], now: Date, stale: Bool) {
        if stale {
            empty = false; debt = false; angry = false
            return
        }
        empty = meters.contains { $0.percent >= 100 }
        debt = meters.contains { m in
            guard let e = m.expectedRemaining(now: now) else { return false }
            return m.remaining < e - 1
        }
        angry = debt || meters.contains { $0.percent >= 90 }
    }
}

// MARK: - Painter (port of SKINS.invader.draw)

enum InvaderPainter {
    static func draw(_ ctx: inout GraphicsContext, g: InvaderGeo, H: CGFloat, meters: [Meter],
                     t: Double, now: Date, stale: Bool, hasAccount: Bool) {
        let C_track = Theme.bg2, C_sand = Theme.sand, C_cream = Theme.cream
        let C_lo = Theme.amber, C_hi = Theme.amberHi, C_bright = Theme.amberBright, C_red = Theme.accent
        let redHot = InvaderArt.redHot
        let st = InvaderState(meters: meters, now: now, stale: stale)

        // (background/glass is the shared notch drawn by OverlayRootView)

        let u = g.u, mid = g.ix + g.iw / 2

        // alien
        let sx = (mid - 4.5 * u).rounded(), sy: CGFloat = InvaderGeo.gap
        if st.empty {
            let fr = InvaderArt.burst[Int(t * 3) % 2]
            sprite(&ctx, fr, x: sx, y: sy, u: u, body: C_red, eye: redHot)
        } else {
            let period = st.angry ? 0.28 : 0.7
            let fr = InvaderArt.alien[Int(t / period) % 2]
            let body: Color = stale || !hasAccount ? Theme.dim : (st.angry ? C_hi : C_sand)
            let eye: Color = stale || !hasAccount ? Theme.muted : (st.angry ? redHot : C_cream)
            if st.angry {
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: C_red, radius: 2))
                    sprite(&l, fr, x: sx, y: sy, u: u, body: body, eye: eye)
                }
            } else {
                sprite(&ctx, fr, x: sx, y: sy, u: u, body: body, eye: eye)
            }
        }

        // invasion: hanging rows, grows with USED
        let y0 = sy + 7 * u + InvaderGeo.gap, L = g.L, rowH: CGFloat = 4
        let rows = Int(L / rowH)

        let columns: [Meter?] = meters.isEmpty ? [nil] : meters.map { $0 }
        let n = min(columns.count, g.colX.count)
        for (i, m) in columns.enumerated() where i < g.colX.count {
            let x = g.colX[i], tw = g.tw
            let used = min(max(m?.percent ?? 0, 0), 100)
            // any usage shows at least one row, so the front never hides below one row's resolution
            let filled = used > 0 ? max(1, Int((used / 100 * Double(rows)).rounded())) : 0
            for r in 0..<rows {
                let y = y0 + CGFloat(r) * rowH
                let rect = CGRect(x: x, y: y, width: tw, height: 3)
                if r < filled {
                    let front = r == filled - 1
                    var col: Color = used >= 90 ? C_red : (r % 2 == 1 ? C_lo : C_hi)
                    if stale { col = r % 2 == 1 ? Theme.dim : Theme.muted.opacity(0.8) }
                    if front && !stale {
                        col = used >= 90 ? redHot : C_bright
                        let glow = used >= 90 ? C_red : C_bright
                        ctx.drawLayer { l in
                            l.addFilter(.shadow(color: glow, radius: 2))
                            l.fill(Path(rect), with: .color(col))
                        }
                    } else {
                        ctx.fill(Path(rect), with: .color(col))
                    }
                    // little teeth so rows read like descending invaders
                    let tooth = Color(hex: 0x1C1B19)
                    ctx.fill(Path(CGRect(x: x + tw / 2 - 0.5, y: y + 2, width: 1, height: 1)), with: .color(tooth))
                    if tw >= 6 {
                        ctx.fill(Path(CGRect(x: x, y: y + 2, width: 1, height: 1)), with: .color(tooth))
                        ctx.fill(Path(CGRect(x: x + tw - 1, y: y + 2, width: 1, height: 1)), with: .color(tooth))
                    }
                } else {
                    // free rows: a clearly visible dim grid (dimmer when stale)
                    ctx.fill(Path(rect), with: .color(stale ? C_track : Theme.overlay))
                }
            }

            // pace: danger line at expected USED
            guard let m, !stale, let f = m.elapsedFraction(now: now) else { continue }
            let expUsed = f * 100
            let front = y0 + CGFloat(filled) * rowH
            let ly = y0 + CGFloat(expUsed / 100) * L
            if used > expUsed + 1 && filled > 0 {
                let a = 0.2 + 0.1 * sin(t * 4)
                ctx.fill(Path(CGRect(x: x - 0.5, y: ly, width: tw + 1, height: max(0, front - ly))),
                         with: .color(C_red.opacity(a)))
            }
            if expUsed > 0.5 {
                // pace marker: small arrows beside the column (never across the rows)
                let hot = used > expUsed + 1
                let col = hot ? C_bright : C_cream
                let yy = min(max(ly.rounded(), y0 + 1), y0 + L - InvaderGeo.rowTail - 2)
                let onLeft = n == 1 || i == 0
                let onRight = n == 1 || i == n - 1
                var arrow = Path()
                if g.narrow {
                    if onLeft { arrow.addRect(CGRect(x: x - 2.5, y: yy, width: 1.5, height: 1)) }
                    if onRight { arrow.addRect(CGRect(x: x + tw + 1, y: yy, width: 1.5, height: 1)) }
                } else {
                    if onLeft {   // ▸
                        arrow.addRect(CGRect(x: x - 4, y: yy - 1, width: 1, height: 3))
                        arrow.addRect(CGRect(x: x - 3, y: yy, width: 1, height: 1))
                    }
                    if onRight {  // ◂
                        arrow.addRect(CGRect(x: x + tw + 3, y: yy - 1, width: 1, height: 3))
                        arrow.addRect(CGRect(x: x + tw + 2, y: yy, width: 1, height: 1))
                    }
                }
                ctx.fill(arrow, with: .color(col))
            }
        }

        // cannon
        let cy = y0 + L - InvaderGeo.rowTail + InvaderGeo.gap
        let blinkOff = st.empty && Int(t * 2.5) % 2 == 0
        if !blinkOff {
            sprite(&ctx, InvaderArt.cannon.map { $0 }, x: (mid - 2.5 * u).rounded(), y: cy, u: u,
                   body: st.empty ? C_red : (stale ? Theme.dim : C_sand), eye: C_sand)
        }

        // remaining %
        if !meters.isEmpty {
            let rem = meters.map(\.remaining).min() ?? 0
            number(&ctx, rem, cx: mid, y: cy + 3 * u + InvaderGeo.gap, u: u,
                   color: stale ? Theme.dim : (rem <= 10 ? C_red : C_hi))
        }
    }

    static func sprite(_ ctx: inout GraphicsContext, _ rows: [String], x: CGFloat, y: CGFloat, u: CGFloat,
                       body: Color, eye: Color) {
        var bodyPath = Path(), eyePath = Path()
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch != "." {
                let rect = CGRect(x: x + CGFloat(c) * u, y: y + CGFloat(r) * u, width: u, height: u)
                if ch == "E" { eyePath.addRect(rect) } else { bodyPath.addRect(rect) }
            }
        }
        ctx.fill(bodyPath, with: .color(body))
        ctx.fill(eyePath, with: .color(eye))
    }

    static func number(_ ctx: inout GraphicsContext, _ n: Double, cx: CGFloat, y: CGFloat, u: CGFloat, color: Color) {
        let s = String(Int(max(0, n).rounded()))
        let widths = s.map { CGFloat(InvaderArt.digits[$0]?[0].count ?? 3) }
        let total = widths.reduce(0, +) * u + CGFloat(s.count - 1) * u
        var x = (cx - total / 2).rounded()
        var path = Path()
        for (i, ch) in s.enumerated() {
            for (r, row) in (InvaderArt.digits[ch] ?? []).enumerated() {
                for (c, bit) in row.enumerated() where bit == "1" {
                    path.addRect(CGRect(x: x + CGFloat(c) * u, y: y + CGFloat(r) * u, width: u, height: u))
                }
            }
            x += widths[i] * u + u
        }
        ctx.fill(path, with: .color(color))
    }
}
