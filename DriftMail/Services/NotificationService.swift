import Foundation
import UserNotifications
import UIKit

enum NotificationService {
    static let categoryID = "NEW_MAIL"

    static func requestAuthorization() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted {
                let markRead = UNNotificationAction(identifier: "MARK_READ", title: "Mark as Read", options: [])
                let archive = UNNotificationAction(identifier: "ARCHIVE", title: "Archive", options: [.destructive])
                let category = UNNotificationCategory(identifier: categoryID, actions: [markRead, archive],
                                                      intentIdentifiers: [], options: [])
                center.setNotificationCategories([category])
            }
        }
    }

    static func postLocal(for message: MessageSummary, accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = message.from.displayName
        content.subtitle = message.subject.isEmpty ? "(No subject)" : message.subject
        content.body = message.preview
        content.sound = .default
        content.threadIdentifier = message.accountID.uuidString
        content.categoryIdentifier = categoryID
        content.userInfo = [
            "account": message.accountID.uuidString,
            "uid": Int(message.uid),
            "mailbox": message.mailboxPath,
        ]
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func updateBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
