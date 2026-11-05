import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Succeeds only in builds signed with push (TestFlight / your developer account);
        // DriftMail then offers native notifications instead of ntfy.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            let relay = PushRelay.shared
            let changed = relay.apnsToken != token
            relay.apnsToken = token
            if changed && relay.delivery == .apns { await relay.sync() }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            let relay = PushRelay.shared
            relay.apnsToken = nil
            if relay.delivery == .apns {
                relay.lastSyncSucceeded = false
                relay.lastMessage = "Native push is unavailable in this build: \(error.localizedDescription). Use the free ntfy option instead."
            }
        }
    }

    /// A push arrived while the app is running: refresh so the list is current.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await MailStore.shared.refresh(.unifiedInbox)
        return .newData
    }

    // Show banners even when DriftMail is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let accountString = info["account"] as? String, let accountID = UUID(uuidString: accountString) else { return }
        let uid = (info["uid"] as? Int).map { UInt32($0) } ?? (info["uid"] as? String).flatMap { UInt32($0) }
        let mailbox = info["mailbox"] as? String
        let action = response.actionIdentifier
        await Self.handleNotificationTap(accountID: accountID, uid: uid, mailbox: mailbox, action: action)
    }

    @MainActor
    private static func handleNotificationTap(accountID: UUID, uid: UInt32?, mailbox: String?, action: String) async {
        let store = MailStore.shared
        await store.open(accountID: accountID, uid: uid, mailboxPath: mailbox)
        guard let uid else { return }
        let id = "\(accountID.uuidString)|\(mailbox ?? "INBOX")|\(uid)"
        guard let message = store.message(id: id) else { return }
        switch action {
        case "ARCHIVE": store.archive(message)
        default: store.setSeen(message, true)
        }
    }
}
