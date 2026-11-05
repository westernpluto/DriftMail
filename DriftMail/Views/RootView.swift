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
    @State private var showSettings = false
    @State private var showNotificationSetup = false
    @AppStorage("didOfferNotificationSetup") private var didOfferNotificationSetup = false
    @Environment(PushRelay.self) private var relay

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            SidebarView(showSettings: $showSettings)
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
        // iOS resizes the app while it's in the background (app switcher snapshots),
        // and the split view can collapse to the message alone. Bring the list back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, columnVisibility == .detailOnly {
                columnVisibility = .doubleColumn
            }
        }
        .overlay { NewMailToast() }
        .sheet(item: $store.compose) { context in
            ComposeView(context: context)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.compose = ComposeContext(mode: .new)
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
            }
            .visibilityPriority(.high)
        }
    }
}
