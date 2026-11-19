// Persists last good snapshots to ~/Library/Caches/Agents/last.json.
// Codable mirrors live here so Core models stay free of Codable.
import Foundation

private struct CachedMeter: Codable {
    var id, label, title: String
    var percent: Double
    var resetsAt: Date?
    var severity: String
    var isActive: Bool
}

private struct CachedExtra: Codable {
    var isEnabled: Bool
    var utilization, usedCredits, monthlyLimit: Double?
    var currency: String?
}

private struct CachedSnapshot: Codable {
    var service: String
    var email, displayName, plan: String?
    var meters: [CachedMeter]
    var extra: CachedExtra?
    var updatedAt: Date?
}

private struct CacheFile: Codable {
    var version = 1
    var snapshots: [CachedSnapshot]
}

enum SnapshotCache {
    static var url: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Agents/last.json")
    }

    /// Loaded snapshots have status `.loading` and no alias (store applies aliases).
    /// The file is treated as untrusted: numbers and dates are brought into range.
    static func load() -> [AccountSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let file = try? dec.decode(CacheFile.self, from: data) else { return [] }
        return file.snapshots.map { c in
            AccountSnapshot(
                account: AccountInfo(service: c.service, email: c.email, displayName: c.displayName, plan: c.plan),
                meters: c.meters.map {
                    Meter(id: $0.id, label: $0.label, title: $0.title, percent: UsageMapper.percent($0.percent),
                          resetsAt: UsageMapper.date($0.resetsAt),
                          severity: Severity(rawValue: $0.severity) ?? .normal, isActive: $0.isActive)
                },
                extraUsage: c.extra.map {
                    ExtraUsage(isEnabled: $0.isEnabled, utilization: $0.utilization.map(UsageMapper.percent),
                               usedCredits: UsageMapper.amount($0.usedCredits),
                               monthlyLimit: UsageMapper.amount($0.monthlyLimit), currency: $0.currency)
                },
                status: .loading,
                updatedAt: UsageMapper.date(c.updatedAt))
        }
    }

    static func save(_ snapshots: [AccountSnapshot]) {
        let file = CacheFile(snapshots: snapshots.filter { !$0.meters.isEmpty }.map { s in
            CachedSnapshot(
                service: s.account.service, email: s.account.email, displayName: s.account.displayName,
                plan: s.account.plan,
                meters: s.meters.map {
                    CachedMeter(id: $0.id, label: $0.label, title: $0.title, percent: $0.percent,
                                resetsAt: $0.resetsAt, severity: $0.severity.rawValue, isActive: $0.isActive)
                },
                extra: s.extraUsage.map {
                    CachedExtra(isEnabled: $0.isEnabled, utilization: $0.utilization, usedCredits: $0.usedCredits,
                                monthlyLimit: $0.monthlyLimit, currency: $0.currency)
                },
                updatedAt: s.updatedAt)
        })
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(file) else { return }
        let u = url
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
    }
}
