import Foundation

/// Saves accounts, mailbox lists and message summaries as JSON files so the
/// app opens instantly with the last known state.
enum Persistence {
    struct Snapshot: Codable {
        var accounts: [MailAccount] = []
        var mailboxes: [String: [Mailbox]] = [:]           // accountID -> mailboxes
        var messages: [String: [MessageSummary]] = [:]     // mailboxKey -> messages
        var highestSeenUID: [String: UInt32] = [:]          // mailboxKey -> highest UID already notified
        // Optional so snapshots saved by older versions still decode.
        var unreadCounts: [String: Int]? = nil              // mailboxKey -> server's unread count
        /// Version of the saved message summaries; older ones are re-downloaded once.
        var cacheVersion: Int? = nil
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DriftMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var snapshotURL: URL { directory.appendingPathComponent("state.json") }

    static func load() -> Snapshot {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return snapshot
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // Full message bodies are cached in Caches so the system can purge them.
    private static var bodyDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func bodyURL(_ id: String) -> URL {
        let safe = Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return bodyDirectory.appendingPathComponent(safe + ".eml")
    }

    static func hasCachedRawMessage(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: bodyURL(id).path)
    }

    static func cachedRawMessage(_ id: String) -> [UInt8]? {
        (try? Data(contentsOf: bodyURL(id))).map { [UInt8]($0) }
    }

    static func cacheRawMessage(_ bytes: [UInt8], id: String) {
        try? Data(bytes).write(to: bodyURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        writesSincePrune += 1
        if writesSincePrune >= 25 {
            writesSincePrune = 0
            pruneBodies()
        }
    }

    nonisolated(unsafe) private static var writesSincePrune = 0

    /// Opened emails are cached so they reopen instantly, but not forever: keep the
    /// newest 400 (at most 150 MB) and delete older ones, so old mail doesn't pile up
    /// on the phone.
    static func pruneBodies(maxFiles: Int = 400, maxBytes: Int = 150 * 1024 * 1024) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bodyDirectory, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for (index, entry) in entries.enumerated() {
            total += entry.2
            if index >= maxFiles || total > maxBytes {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }

    static func clearBodies() {
        try? FileManager.default.removeItem(at: bodyDirectory)
    }
}
