import Foundation

/// What happened the last time the notification extension tried to fetch a new
/// message's sender and subject. Written by the extension, shown in the app
/// (Instant Notifications), so a "New mail" notification can be explained.
/// Stored in the keychain group the app and extension already share.
enum NotificationDiagnostics {
    private static let failureAccount = "notification-last-failure"
    private static let successAccount = "notification-last-success"

    struct Failure: Codable {
        var date: Date
        var account: String
        var reason: String
    }

    static func recordFailure(_ reason: String, account: String) {
        guard let data = try? JSONEncoder().encode(Failure(date: Date(), account: account, reason: reason)) else { return }
        SharedSecrets.set(data, for: failureAccount)
    }

    static func recordSuccess() {
        guard let data = try? JSONEncoder().encode(Date()) else { return }
        SharedSecrets.set(data, for: successAccount)
    }

    static var lastFailure: Failure? {
        SharedSecrets.get(failureAccount).flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }
    }

    static var lastSuccess: Date? {
        SharedSecrets.get(successAccount).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
    }
}
