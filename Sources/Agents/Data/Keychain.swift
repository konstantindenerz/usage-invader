// Reads Claude Code OAuth credentials via /usr/bin/security (never SecItem*,
// never refreshes tokens). Secrets are never logged.
import Foundation

struct ClaudeCredentials: Sendable {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }
}

enum Keychain {
    static let servicePrefix = "Claude Code-credentials"
    static let defaultService = "Claude Code-credentials"

    /// Runs a tool synchronously and returns (exit status, stdout). Call off the main actor.
    static func run(_ path: String, _ args: [String]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        // Read before waiting so a large output cannot deadlock the pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Unique keychain services starting with "Claude Code-credentials" (metadata only, no prompt).
    static func discoverServices() async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            let (_, data) = run("/usr/bin/security", ["dump-keychain"])
            let text = String(decoding: data, as: UTF8.self)
            var seen = Set<String>()
            var result: [String] = []
            for line in text.split(separator: "\n") {
                guard let r = line.range(of: "\"svce\"<blob>=\"") else { continue }
                var rest = line[r.upperBound...]
                guard let end = rest.lastIndex(of: "\"") else { continue }
                rest = rest[..<end]
                let svc = String(rest)
                guard svc.hasPrefix(servicePrefix) else { continue }
                if seen.insert(svc).inserted { result.append(svc) }
            }
            return result
        }.value
    }

    /// Reads and parses the credential JSON for a service. Returns nil if missing/unparseable.
    static func readCredentials(service: String) async -> ClaudeCredentials? {
        await Task.detached(priority: .utility) { () -> ClaudeCredentials? in
            let (status, data) = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
            guard status == 0 else { return nil }
            return parse(data)
        }.value
    }

    static func parse(_ data: Data) -> ClaudeCredentials? {
        var data = data
        // `security -w` may hex-encode non-ASCII payloads; also strip trailing newline.
        if let s = String(data: data, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.hasPrefix("{"), t.count % 2 == 0, t.allSatisfy(\.isHexDigit), let d = Data(hexString: t) {
                data = d
            } else {
                data = Data(t.utf8)
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expires: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }
}

private extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var it = hexString.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(v)
        }
        self.init(bytes)
    }
}
