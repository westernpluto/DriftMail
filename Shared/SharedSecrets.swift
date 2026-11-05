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
