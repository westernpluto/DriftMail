import SwiftUI

struct RootView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        if store.accounts.isEmpty {
            WelcomeView()
        } else {
            MailSplitView()
        }
    }
}

/// Three-column split view. On iPhone Duo it collapses to a single pane on the
/// outer display and expands on the inner display, where the system also adapts
/// the column widths to the fold automatically.
struct MailSplitView: View {
    @Environment(MailStore.self) private var store
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    // Which column the single-pane (outer display) layout shows.
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSettings = false
    @State private var showNotificationSetup = false
    @AppStorage("didOfferNotificationSetup") private var didOfferNotificationSetup = false
    @Environment(PushRelay.self) private var relay

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            SidebarView(showSettings: $showSettings, showsCompose: horizontalSizeClass != .regular)
        } content: {
            MessageListView()
        } detail: {
            if let message = store.message(id: store.selectedMessageID) {
                MessageDetailView(summary: message)
                    .id(message.id)
            } else {
                EmptyDetailView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        // A notification opened a message: show it beside the list (sidebar out of
        // the way) on the inner display, and go straight to it on the outer display.
        .onChange(of: store.revealRequest) {
            withAnimation {
                if columnVisibility != .doubleColumn { columnVisibility = .doubleColumn }
                preferredCompactColumn = .detail
            }
        }
        // DriftMail never offers a message-only layout (the toolbar button only shows
        // and hides the mailbox sidebar), but the split view can fall into one by
        // itself, e.g. when iOS resizes the app in the background for app switcher
        // snapshots. Undo it right away on the inner display, and again on return.
        .onChange(of: columnVisibility) {
            keepListVisible(sizeClass: horizontalSizeClass)
        }
        // While iOS resizes the app in the background, the visibility can flip to
        // detail-only before this view sees the new (regular) size class, so the
        // check above would still read "compact" and skip it. Check again when the
        // size class itself changes, so it's caught whichever change comes first.
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            keepListVisible(sizeClass: sizeClass)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, columnVisibility == .detailOnly {
                restoreListWithoutAnimation()
            }
        }
        .overlay { NewMailToast() }
        .sheet(item: $store.compose) { context in
            ComposeView(context: context)
        }
        .sheet(item: $store.moveRequest) { request in
            MoveToMailboxSheet(request: request)
        }
        // "Show All from Sender": bring the list (with its search) to the front.
        .onChange(of: store.listRevealRequest) {
            preferredCompactColumn = .content
            if horizontalSizeClass == .regular, columnVisibility == .detailOnly {
                restoreListWithoutAnimation()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showNotificationSetup) {
            NavigationStack {
                NotificationSetupView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .cancel) { showNotificationSetup = false } label: {
                                Label("Not Now", systemImage: "xmark")
                            }
                        }
                    }
            }
        }
        .task {
            // Offer free instant notifications once, right after the first account is added.
            guard !didOfferNotificationSetup, !relay.isConfigured else { return }
            try? await Task.sleep(for: .seconds(1.5))
            didOfferNotificationSetup = true
            showNotificationSetup = true
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

extension MailSplitView {
    /// On the inner display (regular width), never stay in a message-only layout.
    fileprivate func keepListVisible(sizeClass: UserInterfaceSizeClass?) {
        if sizeClass == .regular, columnVisibility == .detailOnly {
            restoreListWithoutAnimation()
        }
    }

    /// Puts the list back instantly. These corrections undo a layout change the user
    /// never made, so animating them (the split view's default) showed as the list
    /// and message sliding across the screen when DriftMail was reopened.
    fileprivate func restoreListWithoutAnimation() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            columnVisibility = .doubleColumn
        }
    }
}

struct EmptyDetailView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        ZStack {
            Theme.softDrift.ignoresSafeArea()
            VStack(spacing: 18) {
                DriftLogo(size: 84)
                Text(store.unreadCount(.unifiedInbox) == 0 ? "You're all caught up" : "\(store.unreadCount(.unifiedInbox)) unread")
                    .font(.title2.weight(.semibold))
                Text("Choose a message to read it here.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding()
        }
        // No New Message here: this only appears on the inner display, where the
        // message list beside it already has one.
    }
}
