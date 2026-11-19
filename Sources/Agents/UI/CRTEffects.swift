// Terminal surface effects: faint scanlines, shading, edge, blur, glitch, type-on.
import AppKit
import SwiftUI

/// Static scanline overlay: 1px dark line every `pitch` points. Drawn once (Canvas), no animation.
struct Scanlines: View {
    var pitch: CGFloat = 3
    var opacity: Double = 0.07

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += pitch
            }
            ctx.fill(path, with: .color(.black.opacity(opacity)))
        }
        .allowsHitTesting(false)
    }
}

/// Calm surface shading: a faint top sheen and a soft bottom falloff.
struct TubeShading: View {
    var body: some View {
        LinearGradient(colors: [Theme.cream.opacity(0.035), .clear, .clear, .black.opacity(0.18)],
                       startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

/// Behind-window blur (like ghostty's background-blur), masked to the notch silhouette.
struct BackdropBlur: NSViewRepresentable {
    var flare: CGFloat
    var leftRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.maskImage = Self.notchMask(flare: flare, leftRadius: leftRadius)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.maskImage = Self.notchMask(flare: flare, leftRadius: leftRadius)
    }

    /// Stretchable notch mask. Caps: top/bottom f+rL, left rL, right f; the 1pt middle stretches.
    static func notchMask(flare f: CGFloat, leftRadius rL: CGFloat) -> NSImage {
        let f = max(0, f), rL = max(0, rL)
        let size = NSSize(width: rL + f + 1, height: 2 * (f + rL) + 1)
        let img = NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            let path = NotchShape(flare: f, leftRadius: rL).path(in: rect).cgPath
            NSBezierPath(cgPath: path).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: f + rL, left: rL, bottom: f + rL, right: f)
        img.resizingMode = .stretch
        return img
    }
}

/// Apple-notch silhouette growing out of the right screen edge: convex rounded corners on the
/// left, CONCAVE inverse fillets (radius f) on the right that flare into the edge. The body
/// occupies y ∈ [f, h−f]; the flares overhang it by f at the top and bottom.
struct NotchShape: Shape {
    var flare: CGFloat
    var leftRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, leftRadius) }
        set { flare = newValue.first; leftRadius = newValue.second }
    }

    /// Flare radius for a given notch width.
    static func flare(width w: CGFloat) -> CGFloat { min(8, w * 0.45) }

    func path(in rect: CGRect) -> Path { outline(in: rect, closed: true) }

    /// Contour; `closed: false` leaves out the screen-edge side (for the hairline).
    func outline(in rect: CGRect, closed: Bool) -> Path {
        let x0 = rect.minX, y0 = rect.minY, w = rect.width, h = rect.height
        let f = min(flare, w / 2, h / 4)
        let rL = max(0, min(leftRadius, (h - 2 * f) / 2, w - f))
        var p = Path()
        p.move(to: CGPoint(x: x0 + w, y: y0))
        p.addQuadCurve(to: CGPoint(x: x0 + w - f, y: y0 + f), control: CGPoint(x: x0 + w, y: y0 + f))
        p.addLine(to: CGPoint(x: x0 + rL, y: y0 + f))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0 + f), tangent2End: CGPoint(x: x0, y: y0 + f + rL), radius: rL)
        p.addLine(to: CGPoint(x: x0, y: y0 + h - f - rL))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0 + h - f), tangent2End: CGPoint(x: x0 + rL, y: y0 + h - f), radius: rL)
        p.addLine(to: CGPoint(x: x0 + w - f, y: y0 + h - f))
        p.addQuadCurve(to: CGPoint(x: x0 + w, y: y0 + h), control: CGPoint(x: x0 + w, y: y0 + h - f))
        if closed { p.closeSubpath() }
        return p
    }
}

/// Hairline along the notch contour, OPEN at the screen edge and fading out into it.
struct NotchEdge: View {
    var flare: CGFloat
    var leftRadius: CGFloat

    var body: some View {
        GeometryReader { geo in
            let shape = NotchShape(flare: flare, leftRadius: leftRadius)
            let w = geo.size.width
            let fadeStart = max(0, (w - flare * 1.6) / max(w, 1))
            shape.outline(in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 0, dy: 0.5).offsetBy(dx: 0.5, dy: 0), closed: false)
                .stroke(LinearGradient(colors: [Theme.dim.opacity(0.9), Theme.overlay.opacity(0.7)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 1)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: fadeStart),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .allowsHitTesting(false)
    }
}

/// Dotted pixel rule.
struct PixelDivider: View {
    var color: Color = Theme.overlay
    var dot: CGFloat = 2
    var gap: CGFloat = 2
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            var path = Path()
            while x < size.width {
                path.addRect(CGRect(x: x, y: 0, width: dot, height: 1))
                x += dot + gap
            }
            ctx.fill(path, with: .color(color))
        }
        .frame(height: 1)
    }
}

// MARK: - Glitch transition

/// Animatable "signal re-sync": horizontal jitter, faint brightness flash, fade.
struct GlitchModifier: ViewModifier, Animatable {
    var amount: Double // 1 = fully glitched/hidden, 0 = identity
    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        let jitter = sin(amount * 30) * 3 * amount
        content
            .offset(x: jitter)
            .opacity(1 - amount)
            .brightness(amount * 0.12)
            .scaleEffect(x: 1, y: 1 - amount * 0.04, anchor: .center)
    }
}

extension AnyTransition {
    static var glitch: AnyTransition {
        .modifier(active: GlitchModifier(amount: 1), identity: GlitchModifier(amount: 0))
    }
}

// MARK: - Type-on text

/// Terminal-style text that types itself in once when it appears. Layout is reserved
/// up front (hidden full string) so nothing reflows while typing.
struct TypeOn: View {
    let text: String
    var delay: Double = 0
    var charInterval: Double = 0.008

    @Environment(\.pixelStill) private var still
    @State private var count: Int = 0
    @State private var done = false

    var body: some View {
        let visible = (still || done) ? text : String(text.prefix(count))
        Text(text)
            .hidden()
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Text(visible)
                    if !(still || done) && count < text.count && count > 0 {
                        Rectangle().frame(width: 4, height: 6) // typing caret
                    }
                }
                .fixedSize()
            }
            .task {
                guard !still, !done else { return }
                try? await Task.sleep(for: .seconds(delay))
                // Type in chunks so long strings stay fast.
                let chunk = max(1, text.count / 12)
                while count < text.count {
                    if Task.isCancelled { return }
                    count = min(text.count, count + chunk)
                    try? await Task.sleep(for: .seconds(charInterval * Double(chunk)))
                }
                done = true
            }
    }
}
