// Location and permissions of the app's cache files.
import Foundation

enum CacheFiles {
    static func url(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("UsageInvader").appendingPathComponent(name)
    }

    /// Writes atomically, readable by the owner only: the snapshot holds the account email and plan.
    static func write(_ data: Data, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Also tighten a directory or file created by an earlier version.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
