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

    /// The last few notifications the extension handled and how, newest first. If a
    /// notification shows only "New mail" and has no entry here, iOS didn't run the
    /// extension for it.
    struct Run: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var outcome: String
    }

    private static let runsAccount = "notification-recent-runs"

    static func recordRun(_ outcome: String) {
        let runs = [Run(date: Date(), outcome: outcome)] + recentRuns.prefix(11)
        guard let data = try? JSONEncoder().encode(runs) else { return }
        SharedSecrets.set(data, for: runsAccount)
    }

    static var recentRuns: [Run] {
        SharedSecrets.get(runsAccount).flatMap { try? JSONDecoder().decode([Run].self, from: $0) } ?? []
    }

    static var lastFailure: Failure? {
        SharedSecrets.get(failureAccount).flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }
    }

    static var lastSuccess: Date? {
        SharedSecrets.get(successAccount).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
    }
}
