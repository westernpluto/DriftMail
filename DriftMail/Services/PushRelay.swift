import Foundation
import Observation
import UIKit

/// Talks to the DriftMail relay, a free Cloudflare Worker you deploy yourself.
/// The Worker stays connected to your inboxes (IMAP IDLE) and sends a push the moment
/// new mail lands, even when DriftMail is closed.
@MainActor
@Observable
final class PushRelay {
    static let shared = PushRelay()

    enum Delivery: String, CaseIterable, Identifiable {
        case ntfy      // free: the ntfy app shows the notification (no Apple developer account needed)
        case apns      // native DriftMail notifications (needs a paid Apple developer account)
        var id: String { rawValue }
        var title: String { self == .ntfy ? "ntfy app" : "Apple Push" }
    }

    struct Status: Decodable {
        struct AccountStatus: Decodable, Identifiable {
            var id: String
            var email: String
            var lastError: String?
            var lastChecked: String?
        }
        var configured: Bool
        var delivery: String?
        var accounts: [AccountStatus]
        var lastRun: String?
    }

    var workerURL: String {
        didSet { UserDefaults.standard.set(workerURL, forKey: "relay.url") }
    }
    var delivery: Delivery {
        didSet { UserDefaults.standard.set(delivery.rawValue, forKey: "relay.delivery") }
    }
    /// The person has picked Apple Push or ntfy. Nothing is set up until they do.
    var hasChosenDelivery: Bool {
        didSet { UserDefaults.standard.set(hasChosenDelivery, forKey: "relay.deliveryChosen") }
    }
    var ntfyServer: String {
        didSet { UserDefaults.standard.set(ntfyServer, forKey: "relay.ntfyServer") }
    }
    var ntfyTopic: String {
        didSet { UserDefaults.standard.set(ntfyTopic, forKey: "relay.ntfyTopic") }
    }
    /// Apple Push only: the phone fetches sender and subject itself (needs the
    /// notification extension). Off: the relay includes them, like ntfy.
    var privateNotifications: Bool {
        didSet { UserDefaults.standard.set(privateNotifications, forKey: "relay.private") }
    }
    var showPreviews: Bool {
        didSet { UserDefaults.standard.set(showPreviews, forKey: "relay.previews") }
    }
    var apnsToken: String? {
        didSet { UserDefaults.standard.set(apnsToken, forKey: "relay.apnsToken") }
    }

    var isSyncing = false
    var isSettingUp = false
    var setupProgress: String?
    var lastMessage: String?
    var lastSyncSucceeded: Bool?
    var status: Status?

    var isConfigured: Bool { URL(string: workerURL)?.host != nil }

    /// Shared secret between this phone and your Worker. Generated once, kept in the Keychain.
    var token: String {
        if let existing = Keychain.get("relay.token") { return existing }
        let fresh = Self.randomString(40)
        Keychain.set(fresh, for: "relay.token")
        return fresh
    }

    /// The code you chose when deploying the relay (RELAY_PAIRING_CODE). Only needed to pair.
    var pairingCode: String = Keychain.get("relay.pairingCode") ?? "" {
        didSet { Keychain.set(pairingCode, for: "relay.pairingCode") }
    }

    var ntfySubscribeURL: URL? {
        URL(string: "\(ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(ntfyTopic)")
    }

    private init() {
        let defaults = UserDefaults.standard
        workerURL = defaults.string(forKey: "relay.url") ?? ""
        delivery = Delivery(rawValue: defaults.string(forKey: "relay.delivery") ?? "") ?? .ntfy
        // Relays set up before this choice existed keep their current method.
        hasChosenDelivery = defaults.bool(forKey: "relay.deliveryChosen")
            || URL(string: defaults.string(forKey: "relay.url") ?? "")?.host != nil
        ntfyServer = defaults.string(forKey: "relay.ntfyServer") ?? "https://ntfy.sh"
        showPreviews = defaults.object(forKey: "relay.previews") as? Bool ?? true
        privateNotifications = defaults.object(forKey: "relay.private") as? Bool ?? true
        apnsToken = defaults.string(forKey: "relay.apnsToken")
        if let topic = defaults.string(forKey: "relay.ntfyTopic") {
            ntfyTopic = topic
        } else {
            let topic = "driftmail-" + Self.randomString(22).lowercased()
            ntfyTopic = topic
            defaults.set(topic, forKey: "relay.ntfyTopic")
        }
    }

