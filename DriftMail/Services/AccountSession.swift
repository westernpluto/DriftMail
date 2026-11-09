import Foundation

/// Keeps one signed-in IMAP connection per account and serialises commands on it.
/// Reconnects once automatically when the connection has dropped.
actor AccountSession {
    let account: MailAccount
    private var client: IMAPClient?
    private var lastUsed = Date.distantPast
    // IMAP is one conversation per connection. Actor methods interleave at every
    // `await`, so without this gate two operations (e.g. a list refresh and opening
    // a message) would talk over each other on one socket, and one would swallow
    // the other's reply and hang until the timeout.
    private var busy = false
    private var waiters: [(priority: Priority, continuation: CheckedContinuation<Void, Never>)] = []

    /// Who gets the connection next when several operations are waiting. Opening a
    /// message you tapped goes ahead of list refreshes, which go ahead of prefetching.
    enum Priority: Int, Comparable, Sendable {
        case low, normal, high
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    /// How long the last operation waited for its turn, and how long it then spent
    /// checking or re-establishing the connection (for the open-speed diagnostics).
    private(set) var lastWait: TimeInterval = 0
    private(set) var lastConnect: TimeInterval = 0

    private func acquire(_ priority: Priority) async {
        let started = Date()
        if busy {
            await withCheckedContinuation { waiters.append((priority, $0)) }
        } else {
            busy = true
        }
        lastWait = Date().timeIntervalSince(started)
    }

    private func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        // Highest priority first; among equals, whoever asked first.
        let best = waiters.indices.max { waiters[$0].priority < waiters[$1].priority || 
            (waiters[$0].priority == waiters[$1].priority && $0 > $1) }!
        waiters.remove(at: best).continuation.resume()  // hand the turn straight over
    }

    init(account: MailAccount) {
        self.account = account
    }

    static func verify(account: MailAccount, password: String) async throws {
        let client = IMAPClient(host: account.imapHost, port: account.imapPort)
        try await client.connect()
        try await client.login(username: account.username, password: password)
        await client.logout()
    }

    private func connected() async throws -> IMAPClient {
        let started = Date()
        defer { lastConnect = Date().timeIntervalSince(started) }
        if let client {
            // A connection left unused (app in the background, phone asleep) is often
            // dropped without notice. Check it quickly rather than letting the next
            // command hang for the full timeout while everything queues behind it.
            if Date().timeIntervalSince(lastUsed) > 30 {
                do {
                    try await client.noop(timeout: 4)
                    lastUsed = Date()
                    return client
                } catch {
                    reset()
                }
            } else {
                lastUsed = Date()
                return client
            }
        }
        guard let password = Keychain.password(for: account) else { throw MailError.missingPassword }
        let fresh = IMAPClient(host: account.imapHost, port: account.imapPort)
        try await fresh.connect()
        try await fresh.login(username: account.username, password: password)
        client = fresh
        lastUsed = Date()
        return fresh
    }

    private func perform<T>(priority: Priority = .normal, _ operation: (IMAPClient) async throws -> T) async throws -> T {
        await acquire(priority)
        defer {
            if client != nil { lastUsed = Date() }
            release()
        }
        do {
            return try await operation(try await connected())
        } catch let error as MailError {
            switch error {
            case .authentication, .missingPassword, .notFound: throw error
            default: break
            }
            reset()
            return try await operation(try await connected())
        } catch {
            reset()
            return try await operation(try await connected())
        }
    }

    private func ensureSelected(_ client: IMAPClient, _ mailbox: String) async throws -> IMAPMailboxStatus? {
        if client.selectedMailbox == mailbox { return nil }
        return try await client.select(mailbox)
    }

    func reset() {
        client?.close()
        client = nil
    }

    func disconnect() async {
        if let client { await client.logout() }
        client = nil
    }

    // MARK: Operations

    func mailboxes() async throws -> [Mailbox] {
        try await perform { try await $0.listMailboxes(accountID: account.id) }
    }

    struct PageResult: Sendable {
        var flags: [UInt32: [String]]       // every UID in the page with its current flags
        var newSummaries: [MessageSummary]  // summaries for UIDs that were not known yet
        var totalCount: Int
    }

    /// Loads one page of messages, newest first. `offset` counts back from the newest message.
    func page(mailbox: String, offset: Int, limit: Int, known: Set<UInt32>) async throws -> PageResult {
        let accountID = account.id
        return try await perform { client in
            // Re-select to get a fresh message count.
            let status = try await client.select(mailbox)
            let total = status.exists
            guard total > 0, offset < total else {
                return PageResult(flags: [:], newSummaries: [], totalCount: total)
            }
            let upper = total - offset
            let lower = max(1, upper - limit + 1)
            let flagged = try await client.fetchFlags(sequenceRange: lower...upper)
            var flags: [UInt32: [String]] = [:]
            for item in flagged { flags[item.uid] = item.flags }
            let missing = flagged.map(\.uid).filter { !known.contains($0) }
            var summaries: [MessageSummary] = []
            // Fetch previews in chunks so one huge message cannot stall the page.
            for chunk in stride(from: 0, to: missing.count, by: 20).map({ Array(missing[$0..<min($0 + 20, missing.count)]) }) {
                let previews = try await client.fetchPreviews(uids: chunk, previewBytes: Self.previewBytes)
                for item in previews {
                    summaries.append(Self.summary(from: item, accountID: accountID, mailbox: mailbox))
                }
            }
            return PageResult(flags: flags, newSummaries: summaries, totalCount: total)
        }
    }

    func rawMessage(mailbox: String, uid: UInt32, priority: Priority = .high) async throws -> [UInt8] {
        try await perform(priority: priority) { client in
            _ = try await self.ensureSelected(client, mailbox)
            return try await client.fetchFullMessage(uid: uid)
        }
    }

    struct NetworkTiming: Sendable {
        var wait: TimeInterval      // queued behind another operation on this connection
        var connect: TimeInterval   // checking a reused connection, or connecting + signing in
        var fetch: TimeInterval     // selecting the mailbox and downloading the message
    }

    /// Opens a message, with timings for the open-speed diagnostics.
    func rawMessageTimed(mailbox: String, uid: UInt32) async throws -> (bytes: [UInt8], timing: NetworkTiming) {
        try await perform(priority: .high) { client in
            let wait = self.lastWait
            let connect = self.lastConnect
            let started = Date()
            _ = try await self.ensureSelected(client, mailbox)
            let bytes = try await client.fetchFullMessage(uid: uid)
            return (bytes, NetworkTiming(wait: wait, connect: connect, fetch: Date().timeIntervalSince(started)))
        }
    }

    /// Makes sure the connection is up (reconnecting if it died), so the next message
    /// opened doesn't pay for that. Used when the app comes to the foreground.
    func warm() async {
        _ = try? await perform(priority: .low) { _ in }
    }

    /// Builds a summary from a preview fetch. When that fetch already holds the whole
    /// message (most emails are smaller than the preview size), it's cached, so the
    /// message opens instantly without downloading it again.
    private static func summary(from item: IMAPFetchResult, accountID: UUID, mailbox: String) -> MessageSummary {
        var summary = MIME.summary(from: item.body ?? [], accountID: accountID, mailbox: mailbox,
                                   uid: item.uid, flags: item.flags, internalDate: item.internalDate)
        summary.size = item.size
        if let size = item.size, size > 0, let body = item.body, body.count >= size,
           !Persistence.hasCachedRawMessage(summary.id) {
            Persistence.cacheRawMessage(body, id: summary.id)
        }
        return summary
    }

    /// How much of each message the list downloads for its preview. Newsletters often
    /// put a plain-text copy or a long stylesheet first, so 16 KB missed the real text.
    private static let previewBytes = 48 * 1024

    // Bulk operations go out in chunks: a sparse set of thousands of UIDs makes a
    // command line some servers reject.
    private static func chunks(_ uids: [UInt32]) -> [[UInt32]] {
        let sorted = uids.sorted()
        return stride(from: 0, to: sorted.count, by: 400).map { Array(sorted[$0..<min($0 + 400, sorted.count)]) }
    }

    func setFlag(_ flag: String, add: Bool, uids: [UInt32], mailbox: String) async throws {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            for chunk in Self.chunks(uids) {
                try await client.store(uids: chunk, add: add, flags: [flag])
            }
        }
    }

    func move(uids: [UInt32], from mailbox: String, to destination: String) async throws {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            for chunk in Self.chunks(uids) {
                try await client.move(uids: chunk, to: destination)
            }
        }
    }

    func deletePermanently(uids: [UInt32], mailbox: String) async throws {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            for chunk in Self.chunks(uids) {
                try await client.deletePermanently(uids: chunk)
            }
        }
    }

    func markAllSeen(mailbox: String) async throws {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            try await client.markAllSeen()
        }
    }

    // MARK: Counts and search

    /// Unread counts straight from the server, for every mailbox in `paths`.
    /// A mailbox the server refuses is skipped rather than failing the rest.
    func unreadCounts(paths: [String]) async throws -> [String: Int] {
        try await perform { client in
            var counts: [String: Int] = [:]
            for path in paths {
                if let status = try? await client.status(path) { counts[path] = status.unseen }
            }
            return counts
        }
    }

    /// Every UID in `mailbox` matching `query` in `fields`, newest first.
    func search(mailbox: String, query: String, fields: [IMAPClient.SearchField]) async throws -> [UInt32] {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            return try await client.search(query, in: fields).sorted(by: >)
        }
    }

    /// Summaries (headers + preview) for specific UIDs, e.g. search results.
    func summaries(mailbox: String, uids: [UInt32]) async throws -> [MessageSummary] {
        let accountID = account.id
        return try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            var summaries: [MessageSummary] = []
            for start in stride(from: 0, to: uids.count, by: 20) {
                let chunk = Array(uids[start..<min(start + 20, uids.count)])
                for item in try await client.fetchPreviews(uids: chunk, previewBytes: Self.previewBytes) {
                    summaries.append(Self.summary(from: item, accountID: accountID, mailbox: mailbox))
                }
            }
            return summaries
        }
    }

    func append(_ message: Data, to mailbox: String) async throws {
        try await perform { try await $0.append(to: mailbox, message: message) }
    }
}
