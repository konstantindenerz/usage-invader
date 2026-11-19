// Offline still renderer used by `--snapshot <path>` and `--readme-shots <dir>`.
// Mimics the real context: the strip sits in the gap between a warm-gray translucent terminal
// and a beige paper desktop, at several widths, for several usage scenarios.
import AppKit
import SwiftUI

enum SnapshotRenderer {
    @MainActor
    private static func scenarios() -> [(String, UsageStore)] {
        [
            ("FRESH  0/0 USED", store([one(f: 0.01, week: 0, fable: 0)])),
            ("ON PACE  42/36 @ HALF", store([one(f: 0.50, week: 42, fable: 36)])),
            ("TOO FAST  70/64 @ HALF", store([one(f: 0.50, week: 70, fable: 64)])),
            ("CRITICAL  93/86", store([one(f: 0.80, week: 93, fable: 86)])),
            ("EMPTY  97/100", store([one(f: 0.72, week: 97, fable: 100, bindingFable: true)])),
            ("TWO ACCOUNTS", store(scenarioTwo())),
        ]
    }

    /// Writes the README images (`panel.png`, `strip.png`, `states.png`) into `dir`.
    @MainActor
    static func renderReadmeShots(to dir: URL) {
        Fonts.register()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scenarios = scenarios()
        let two = scenarios[5].1
        let widths: [CGFloat] = [12, 16, 25.5, 34]

        write(panel(store: two, expanded: true), to: dir.appendingPathComponent("panel.png"))

        // Both skins side by side, each at every supported width.
        write(HStack(alignment: .top, spacing: 44) {
            ForEach(StripStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: 12) {
                    Text(style.title.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x4A443D))
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(widths, id: \.self) { w in gapCell(width: w, store: two) }
                    }
                }
                .environment(\.stripStyleOverride, style)
            }
        }, to: dir.appendingPathComponent("strip.png"))

        // Three panels per row keep the text readable at README width.
        write(VStack(alignment: .leading, spacing: 26) {
            ForEach([0, 3], id: \.self) { start in
                HStack(alignment: .top, spacing: 22) {
                    ForEach(Array(scenarios[start..<min(start + 3, 5)].enumerated()), id: \.offset) { _, sc in
                        caption(sc.0) { panel(store: sc.1, expanded: true) }
                    }
                }
            }
        }, to: dir.appendingPathComponent("states.png"))
    }

    @MainActor
    static func render(to url: URL) {
        Fonts.register()

        let scenarios = scenarios()
        let states = UsageStore()
        states.lastRefresh = fixedNow.addingTimeInterval(-40)
        states.isRefreshing = true
        states.snapshots = stateDemo()
        let empty = UsageStore()
        empty.snapshots = [] // never show cached real accounts in renders
        empty.allAccounts = []

        let widths: [CGFloat] = [12, 16, 25.5, 34]

        let scene = VStack(alignment: .leading, spacing: 34) {
            // Row 1: expanded panels.
            HStack(alignment: .top, spacing: 22) {
                ForEach(Array(scenarios.enumerated()), id: \.offset) { _, sc in
                    caption(sc.0) { panel(store: sc.1, expanded: true) }
                }
                caption("STATES") { panel(store: states, expanded: true) }
                caption("EMPTY") { panel(store: empty, expanded: true) }
            }
            // Rows 2+: collapsed INVADER strips in the real-world gap, per scenario.
            ForEach(Array(scenarios.enumerated()), id: \.offset) { _, sc in
                stripRow(sc.0, store: sc.1, widths: widths, style: .invader, extra: [])
            }
            stripRow("STATES + EMPTY", store: states, widths: [12, 30], style: .invader, extra: [empty])
            // Alternative skin for comparison.
            stripRow("INSTRUMENT  TOO FAST", store: scenarios[2].1, widths: widths, style: .instrument, extra: [])
            stripRow("INSTRUMENT  TWO", store: scenarios[5].1, widths: widths, style: .instrument, extra: [])
        }
        write(scene, to: url)
    }

    /// Renders `content` on the paper desktop with the fixed clock and saves it as a PNG.
    @MainActor
    private static func write<V: View>(_ content: V, to url: URL) {
        let scene = content
            .padding(28)
            .background(PaperDesktop())
            .environment(\.pixelStill, true)
            .environment(\.pixelNow, fixedNow)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write("snapshot: render failed\n".data(using: .utf8)!)
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
            print("snapshot: wrote \(url.path) (\(cg.width)x\(cg.height))")
        } catch {
            FileHandle.standardError.write("snapshot: \(error)\n".data(using: .utf8)!)
        }
    }

    // MARK: building blocks

    /// Fixed clock so pace markers / countdowns are deterministic.
    static let fixedNow = Date(timeIntervalSinceReferenceDate: 816_000_000)

    @MainActor
    private static func stripRow(_ title: String, store: UsageStore, widths: [CGFloat], style: StripStyle,
                                 extra: [UsageStore]) -> some View {
        HStack(alignment: .top, spacing: 26) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x4A443D))
                .frame(width: 170, alignment: .leading)
            ForEach(widths, id: \.self) { w in gapCell(width: w, store: store) }
            ForEach(Array(extra.enumerated()), id: \.offset) { _, e in
                ForEach(widths, id: \.self) { w in gapCell(width: w, store: e) }
            }
        }
        .environment(\.stripStyleOverride, style)
    }

    @MainActor
    private static func store(_ snaps: [AccountSnapshot]) -> UsageStore {
        let s = UsageStore()
        s.snapshots = snaps
        s.lastRefresh = fixedNow.addingTimeInterval(-125)
        return s
    }

    private static func caption<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x4A443D))
            content()
        }
    }

    @MainActor
    private static func panel(store: UsageStore, expanded: Bool) -> some View {
        let h = Layout.height(for: store.snapshots)
        return HStack(spacing: 0) {
            OverlayRootView(store: store, isExpanded: expanded)
                .frame(width: expanded ? Layout.expandedWidth : Layout.collapsedWidth, height: h)
            // physical screen edge
            Rectangle().fill(Color(hex: 0x141210)).frame(width: 5, height: h)
        }
    }

    /// Strip of `width` squeezed between a translucent terminal and the screen edge.
    @MainActor
    private static func gapCell(width: CGFloat, store: UsageStore) -> some View {
        let h = Layout.height(for: store.snapshots)
        return VStack(alignment: .trailing, spacing: 6) {
            Text("\(Int(width))PT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x4A443D).opacity(0.8))
            HStack(alignment: .top, spacing: 0) {
                FakeTerminal().frame(width: 54, height: h + 30).clipped()
                OverlayRootView(store: store, isExpanded: false)
                    .frame(width: width, height: h)
                    .padding(.top, 10)
                    .frame(height: h + 30, alignment: .top)
                // physical screen edge
                Rectangle().fill(Color(hex: 0x141210)).frame(width: 5, height: h + 30)
            }
        }
    }

    // MARK: scenarios

    private static func acct(_ email: String, _ plan: String, display: String? = nil) -> AccountInfo {
        AccountInfo(service: "svc-\(email)", email: email, displayName: display, plan: plan)
    }

    /// Meter whose window (7d) is `f` elapsed at fixedNow.
    private static func weekly(_ id: String, _ label: String, f: Double, used: Double, binding: Bool = false) -> Meter {
        Meter(id: id, label: label, title: label, percent: used,
              resetsAt: fixedNow.addingTimeInterval((1 - f) * 7 * 86_400),
              severity: used >= 90 ? .critical : used >= 70 ? .warning : .normal, isActive: binding)
    }

    private static func one(f: Double, week: Double, fable: Double, bindingFable: Bool = false) -> AccountSnapshot {
        AccountSnapshot(account: acct("kode@example.com", "Ultra", display: "Kode"),
                        meters: [weekly("weekly_all", "WEEK", f: f, used: week),
                                 weekly("weekly_scoped:Fable", "FABLE", f: f, used: fable, binding: bindingFable)],
                        extraUsage: nil, status: .ok, updatedAt: fixedNow)
    }

    private static func scenarioTwo() -> [AccountSnapshot] {
        [
            one(f: 0.50, week: 70, fable: 64),
            AccountSnapshot(account: AccountInfo(service: "svc-work", email: "work@example.com", displayName: "Work Account", plan: "Team", alias: "Work"),
                            meters: [
                                Meter(id: "five_hour", label: "5H", title: "Current session", percent: 18,
                                      resetsAt: fixedNow.addingTimeInterval(3600 * 3), severity: .normal, isActive: false),
                                weekly("weekly_all", "WEEK", f: 0.5, used: 31),
                            ],
                            extraUsage: ExtraUsage(isEnabled: true, utilization: 12, usedCredits: 6, monthlyLimit: 50, currency: "USD"),
                            status: .ok, updatedAt: fixedNow),
        ]
    }

    private static func stateDemo() -> [AccountSnapshot] {
        let now = fixedNow
        return [
            AccountSnapshot(account: acct("ops@lab.dev", "Pro"),
                            meters: [
                                Meter(id: "five_hour", label: "5H", title: "", percent: 74, resetsAt: now.addingTimeInterval(1500), severity: .warning, isActive: true),
                                Meter(id: "weekly_all", label: "WEEK", title: "", percent: 33, resetsAt: now.addingTimeInterval(86400 * 2.1), severity: .normal, isActive: false),
                            ],
                            extraUsage: nil, status: .rateLimited, updatedAt: now),
            AccountSnapshot(account: acct("night@lab.dev", "Max"),
                            meters: [
                                Meter(id: "five_hour", label: "5H", title: "", percent: 76, resetsAt: now.addingTimeInterval(45), severity: .warning, isActive: false),
                                Meter(id: "weekly_all", label: "WEEK", title: "", percent: 38, resetsAt: now.addingTimeInterval(86400 * 4.2), severity: .normal, isActive: false),
                            ],
                            extraUsage: nil, status: .offline, updatedAt: now),
            AccountSnapshot(account: acct("new@lab.dev", "Team"), meters: [], extraUsage: nil, status: .loading, updatedAt: nil),
        ]
    }
}

// MARK: - Fake context

/// Beige/sepia paper desktop with a faint deterministic fiber texture.
private struct PaperDesktop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xDCCCAD), Color(hex: 0xD6C5A5), Color(hex: 0xCBB894)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { ctx, size in
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func rnd() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(1 << 31)
                }
                for _ in 0..<Int(size.width * size.height / 90) {
                    let r = CGRect(x: rnd() * size.width, y: rnd() * size.height, width: 1 + rnd() * 2, height: 1)
                    let dark = rnd() > 0.5
                    ctx.fill(Path(r), with: .color((dark ? Color(hex: 0x8A7552) : .white).opacity(0.10 + rnd() * 0.1)))
                }
            }
        }
    }
}

/// Warm-gray translucent terminal window edge (like ghostty at 70% + blur over the paper).
private struct FakeTerminal: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(hex: 0x4A443D).opacity(0.93))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<40, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(hex: i % 7 == 3 ? 0xC2A571 : 0xD4BD99).opacity(0.35))
                        .frame(width: CGFloat([30, 44, 18, 38, 26, 48, 12][i % 7]), height: 3)
                }
            }
            .padding(.top, 14)
            .padding(.leading, 8)
        }
    }
}
