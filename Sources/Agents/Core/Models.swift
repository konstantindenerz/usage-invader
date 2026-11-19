// Core models shared by the data layer, the UI and the shell.
import Foundation
import SwiftUI

enum Severity: String, Equatable, Sendable {
    case normal, warning, critical
}

/// One usage window, e.g. "weekly (all models)" or "weekly Fable".
struct Meter: Identifiable, Equatable, Sendable {
    /// Stable id, e.g. "weekly_all", "weekly_scoped:Fable", "five_hour".
    var id: String
    /// Short uppercase label for the pixel UI, max ~6 chars: "WEEK", "FABLE", "5H".
    var label: String
    /// Long human title: "Current week (all models)".
    var title: String
    /// Percent USED, 0...100 (may exceed 100 → clamp in UI).
    var percent: Double
    var resetsAt: Date?
    var severity: Severity
    /// Server says this is the limit currently binding.
    var isActive: Bool

    var remaining: Double { max(0, 100 - percent) }

    /// The server flags one meter as the binding limit even right after a reset (0%).
    /// Only treat it as "hot" (red pill / red bar) once it actually matters.
    var isBinding: Bool { isActive && (percent >= 70 || severity != .normal) }
}

struct ExtraUsage: Equatable, Sendable {
    var isEnabled: Bool
    /// 0...100 used, if known.
    var utilization: Double?
    var usedCredits: Double?
    var monthlyLimit: Double?
    var currency: String?
}

struct AccountInfo: Identifiable, Equatable, Sendable {
    /// Keychain service name, e.g. "Claude Code-credentials" or "Claude Code-credentials-1a2b3c4d".
    var id: String { service }
    var service: String
    var email: String?
    var displayName: String?
    /// e.g. "Max", "Pro", "Team".
    var plan: String?
    /// User alias from settings (wins over email for display).
    var alias: String?

    var label: String { alias ?? email ?? displayName ?? service }

    /// Two-letter uppercase tag for the collapsed strip.
    var tag: String {
        let base = (alias ?? displayName ?? email ?? "CC")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters: String
        if base.count >= 2 {
            letters = String(base[0].prefix(1)) + String(base[1].prefix(1))
        } else {
            letters = String((base.first ?? "CC").prefix(2))
        }
        return letters.uppercased()
    }
}

enum AccountStatus: Equatable, Sendable {
    case loading
    case ok
    /// Token expired locally — show last values, hint "run claude".
    case tokenExpired
    /// Network unreachable.
    case offline
    /// 429 — backing off.
    case rateLimited
    case error(String)
}

struct AccountSnapshot: Identifiable, Equatable, Sendable {
    var id: String { account.id }
    var account: AccountInfo
    var meters: [Meter]
    var extraUsage: ExtraUsage?
    var status: AccountStatus
    /// Time of last successful fetch.
    var updatedAt: Date?

    var isStale: Bool { status != .ok && status != .loading }
    /// Highest used percent across meters (drives alarm state).
    var peak: Double { meters.map(\.percent).max() ?? 0 }
}

/// Skins for the collapsed strip. The expanded panel is the same for all.
enum StripStyle: String, CaseIterable, Sendable {
    case invader, instrument
    var title: String { self == .invader ? "Invader" : "Instrument" }
}

/// Persisted user preferences (UserDefaults-backed).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var aliases: [String: String] {
        didSet { UserDefaults.standard.set(aliases, forKey: "aliases") }
    }
    var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hidden") }
    }
    /// Keychain services in display order (unknown ones appended).
    var order: [String] {
        didSet { UserDefaults.standard.set(order, forKey: "order") }
    }
    var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: "pollInterval") }
    }
    var scanlines: Bool {
        didSet { UserDefaults.standard.set(scanlines, forKey: "scanlines") }
    }
    /// Look of the collapsed strip.
    var stripStyle: StripStyle {
        didSet { UserDefaults.standard.set(stripStyle.rawValue, forKey: "stripStyle") }
    }

    private init() {
        let d = UserDefaults.standard
        aliases = d.dictionary(forKey: "aliases") as? [String: String] ?? [:]
        hidden = Set(d.stringArray(forKey: "hidden") ?? [])
        order = d.stringArray(forKey: "order") ?? []
        let p = d.double(forKey: "pollInterval")
        pollInterval = p > 0 ? p : 120
        scanlines = d.object(forKey: "scanlines") as? Bool ?? true
        stripStyle = StripStyle(rawValue: d.string(forKey: "stripStyle") ?? "") ?? .invader
    }
}

