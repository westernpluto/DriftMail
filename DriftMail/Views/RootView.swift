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
    @State private var showSettings = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        .overlay { NewMailToast() }
        .sheet(item: $store.compose) { context in
            ComposeView(context: context)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