    nonisolated static func randomString(_ length: Int) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }

    func regenerateTopic() {
        ntfyTopic = "driftmail-" + Self.randomString(22).lowercased()
    }

    // MARK: Automatic setup

    /// True when the app deployed the relay itself and can keep it updated.
    var isManagedByApp: Bool { Keychain.get("relay.cloudflareToken") != nil }

    /// Deploys the relay to the person's Cloudflare account, pairs this phone,
    /// uploads the accounts and sends a test notification. One tap.
    func setUpAutomatically(cloudflareToken: String) async {
        var token = cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty, let stored = Keychain.get("relay.cloudflareToken") { token = stored }
        guard !token.isEmpty else { return }
        // Use exactly the method the person chose; never fall back silently.
        let useNative = delivery == .apns
        if useNative {
            if apnsToken == nil {
                lastSyncSucceeded = false
                lastMessage = "This build can't receive Apple Push. Install the TestFlight build or sideload it signed with your paid developer account, or choose ntfy."
                return
            }
            if apnsCredentials == nil {
                lastSyncSucceeded = false
                lastMessage = "Choose your Apple Push key (.p8) first."
                return
            }
        }
        isSettingUp = true
        lastMessage = nil
        lastSyncSucceeded = nil
        defer { isSettingUp = false; setupProgress = nil }
        do {
            let code = pairingCode.count >= 16 ? pairingCode : Self.randomString(32)
            let result = try await CloudflareSetup.deploy(token: token, pairingCode: code, encryptionKey: encryptionKey,
                                                          apns: useNative ? apnsCredentials : nil) { step in
                self.setupProgress = step
            }
            Keychain.set(token, for: "relay.cloudflareToken")
            pairingCode = result.pairingCode
            workerURL = result.url
            UserDefaults.standard.set(CloudflareSetup.bundledScriptHash, forKey: "relay.deployedHash")
            hasChosenDelivery = true
            setupProgress = "Connecting your accounts…"
            await sync()
            if lastSyncSucceeded == true {
                await sendTest()
                lastMessage = "All set. Your relay is live and a test notification is on its way."
            }
        } catch {
            lastSyncSucceeded = false
            lastMessage = error.localizedDescription
        }
    }

    /// When a new DriftMail version ships updated relay code, redeploy it quietly.
    func updateRelayIfNeeded() async {
        guard !isSettingUp, let token = Keychain.get("relay.cloudflareToken"), isConfigured,
              let hash = CloudflareSetup.bundledScriptHash,
              UserDefaults.standard.string(forKey: "relay.deployedHash") != hash else { return }
        do {
            _ = try await CloudflareSetup.deploy(token: token, pairingCode: pairingCode, encryptionKey: encryptionKey,
                                                 apns: delivery == .apns ? apnsCredentials : nil) { _ in }
            UserDefaults.standard.set(hash, forKey: "relay.deployedHash")
            // Re-sync so the relay gets anything new it needs (such as the encryption key).
            await sync()
        } catch {
            // Try again next launch.
        }
    }

    /// After an app update, wakes the new notification extension once with a silent push
    /// (the app hides it), so the first real email isn't the one delayed by the
    /// extension's first launch, which iOS makes slower for newly installed apps.
    func warmUpAfterUpdateIfNeeded() async {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard isConfigured, delivery == .apns, apnsToken != nil,
              UserDefaults.standard.string(forKey: "relay.warmedBuild") != build else { return }
        do {
            _ = try await request("/v1/test", method: "POST", body: ["warmup": true])
            UserDefaults.standard.set(build, forKey: "relay.warmedBuild")
        } catch {
            // Try again next launch.
        }
    }

    // MARK: Native push (paid Apple Developer account)

    /// This build is signed with push enabled and Apple gave us a device token.
    var canUseNativePush: Bool { apnsToken != nil }

    /// Native notifications are encrypted so only this phone can read them.
    var isEndToEndEncrypted: Bool {
        delivery == .apns && privateNotifications && SharedSecrets.notificationKey(createIfMissing: false) != nil
    }

    var hasAPNsKey: Bool { Keychain.get("relay.apnsKey") != nil }
    var apnsKeyID: String { Keychain.get("relay.apnsKeyID") ?? "" }

    var apnsCredentials: CloudflareSetup.APNsCredentials? {
        guard let key = Keychain.get("relay.apnsKey"), let keyID = Keychain.get("relay.apnsKeyID"),
              let teamID = Keychain.teamID() ?? SharedSecrets.signingTeamID, let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return CloudflareSetup.APNsCredentials(key: key, keyID: keyID, teamID: teamID, bundleID: bundleID)
    }

    /// Saves the Apple Push key picked from Files. The Key ID is read from the
    /// standard file name (AuthKey_ABC123DEFG.p8) when possible.
    func importAPNsKey(contents: String, filename: String, keyID manualKeyID: String?) throws {
        guard contents.contains("BEGIN PRIVATE KEY") else {
            throw CloudflareSetup.SetupError("That file isn't an Apple Push key (.p8).")
        }
        var keyID = manualKeyID?.trimmingCharacters(in: .whitespaces) ?? ""
        if keyID.isEmpty, let match = filename.firstMatch(of: #/AuthKey_([A-Z0-9]{10})/#) {
            keyID = String(match.1)
        }
        guard keyID.count == 10 else {
            throw CloudflareSetup.SetupError("Enter the 10-character Key ID shown next to the key in your developer account.")
        }
        Keychain.set(contents, for: "relay.apnsKey")
        Keychain.set(keyID, for: "relay.apnsKeyID")
    }

    /// Records the person's choice and, if the relay is already running, switches it over.
    func choose(_ newDelivery: Delivery) {
        let changed = delivery != newDelivery || !hasChosenDelivery
        delivery = newDelivery
        hasChosenDelivery = true
        lastMessage = nil
        lastSyncSucceeded = nil
        if changed && isConfigured { Task { await reconfigure() } }
    }

    /// Applies the chosen delivery method to a running relay.
    func reconfigure() async {
        guard isConfigured else { return }
        if delivery == .apns && apnsCredentials == nil {
            lastSyncSucceeded = false
            lastMessage = "Choose your Apple Push key (.p8) to finish switching. Until then notifications keep going through ntfy."
            return
        }
        if isManagedByApp {
            // Redeploys so the relay gets (or drops) the Apple Push key, then re-syncs.
            await setUpAutomatically(cloudflareToken: "")
        } else {
            await sync()
            if lastSyncSucceeded == true {
                lastMessage = delivery == .apns
                    ? "Switched to Apple Push. If you deployed the relay yourself, make sure its APNS_* secrets are set."
                    : "Switched to ntfy."
            }
        }
    }

    // MARK: Security

    private func relayPasswordKey(_ account: MailAccount) -> String { "relaypw.\(account.id.uuidString)" }

    /// A separate app password used only by the relay (recommended).
    func relayPassword(for account: MailAccount) -> String? { Keychain.get(relayPasswordKey(account)) }

    func hasSeparatePassword(_ account: MailAccount) -> Bool { relayPassword(for: account) != nil }

    /// Checks the password signs in, saves it, and sends it to the relay in place of the phone's.
    func setRelayPassword(_ password: String, for account: MailAccount) async throws {
        var clean = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.providerID == MailProvider.gmail.id { clean = clean.replacingOccurrences(of: " ", with: "") }
        if clean == Keychain.password(for: account) {
            throw CloudflareSetup.SetupError("That's the same password the phone uses. Create a new app password just for the relay.")
        }
        try await AccountSession.verify(account: account, password: clean)
        Keychain.set(clean, for: relayPasswordKey(account))
        await syncIfConfigured()
    }

    func clearRelayPassword(for account: MailAccount) async {
        Keychain.delete(relayPasswordKey(account))
        await syncIfConfigured()
    }

    /// Stops storing the Cloudflare token on this phone. The relay keeps working;
    /// it just won't update automatically until a token is pasted again.
    func forgetCloudflareToken() {
        Keychain.delete("relay.cloudflareToken")
    }

    /// A newer relay is bundled with the app but there's no token to install it with.
    var relayUpdateAvailable: Bool {
        guard isConfigured, !isManagedByApp,
              let deployed = UserDefaults.standard.string(forKey: "relay.deployedHash") else { return false }
        return deployed != CloudflareSetup.bundledScriptHash
    }

    /// Stable key the relay uses to encrypt stored app passwords.
    private var encryptionKey: String {
        if let existing = Keychain.get("relay.encKey") { return existing }
        let fresh = Self.randomString(44)
        Keychain.set(fresh, for: "relay.encKey")
        return fresh
    }

    // MARK: API

    private func request(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var base = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasPrefix("http") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let pairing = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pairing.isEmpty { request.setValue(pairing, forHTTPHeaderField: "X-Pairing-Code") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MailError.server(detail ?? "Relay answered with HTTP \(code).")
        }
        return data
    }

    private func deliveryPayload() -> [String: Any] {
        switch delivery {
        case .ntfy:
            return ["type": "ntfy", "server": ntfyServer, "topic": ntfyTopic]
        case .apns:
            // Matches however the app was signed (TestFlight, ad hoc, or sideloaded
            // with a development certificate).
            let environment = SharedSecrets.apnsEnvironment
            return ["type": "apns", "token": apnsToken ?? "", "environment": environment,
                    "topic": Bundle.main.bundleIdentifier ?? ""]
        }
    }

    /// Sends the account list (with app passwords) and delivery settings to your Worker.
    func sync() async {
        guard isConfigured else { return }
        if delivery == .apns && isManagedByApp && apnsCredentials == nil {
            lastSyncSucceeded = false
            lastMessage = "Choose your Apple Push key (.p8) first."
            return
        }
        if delivery == .apns && apnsToken == nil {
            UIApplication.shared.registerForRemoteNotifications()
            lastMessage = "Waiting for Apple to issue a push token. This only works when the app is signed with a paid Apple Developer account."
            lastSyncSucceeded = false
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let accounts: [[String: Any]] = MailStore.shared.accounts.compactMap { account in
            // Prefer the relay's own app password, so it can be revoked without affecting the phone.
            guard let password = relayPassword(for: account) ?? Keychain.password(for: account) else { return nil }
            return [
                "id": account.id.uuidString,
                "email": account.email,
                "host": account.imapHost,
                "port": account.imapPort,
                "username": account.username,
                "password": password,
            ]
        }
        do {
            var body: [String: Any] = [
                "delivery": deliveryPayload(),
                "showPreviews": showPreviews,
                "accounts": accounts,
            ]
            // Native notifications are end-to-end encrypted with a key made on this phone.
            if delivery == .apns, privateNotifications, let key = SharedSecrets.notificationKey(createIfMissing: true) {
                body["e2eKey"] = key.base64EncodedString()
            }
            _ = try await request("/v1/sync", method: "POST", body: body)
            lastSyncSucceeded = true
            lastMessage = "Connected. Your Worker now watches \(accounts.count) inbox\(accounts.count == 1 ? "" : "es") live."
            await refreshStatus()
        } catch {
            lastSyncSucceeded = false
            lastMessage = error.localizedDescription
        }
    }

    func syncIfConfigured() async {
        if isConfigured { await sync() }
    }

    func sendTest() async {
        do {
            _ = try await request("/v1/test", method: "POST", body: [:])
            lastSyncSucceeded = true
            lastMessage = "Test notification sent. It should arrive within a few seconds."
        } catch {
            lastSyncSucceeded = false
            lastMessage = error.localizedDescription
        }
    }

    func refreshStatus() async {
        do {
            let data = try await request("/v1/status", method: "GET")
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            status = nil
        }
    }

    func disconnect() async {
        _ = try? await request("/v1/sync", method: "DELETE")
        Keychain.delete("relay.cloudflareToken")
        delivery = .ntfy
        status = nil
        lastSyncSucceeded = nil
        lastMessage = "Disconnected. Your Worker no longer stores your accounts."
    }
}