// MARK: - Preview / demo data (used by previews, snapshots and the `--demo` flag)

extension AccountSnapshot {
    static let demo: [AccountSnapshot] = {
        let now = Date()
        return [
            AccountSnapshot(
                account: AccountInfo(service: "Claude Code-credentials", email: "kode@example.com", displayName: "Kode", plan: "Max"),
                meters: [
                    Meter(id: "weekly_all", label: "WEEK", title: "Current week (all models)", percent: 92, resetsAt: now.addingTimeInterval(3600 * 5), severity: .critical, isActive: false),
                    Meter(id: "weekly_scoped:Fable", label: "FABLE", title: "Current week (Fable)", percent: 100, resetsAt: now.addingTimeInterval(3600 * 5), severity: .critical, isActive: true),
                ],
                extraUsage: nil, status: .ok, updatedAt: now),
            AccountSnapshot(
                account: AccountInfo(service: "Claude Code-credentials-1a2b3c4d", email: "work@example.com", displayName: "Work Account", plan: "Team", alias: "Work"),
                meters: [
                    Meter(id: "five_hour", label: "5H", title: "Current session", percent: 18, resetsAt: now.addingTimeInterval(3600 * 2.3), severity: .normal, isActive: false),
                    Meter(id: "weekly_all", label: "WEEK", title: "Current week (all models)", percent: 41, resetsAt: now.addingTimeInterval(86400 * 3.4), severity: .normal, isActive: false),
                    Meter(id: "weekly_scoped:Fable", label: "FABLE", title: "Current week (Fable)", percent: 67, resetsAt: now.addingTimeInterval(86400 * 3.4), severity: .warning, isActive: false),
                ],
                extraUsage: ExtraUsage(isEnabled: true, utilization: 12, usedCredits: 6, monthlyLimit: 50, currency: "USD"),
                status: .tokenExpired, updatedAt: now.addingTimeInterval(-1800)),
        ]
    }()
}

// MARK: - Pace (how fast you burn vs. an even burn across the window)

extension Meter {
    /// Length of the rolling window this meter belongs to; nil = unknown (no pace marker).
    var windowLength: TimeInterval? {
        if id == "five_hour" { return 5 * 3600 }
        if id.hasPrefix("weekly") { return 7 * 86_400 }
        return nil
    }

    /// Fraction 0...1 of the window that has elapsed at `now`.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let len = windowLength, let reset = resetsAt else { return nil }
        let left = reset.timeIntervalSince(now)
        return min(1, max(0, 1 - left / len))
    }

    /// Percent that WOULD be left at `now` with a perfectly even burn (0...100).
    /// This is where the pace marker sits on a remaining-gauge.
    func expectedRemaining(now: Date = Date()) -> Double? {
        guard let f = elapsedFraction(now: now) else { return nil }
        return 100 * (1 - f)
    }

    /// remaining − expectedRemaining. Positive = buffer, negative = burning too fast.
    func paceDelta(now: Date = Date()) -> Double? {
        guard let e = expectedRemaining(now: now) else { return nil }
        return remaining - e
    }

    /// When the meter runs dry at the current average rate — only if that's before the reset.
    func projectedEmpty(now: Date = Date()) -> Date? {
        guard let len = windowLength, let reset = resetsAt, percent > 0, percent < 100 else { return nil }
        let start = reset.addingTimeInterval(-len)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 60 else { return nil }
        let rate = percent / elapsed                 // % per second
        let dry = start.addingTimeInterval(100 / rate)
        return dry < reset ? dry : nil
    }
}
