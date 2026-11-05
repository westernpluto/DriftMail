import Foundation
import Security

/// Secrets shared between DriftMail and its notification extension through a
/// keychain access group ("TEAMID.app.driftmail.shared"). Only available in
/// builds signed with a team (TestFlight / your developer account).
enum SharedSecrets {
    private static let service = "app.driftmail.shared"
    private static let e2eAccount = "notification-e2e-key"

    /// From Info.plist: "$(AppIdentifierPrefix)app.driftmail.shared".
    static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DriftKeychainGroup") as? String,
              let prefix = group.split(separator: ".").first, prefix.count == 10 else { return nil }
        return group
    }

    static func get(_ account: String) -> Data? {
        guard let group = accessGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        guard let group = accessGroup else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Notifications can arrive while the phone is locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        guard let group = accessGroup else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// The 256-bit AES-GCM key that notification contents are encrypted with.
    /// Created on this phone; a copy is given only to your own relay.
    static func notificationKey(createIfMissing: Bool) -> Data? {
        if let existing = get(e2eAccount), existing.count == 32 { return existing }
        guard createIfMissing else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let key = Data(bytes)
        return set(key, for: e2eAccount) ? key : nil
    }
}

/// The account list and app passwords, shared with the notification extension so
/// it can fetch a new message's sender and subject straight from the provider.
enum SharedAccounts {
    private static let listKey = "accounts"
    private static func passwordKey(_ id: UUID) -> String { "password.\(id.uuidString)" }

    static func store(_ accounts: [MailAccount], passwords: [UUID: String]) {
        guard SharedSecrets.accessGroup != nil,
              let data = try? JSONEncoder().encode(accounts) else { return }
        SharedSecrets.set(data, for: listKey)
        for (id, password) in passwords {
            SharedSecrets.set(Data(password.utf8), for: passwordKey(id))
        }
    }

    static func remove(_ id: UUID) {
        SharedSecrets.delete(passwordKey(id))
    }

    static func account(_ id: UUID) -> MailAccount? {
        guard let data = SharedSecrets.get(listKey),
              let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) else { return nil }
        return accounts.first { $0.id == id }
    }

    static func password(for id: UUID) -> String? {
        SharedSecrets.get(passwordKey(id)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
