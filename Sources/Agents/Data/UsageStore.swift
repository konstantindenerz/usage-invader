// Polls usage for all discovered accounts.
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    /// Visible snapshots, already filtered by AppSettings.hidden and sorted by AppSettings.order.
    var snapshots: [AccountSnapshot] = []
    /// All discovered accounts including hidden ones (for settings UI).
    var allAccounts: [AccountInfo] = []
    var isRefreshing = false
    var lastRefresh: Date?

    // Internal state (not observed).
    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private var all: [String: AccountSnapshot] = [:]
    @ObservationIgnored private var services: [String] = []
    @ObservationIgnored private var profiles: [String: AccountProfile] = [:]
    @ObservationIgnored private var subscriptionTypes: [String: String] = [:]
    /// Per-account "don't ask before" times from 429 responses. Persisted, so a restart
    /// doesn't hit the API again while it is still rate limiting us.
    @ObservationIgnored private var retryUntil: [String: Date] = UsageStore.loadRetryUntil() {
        didSet { UsageStore.saveRetryUntil(retryUntil) }
    }
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            snapshots = AccountSnapshot.demo
            allAccounts = snapshots.map(\.account)
            return
        }
        for s in SnapshotCache.load() {
            all[s.account.service] = s
            services.append(s.account.service)
        }
        publish()
    }

    /// Start polling (AppSettings.shared.pollInterval). Idempotent.
    func start() {
        guard !demo, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = max(30, AppSettings.shared.pollInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Give the network a moment to come back after wake.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refresh()
            }
        }
        // Re-apply aliases/hidden/order when settings change.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish() }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
        wakeObserver = nil
        settingsObserver = nil
    }

    /// Rediscover keychain accounts and fetch usage for all of them.
    func refresh() async {
        if demo { lastRefresh = Date(); return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }

        let discovered = await Keychain.discoverServices()
        // If discovery fails entirely (empty), keep cached accounts rather than wiping the UI.
        if !discovered.isEmpty {
            services = discovered
            for key in all.keys where !discovered.contains(key) { all[key] = nil }
        }

        let now = Date()
        let toFetch = services.filter { (retryUntil[$0] ?? .distantPast) <= now }
        let needProfile = Set(services.filter { profiles[$0] == nil })

        let results = await withTaskGroup(of: AccountFetchResult.self) { group -> [AccountFetchResult] in
            for svc in toFetch {
                let np = needProfile.contains(svc)
                group.addTask { await AccountFetcher.fetch(service: svc, needProfile: np) }
            }
            var out: [AccountFetchResult] = []
            for await r in group { out.append(r) }
            return out
        }

        for r in results { apply(r) }
        // Accounts skipped because of a pending Retry-After show as throttled, not as loading.
        for svc in services where !toFetch.contains(svc) && all[svc]?.status == .loading {
            all[svc]?.status = .rateLimited
        }
        // Ensure every discovered service has a snapshot.
        for svc in services where all[svc] == nil {
            all[svc] = AccountSnapshot(account: AccountInfo(service: svc), meters: [], extraUsage: nil,
                                       status: .loading, updatedAt: nil)
        }
        publish()
        SnapshotCache.save(services.compactMap { all[$0] })
    }

    // MARK: - Private

    private static let retryKey = "retryUntil"

    private static func loadRetryUntil() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: retryKey) as? [String: Double] ?? [:]
        let now = Date()
        return raw.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value > now }
    }

    private static func saveRetryUntil(_ value: [String: Date]) {
        UserDefaults.standard.set(value.mapValues { $0.timeIntervalSince1970 }, forKey: retryKey)
    }

    private func apply(_ r: AccountFetchResult) {
        if let p = r.profile { profiles[r.service] = p }
        if let st = r.subscriptionType { subscriptionTypes[r.service] = st }
        if let until = r.retryUntil { retryUntil[r.service] = until } else { retryUntil[r.service] = nil }

        var snap = all[r.service] ?? AccountSnapshot(account: AccountInfo(service: r.service), meters: [],
                                                     extraUsage: nil, status: .loading, updatedAt: nil)
        snap.status = r.status
        if let m = r.meters {
            snap.meters = m
            snap.extraUsage = r.extraUsage
            snap.updatedAt = Date()
        }
        if let p = profiles[r.service] {
            snap.account.email = p.email ?? snap.account.email
            snap.account.displayName = p.displayName ?? snap.account.displayName
            snap.account.plan = p.plan ?? snap.account.plan
        }
        if snap.account.plan == nil, let st = subscriptionTypes[r.service], !st.isEmpty {
            snap.account.plan = st.prefix(1).uppercased() + st.dropFirst()
        }
        all[r.service] = snap
    }

    /// Apply settings (aliases, hidden, order) and publish observable state.
    private func publish() {
        let settings = AppSettings.shared
        let order = settings.order
        func rank(_ svc: String) -> (Int, Int, String) {
            if let i = order.firstIndex(of: svc) { return (0, i, svc) }
            if svc == Keychain.defaultService { return (1, 0, svc) }
            return (1, 1 + (services.firstIndex(of: svc) ?? Int.max - 1), svc)
        }
        let sorted = all.values
            .map { s -> AccountSnapshot in
                var s = s
                let a = settings.aliases[s.account.service]?.trimmingCharacters(in: .whitespaces)
                s.account.alias = (a?.isEmpty ?? true) ? nil : a
                return s
            }
            .sorted { rank($0.account.service) < rank($1.account.service) }
        let accounts = sorted.map(\.account)
        let visible = sorted.filter { !settings.hidden.contains($0.account.service) }
        if accounts != allAccounts { allAccounts = accounts }
        if visible != snapshots { snapshots = visible }
    }
}

