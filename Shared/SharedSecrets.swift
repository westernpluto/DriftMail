import Foundation
import Security

/// Secrets shared between DriftMail and its notification extension through a
/// keychain access group ("TEAMID.app.driftmail.shared"). Only available in
/// builds signed with a team (TestFlight / your developer account).
enum SharedSecrets {
    private static let service = "app.driftmail.shared"
    private static let e2eAccount = "notification-e2e-key"

    /// From Info.plist: "$(AppIdentifierPrefix)app.driftmail.shared".
    /// Filled in at build time for signed builds; for builds re-signed after the
    /// fact (sideloaded with a paid account) it's derived from the signing team.
    static var accessGroup: String? {
        if let group = Bundle.main.object(forInfoDictionaryKey: "DriftKeychainGroup") as? String,
           let prefix = group.split(separator: ".").first, prefix.count == 10 {
            return group
        }
        return signingTeamID.map { "\($0).app.driftmail.shared" }
    }

    /// The signing Team ID.
    ///
    /// Read from this bundle's provisioning profile first: that needs no keychain. The
    /// older way, a probe keychain item, used iOS's default protection ("only while
    /// unlocked"), so a notification extension started while the phone was locked found
    /// no Team ID, couldn't reach the shared key and showed only "New mail".
    /// A missing value is never cached, so one locked moment can't stick.
    static var signingTeamID: String? {
        if let cachedTeamID { return cachedTeamID }
        let found = teamIDFromProfile() ?? teamIDFromProbe()
        if let found { cachedTeamID = found }
        return found
    }

    nonisolated(unsafe) private static var cachedTeamID: String?

    private static func teamIDFromProfile() -> String? {
        guard let team = (embeddedProfile?["TeamIdentifier"] as? [String])?.first, team.count == 10 else { return nil }
        return team
    }

    private static func teamIDFromProbe() -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.driftmail.team-probe",
            kSecAttrAccount as String: "probe",
        ]
        let accessible = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var query = base
        query[kSecReturnAttributes as String] = true
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data("probe".utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
            status = SecItemCopyMatching(query as CFDictionary, &result)
        } else if status == errSecSuccess {
            // Probes made by older versions were "only while unlocked": upgrade them.
            SecItemUpdate(base as CFDictionary, accessible as CFDictionary)
        }
        guard status == errSecSuccess,
              let group = (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first, prefix.count == 10 else { return nil }
        return String(prefix)
    }

    /// This bundle's embedded.mobileprovision as a dictionary (nil for App Store builds).
    private static let embeddedProfile: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              start.lowerBound < end.upperBound,
              let plistData = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
    }()

    /// "development" or "production", from the push entitlement in this build's
    /// provisioning profile. App Store/TestFlight builds have no embedded profile
    /// and always use production.
    static var apnsEnvironment: String {
        guard let entitlements = embeddedProfile?["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return "production" }
        return environment == "development" ? "development" : "production"
    }

    private static func query(_ account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    /// Reads from the shared group, or from any group this binary can access (which
    /// covers signers that give both binaries the profile's wildcard "TEAMID.*" group).
    static func get(_ account: String) -> Data? {
        for group in [accessGroup, nil] {
            if group == nil && accessGroup == nil && signingTeamID == nil { break }
            var q = query(account, group: group)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return data
            }
        }
        return nil
    }

    /// Writes to the shared group. If the signature doesn't grant that exact group
    /// (some on-device signers apply only the profile's wildcard), falls back to the
    /// default group, which the app and extension then have in common.
    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        guard accessGroup != nil || signingTeamID != nil else { return false }
        delete(account)
        for group in [accessGroup, nil] {
            var attributes = query(account, group: group)
            attributes[kSecValueData as String] = data
            // Notifications can arrive while the phone is locked.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    static func delete(_ account: String) {
        if let group = accessGroup { SecItemDelete(query(account, group: group) as CFDictionary) }
        SecItemDelete(query(account, group: nil) as CFDictionary)
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
