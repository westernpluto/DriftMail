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
            contentHandler(content)
            return
        }
        let mailbox = payload["mailbox"] as? String ?? "INBOX"

        work = Task {
            if let summary = await Self.fetchSummary(account: account, password: password, mailbox: mailbox, uid: uid) {
                content.title = summary.from.displayName
                content.subtitle = summary.subject.isEmpty ? "(No subject)" : summary.subject
                content.body = summary.preview
            }
            self.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
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

    /// Signs in over TLS and fetches the start of one message. Gives up after 20 s.
    private static func fetchSummary(account: MailAccount, password: String, mailbox: String, uid: UInt32) async -> MessageSummary? {
        await withTaskGroup(of: MessageSummary?.self) { group in
            group.addTask {
                let client = IMAPClient(host: account.imapHost, port: account.imapPort)
                defer { client.close() }
                do {
                    try await client.connect()
                    try await client.login(username: account.username, password: password)
                    try await client.select(mailbox, readOnly: true)
                    guard let item = try await client.fetchPreviews(uids: [uid], previewBytes: 8192).first(where: { $0.uid == uid }) else {
                        return nil
                    }
                    return MIME.summary(from: item.body ?? [], accountID: account.id, mailbox: mailbox,
                                        uid: uid, flags: item.flags, internalDate: item.internalDate)
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
