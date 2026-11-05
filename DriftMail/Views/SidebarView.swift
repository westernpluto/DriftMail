import SwiftUI

struct SidebarView: View {
    @Environment(MailStore.self) private var store
    @Environment(PushRelay.self) private var relay
    @Binding var showSettings: Bool
    /// Only on the outer display, where the mailboxes are shown on their own. On the
    /// inner display the message list beside it already has New Message.
    var showsCompose = true

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section {
                MailboxRow(title: "All Inboxes", symbol: "tray.2.fill", tint: Theme.accent,
                           unread: store.unreadCount(.unifiedInbox))
                    .tag(MailboxSelection.unifiedInbox)
            }

            ForEach(store.accounts) { account in
                Section {
                    ForEach(store.mailboxes[account.id] ?? [], id: \.id) { box in
                        if box.selectable {
                            MailboxRow(title: box.name, symbol: box.role.symbol,
                                       tint: box.role == .inbox ? Theme.accountColor(account) : .secondary,
                                       unread: box.role == .inbox || box.role == .junk ? store.unreadCount(.mailbox(box)) : 0)
                                .tag(MailboxSelection.mailbox(box))
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        AccountDot(account: account)
                        Text(account.email).textCase(nil)
                        Spacer()
                        if store.liveAccounts.contains(account.id) {
                            LiveBadge()
                        }
                    }
                }
            }

            Section {
                NotificationStatusRow()
                    .onTapGesture { showSettings = true }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DriftMail")
        .refreshable { await store.refreshAll() }
        .toolbar {
            if showsCompose {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.compose = ComposeContext(mode: .new)
                    } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                }
                .visibilityPriority(.high)
            }

            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }
}

struct MailboxRow: View {
    var title: String
    var symbol: String
    var tint: Color
    var unread: Int

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if unread > 0 {
                    Text("\(unread)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

struct LiveBadge: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.25 : 0.85)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            Text("Live").font(.caption2.weight(.semibold)).textCase(nil)
        }
        .foregroundStyle(.green)
        .onAppear { pulse = true }
        .accessibilityLabel("Live updates connected")
    }
}

struct NotificationStatusRow: View {
    @Environment(PushRelay.self) private var relay

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Instant Notifications")
                Text(relay.isConfigured ? (relay.lastSyncSucceeded == false ? "Needs attention" : "Connected to your relay") : "Set up free push in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: relay.isConfigured ? "bell.badge.fill" : "bell.slash")
                .foregroundStyle(relay.isConfigured ? AnyShapeStyle(Theme.drift) : AnyShapeStyle(.secondary))
        }
    }
}
