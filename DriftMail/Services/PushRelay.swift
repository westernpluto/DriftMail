import Foundation
import Observation
import UIKit

/// Talks to the DriftMail relay, a free Cloudflare Worker you deploy yourself.
/// The Worker watches your inboxes every minute and sends a push the moment
/// new mail lands, even when DriftMail is closed.
@MainActor
@Observable
final class PushRelay {
    static let shared = PushRelay()

    enum Delivery: String, CaseIterable, Identifiable {
        case ntfy      // free: the ntfy app shows the notification (no Apple developer account needed)
        case apns      // native DriftMail notifications (needs a paid Apple developer account)
        var id: String { rawValue }
        var title: String { self == .ntfy ? "ntfy app (free)" : "Native push (Apple Developer)" }
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
    var ntfyServer: String {
        didSet { UserDefaults.standard.set(ntfyServer, forKey: "relay.ntfyServer") }
    }
    var ntfyTopic: String {
        didSet { UserDefaults.standard.set(ntfyTopic, forKey: "relay.ntfyTopic") }
    }
    var showPreviews: Bool {
        didSet { UserDefaults.standard.set(showPreviews, forKey: "relay.previews") }
    }
    var apnsToken: String? {
        didSet { UserDefaults.standard.set(apnsToken, forKey: "relay.apnsToken") }
    }

    var isSyncing = false
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
        ntfyServer = defaults.string(forKey: "relay.ntfyServer") ?? "https://ntfy.sh"
        showPreviews = defaults.object(forKey: "relay.previews") as? Bool ?? true
        apnsToken = defaults.string(forKey: "relay.apnsToken")
        if let topic = defaults.string(forKey: "relay.ntfyTopic") {
            ntfyTopic = topic
        } else {
            let topic = "driftmail-" + Self.randomString(22).lowercased()
            ntfyTopic = topic
            defaults.set(topic, forKey: "relay.ntfyTopic")
        }
    }

    static func randomString(_ length: Int) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }

    func regenerateTopic() {
        ntfyTopic = "driftmail-" + Self.randomString(22).lowercased()
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
            #if DEBUG
            let environment = "development"
            #else
            let environment = "production"
            #endif
            return ["type": "apns", "token": apnsToken ?? "", "environment": environment,
                    "topic": Bundle.main.bundleIdentifier ?? ""]
        }
    }

    /// Sends the account list (with app passwords) and delivery settings to your Worker.
    func sync() async {
        guard isConfigured else { return }
        if delivery == .apns && apnsToken == nil {
            UIApplication.shared.registerForRemoteNotifications()
            lastMessage = "Waiting for Apple to issue a push token. This only works when the app is signed with a paid Apple Developer account."
            lastSyncSucceeded = false
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let accounts: [[String: Any]] = MailStore.shared.accounts.compactMap { account in
            guard let password = Keychain.password(for: account) else { return nil }
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
            _ = try await request("/v1/sync", method: "POST", body: [
                "delivery": deliveryPayload(),
                "showPreviews": showPreviews,
                "accounts": accounts,
            ])
            lastSyncSucceeded = true
            lastMessage = "Connected. Your Worker now checks \(accounts.count) inbox\(accounts.count == 1 ? "" : "es") every minute."
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
        status = nil
        lastSyncSucceeded = nil
        lastMessage = "Disconnected. Your Worker no longer stores your accounts."
    }
}
