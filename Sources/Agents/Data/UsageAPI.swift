// Anthropic OAuth usage/profile endpoints + lenient decoding + Meter mapping.
import Foundation

// MARK: - Wire models (all optional / lenient)

struct UsageResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        var utilization: Double?
        var resets_at: String?
    }
    struct Extra: Decodable, Sendable {
        var is_enabled: Bool?
        var monthly_limit: Double?
        var used_credits: Double?
        var utilization: Double?
        var currency: String?
    }
    struct Limit: Decodable, Sendable {
        struct Scope: Decodable, Sendable {
            struct Model: Decodable, Sendable {
                var id: String?
                var display_name: String?
            }
            var model: Model?
            var surface: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                model = try? c.decodeIfPresent(Model.self, forKey: .model)
                // surface may be a string or an object; accept string or object's display_name/name.
                if let s = try? c.decodeIfPresent(String.self, forKey: .surface) {
                    surface = s
                } else if let o = try? c.decodeIfPresent([String: LenientValue].self, forKey: .surface) {
                    surface = o["display_name"]?.string ?? o["name"]?.string ?? o["id"]?.string
                }
            }
            enum Keys: String, CodingKey { case model, surface }
        }
        var kind: String?
        var group: String?
        var percent: Double?
        var severity: String?
        var resets_at: String?
        var scope: Scope?
        var is_active: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            group = try? c.decodeIfPresent(String.self, forKey: .group)
            percent = try? c.decodeIfPresent(Double.self, forKey: .percent)
            severity = try? c.decodeIfPresent(String.self, forKey: .severity)
            resets_at = try? c.decodeIfPresent(String.self, forKey: .resets_at)
            scope = try? c.decodeIfPresent(Scope.self, forKey: .scope)
            is_active = try? c.decodeIfPresent(Bool.self, forKey: .is_active)
        }
        enum Keys: String, CodingKey { case kind, group, percent, severity, resets_at, scope, is_active }
    }

    var five_hour: Window?
    var seven_day: Window?
    var seven_day_opus: Window?
    var seven_day_sonnet: Window?
    var extra_usage: Extra?
    var limits: [Limit]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        five_hour = try? c.decodeIfPresent(Window.self, forKey: .five_hour)
        seven_day = try? c.decodeIfPresent(Window.self, forKey: .seven_day)
        seven_day_opus = try? c.decodeIfPresent(Window.self, forKey: .seven_day_opus)
        seven_day_sonnet = try? c.decodeIfPresent(Window.self, forKey: .seven_day_sonnet)
        extra_usage = try? c.decodeIfPresent(Extra.self, forKey: .extra_usage)
        // Decode element-by-element so one malformed entry doesn't drop the rest.
        if let raw = try? c.decodeIfPresent([LenientLimit].self, forKey: .limits) {
            limits = raw.compactMap(\.value)
        }
    }
    enum Keys: String, CodingKey { case five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage, limits }

    private struct LenientLimit: Decodable {
        var value: Limit?
        init(from decoder: Decoder) throws { value = try? Limit(from: decoder) }
    }
}

struct LenientValue: Decodable, Sendable {
    var string: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        string = try? c.decode(String.self)
    }
}

struct ProfileResponse: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        var email: String?
        var display_name: String?
        var full_name: String?
    }
    struct Organization: Decodable, Sendable {
        var name: String?
        var plan_display_name: String?
        var rate_limit_tier: String?
    }
    var account: Account?
    var organization: Organization?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        account = try? c.decodeIfPresent(Account.self, forKey: .account)
        organization = try? c.decodeIfPresent(Organization.self, forKey: .organization)
    }
    enum Keys: String, CodingKey { case account, organization }
}

// MARK: - Fetch

enum FetchError: Error, Sendable {
    case unauthorized
    case rateLimited(until: Date)
    case offline
    case http(Int)
    case decoding
    case other(String)
}

