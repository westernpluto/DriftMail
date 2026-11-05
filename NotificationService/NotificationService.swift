import UserNotifications
import CryptoKit

/// Decrypts end-to-end encrypted DriftMail notifications on the phone.
///
/// The relay sends Apple a placeholder ("New mail") plus an `enc` field holding
/// AES-256-GCM ciphertext (nonce | ciphertext | tag) of the real sender, subject
/// and message reference. Only this phone has the key, so Apple can't read it.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        if let encoded = content.userInfo["enc"] as? String,
           let sealed = Data(base64Encoded: encoded),
           let keyData = SharedSecrets.notificationKey(createIfMissing: false),
           let box = try? AES.GCM.SealedBox(combined: sealed),
           let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
           let payload = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] {
            if let title = payload["title"] as? String { content.title = title }
            if let body = payload["body"] as? String { content.body = body }
            var info = content.userInfo
            info["enc"] = nil
            for key in ["account", "uid", "mailbox"] {
                if let value = payload[key], !(value is NSNull) { info[key] = value }
            }
            content.userInfo = info
            if let account = payload["account"] as? String { content.threadIdentifier = account }
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let content { contentHandler(content) }
    }
}
