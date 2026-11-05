import Foundation
import Observation
import SwiftUI

struct NewMailBanner: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var subtitle: String
    var messageID: MessageSummary.ID
}

@MainActor
@Observable
final class MailStore {
    static let shared = MailStore()

    var accounts: [MailAccount] = []
    var mailboxes: [UUID: [Mailbox]] = [:]
    var messagesByMailbox: [String: [MessageSummary]] = [:]
    var totalCounts: [String: Int] = [:]

    var selection: MailboxSelection? = .unifiedInbox
    var selectedMessageID: MessageSummary.ID?

    var refreshing: Set<String> = []
    var errorMessage: String?
    var liveAccounts: Set<UUID> = []
    var banner: NewMailBanner?
    var compose: ComposeContext?

    @ObservationIgnored private var sessions: [UUID: AccountSession] = [:]
    @ObservationIgnored private var liveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var highestSeenUID: [String: UInt32] = [:]
    @ObservationIgnored private var bodyCache: [MessageSummary.ID: MessageBody] = [:]
    @ObservationIgnored private var liveEnabled = false

    private static let pageSize = 50

    init() {
        let snapshot = Persistence.load()
        accounts = snapshot.accounts
        mailboxes = Dictionary(uniqueKeysWithValues: snapshot.mailboxes.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
        messagesByMailbox = snapshot.messages
        highestSeenUID = snapshot.highestSeenUID
        shareAccountsWithExtension()
    }

    /// Lets the notification extension fetch sender and subject itself, so the
    /// relay never has to read them (signed builds only; a no-op otherwise).
    func shareAccountsWithExtension() {
        var passwords: [UUID: String] = [:]
        for account in accounts {
            if let password = Keychain.password(for: account) { passwords[account.id] = password }
        }
        SharedAccounts.store(accounts, passwords: passwords)
    }

    // MARK: Persistence

    func save() {
        var snapshot = Persistence.Snapshot()
        snapshot.accounts = accounts
        snapshot.mailboxes = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.key.uuidString, $0.value) })
        // Keep the cache small: only the newest messages per mailbox.
        snapshot.messages = messagesByMailbox.mapValues { Array($0.prefix(200)) }
        snapshot.highestSeenUID = highestSeenUID
        Persistence.save(snapshot)
    }

    // MARK: Lookups

    func session(for account: MailAccount) -> AccountSession {
        if let existing = sessions[account.id], existing.account == account { return existing }
        let session = AccountSession(account: account)
        sessions[account.id] = session
        return session
    }

    func account(_ id: UUID) -> MailAccount? { accounts.first { $0.id == id } }

    /// The account of the mailbox being viewed, if a single account's mailbox is selected.
    var selectionAccountID: UUID? {
        if case .mailbox(let box) = selection { return box.accountID }
        return nil
    }

    func mailbox(_ role: MailboxRole, for accountID: UUID) -> Mailbox? {
        mailboxes[accountID]?.first { $0.role == role && $0.selectable }
    }

    func inbox(for accountID: UUID) -> Mailbox {
        mailbox(.inbox, for: accountID) ?? Mailbox(accountID: accountID, path: "INBOX", name: "Inbox", role: .inbox)
    }

    func archiveMailbox(for accountID: UUID) -> Mailbox? {
        if let archive = mailbox(.archive, for: accountID) { return archive }
        if account(accountID)?.providerID == MailProvider.gmail.id { return mailbox(.all, for: accountID) }
        return nil
    }

    func messages(for selection: MailboxSelection?) -> [MessageSummary] {
        switch selection {
        case .none: return []
        case .unifiedInbox:
            return accounts
                .flatMap { messagesByMailbox[inbox(for: $0.id).id] ?? [] }
                .sorted { $0.date > $1.date }
        case .mailbox(let box):
            return messagesByMailbox[box.id] ?? []
        }
    }

    func message(id: MessageSummary.ID?) -> MessageSummary? {
        guard let id else { return nil }
        for list in messagesByMailbox.values {
            if let found = list.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    func unreadCount(_ selection: MailboxSelection) -> Int {
        messages(for: selection).filter { !$0.isSeen }.count
    }

    func isRefreshing(_ selection: MailboxSelection?) -> Bool {
        switch selection {
        case .none: false
        case .unifiedInbox: accounts.contains { refreshing.contains(inbox(for: $0.id).id) }
        case .mailbox(let box): refreshing.contains(box.id)
        }
    }

    func canLoadMore(_ selection: MailboxSelection?) -> Bool {
        guard case .mailbox(let box) = selection else { return false }
        return (messagesByMailbox[box.id]?.count ?? 0) < (totalCounts[box.id] ?? 0)
    }

    // MARK: Accounts

    func addAccount(_ account: MailAccount, password: String) async throws {
        try await AccountSession.verify(account: account, password: password)
        Keychain.setPassword(password, for: account)
        var stored = account
        stored.colorIndex = accounts.count
        accounts.append(stored)
        save()
        shareAccountsWithExtension()
        await loadMailboxes(for: stored)
        await refresh(.mailbox(inbox(for: stored.id)))
        // Everything currently in the inbox counts as already seen.
        markAllSeenForNotifications(stored.id)
        if liveEnabled { startLive(for: stored) }
        NotificationService.requestAuthorization()
        Task { await PushRelay.shared.syncIfConfigured() }
    }

    func updateAccount(_ account: MailAccount, password: String?) async throws {
        if let password, !password.isEmpty {
            try await AccountSession.verify(account: account, password: password)
            Keychain.setPassword(password, for: account)
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        shareAccountsWithExtension()
        await sessions[account.id]?.reset()
        sessions[account.id] = nil
        stopLive(for: account.id)
        if liveEnabled { startLive(for: account) }
        save()
        Task { await PushRelay.shared.syncIfConfigured() }
    }

    func removeAccount(_ account: MailAccount) {
        stopLive(for: account.id)
        sessions[account.id] = nil
        Keychain.deletePassword(for: account)
        accounts.removeAll { $0.id == account.id }
        SharedAccounts.remove(account.id)
        shareAccountsWithExtension()
        mailboxes[account.id] = nil
        messagesByMailbox = messagesByMailbox.filter { !$0.key.hasPrefix(account.id.uuidString) }
        if case .mailbox(let box) = selection, box.accountID == account.id { selection = .unifiedInbox }
        save()
        Task { await PushRelay.shared.syncIfConfigured() }
    }

    func loadMailboxes(for account: MailAccount) async {
        do {
            let boxes = try await session(for: account).mailboxes()
            mailboxes[account.id] = boxes
            save()
        } catch {
            report(error, account: account)
        }
    }

    // MARK: Refresh

    func refresh(_ selection: MailboxSelection?) async {
        switch selection {
        case .none: return
        case .unifiedInbox:
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    let box = inbox(for: account.id)
                    group.addTask { _ = await self.refreshMailbox(box) }
                }
            }
        case .mailbox(let box):
            await refreshMailbox(box)
        }
    }

    func refreshAll() async {
        for account in accounts where mailboxes[account.id]?.isEmpty ?? true {
            await loadMailboxes(for: account)
        }
        await refresh(.unifiedInbox)
        if case .mailbox = selection { await refresh(selection) }
    }

    /// Refreshes the newest page of a mailbox and returns messages that are new since the last check.
    @discardableResult
    func refreshMailbox(_ box: Mailbox) async -> [MessageSummary] {
        guard let account = account(box.accountID) else { return [] }
        guard !refreshing.contains(box.id) else { return [] }
        refreshing.insert(box.id)
        defer { refreshing.remove(box.id) }

        let existing = messagesByMailbox[box.id] ?? []
        let known = Set(existing.map(\.uid))
        do {
            let result = try await session(for: account).page(mailbox: box.path, offset: 0, limit: Self.pageSize, known: known)
            totalCounts[box.id] = result.totalCount
            let pageUIDs = Set(result.flags.keys)
            let lowestInPage = pageUIDs.min() ?? 0
            var merged: [MessageSummary] = []
            for var message in existing {
                if let flags = result.flags[message.uid] {
                    let lower = flags.map { $0.lowercased() }
                    message.isSeen = lower.contains("\\seen")
                    message.isFlagged = lower.contains("\\flagged")
                    merged.append(message)
                } else if message.uid < lowestInPage && result.totalCount > pageUIDs.count {
                    // Older than this page: keep it (loaded by "load more").
                    merged.append(message)
                }
                // Otherwise the message was deleted or moved elsewhere.
            }
            merged.append(contentsOf: result.newSummaries)
            merged.sort { $0.date > $1.date }
            messagesByMailbox[box.id] = merged
            errorMessage = nil

            let previousHighest = highestSeenUID[box.id] ?? 0
            let fresh = result.newSummaries.filter { $0.uid > previousHighest && !$0.isSeen }
            if let maxUID = pageUIDs.max(), maxUID > previousHighest { highestSeenUID[box.id] = maxUID }
            save()
            return previousHighest == 0 ? [] : fresh
        } catch {
            report(error, account: account)
            return []
        }
    }

    func loadMore(_ selection: MailboxSelection?) async {
        guard case .mailbox(let box) = selection, let account = account(box.accountID),
              !refreshing.contains(box.id) else { return }
        refreshing.insert(box.id)
        defer { refreshing.remove(box.id) }
        let existing = messagesByMailbox[box.id] ?? []
        do {
            let result = try await session(for: account).page(mailbox: box.path, offset: existing.count,
                                                              limit: Self.pageSize, known: Set(existing.map(\.uid)))
            totalCounts[box.id] = result.totalCount
            messagesByMailbox[box.id] = (existing + result.newSummaries).sorted { $0.date > $1.date }
            save()
        } catch {
            report(error, account: account)
        }
    }

    private func markAllSeenForNotifications(_ accountID: UUID) {
        let box = inbox(for: accountID)
        if let maxUID = messagesByMailbox[box.id]?.map(\.uid).max() {
            highestSeenUID[box.id] = maxUID
            save()
        }
    }

    // MARK: Message bodies

    func body(for summary: MessageSummary) async throws -> MessageBody {
        if let cached = bodyCache[summary.id] { return cached }
        let raw: [UInt8]
        if let cachedRaw = Persistence.cachedRawMessage(summary.id) {
            raw = cachedRaw
        } else {
            guard let account = account(summary.accountID) else { throw MailError.notFound }
            raw = try await session(for: account).rawMessage(mailbox: summary.mailboxPath, uid: summary.uid)
            Persistence.cacheRawMessage(raw, id: summary.id)
        }
        let body = await Task.detached(priority: .userInitiated) { MIME.extractBody(MIME.parse(raw)) }.value
        bodyCache[summary.id] = body
        return body
    }

    // MARK: Actions (optimistic)

    private func update(_ summary: MessageSummary, _ change: (inout MessageSummary) -> Void) {
        guard var list = messagesByMailbox[summary.mailboxKey],
              let index = list.firstIndex(where: { $0.id == summary.id }) else { return }
        change(&list[index])
        messagesByMailbox[summary.mailboxKey] = list
    }

    private func removeLocally(_ summary: MessageSummary) {
        messagesByMailbox[summary.mailboxKey]?.removeAll { $0.id == summary.id }
        if selectedMessageID == summary.id { selectedMessageID = nil }
        save()
    }

    func setSeen(_ summary: MessageSummary, _ seen: Bool) {
        guard summary.isSeen != seen, let account = account(summary.accountID) else { return }
        update(summary) { $0.isSeen = seen }
        save()
        Task {
            do {
                try await session(for: account).setFlag("\\Seen", add: seen, uids: [summary.uid], mailbox: summary.mailboxPath)
            } catch {
                update(summary) { $0.isSeen = !seen }
                report(error, account: account)
            }
        }
    }

    func toggleFlag(_ summary: MessageSummary) {
        guard let account = account(summary.accountID) else { return }
        let flagged = !summary.isFlagged
        update(summary) { $0.isFlagged = flagged }
        save()
        Task {
            do {
                try await session(for: account).setFlag("\\Flagged", add: flagged, uids: [summary.uid], mailbox: summary.mailboxPath)
            } catch {
                update(summary) { $0.isFlagged = !flagged }
                report(error, account: account)
            }
        }
    }

    func canArchive(_ summary: MessageSummary) -> Bool {
        guard let archive = archiveMailbox(for: summary.accountID) else { return false }
        return archive.path != summary.mailboxPath
    }

    func archive(_ summary: MessageSummary) {
        guard let target = archiveMailbox(for: summary.accountID) else { return }
        move(summary, to: target)
    }

    func trash(_ summary: MessageSummary) {
        guard let account = account(summary.accountID) else { return }
        if let trash = mailbox(.trash, for: summary.accountID), trash.path != summary.mailboxPath {
            move(summary, to: trash)
        } else {
            removeLocally(summary)
            Task {
                do {
                    try await session(for: account).deletePermanently(uids: [summary.uid], mailbox: summary.mailboxPath)
                } catch {
                    report(error, account: account)
                }
            }
        }
    }

    func moveToJunk(_ summary: MessageSummary) {
        guard let junk = mailbox(.junk, for: summary.accountID) else { return }
        move(summary, to: junk)
    }

    func move(_ summary: MessageSummary, to target: Mailbox) {
        guard let account = account(summary.accountID) else { return }
        removeLocally(summary)
        Task {
            do {
                try await session(for: account).move(uids: [summary.uid], from: summary.mailboxPath, to: target.path)
                messagesByMailbox[target.id] = nil  // refetch the destination next time
            } catch {
                report(error, account: account)
                await refreshMailbox(Mailbox(accountID: account.id, path: summary.mailboxPath, name: "", role: .other))
            }
        }
    }

    // MARK: Sending

    func send(_ message: OutgoingMessage, from account: MailAccount) async throws {
        guard let password = Keychain.password(for: account) else { throw MailError.missingPassword }
        let data = MessageBuilder.build(message)
        try await SMTPClient.send(account: account, password: password, envelopeFrom: account.email,
                                  recipients: message.allRecipients, message: data)
        if !account.provider.savesSentMailAutomatically, let sent = mailbox(.sent, for: account.id) {
            try? await session(for: account).append(data, to: sent.path)
        }
    }

    // MARK: Live updates (IMAP IDLE while the app is open)

    func startLive() {
        liveEnabled = true
        for account in accounts { startLive(for: account) }
    }

    func stopLive() {
        liveEnabled = false
        for id in Array(liveTasks.keys) { stopLive(for: id) }
    }

    private func startLive(for account: MailAccount) {
        guard liveTasks[account.id] == nil else { return }
        let inboxPath = inbox(for: account.id).path
        liveTasks[account.id] = Task { [weak self] in
            var backoff: Double = 3
            while !Task.isCancelled {
                guard let password = Keychain.password(for: account) else { return }
                let client = IMAPClient(host: account.imapHost, port: account.imapPort)
                do {
                    try await client.connect()
                    try await client.login(username: account.username, password: password)
                    try await client.select(inboxPath, readOnly: true)
                    self?.liveAccounts.insert(account.id)
                    backoff = 3
                    await self?.handleLiveChange(account)
                    while !Task.isCancelled {
                        // Servers drop idle connections after ~29 minutes; restart well before that.
                        if try await client.idle(seconds: 9 * 60) {
                            await self?.handleLiveChange(account)
                        }
                    }
                } catch {
                    self?.liveAccounts.remove(account.id)
                }
                client.close()
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 120)
            }
            self?.liveAccounts.remove(account.id)
        }
    }

    private func stopLive(for accountID: UUID) {
        liveTasks[accountID]?.cancel()
        liveTasks[accountID] = nil
        liveAccounts.remove(accountID)
    }

    private func handleLiveChange(_ account: MailAccount) async {
        let fresh = await refreshMailbox(inbox(for: account.id))
        if let newest = fresh.max(by: { $0.date < $1.date }) {
            withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                banner = NewMailBanner(
                    title: newest.from.displayName,
                    subtitle: newest.subject.isEmpty ? "(No subject)" : newest.subject,
                    messageID: newest.id)
            }
        }
    }

    // MARK: Background refresh fallback

    /// Checks every inbox and posts local notifications. Used by background app refresh
    /// when the push relay is not set up.
    func backgroundCheck() async {
        var fresh: [MessageSummary] = []
        for account in accounts {
            fresh += await refreshMailbox(inbox(for: account.id))
        }
        for message in fresh.prefix(10) {
            NotificationService.postLocal(for: message, accountName: account(message.accountID)?.email ?? "")
        }
    }

    // MARK: Deep links (notification taps)

    func open(accountID: UUID, uid: UInt32?, mailboxPath: String?) async {
        guard account(accountID) != nil else { return }
        let box = mailboxPath.flatMap { path in mailboxes[accountID]?.first { $0.path == path } } ?? inbox(for: accountID)
        selection = .unifiedInbox
        await refreshMailbox(box)
        if let uid {
            let id = "\(accountID.uuidString)|\(box.path)|\(uid)"
            if message(id: id) != nil { selectedMessageID = id }
        }
    }

    // MARK: Errors

    private func report(_ error: Error, account: MailAccount) {
        if error is CancellationError { return }
        errorMessage = "\(account.email): \(error.localizedDescription)"
    }
}
