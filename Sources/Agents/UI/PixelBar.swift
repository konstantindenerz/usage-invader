// Segmented pixel "fuel gauge": lit blocks = REMAINING quota.
import SwiftUI

/// Alarm tier by quota left: normal (>30% left), warning (≤30% left), alarm (≤10% left),
/// overload (nothing left / empty).
enum AlarmLevel {
    case normal, warning, alarm, overload

    init(percent: Double, severity: Severity = .normal) {
        if percent >= 100 { self = .overload }
        else if percent >= 90 { self = .alarm }
        else if percent >= 70 || severity == .warning { self = .warning }
        else { self = .normal }
    }
}

struct PixelBar: View {
    enum Direction { case horizontal, vertical }

    /// Percent USED (meter.percent). The bar shows what's left: 100 - percent.
    var percent: Double
    var segments: Int
    var direction: Direction = .horizontal
    /// Block length along the bar axis.
    var blockLength: CGFloat = 5
    /// Block thickness across the bar axis.
    var thickness: CGFloat = 7
    var gap: CGFloat = 1
    var stale: Bool = false
    var severity: Severity = .normal
    /// Server says this is the binding limit -> red (the "active window" of the meters).
    var isActive: Bool = false
    /// Chrome-less style for the slim strip: bars float over the desktop, so lit blocks get a
    /// soft dark outline and unlit blocks a dark translucent fill (legible on light and dark).
    var floating: Bool = false
    /// Pace marker: the % that WOULD be left with an even burn (Meter.expectedRemaining).
    var paceMark: Double? = nil

    @Environment(\.pixelStill) private var still
    @State private var shown: Int = 0
    @State private var stepper: Task<Void, Never>?

    private var target: Int {
        let left = 100 - min(max(percent, 0), 100)
        if left <= 0 { return 0 }
        if left >= 100 { return segments }
        // Anything left keeps one block lit; never show full once anything is used.
        return min(segments - 1, max(1, Int((left / 100 * Double(segments)).rounded())))
    }

    /// Red territory: ≥90%, or the binding limit.
    private var isHot: Bool { !stale && (level == .alarm || level == .overload || isActive) }

    private var level: AlarmLevel { stale ? .normal : AlarmLevel(percent: percent, severity: severity) }

    var body: some View {
        let lit = still ? target : shown
        Blink(period: level == .overload ? 0.35 : 0.5, enabled: level == .alarm || level == .overload) { on in
            // Track (unlit) and fuel (lit) are separate layers so the hot red bloom only
            // surrounds lit blocks instead of smudging the whole track.
            ZStack {
                stack(lit: lit, on: on, layer: .track)
                stack(lit: lit, on: on, layer: .fuel)
                    .shadow(color: Theme.accent.opacity(isHot && !floating ? 0.5 : 0), radius: 2)
            }
            .overlay(alignment: direction == .horizontal ? .leading : .bottom) { paceLine }
        }
        .modifier(FloatHalo(enabled: floating))
        .onAppear { step(to: target) }
        .onChange(of: target) { _, t in step(to: t) }
        .onDisappear { stepper?.cancel() }
        .accessibilityLabel("\(Int(100 - min(max(percent, 0), 100))) percent left")
    }

    @ViewBuilder
    private func stack(lit: Int, on: Bool, layer: Layer) -> some View {
        let blocks = ForEach(0..<segments, id: \.self) { i in
            let isLit = i < lit
            let c: Color = layer == .track ? (isLit ? .clear : color(index: i, lit: lit, on: on))
                                           : (isLit ? color(index: i, lit: lit, on: on) : .clear)
            RoundedRectangle(cornerRadius: floating ? 1 : 0, style: .continuous)
                .fill(c)
                .overlay {
                    // Crisp dark rim keeps lit blocks legible on a light desktop.
                    if floating && layer == .fuel && isLit {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .strokeBorder(Theme.bg.opacity(0.55), lineWidth: 0.5)
                    }
                }
                .frame(width: direction == .horizontal ? blockLength : thickness,
                       height: direction == .horizontal ? thickness : blockLength)
        }
        switch direction {
        case .horizontal:
            HStack(spacing: gap) { blocks }
        case .vertical:
            // Index 0 at the bottom.
            VStack(spacing: gap) { blocks }.rotationEffect(.degrees(180))
        }
    }

    private func color(index i: Int, lit: Int, on: Bool) -> Color {
        guard i < lit else {
            // Empty tank: the unlit track itself pulses red.
            if level == .overload { return on ? Theme.red.opacity(0.55) : unlit }
            // Pace debt: the gap between the fuel and where it should be glows faintly red.
            if behind && i < markBlock { return Theme.accent.opacity(0.28) }
            return unlit
        }
        if stale { return floating ? Theme.muted : Theme.dim }
        if level == .alarm || isActive {
            // Head block pulses when nearly drained.
            if level == .alarm && i == lit - 1 { return on ? Theme.accent : Theme.red.opacity(0.45) }
            return Theme.accent
        }
        if level == .warning && i == lit - 1 { return Theme.amberBright }
        // Amber warms toward the top of the tank.
        return Double(i) / Double(max(1, segments - 1)) < 0.55 ? Theme.amber : Theme.amberHi
    }

    private enum Layer { case track, fuel }

    private var remainingPct: Double { 100 - min(max(percent, 0), 100) }
    /// Burning faster than an even pace.
    private var behind: Bool { !stale && (paceMark.map { remainingPct < $0 - 0.5 } ?? false) }
    private var markBlock: Int {
        guard let m = paceMark else { return 0 }
        return Int((min(max(m, 0), 100) / 100 * Double(segments)).rounded())
    }
    private var totalLength: CGFloat { CGFloat(segments) * blockLength + CGFloat(segments - 1) * gap }

    /// Cream hairline across the bar at the expected-remaining level; amber when behind pace.
    @ViewBuilder private var paceLine: some View {
        if let m = paceMark, !stale, m > 0.5, m < 99.5 {
            let pos = totalLength * CGFloat(m / 100)
            let color = behind ? Theme.amberBright : Theme.cream
            if direction == .horizontal {
                Rectangle().fill(color)
                    .frame(width: 1, height: thickness + 4)
                    .offset(x: pos - 0.5)
                    .shadow(color: color.opacity(0.5), radius: 1.5)
            } else {
                Rectangle().fill(color)
                    .frame(width: thickness + 2, height: 1)
                    .offset(y: -(pos - 0.5))
                    .shadow(color: color.opacity(0.5), radius: 1.5)
            }
        }
    }

    private var unlit: Color { floating ? Theme.bg.opacity(0.42) : Theme.overlay }

    private func step(to t: Int) {
        stepper?.cancel()
        if still { shown = t; return }
        stepper = Task { @MainActor in
            while shown != t {
                try? await Task.sleep(for: .milliseconds(22))
                if Task.isCancelled { return }
                shown += shown < t ? 1 : -1
            }
        }
    }
}

