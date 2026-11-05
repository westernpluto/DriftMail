import SwiftUI

struct MessageListView: View {
    @Environment(MailStore.self) private var store
    @State private var searchText = ""
    @State private var unreadOnly = false

    private var selection: MailboxSelection { store.selection ?? .unifiedInbox }

    private var visibleMessages: [MessageSummary] {
        var list = store.messages(for: selection)
        if unreadOnly { list = list.filter { !$0.isSeen } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.subject.localizedCaseInsensitiveContains(query)
                    || $0.from.displayName.localizedCaseInsensitiveContains(query)
                    || $0.from.address.localizedCaseInsensitiveContains(query)
                    || $0.preview.localizedCaseInsensitiveContains(query)
            }
        }
        return list
    }

    var body: some View {
        @Bindable var store = store
        let messages = visibleMessages
        List(selection: $store.selectedMessageID) {
            ForEach(messages) { message in
                MessageRow(message: message,
                           account: store.account(message.accountID),
                           showAccount: selection == .unifiedInbox && store.accounts.count > 1)
                    .tag(message.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            store.setSeen(message, !message.isSeen)
                        } label: {
                            Label(message.isSeen ? "Unread" : "Read",
                                  systemImage: message.isSeen ? "envelope.badge" : "envelope.open")
                        }
                        .tint(Theme.accent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if store.canArchive(message) {
                            Button {
                                withAnimation { store.archive(message) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.purple)
                        }
                        Button(role: .destructive) {
                            withAnimation { store.trash(message) }
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        Button {
                            store.toggleFlag(message)
                        } label: {
                            Label(message.isFlagged ? "Unflag" : "Flag", systemImage: "flag")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        MessageActionsMenu(message: message)
                    }
            }

            if store.canLoadMore(selection) && searchText.isEmpty && !unreadOnly {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .task { await store.loadMore(selection) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if messages.isEmpty {
                if store.isRefreshing(selection) {
                    ProgressView("Checking mail…")
                } else if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(unreadOnly ? "No Unread Mail" : "No Mail",
                                           systemImage: unreadOnly ? "envelope.open" : "tray",
                                           description: Text("New messages appear here the moment they arrive."))
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search")
        .refreshable { await store.refresh(selection) }
        .navigationTitle(selection.title)
        .navigationSubtitle(subtitle)
        .task(id: selection) {
            if store.messages(for: selection).isEmpty { await store.refresh(selection) }
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

            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $unreadOnly.animation()) {
                    Label("Unread Only", systemImage: "line.3.horizontal.decrease")
                }
            }

            ToolbarOverflowMenu {
                Button {
                    for message in store.messages(for: selection) where !message.isSeen {
                        store.setSeen(message, true)
                    }
                } label: {
                    Label("Mark All as Read", systemImage: "envelope.open")
                }
                Button {
                    Task { await store.refresh(selection) }
                } label: {
                    Label("Check for Mail", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var subtitle: String {
        if store.isRefreshing(selection) { return String(localized: "Checking for mail…") }
        let unread = store.unreadCount(selection)
        if store.liveAccounts.isEmpty == false {
            return unread > 0 ? String(localized: "\(unread) unread · Live") : String(localized: "Live")
        }
        return unread > 0 ? String(localized: "\(unread) unread") : ""
    }
}

struct MessageRow: View {
    var message: MessageSummary
    var account: MailAccount?
    var showAccount: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                AvatarView(address: message.from, size: 42)
                if !message.isSeen {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                        .offset(x: -3, y: -2)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.from.displayName)
                        .font(.body.weight(message.isSeen ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    if message.isFlagged {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Text(message.date.mailListLabel)
                        .font(.subheadline)
                        .foregroundStyle(message.isSeen ? Color.secondary : Theme.accent)
                }
                Text(message.subject.isEmpty ? String(localized: "(No subject)") : message.subject)
                    .font(.subheadline.weight(message.isSeen ? .regular : .medium))
                    .lineLimit(1)
                Text(message.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if showAccount, let account {
                    HStack(spacing: 5) {
                        AccountDot(account: account)
                        Text(account.email).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct MessageActionsMenu: View {
    @Environment(MailStore.self) private var store
    var message: MessageSummary

    var body: some View {
        Button {
            store.compose = ComposeContext(mode: .reply(message))
        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        Button {
            store.compose = ComposeContext(mode: .replyAll(message))
        } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
        Button {
            store.compose = ComposeContext(mode: .forward(message))
        } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        Divider()
        Button {
            store.setSeen(message, !message.isSeen)
        } label: {
            Label(message.isSeen ? "Mark as Unread" : "Mark as Read",
                  systemImage: message.isSeen ? "envelope.badge" : "envelope.open")
        }
        Button {
            store.toggleFlag(message)
        } label: { Label(message.isFlagged ? "Unflag" : "Flag", systemImage: "flag") }
        if store.mailbox(.junk, for: message.accountID) != nil {
            Button {
                store.moveToJunk(message)
            } label: { Label("Move to Junk", systemImage: "xmark.bin") }
        }
        if store.canArchive(message) {
            Button {
                store.archive(message)
            } label: { Label("Archive", systemImage: "archivebox") }
        }
        Button(role: .destructive) {
            store.trash(message)
        } label: { Label("Trash", systemImage: "trash") }
    }
}
