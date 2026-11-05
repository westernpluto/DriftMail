import Foundation
import CryptoKit

/// Deploys the DriftMail relay to the person's own Cloudflare account straight
/// from the app, using an API token they paste once. It creates the KV store,
/// uploads the Worker bundled in the app, adds the one-minute schedule, turns on
/// the workers.dev address and returns that address.
enum CloudflareSetup {
    static let scriptName = "driftmail-relay"
    static let kvTitle = "driftmail-kv"
    static let compatibilityDate = "2025-09-01"

    /// Opens the Cloudflare dashboard with a token already filled in: Workers
    /// Scripts (edit), Workers KV Storage (edit) and Account Settings (read).
    static let createTokenURL: URL = {
        let permissions = #"[{"key":"workers_scripts","type":"edit"},{"key":"workers_kv_storage","type":"edit"},{"key":"account_settings","type":"read"}]"#
        var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        components.queryItems = [
            URLQueryItem(name: "permissionGroupKeys", value: permissions),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "name", value: "DriftMail relay"),
        ]
        // URLComponents leaves some JSON characters unescaped; encode them strictly.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        components.percentEncodedQueryItems = components.queryItems?.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url!
    }()

    static let signUpURL = URL(string: "https://dash.cloudflare.com/sign-up/workers-and-pages")!

    /// Apple Push credentials stored as Worker secrets (paid developer accounts).
    struct APNsCredentials {
        var key: String       // contents of AuthKey_XXXXXXXXXX.p8
        var keyID: String
        var teamID: String
        var bundleID: String
    }

    struct Result {
        var url: String
        var pairingCode: String
    }

    /// The relay source shipped inside the app (worker/src/index.js).
    static var bundledScript: Data? {
        Bundle.main.url(forResource: "index", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
    }

    static var bundledScriptHash: String? {
        bundledScript.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: Deploy

    static func deploy(token: String, pairingCode: String, encryptionKey: String,
                       apns: APNsCredentials? = nil,
                       progress: @MainActor (String) -> Void) async throws -> Result {
        guard let script = bundledScript else { throw SetupError("The relay code is missing from this build.") }
        let api = API(token: token)

        await progress("Checking your token…")
        let verify = try await api.call("GET", "/user/tokens/verify")
        guard (verify["status"] as? String) == "active" else { throw SetupError("This Cloudflare token isn't active.") }

        await progress("Finding your account…")
        let accounts = try await api.list("/accounts?per_page=50")
        guard let accountID = accounts.first?["id"] as? String else {
            throw SetupError("The token can't see any Cloudflare account. Create it with the DriftMail link so it includes Account Settings: Read.")
        }

        await progress("Creating storage…")
        let namespaces = try await api.list("/accounts/\(accountID)/storage/kv/namespaces?per_page=100")
        let namespaceID: String
        if let existing = namespaces.first(where: { ($0["title"] as? String) == kvTitle })?["id"] as? String {
            namespaceID = existing
        } else {
            let created = try await api.call("POST", "/accounts/\(accountID)/storage/kv/namespaces", json: ["title": kvTitle])
            guard let id = created["id"] as? String else { throw SetupError("Cloudflare didn't return a storage ID.") }
            namespaceID = id
        }

        await progress("Uploading the relay…")
        var bindings: [[String: Any]] = [
            ["type": "kv_namespace", "name": "DRIFT", "namespace_id": namespaceID],
            ["type": "secret_text", "name": "PAIRING_CODE", "text": pairingCode],
            ["type": "secret_text", "name": "ENC_KEY", "text": encryptionKey],
        ]
        if let apns {
            bindings += [
                ["type": "secret_text", "name": "APNS_KEY", "text": apns.key],
                ["type": "secret_text", "name": "APNS_KEY_ID", "text": apns.keyID],
                ["type": "secret_text", "name": "APNS_TEAM_ID", "text": apns.teamID],
                ["type": "secret_text", "name": "APNS_BUNDLE_ID", "text": apns.bundleID],
            ]
        }
        let metadata: [String: Any] = [
            "main_module": "index.js",
            "compatibility_date": compatibilityDate,
            "bindings": bindings,
            // Logs off: nothing from your mail servers is kept in Cloudflare's log storage.
            "observability": ["enabled": false],
        ]
        _ = try await api.upload("/accounts/\(accountID)/workers/scripts/\(scriptName)", metadata: metadata, script: script)

        await progress("Scheduling inbox checks…")
        _ = try await api.call("PUT", "/accounts/\(accountID)/workers/scripts/\(scriptName)/schedules",
                               jsonArray: [["cron": "* * * * *"]])

        await progress("Turning on your relay address…")
        let subdomain = try await ensureSubdomain(api: api, accountID: accountID)
        _ = try await api.call("POST", "/accounts/\(accountID)/workers/scripts/\(scriptName)/subdomain",
                               json: ["enabled": true, "previews_enabled": false])

        let url = "https://\(scriptName).\(subdomain).workers.dev"
        await progress("Waiting for the address to go live…")
        try await waitUntilReachable(url)
        return Result(url: url, pairingCode: pairingCode)
    }

    private static func ensureSubdomain(api: API, accountID: String) async throws -> String {
        if let existing = try? await api.call("GET", "/accounts/\(accountID)/workers/subdomain"),
           let name = existing["subdomain"] as? String, !name.isEmpty {
            return name
        }
        // New accounts have no workers.dev subdomain yet: pick a random one.
        for _ in 0..<3 {
            let candidate = "driftmail-" + PushRelay.randomString(8).lowercased()
            if let created = try? await api.call("PUT", "/accounts/\(accountID)/workers/subdomain", json: ["subdomain": candidate]),
               let name = created["subdomain"] as? String {
                return name
            }
        }
        throw SetupError("Couldn't create a workers.dev address. Open Workers & Pages in the Cloudflare dashboard once, then try again.")
    }

    /// A brand-new workers.dev address can take a minute or two to start answering.
    private static func waitUntilReachable(_ url: String) async throws {
        guard let target = URL(string: url) else { return }
        for attempt in 0..<40 {
            var request = URLRequest(url: target, timeoutInterval: 10)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .seconds(attempt < 5 ? 3 : 6))
        }
        throw SetupError("The relay was deployed but its address isn't answering yet. Wait a few minutes and tap Set Up again.")
    }

    // MARK: API client

    struct SetupError: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct API {
        let token: String
        let base = "https://api.cloudflare.com/client/v4"

        /// For endpoints whose result is an object.
        func call(_ method: String, _ path: String, json: [String: Any]? = nil, jsonArray: [[String: Any]]? = nil) async throws -> [String: Any] {
            var body: Any? = nil
            if let json { body = json } else if let jsonArray { body = jsonArray }
            let result = try await send(method, path, body: body)
            return result as? [String: Any] ?? [:]
        }

        /// For endpoints whose result is a list.
        func list(_ path: String) async throws -> [[String: Any]] {
            try await send("GET", path, body: nil) as? [[String: Any]] ?? []
        }

        private func send(_ method: String, _ path: String, body: Any?) async throws -> Any {
            guard let url = URL(string: base + path) else { throw URLError(.badURL) }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            return try await perform(request)
        }

        func upload(_ path: String, metadata: [String: Any], script: Data) async throws -> Any {
            guard let url = URL(string: base + path) else { throw URLError(.badURL) }
            let boundary = "driftmail-\(UUID().uuidString)"
            var body = Data()
            func part(_ header: String, _ content: Data) {
                body.append(Data("--\(boundary)\r\n\(header)\r\n\r\n".utf8))
                body.append(content)
                body.append(Data("\r\n".utf8))
            }
            part("Content-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json",
                 try JSONSerialization.data(withJSONObject: metadata))
            part("Content-Disposition: form-data; name=\"index.js\"; filename=\"index.js\"\r\nContent-Type: application/javascript+module",
                 script)
            body.append(Data("--\(boundary)--\r\n".utf8))

            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return try await perform(request)
        }

        private func perform(_ request: URLRequest) async throws -> Any {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let success = object["success"] as? Bool ?? (200..<300).contains(status)
            guard success, (200..<300).contains(status) else {
                let errors = (object["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
                if status == 401 || status == 403 {
                    throw SetupError("Cloudflare refused the token (\(errors.first ?? "HTTP \(status)")). Create it with the DriftMail link so it has the right permissions.")
                }
                throw SetupError(errors.isEmpty ? "Cloudflare answered with HTTP \(status)." : errors.joined(separator: " "))
            }
            return object["result"] ?? [:]
        }
    }
}