/// CLI: `Agents --dump` prints discovered accounts + parsed meters, then exits.
/// Nonisolated: runs from `main()` while the main thread is blocked on a semaphore.
enum DumpCommand {
    static func run() async -> Int32 {
        let services = await Keychain.discoverServices()
        if services.isEmpty {
            print("No \"\(Keychain.servicePrefix)*\" keychain items found.")
            return 0
        }
        let results = await withTaskGroup(of: AccountFetchResult.self) { group -> [AccountFetchResult] in
            for svc in services { group.addTask { await AccountFetcher.fetch(service: svc, needProfile: true) } }
            var out: [AccountFetchResult] = []
            for await r in group { out.append(r) }
            return out
        }
        func rank(_ svc: String) -> (Int, Int) {
            (svc == Keychain.defaultService ? 0 : 1, services.firstIndex(of: svc) ?? 0)
        }
        let ordered = results.sorted { rank($0.service) < rank($1.service) }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        for r in ordered {
            let info = AccountInfo(service: r.service, email: r.profile?.email, displayName: r.profile?.displayName,
                                   plan: r.profile?.plan)
            var plan = info.plan
            if plan == nil, let st = r.subscriptionType, !st.isEmpty { plan = st.prefix(1).uppercased() + st.dropFirst() }
            print("service: \(r.service)")
            print("  label:  \(info.label)")
            print("  plan:   \(plan ?? "-")")
            print("  status: \(describe(r.status))")
            if let until = r.retryUntil { print("  retry after: \(df.string(from: until))") }
            for m in r.meters ?? [] {
                let label = m.label.padding(toLength: 6, withPad: " ", startingAt: 0)
                let pct = String(format: "%3.0f%%", m.percent)
                let reset = m.resetsAt.map { "resets \(df.string(from: $0))" } ?? "no reset"
                print("  \(label) \(pct)  \(reset)  [\(m.severity.rawValue)]\(m.isActive ? " *active*" : "")")
            }
            if let e = r.extraUsage {
                print("  EXTRA  util=\(e.utilization.map { String(format: "%.0f%%", $0) } ?? "-") used=\(e.usedCredits.map { String($0) } ?? "-") limit=\(e.monthlyLimit.map { String($0) } ?? "-") \(e.currency ?? "")")
            }
            print("")
        }
        return 0
    }

    private static func describe(_ s: AccountStatus) -> String {
        switch s {
        case .loading: return "loading"
        case .ok: return "ok"
        case .tokenExpired: return "tokenExpired (run `claude` to refresh)"
        case .offline: return "offline"
        case .rateLimited: return "rateLimited"
        case .error(let m): return "error: \(m)"
        }
    }
}
