import Foundation
import Observation
import UIKit

/// Logos for business senders, taken from the sender's own website (its
/// apple-touch-icon or favicon) and cached on disk. Only the sender's domain is
/// contacted, never a third-party icon service. Personal mail domains (gmail.com,
/// icloud.com…) are skipped so people keep their initials.
@MainActor
@Observable
final class SenderLogos {
    static let shared = SenderLogos()
    static let enabledKey = "showSenderLogos"

    /// Loaded logos by domain. Views read this, so they update when a logo arrives.
    private(set) var images: [String: UIImage] = [:]

    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var missing: [String: Date]
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let maxConcurrent = 4
    private static let retryMissingAfter: TimeInterval = 7 * 24 * 3600
    private static let missingKey = "senderLogos.missing"

    private init() {
        missing = (UserDefaults.standard.dictionary(forKey: Self.missingKey) as? [String: Date]) ?? [:]
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The logo if it's already in memory (cheap; safe to call while drawing a view).
    func cachedLogo(for address: String) -> UIImage? {
        guard Self.isEnabled, let domain = Self.domain(for: address) else { return nil }
        return images[domain]
    }

    /// Loads the logo for an address from disk or the sender's website.
    func load(for address: String) async {
        guard Self.isEnabled, let domain = Self.domain(for: address),
              images[domain] == nil, !inFlight.contains(domain) else { return }
        if let last = missing[domain], Date().timeIntervalSince(last) < Self.retryMissingAfter { return }
        inFlight.insert(domain)
        defer { inFlight.remove(domain) }

        if let data = await Self.readDisk(domain), let image = UIImage(data: data) {
            images[domain] = image
            return
        }
        await acquireSlot()
        let data = await Self.download(domain)
        releaseSlot()
        if let data, let image = UIImage(data: data) {
            images[domain] = image
            await Self.writeDisk(data, domain)
        } else {
            missing[domain] = Date()
            UserDefaults.standard.set(missing, forKey: Self.missingKey)
        }
    }

    func clearCache() {
        images = [:]
        missing = [:]
        UserDefaults.standard.removeObject(forKey: Self.missingKey)
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Concurrency limit

    private func acquireSlot() async {
        if running < Self.maxConcurrent {
            running += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()  // the slot passes straight to the next one
        }
    }

    // MARK: Domains

    private nonisolated static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
        "live.com", "msn.com", "yahoo.com", "ymail.com", "rocketmail.com", "aol.com", "proton.me",
        "protonmail.com", "pm.me", "gmx.com", "gmx.net", "gmx.de", "web.de", "mail.com", "zoho.com",
        "zohomail.com", "fastmail.com", "fastmail.fm", "hey.com", "yandex.com", "yandex.ru", "qq.com",
        "163.com", "126.com", "comcast.net", "att.net", "verizon.net", "sbcglobal.net", "cox.net",
        "charter.net", "btinternet.com", "orange.fr", "free.fr", "libero.it", "tutanota.com", "tuta.io",
        "hotmail.co.uk", "yahoo.co.uk", "outlook.co.uk", "live.co.uk",
    ]

    /// "news@e.usps.com" -> "usps.com"; nil for personal mail domains.
    nonisolated static func domain(for address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let host = address[address.index(after: at)...]
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'"))
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        // Keep three labels for "example.co.uk"-style domains, two otherwise.
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac", "ne", "or"]
        let keep = labels.count >= 3 && labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        let domain = labels.suffix(keep).joined(separator: ".")
        if personalDomains.contains(domain) || personalDomains.contains(host) { return nil }
        return domain
    }

    // MARK: Network and disk

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// Tries the site's high-resolution touch icon first, then its favicon.
    private nonisolated static func download(_ domain: String) async -> Data? {
        let candidates = [
            "https://\(domain)/apple-touch-icon.png",
            "https://www.\(domain)/apple-touch-icon.png",
            "https://\(domain)/favicon.ico",
            "https://www.\(domain)/favicon.ico",
        ]
        var fallback: Data?
        for candidate in candidates {
            guard let url = URL(string: candidate),
                  let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count < 1_000_000,
                  let image = UIImage(data: data), image.size.width >= 16 else { continue }
            if image.size.width * image.scale >= 64 { return data }
            if fallback == nil { fallback = data }  // small favicon: keep looking for a sharper one
        }
        return fallback
    }

    private nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SenderLogos", isDirectory: true)
    }

    private nonisolated static func readDisk(_ domain: String) async -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(domain))
    }

    private nonisolated static func writeDisk(_ data: Data, _ domain: String) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(domain), options: .atomic)
    }
}
