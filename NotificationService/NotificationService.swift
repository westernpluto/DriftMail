import UserNotifications
import CryptoKit

/// Builds DriftMail's native notifications on the phone.
///
/// The relay sends Apple only a placeholder ("New mail") plus AES-256-GCM
/// ciphertext of a message reference (account + message number). This extension
/// decrypts it with the key only this phone has, then signs in to the mail
/// provider itself and fetches the sender, subject and preview. Neither Apple nor
/// the relay ever handles them.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        guard let encoded = content.userInfo["enc"] as? String,
              let payload = Self.decrypt(encoded) else {
            if content.userInfo["enc"] != nil {
                NotificationDiagnostics.recordFailure(
                    "Couldn't decrypt it: the key on this phone doesn't match the relay's (set up Apple Push again)",
                    account: "unknown account")
            }
            contentHandler(content)
            return
        }

        var info = content.userInfo
        info["enc"] = nil
        for key in ["account", "uid", "mailbox"] {
            if let value = payload[key], !(value is NSNull) { info[key] = value }
        }
        content.userInfo = info

        // Test notifications carry their own text.
        if let title = payload["title"] as? String, let body = payload["body"] as? String {
            content.title = title
            content.body = body
            contentHandler(content)
            return
        }

        let accountID = (payload["account"] as? String).flatMap(UUID.init(uuidString:))
        let account = accountID.flatMap(SharedAccounts.account)
        if let account {
            content.threadIdentifier = account.id.uuidString
            content.title = "New mail"
            content.body = account.email
        }
        if let more = payload["more"] as? Int, let account {
            content.title = account.email
            content.body = "\(more) more new messages"
            contentHandler(content)
            return
        }

        guard let account,
              let uid = (payload["uid"] as? Int).map({ UInt32($0) }),
              let password = SharedAccounts.password(for: account.id) else {
            let reason: String
            if account == nil {
                reason = "The account it was for isn't shared with the notification extension (open DriftMail once)"
            } else if (payload["uid"] as? Int) == nil {
                reason = "The relay didn't say which message it was"
            } else {
                reason = "Couldn't read the account's password from the shared keychain"
            }
            NotificationDiagnostics.recordFailure(reason, account: account?.email ?? "unknown account")
            contentHandler(content)
            return
        }
        let mailbox = payload["mailbox"] as? String ?? "INBOX"

        work = Task {
            // Two tries on fresh connections: a phone waking on cellular often loses
            // the first connection attempt. iOS gives the extension about 30 seconds.
            var failure = ""
            attempts: for (attempt, budget) in [(1, 10.0), (2, 12.0)] {
                if Task.isCancelled { break }
                switch await Self.fetchSummary(account: account, password: password, mailbox: mailbox,
                                               uid: uid, timeout: budget) {
                case .success(let summary):
                    content.title = summary.from.displayName
                    content.subtitle = summary.subject.isEmpty ? "(No subject)" : summary.subject
                    content.body = summary.preview
                    NotificationDiagnostics.recordSuccess()
                    self.finish()
                    return
                case .failure(let error):
                    failure = "Attempt \(attempt): \(error.localizedDescription)"
                    if case FetchError.notFound = error { break attempts }  // retrying won't help
                }
            }
            NotificationDiagnostics.recordFailure(failure, account: account.email)
            self.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        if contentHandler != nil, let email = SharedAccounts.account(
            (content?.userInfo["account"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID())?.email {
            NotificationDiagnostics.recordFailure("iOS stopped the notification extension before it finished", account: email)
        }
        finish()
    }

    private func finish() {
        guard let handler = contentHandler, let content else { return }
        contentHandler = nil
        handler(content)
    }

    private static func decrypt(_ encoded: String) -> [String: Any]? {
        guard let sealed = Data(base64Encoded: encoded),
              let keyData = SharedSecrets.notificationKey(createIfMissing: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    enum FetchError: LocalizedError {
        case timedOut(step: String, seconds: Double)
        case failed(step: String, reason: String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .timedOut(let step, let seconds): return "timed out after \(Int(seconds)) s while \(step)"
            case .failed(let step, let reason): return "failed while \(step): \(reason)"
            case .notFound: return "the message was no longer in the mailbox"
            }
        }
    }

    /// Which step an attempt is on, for the diagnostics.
    private final class Step: @unchecked Sendable {
        var name = "connecting"
        var timedOut = false
    }

    /// Signs in over TLS and fetches the start of one message, giving up after `timeout`
    /// seconds. On a timeout the connection is closed at once so nothing lingers.
    private static func fetchSummary(account: MailAccount, password: String, mailbox: String,
                                     uid: UInt32, timeout: Double) async -> Result<MessageSummary, Error> {
        let client = IMAPClient(host: account.imapHost, port: account.imapPort)
        let step = Step()
        defer { client.close() }
        do {
            return .success(try await withThrowingTaskGroup(of: MessageSummary.self) { group in
                group.addTask {
                    do {
                        try await client.connect()
                        step.name = "signing in"
                        try await client.login(username: account.username, password: password)
                        step.name = "opening \(mailbox)"
                        try await client.select(mailbox, readOnly: true)
                        step.name = "fetching the message"
                        // 16 KB: some senders put more than 8 KB of routing headers before From/Subject.
                        guard let item = try await client.fetchPreviews(uids: [uid], previewBytes: 16384)
                            .first(where: { $0.uid == uid }) else { throw FetchError.notFound }
                        return MIME.summary(from: item.body ?? [], accountID: account.id, mailbox: mailbox,
                                            uid: uid, flags: item.flags, internalDate: item.internalDate)
                    } catch let error as FetchError {
                        throw error
                    } catch {
                        // The timeout below closes the connection, which also lands here.
                        if step.timedOut { throw FetchError.timedOut(step: step.name, seconds: timeout) }
                        throw FetchError.failed(step: step.name, reason: error.localizedDescription)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    // Close the connection so the stalled step above fails now: the group
                    // waits for every task, and a socket read could otherwise hang for 90 s.
                    step.timedOut = true
                    client.close()
                    throw FetchError.timedOut(step: step.name, seconds: timeout)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw FetchError.notFound }
                return first
            })
        } catch {
            return .failure(error)
        }
    }
}
