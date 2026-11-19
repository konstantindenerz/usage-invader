// "Mechanoonna" palette (warm, desaturated; red + amber families only),
// pixel font helpers, subtle warm glow.
import SwiftUI
import CoreText

enum Theme {
    // Backgrounds
    static let bg = Color(hex: 0x1C1B19)
    static let bg2 = Color(hex: 0x2A2825)
    static let surface = Color(hex: 0x32302C)
    static let selection = Color(hex: 0x3A3733)
    static let overlay = Color(hex: 0x43403A)
    /// Panel fill opacity over the behind-window blur (mirrors ghostty 70% + blur).
    static let backgroundOpacity = 0.72

    // Foregrounds
    static let dim = Color(hex: 0x6B655C)       // comments
    static let muted = Color(hex: 0x908D88)     // secondary text
    static let sand = Color(hex: 0xD4BD99)      // default fg
    static let fgLight = Color(hex: 0xEBDBB2)
    static let cream = Color(hex: 0xF0E4C5)     // header, text on accent
    static let lightest = Color(hex: 0xFFF8E8)

    // Amber family (numbers / fill)
    static let amber = Color(hex: 0xC2A571)
    static let amberHi = Color(hex: 0xE7C07C)
    static let amberBright = Color(hex: 0xF7DF97)

    // Red: the sole accent — active/binding limit and critical only.
    static let accent = Color(hex: 0xD94E38)
    static let red = Color(hex: 0xC5564A)

    static let cornerRadius: CGFloat = 8
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Fonts

enum Fonts {
    /// Register bundled pixel font(s). Called once at launch by the shell. Safe to call repeatedly.
    static func register() { _ = available }

    /// True when Silkscreen was registered (or already installed).
    static let available: Bool = {
        let names = ["Silkscreen-Regular", "Silkscreen-Bold"]
        var ok = false
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf")
                    ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Resources")
            else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                ok = true
            } else if let err = error?.takeRetainedValue(),
                      CFErrorGetCode(err) == CTFontManagerError.alreadyRegistered.rawValue {
                ok = true
            }
        }
        return ok
    }()
}

extension Font {
    /// Silkscreen pixel font. Looks crisp at multiples of 8pt (8, 16).
    static func pixel(_ size: CGFloat, bold: Bool = false) -> Font {
        if Fonts.available {
            return .custom(bold ? "Silkscreen-Bold" : "Silkscreen-Regular", fixedSize: size)
        }
        return .system(size: size * 0.95, weight: bold ? .bold : .regular, design: .monospaced)
    }
}

// MARK: - Glow

extension View {
    /// Subtle warm bloom (a hint of CRT, not neon). Apply on groups rather than per-leaf.
    func warmGlow(_ color: Color = Theme.amber, intensity: Double = 1) -> some View {
        self
            .shadow(color: color.opacity(0.28 * intensity), radius: 1)
            .shadow(color: color.opacity(0.12 * intensity), radius: 5)
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// When true (snapshots), skip boot/blink animations and render final state.
    @Entry var pixelStill: Bool = false
    /// Fixed clock for snapshots (pace marker / countdowns). nil = wall clock.
    @Entry var pixelNow: Date? = nil
    /// Snapshot-only: force a collapsed skin without touching the user's persisted setting.
    @Entry var stripStyleOverride: StripStyle? = nil
}

// MARK: - Formatting

enum PixelFormat {
    static func countdown(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "RST --" }
        if interval <= 0 { return "RST NOW" }
        return "RST " + duration(interval)
    }

    /// "3d 11h", "4h 12m", "12m 30s", "59s".
    static func duration(_ interval: TimeInterval) -> String {
        let s = Int(min(max(0, interval), 9_999 * 86_400).rounded(.up))
        if s >= 86_400 { return "\(s / 86_400)d \((s % 86_400) / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "--" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    /// "TUE 14:00" (or just "14:00" when it's today).
    static func dryTime(_ date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date).uppercased()
    }

    static func percent(_ p: Double) -> String {
        "\(Int(min(max(p, 0), 999).rounded()))%"
    }
}

// MARK: - Blink

/// Hard on/off blink driven by a low-rate TimelineView (2-3 ticks/sec). Phase is derived
/// from wall-clock time so every blinker on screen stays in sync.
struct Blink<Content: View>: View {
    var period: Double = 0.5
    var enabled: Bool = true
    @ViewBuilder var content: (_ on: Bool) -> Content
    @Environment(\.pixelStill) private var still

    var body: some View {
        if !enabled || still {
            content(true)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: period)) { ctx in
                content(Int((ctx.date.timeIntervalSinceReferenceDate / period).rounded(.down)) % 2 == 0)
            }
        }
    }
}
