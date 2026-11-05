import SwiftUI
import BackgroundTasks

@main
struct DriftMailApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = MailStore.shared
    @State private var relay = PushRelay.shared

    static let refreshTaskID = "app.driftmail.refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(relay)
                .tint(Theme.accent)
                .onOpenURL { url in handle(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.startLive()
                Task { await store.refreshAll() }
            case .background:
                store.stopLive()
                NotificationService.updateBadge(store.unreadCount(.unifiedInbox))
                Task { await Self.scheduleBackgroundRefresh() }
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await Self.scheduleBackgroundRefresh()
            await MailStore.shared.backgroundCheck()
        }
    }

    /// driftmail://message?account=<uuid>&uid=<uid>&mailbox=INBOX (used by ntfy "click" links).
    private func handle(_ url: URL) {
        guard url.scheme == "driftmail" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let accountID = value("account").flatMap(UUID.init(uuidString:)) else {
            Task { await store.refreshAll() }
            return
        }
        Task {
            await store.open(accountID: accountID, uid: value("uid").flatMap { UInt32($0) }, mailboxPath: value("mailbox"))
        }
    }

    static func scheduleBackgroundRefresh() async {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? await BGTaskScheduler.shared.submitTaskRequest(request)
    }
}
