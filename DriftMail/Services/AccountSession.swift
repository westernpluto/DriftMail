import Foundation

/// Keeps one signed-in IMAP connection per account and serialises commands on it.
/// Reconnects once automatically when the connection has dropped.
actor AccountSession {
    let account: MailAccount
    private var client: IMAPClient?

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
        if let client { return client }
        guard let password = Keychain.password(for: account) else { throw MailError.missingPassword }
        let fresh = IMAPClient(host: account.imapHost, port: account.imapPort)
        try await fresh.connect()
        try await fresh.login(username: account.username, password: password)
        client = fresh
        return fresh
    }

    private func perform<T>(_ operation: (IMAPClient) async throws -> T) async throws -> T {
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
                let previews = try await client.fetchPreviews(uids: chunk)
                for item in previews {
                    summaries.append(MIME.summary(from: item.body ?? [], accountID: accountID, mailbox: mailbox,
                                                  uid: item.uid, flags: item.flags, internalDate: item.internalDate))
                }
            }
            return PageResult(flags: flags, newSummaries: summaries, totalCount: total)
        }
    }

    func rawMessage(mailbox: String, uid: UInt32) async throws -> [UInt8] {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            return try await client.fetchFullMessage(uid: uid)
        }
    }

    func setFlag(_ flag: String, add: Bool, uids: [UInt32], mailbox: String) async throws {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            try await client.store(uids: uids, add: add, flags: [flag])
        }
    }

    func move(uids: [UInt32], from mailbox: String, to destination: String) async throws {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            try await client.move(uids: uids, to: destination)
        }
    }

    func deletePermanently(uids: [UInt32], mailbox: String) async throws {
        try await perform { client in
            _ = try await self.ensureSelected(client, mailbox)
            try await client.deletePermanently(uids: uids)
        }
    }

    func append(_ message: Data, to mailbox: String) async throws {
        try await perform { try await $0.append(to: mailbox, message: message) }
    }
}
