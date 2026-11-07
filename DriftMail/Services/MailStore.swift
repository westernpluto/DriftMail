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
    /// The server's unread count per mailbox (IMAP STATUS), so counts cover every
    /// message, not only the ones downloaded. Keyed like `messagesByMailbox`.
    var unreadCounts: [String: Int] = [:]

    /// Server-side search results for the message list's search field.
    var serverSearch: ServerSearch?
    var isSearchingServer = false
    /// "Show All from Sender": asks the message list to search for this address.
    var senderSearchRequest: SenderSearchRequest?
    /// Bumped to bring the message list to the front (outer display), e.g. for a sender search.
    var listRevealRequest = 0
    /// Messages waiting for a destination in the Move to Folder sheet.
    var moveRequest: MoveRequest?
    @ObservationIgnored private var searchGeneration = 0

    var selection: MailboxSelection? = .unifiedInbox
    var selectedMessageID: MessageSummary.ID?
    /// Bumped when a notification opens a message, so the layout brings it to the front
    /// (even if that message was already selected).
    var revealRequest = 0

    var refreshing: Set<String> = []
    var errorMessage: String?
    /// A temporary network problem (shown quietly in the list, retried automatically)
    /// rather than an alert, e.g. the first try right after returning to the app.
    var connectionIssue: String?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    var liveAccounts: Set<UUID> = []
    var banner: NewMailBanner?
    var compose: ComposeContext?

    @ObservationIgnored private var sessions: [UUID: AccountSession] = [:]
    /// A second connection per account for opening (and prefetching) messages, so opening
    /// an email never waits behind a list refresh on the first one.
    @ObservationIgnored private var bodySessions: [UUID: AccountSession] = [:]
    @ObservationIgnored private var prefetching: Set<String> = []
    @ObservationIgnored private var liveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var highestSeenUID: [String: UInt32] = [:]
    @ObservationIgnored private var bodyCache: [MessageSummary.ID: MessageBody] = [:]
    @ObservationIgnored private var liveEnabled = false

    private static let pageSize = 50
    /// Bump when the way summaries (subject, sender, preview) are decoded changes, so
    /// messages saved by an older version are downloaded again instead of keeping
    /// e.g. "?" for emoji or CSS in the preview.
    private static let cacheVersion = 3  // 3: base64 padding fix (subjects ending in "?")

    init() {
        let snapshot = Persistence.load()
        accounts = snapshot.accounts
        mailboxes = Dictionary(uniqueKeysWithValues: snapshot.mailboxes.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
        if snapshot.cacheVersion == Self.cacheVersion {
            messagesByMailbox = snapshot.messages.mapValues { $0.uniquedByID() }
        }  // otherwise start empty: each mailbox reloads from the server
        highestSeenUID = snapshot.highestSeenUID
        unreadCounts = snapshot.unreadCounts ?? [:]
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
        snapshot.unreadCounts = unreadCounts
        snapshot.cacheVersion = Self.cacheVersion
        Persistence.save(snapshot)
    }

    // MARK: Lookups

    func bodySession(for account: MailAccount) -> AccountSession {
        if let existing = bodySessions[account.id], existing.account == account { return existing }
        let session = AccountSession(account: account)
        bodySessions[account.id] = session
        return session
    }

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
        // Search results can be older messages that were never downloaded into a list.
        return serverSearch?.results.first { $0.id == id }
    }

    /// Unread messages on the server; falls back to the downloaded ones until the
    /// first count arrives.
    func unreadCount(_ selection: MailboxSelection) -> Int {
        switch selection {
        case .unifiedInbox:
            return accounts.reduce(0) { $0 + unreadCount(.mailbox(inbox(for: $1.id))) }
        case .mailbox(let box):
            return unreadCounts[box.id] ?? (messagesByMailbox[box.id] ?? []).filter { !$0.isSeen }.count
        }
    }

    /// Keeps the server count in step with a change made here, until the next refresh.
    private func adjustUnread(_ mailboxKey: String, by delta: Int) {
        guard delta != 0, let count = unreadCounts[mailboxKey] else { return }
        unreadCounts[mailboxKey] = max(0, count + delta)
    }

    /// Fetches the server's unread count for every mailbox of an account.
    func refreshUnreadCounts(for account: MailAccount) async {
        let boxes = (mailboxes[account.id] ?? []).filter(\.selectable)
        guard !boxes.isEmpty,
              let counts = try? await session(for: account).unreadCounts(paths: boxes.map(\.path)) else { return }
        for box in boxes {
            if let count = counts[box.path] { unreadCounts[box.id] = count }
        }
        save()
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
        bodySessions[account.id] = nil
        stopLive(for: account.id)
        if liveEnabled { startLive(for: account) }
        save()
        Task { await PushRelay.shared.syncIfConfigured() }
    }

    func removeAccount(_ account: MailAccount) {
        stopLive(for: account.id)
        sessions[account.id] = nil
        bodySessions[account.id] = nil
        Keychain.deletePassword(for: account)
        accounts.removeAll { $0.id == account.id }
        SharedAccounts.remove(account.id)
        Keychain.delete("relaypw.\(account.id.uuidString)")
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
        for account in accounts { await refreshUnreadCounts(for: account) }
    }

    /// Refreshes the newest page of a mailbox and returns messages that are new since the last check.
    @discardableResult
    func refreshMailbox(_ box: Mailbox) async -> [MessageSummary] {
        guard let account = account(box.accountID) else { return [] }
        guard !refreshing.contains(box.id) else { return [] }
        refreshing.insert(box.id)
        defer { refreshing.remove(box.id) }

        let existing = messagesByMailbox[box.id] ?? []
        // Previews saved while markup still leaked into them (CSS etc.) are fetched again.
        let needsRepair = Set(existing.filter { MIME.looksLikeMarkup($0.preview) }.map(\.uid))
        let known = Set(existing.map(\.uid)).subtracting(needsRepair)
        do {
            let result = try await session(for: account).page(mailbox: box.path, offset: 0, limit: Self.pageSize, known: known)
            totalCounts[box.id] = result.totalCount
            let pageUIDs = Set(result.flags.keys)
            let lowestInPage = pageUIDs.min() ?? 0
            var replacements = Dictionary(result.newSummaries.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            var merged: [MessageSummary] = []
            for var message in existing {
                if let repaired = replacements.removeValue(forKey: message.uid) {
                    merged.append(repaired)
                } else if let flags = result.flags[message.uid] {
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
            merged.append(contentsOf: result.newSummaries.filter { replacements[$0.uid] != nil })
            merged.sort { $0.date > $1.date }
            messagesByMailbox[box.id] = merged.uniquedByID()
            errorMessage = nil
            connectionRecovered()

            let previousHighest = highestSeenUID[box.id] ?? 0
            let fresh = result.newSummaries.filter { $0.uid > previousHighest && !$0.isSeen && !needsRepair.contains($0.uid) }
            if let maxUID = pageUIDs.max(), maxUID > previousHighest { highestSeenUID[box.id] = maxUID }
            if let count = try? await session(for: account).unreadCounts(paths: [box.path])[box.path] {
                unreadCounts[box.id] = count
            }
            save()
            if box.role == .inbox || selection == .mailbox(box) { prefetchBodies(in: box) }
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
            messagesByMailbox[box.id] = (existing + result.newSummaries).uniquedByID().sorted { $0.date > $1.date }
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

    /// Downloads the newest messages of a mailbox in the background so they open
    /// instantly. One at a time on the body connection, so a message you tap waits
    /// behind at most one prefetch. Already-downloaded ones are skipped.
    private func prefetchBodies(in box: Mailbox, count: Int = 12) {
        guard !prefetching.contains(box.id), let account = account(box.accountID) else { return }
        let targets = (messagesByMailbox[box.id] ?? []).prefix(count)
            .filter { !Persistence.hasCachedRawMessage($0.id) }
        guard !targets.isEmpty else { return }
        prefetching.insert(box.id)
        Task { [weak self] in
            defer { self?.prefetching.remove(box.id) }
            for summary in targets {
                guard let self, self.liveEnabled else { return }  // stop when the app leaves the screen
                guard let raw = try? await self.bodySession(for: account)
                    .rawMessage(mailbox: summary.mailboxPath, uid: summary.uid) else { continue }
                Persistence.cacheRawMessage(raw, id: summary.id)
            }
        }
    }

    func body(for summary: MessageSummary) async throws -> MessageBody {
        if let cached = bodyCache[summary.id] { return cached }
        let raw: [UInt8]
        if let cachedRaw = Persistence.cachedRawMessage(summary.id) {
            raw = cachedRaw
        } else {
            guard let account = account(summary.accountID) else { throw MailError.notFound }
            raw = try await bodySession(for: account).rawMessage(mailbox: summary.mailboxPath, uid: summary.uid)
            Persistence.cacheRawMessage(raw, id: summary.id)
        }
        // Parsing and preview text stay off the main thread: a very large HTML email
        // could otherwise freeze the app long enough for iOS to stop it.
        let (body, preview, subject, from) = await Task.detached(priority: .userInitiated) {
            () -> (MessageBody, String, String?, EmailAddress?) in
            let root = MIME.parse(raw)
            let body = MIME.extractBody(root)
            let subject = root.header("subject").map {
                MIME.decodeEncodedWords($0).trimmingCharacters(in: .whitespaces)
            }
            return (body, MIME.previewText(from: body), subject, MIME.parseAddresses(root.header("from")).first)
        }.value
        bodyCache[summary.id] = body
        // The list row came from the start of the message only (and may have been saved
        // by an older version); the full message gives the real subject, sender and preview.
        let newPreview = preview.isEmpty ? summary.preview : preview
        let newSubject = subject ?? summary.subject
        let newFrom = from ?? summary.from
        if newPreview != summary.preview || newSubject != summary.subject || newFrom != summary.from {
            update(summary) {
                $0.preview = newPreview
                $0.subject = newSubject
                $0.from = newFrom
            }
            save()
        }
        return body
    }

    // MARK: Actions (optimistic)

    private func update(_ summary: MessageSummary, _ change: (inout MessageSummary) -> Void) {
        if var list = messagesByMailbox[summary.mailboxKey],
           let index = list.firstIndex(where: { $0.id == summary.id }) {
            change(&list[index])
            messagesByMailbox[summary.mailboxKey] = list
        }
        if let index = serverSearch?.results.firstIndex(where: { $0.id == summary.id }) {
            change(&serverSearch!.results[index])
        }
    }

    private func removeLocally(_ summary: MessageSummary) {
        if !summary.isSeen { adjustUnread(summary.mailboxKey, by: -1) }
        messagesByMailbox[summary.mailboxKey]?.removeAll { $0.id == summary.id }
        serverSearch?.remove([summary.uid], from: summary.mailboxKey)
        if selectedMessageID == summary.id { selectedMessageID = nil }
        save()
    }

    func setSeen(_ summary: MessageSummary, _ seen: Bool) {
        guard summary.isSeen != seen, let account = account(summary.accountID) else { return }
        update(summary) { $0.isSeen = seen }
        adjustUnread(summary.mailboxKey, by: seen ? -1 : 1)
        save()
        Task {
            do {
                try await session(for: account).setFlag("\\Seen", add: seen, uids: [summary.uid], mailbox: summary.mailboxPath)
            } catch {
                update(summary) { $0.isSeen = !seen }
                adjustUnread(summary.mailboxKey, by: seen ? 1 : -1)
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
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        for id in Array(liveTasks.keys) { stopLive(for: id) }
    }

    /// Drops the command connections when the app leaves the foreground: iOS and
    /// mail servers often cut them silently while the app is suspended, and a
    /// dead connection would stall the next message opened. New ones are made on demand.
    func closeConnections() {
        let open = Array(sessions.values) + Array(bodySessions.values)
        sessions.removeAll()
        bodySessions.removeAll()
        Task { for session in open { await session.reset() } }
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
        // With the relay set up it already announced these: posting them again here
        // gave duplicate notifications whenever iOS ran a background refresh.
        guard !PushRelay.shared.isConfigured else { return }
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
            if message(id: id) != nil { reveal(id) }
        }
    }

    /// Selects a message and brings it to the front of the layout (used for
    /// notification taps and the in-app new-mail toast).
    func reveal(_ id: MessageSummary.ID) {
        selectedMessageID = id
        revealRequest += 1
    }

    // MARK: Errors

    private func report(_ error: Error, account: MailAccount) {
        if error is CancellationError { return }
        if Self.isTransient(error) {
            connectionIssue = "Can\u{2019}t reach the mail server"
            scheduleRetry()
            return
        }
        errorMessage = "\(account.email): \(error.localizedDescription)"
    }

    /// Network hiccups that usually fix themselves (no connection yet after waking,
    /// a dropped or timed-out connection). Sign-in and server errors are not transient.
    private static func isTransient(_ error: Error) -> Bool {
        if let mail = error as? MailError {
            switch mail {
            case .connectionClosed, .timeout: return true
            default: return false
            }
        }
        if error is URLError { return true }
        let domain = (error as NSError).domain
        return domain == NSURLErrorDomain || domain == NSPOSIXErrorDomain || domain == "kCFErrorDomainCFNetwork"
    }

    /// Tries again after 3, 6, 12… seconds (up to 30) while the app is open.
    private func scheduleRetry() {
        guard retryTask == nil, liveEnabled else { return }
        retryAttempt += 1
        let delay = min(30.0, 3.0 * pow(2.0, Double(retryAttempt - 1)))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.refresh(self.selection ?? .unifiedInbox)
        }
    }

    private func connectionRecovered() {
        connectionIssue = nil
        retryAttempt = 0
        retryTask?.cancel()
        retryTask = nil
    }
}

// MARK: - Server search

enum SearchScope: String, CaseIterable, Hashable, Sendable {
    case all, from, subject

    var title: String {
        switch self {
        case .all: "All"
        case .from: "From"
        case .subject: "Subject"
        }
    }

    var fields: [IMAPClient.SearchField] {
        switch self {
        case .all: [.from, .to, .subject]
        case .from: [.from]
        case .subject: [.subject]
        }
    }
}

/// Every message on the server matching a search, not only the downloaded ones.
struct ServerSearch: Equatable {
    var query: String
    var scope: SearchScope
    var selection: MailboxSelection
    /// All matching UIDs per mailbox (key: `Mailbox.id`), newest first.
    var matches: [String: [UInt32]]
    var boxes: [String: Mailbox]
    /// The matches downloaded so far (headers + preview), newest first.
    var results: [MessageSummary] = []
    var loadedCount: [String: Int] = [:]

    var total: Int { matches.values.reduce(0) { $0 + $1.count } }
    var canLoadMore: Bool { matches.contains { key, uids in (loadedCount[key] ?? 0) < uids.count } }

    func isFor(_ query: String, _ scope: SearchScope, _ selection: MailboxSelection) -> Bool {
        self.query == query.trimmingCharacters(in: .whitespaces) && self.scope == scope && self.selection == selection
    }

    mutating func remove(_ uids: Set<UInt32>, from mailboxKey: String) {
        guard !uids.isEmpty else { return }
        let removedBefore = (matches[mailboxKey] ?? []).prefix(loadedCount[mailboxKey] ?? 0).filter { uids.contains($0) }.count
        matches[mailboxKey]?.removeAll { uids.contains($0) }
        if let loaded = loadedCount[mailboxKey] { loadedCount[mailboxKey] = loaded - removedBefore }
        results.removeAll { $0.mailboxKey == mailboxKey && uids.contains($0.uid) }
    }
}

struct MoveRequest: Identifiable {
    let id = UUID()
    var messages: [MessageSummary]
}

struct SenderSearchRequest: Equatable {
    var id = UUID()
    var address: String
}

enum BulkAction {
    case markRead, archive, trash
}

extension MailStore {
    private static let searchPage = 100

    /// Searches the server (the selected mailbox, or every inbox for All Inboxes).
    func searchServer(_ query: String, scope: SearchScope, in selection: MailboxSelection) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        searchGeneration += 1
        let generation = searchGeneration
        guard !trimmed.isEmpty else {
            serverSearch = nil
            isSearchingServer = false
            return
        }
        isSearchingServer = true
        defer { if generation == searchGeneration { isSearchingServer = false } }

        let boxes: [Mailbox]
        switch selection {
        case .unifiedInbox: boxes = accounts.map { inbox(for: $0.id) }
        case .mailbox(let box): boxes = [box]
        }
        var search = ServerSearch(query: trimmed, scope: scope, selection: selection, matches: [:], boxes: [:])
        for box in boxes {
            guard let account = account(box.accountID) else { continue }
            do {
                search.matches[box.id] = try await session(for: account).search(mailbox: box.path, query: trimmed,
                                                                                fields: scope.fields)
                search.boxes[box.id] = box
            } catch {
                report(error, account: account)
            }
            if generation != searchGeneration { return }  // a newer search started
        }
        await loadResults(&search)
        if generation == searchGeneration { serverSearch = search }
    }

    func loadMoreSearchResults() async {
        guard var search = serverSearch, search.canLoadMore else { return }
        let generation = searchGeneration
        await loadResults(&search)
        if generation == searchGeneration { serverSearch = search }
    }

    private func loadResults(_ search: inout ServerSearch) async {
        let perBox = max(20, Self.searchPage / max(1, search.matches.count))
        for (key, uids) in search.matches {
            let start = search.loadedCount[key] ?? 0
            guard start < uids.count, let box = search.boxes[key], let account = account(box.accountID) else { continue }
            let next = Array(uids[start..<min(start + perBox, uids.count)])
            do {
                let fetched = try await session(for: account).summaries(mailbox: box.path, uids: next)
                search.results += fetched
                search.loadedCount[key] = start + next.count
            } catch {
                report(error, account: account)
            }
        }
        search.results = search.results.uniquedByID().sorted { $0.date > $1.date }
    }

    /// Applies an action to every match of the current search on the server,
    /// including the ones never downloaded, then searches again.
    func applyToAllMatches(_ action: BulkAction) async {
        guard let search = serverSearch else { return }
        for (key, uids) in search.matches where !uids.isEmpty {
            guard let box = search.boxes[key], let account = account(box.accountID) else { continue }
            await apply(action, uids: uids, in: box, account: account)
        }
        await searchServer(search.query, scope: search.scope, in: search.selection)
    }

    /// The selected messages (select mode in the list), grouped per mailbox.
    func apply(_ action: BulkAction, to messages: [MessageSummary]) async {
        for (key, group) in Dictionary(grouping: messages, by: \.mailboxKey) {
            guard let first = group.first, let account = account(first.accountID) else { continue }
            let box = mailboxes[account.id]?.first { $0.id == key }
                ?? Mailbox(accountID: account.id, path: first.mailboxPath, name: "", role: .other)
            await apply(action, uids: group.map(\.uid), in: box, account: account)
        }
    }

    /// Lists every message from `address` (server search in the current mailbox).
    func showAll(from address: String) {
        senderSearchRequest = SenderSearchRequest(address: address)
        listRevealRequest += 1
    }

    /// Marks everything in the mailbox (or every inbox) as read on the server.
    func markAllRead(in selection: MailboxSelection) async {
        let boxes: [Mailbox]
        switch selection {
        case .unifiedInbox: boxes = accounts.map { inbox(for: $0.id) }
        case .mailbox(let box): boxes = [box]
        }
        for box in boxes {
            guard let account = account(box.accountID) else { continue }
            for message in messagesByMailbox[box.id] ?? [] where !message.isSeen {
                update(message) { $0.isSeen = true }
            }
            unreadCounts[box.id] = 0
            do {
                try await session(for: account).markAllSeen(mailbox: box.path)
            } catch {
                report(error, account: account)
                await refreshMailbox(box)
            }
        }
        save()
    }

    func setFlagged(_ messages: [MessageSummary], _ flagged: Bool) async {
        for (key, group) in Dictionary(grouping: messages, by: \.mailboxKey) {
            guard let first = group.first, let account = account(first.accountID) else { continue }
            for message in group { update(message) { $0.isFlagged = flagged } }
            do {
                try await session(for: account).setFlag("\\Flagged", add: flagged, uids: group.map(\.uid),
                                                         mailbox: first.mailboxPath)
            } catch {
                report(error, account: account)
                if let box = mailboxes[account.id]?.first(where: { $0.id == key }) { await refreshMailbox(box) }
            }
        }
        save()
    }

    func setSeen(_ messages: [MessageSummary], _ seen: Bool) async {
        for (_, group) in Dictionary(grouping: messages.filter { $0.isSeen != seen }, by: \.mailboxKey) {
            guard let first = group.first, let account = account(first.accountID) else { continue }
            for message in group { update(message) { $0.isSeen = seen } }
            adjustUnread(first.mailboxKey, by: seen ? -group.count : group.count)
            do {
                try await session(for: account).setFlag("\\Seen", add: seen, uids: group.map(\.uid),
                                                         mailbox: first.mailboxPath)
            } catch {
                report(error, account: account)
            }
        }
        save()
    }

    /// Moves messages of one account to `target` (Move to Folder).
    func move(_ messages: [MessageSummary], to target: Mailbox) async {
        let movable = messages.filter { $0.accountID == target.accountID && $0.mailboxPath != target.path }
        guard let account = account(target.accountID) else { return }
        for (_, group) in Dictionary(grouping: movable, by: \.mailboxKey) {
            guard let first = group.first else { continue }
            for message in group { removeLocally(message) }
            do {
                try await session(for: account).move(uids: group.map(\.uid), from: first.mailboxPath, to: target.path)
            } catch {
                report(error, account: account)
            }
        }
        messagesByMailbox[target.id] = nil  // refetch the destination next time
        await refreshUnreadCounts(for: account)
    }

    private func apply(_ action: BulkAction, uids: [UInt32], in box: Mailbox, account: MailAccount) async {
        let uidSet = Set(uids)
        let imap = session(for: account)
        do {
            switch action {
            case .markRead:
                try await imap.setFlag("\\Seen", add: true, uids: uids, mailbox: box.path)
                for message in (messagesByMailbox[box.id] ?? []) + (serverSearch?.results ?? [])
                where message.mailboxKey == box.id && uidSet.contains(message.uid) {
                    update(message) { $0.isSeen = true }
                }
            case .archive:
                guard let target = archiveMailbox(for: account.id), target.path != box.path else { return }
                try await imap.move(uids: uids, from: box.path, to: target.path)
                messagesByMailbox[target.id] = nil
            case .trash:
                if let trash = mailbox(.trash, for: account.id), trash.path != box.path {
                    try await imap.move(uids: uids, from: box.path, to: trash.path)
                    messagesByMailbox[trash.id] = nil
                } else {
                    try await imap.deletePermanently(uids: uids, mailbox: box.path)
                }
            }
            if action != .markRead {
                messagesByMailbox[box.id]?.removeAll { uidSet.contains($0.uid) }
                serverSearch?.remove(uidSet, from: box.id)
                if let selected = selectedMessageID, selected.hasPrefix(box.id + "|"),
                   let uid = selected.split(separator: "|").last.flatMap({ UInt32($0) }), uidSet.contains(uid) {
                    selectedMessageID = nil
                }
            }
        } catch {
            report(error, account: account)
        }
        // The server is the source of truth for what's left and the unread count.
        await refreshMailbox(box)
        save()
    }
}
