// Request budget for the usage API. Every fetch — polling, launch, wake, settings changes,
// manual refresh and `--dump` — has to pass this gate, so nothing can hammer the endpoint.
// State lives in a file next to the snapshot cache, shared by the app and the CLI.
import Foundation

struct FetchState: Codable, Equatable, Sendable {
    /// Last time a request was actually sent for this account.
    var lastAttempt: Date?
    /// Don't ask before this time (429 backoff).
    var retryUntil: Date?
    /// Consecutive 429 answers; drives the exponential backoff.
    var throttleCount: Int = 0
    /// Last successful profile fetch (email / plan change rarely).
    var profileAt: Date?
}

enum FetchGate {
    /// Smallest gap between two requests for one account when the user asks explicitly.
    static let manualGap: TimeInterval = 20
    /// Polling never runs faster than this, whatever the settings say.
    static let minPollInterval: TimeInterval = 120
    /// Longest pause after repeated 429s.
    static let maxBackoff: TimeInterval = 1800
    /// The profile is refetched at most this often.
    static let profileMaxAge: TimeInterval = 86_400

    /// Gap required between automatic requests (launch, poll, wake, settings change).
    static func automaticGap(pollInterval: TimeInterval) -> TimeInterval {
        max(minPollInterval, pollInterval) * 0.9
    }

    enum Decision: Equatable {
        case allowed
        /// Server told us to back off until this time.
        case throttled(until: Date)
        /// Asked too recently; the cached values are still fresh.
        case tooSoon(until: Date)
    }

    static func decide(_ state: FetchState?, now: Date, minGap: TimeInterval) -> Decision {
        guard let state else { return .allowed }
        if let until = state.retryUntil, until > now { return .throttled(until: until) }
        if let last = state.lastAttempt {
            let next = last.addingTimeInterval(minGap)
            if next > now { return .tooSoon(until: next) }
        }
        return .allowed
    }

    static func needsProfile(_ state: FetchState?, hasCachedIdentity: Bool, now: Date) -> Bool {
        guard hasCachedIdentity, let at = state?.profileAt else { return true }
        return now.timeIntervalSince(at) > profileMaxAge
    }

    /// Fold the outcome of one fetch into the account's state.
    static func record(_ state: inout FetchState, requested: Bool, serverRetryUntil: Date?,
                       gotProfile: Bool, now: Date) {
        if gotProfile { state.profileAt = now }
        guard requested else { return }
        state.lastAttempt = now
        if let until = serverRetryUntil {
            // The server's Retry-After can be very short while it keeps answering 429:
            // back off 1, 2, 4 … minutes, capped at `maxBackoff`.
            state.throttleCount += 1
            let backoff = min(maxBackoff, 60 * pow(2, Double(state.throttleCount - 1)))
            state.retryUntil = max(until, now.addingTimeInterval(backoff))
        } else {
            state.throttleCount = 0
            state.retryUntil = nil
        }
    }

    // MARK: Persistence

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Agents/fetch-state.json")
    }

    static func load() -> [String: FetchState] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([String: FetchState].self, from: data)) ?? [:]
    }

    static func save(_ states: [String: FetchState]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(states) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