/// The API never redirects. Refusing redirects keeps the bearer token from following one
/// to another host; the 3xx answer then surfaces as an HTTP error.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum UsageAPI {
    static let base = URL(string: "https://api.anthropic.com/api/oauth/")!

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func get(_ path: String, token: String) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("Agents/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .timedOut, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                 .secureConnectionFailed, .cannotLoadFromNetwork:
                throw FetchError.offline
            case .cancelled:
                throw FetchError.other("cancelled")
            default:
                throw FetchError.other(e.localizedDescription)
            }
        } catch {
            throw FetchError.other(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw FetchError.other("no response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited(until: retryAfter(http) ?? Date().addingTimeInterval(300))
        default: throw FetchError.http(http.statusCode)
        }
    }

    static func retryAfter(_ r: HTTPURLResponse) -> Date? {
        guard let v = r.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let s = Double(v) { return Date().addingTimeInterval(max(30, s)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: v)
    }

    static func fetchUsage(token: String) async throws -> UsageResponse {
        let data = try await get("usage", token: token)
        do { return try JSONDecoder().decode(UsageResponse.self, from: data) }
        catch { throw FetchError.decoding }
    }

    static func fetchProfile(token: String) async -> ProfileResponse? {
        guard let data = try? await get("profile", token: token) else { return nil }
        return try? JSONDecoder().decode(ProfileResponse.self, from: data)
    }
}

// MARK: - Mapping

enum UsageMapper {
    // MARK: Untrusted input
    // Values from the API and from the cache file are formatted with `Int(...)` in the UI,
    // which traps on out-of-range numbers, and strings are printed to the terminal by `--dump`.

    /// Percent used, kept in a range the UI can format.
    static func percent(_ v: Double) -> Double {
        v.isFinite ? min(max(v, 0), 999) : 0
    }

    /// Money amount; nil when missing or not a number.
    static func amount(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return min(max(v, 0), 1_000_000_000)
    }

    /// Date within a plausible range (1970 … year 5138); nil otherwise.
    static func date(_ d: Date?) -> Date? {
        guard let d, (0...100_000_000_000).contains(d.timeIntervalSince1970) else { return nil }
        return d
    }

    /// Text without control characters, capped in length.
    static func text(_ s: String?) -> String? {
        guard let s else { return nil }
        let scalars = s.unicodeScalars.filter { $0.properties.generalCategory != .control }
        return String(String(String.UnicodeScalarView(scalars)).prefix(200))
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    static func severity(_ s: String?, percent: Double) -> Severity {
        switch s?.lowercased() {
        case "normal", "ok", "low", "none": return .normal
        case "warning", "warn", "high", "elevated", "medium": return .warning
        case "critical", "exceeded", "blocked", "max": return .critical
        default: return severity(percent: percent)
        }
    }

    static func severity(percent: Double) -> Severity {
        percent >= 90 ? .critical : percent >= 70 ? .warning : .normal
    }

    static func shortLabel(_ s: String) -> String {
        let cleaned = s.uppercased().filter { $0.isLetter || $0.isNumber }
        return String((cleaned.isEmpty ? s.uppercased() : cleaned).prefix(6))
    }

    static func meters(from r: UsageResponse) -> [Meter] {
        var out: [(rank: Int, idx: Int, meter: Meter)] = []
        if let limits = r.limits, !limits.isEmpty {
            for (i, l) in limits.enumerated() {
                guard let kind = text(l.kind), let pct = l.percent.map(Self.percent) else { continue }
                let resets = parseDate(l.resets_at)
                let sev = severity(l.severity, percent: pct)
                let active = l.is_active ?? false
                let k = kind.lowercased()
                if k == "five_hour" || k.contains("session") || k.contains("five_hour") || k == "5h" {
                    out.append((0, i, Meter(id: "five_hour", label: "5H", title: "Current session",
                                            percent: pct, resetsAt: resets, severity: sev, isActive: active)))
                } else if k == "weekly_all" {
                    out.append((1, i, Meter(id: "weekly_all", label: "WEEK", title: "Current week (all models)",
                                            percent: pct, resetsAt: resets, severity: sev, isActive: active)))
                } else if k == "weekly_scoped" {
                    let name = text(l.scope?.model?.display_name ?? l.scope?.surface ?? l.scope?.model?.id) ?? "scoped"
                    out.append((2, i, Meter(id: "weekly_scoped:\(name)", label: shortLabel(name),
                                            title: "Current week (\(name))",
                                            percent: pct, resetsAt: resets, severity: sev, isActive: active)))
                } else {
                    let pretty = kind.replacingOccurrences(of: "_", with: " ").capitalized
                    out.append((3, i, Meter(id: kind, label: shortLabel(kind.replacingOccurrences(of: "weekly_", with: "W")),
                                            title: pretty, percent: pct, resetsAt: resets, severity: sev, isActive: active)))
                }
            }
        } else {
            let legacy: [(UsageResponse.Window?, String, String, String, Int)] = [
                (r.five_hour, "five_hour", "5H", "Current session", 0),
                (r.seven_day, "weekly_all", "WEEK", "Current week (all models)", 1),
                (r.seven_day_sonnet, "weekly_scoped:Sonnet", "SONNET", "Current week (Sonnet)", 2),
                (r.seven_day_opus, "weekly_scoped:Opus", "OPUS", "Current week (Opus)", 2),
            ]
            for (i, (w, id, label, title, rank)) in legacy.enumerated() {
                guard let w, let pct = w.utilization.map(Self.percent) else { continue }
                out.append((rank, i, Meter(id: id, label: label, title: title, percent: pct,
                                           resetsAt: parseDate(w.resets_at),
                                           severity: severity(percent: pct), isActive: false)))
            }
            // Mark the highest as active if nothing says otherwise.
            if let maxIdx = out.indices.max(by: { out[$0].meter.percent < out[$1].meter.percent }),
               out[maxIdx].meter.percent >= 100 {
                out[maxIdx].meter.isActive = true
            }
        }
        // Dedupe ids (keep first), stable order by rank then server order.
        var seen = Set<String>()
        return out.sorted { ($0.rank, $0.idx) < ($1.rank, $1.idx) }
            .map(\.meter)
            .filter { seen.insert($0.id).inserted }
    }

    static func extra(from r: UsageResponse) -> ExtraUsage? {
        guard let e = r.extra_usage, e.is_enabled == true else { return nil }
        return ExtraUsage(isEnabled: true, utilization: e.utilization.map(Self.percent),
                          usedCredits: amount(e.used_credits), monthlyLimit: amount(e.monthly_limit),
                          currency: text(e.currency))
    }
}

// MARK: - Per-account fetch (nonisolated; used by UsageStore and DumpCommand)

struct AccountProfile: Sendable, Equatable {
    var email: String?
    var displayName: String?
    var plan: String?
}

struct AccountFetchResult: Sendable {
    var service: String
    var status: AccountStatus
    /// nil → keep previous meters.
    var meters: [Meter]?
    var extraUsage: ExtraUsage?
    var profile: AccountProfile?
    var subscriptionType: String?
    var retryUntil: Date?
    /// True once a request was actually sent (not for missing or locally expired credentials).
    var requested = false
}

enum AccountFetcher {
    static func planName(_ profile: ProfileResponse?, subscription: String?) -> String? {
        if let p = profile?.organization?.plan_display_name, !p.isEmpty { return p }
        guard let s = subscription, !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func fetch(service: String, needProfile: Bool) async -> AccountFetchResult {
        var result = AccountFetchResult(service: service, status: .loading)
        guard let creds = await Keychain.readCredentials(service: service) else {
            result.status = .error("no credentials")
            return result
        }
        result.subscriptionType = UsageMapper.text(creds.subscriptionType)
        if creds.isExpired {
            result.status = .tokenExpired
            return result
        }
        let token = creds.accessToken
        result.requested = true
        async let profileTask: ProfileResponse? = needProfile ? UsageAPI.fetchProfile(token: token) : nil
        do {
            let usage = try await UsageAPI.fetchUsage(token: token)
            result.meters = UsageMapper.meters(from: usage)
            result.extraUsage = UsageMapper.extra(from: usage)
            result.status = .ok
        } catch let e as FetchError {
            switch e {
            case .unauthorized: result.status = .tokenExpired
            case .rateLimited(let until): result.status = .rateLimited; result.retryUntil = until
            case .offline: result.status = .offline
            case .http(let code): result.status = .error("HTTP \(code)")
            case .decoding: result.status = .error("bad response")
            case .other(let m): result.status = .error(m)
            }
        } catch {
            result.status = .error(error.localizedDescription)
        }
        let p = await profileTask
        if let p {
            result.profile = AccountProfile(
                email: UsageMapper.text(p.account?.email),
                displayName: UsageMapper.text(p.account?.display_name ?? p.account?.full_name),
                plan: UsageMapper.text(planName(p, subscription: creds.subscriptionType)))
        }
        return result
    }
}
