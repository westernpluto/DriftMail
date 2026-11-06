import SwiftUI

struct MessageListView: View {
    @Environment(MailStore.self) private var store
    @State private var searchText = ""
    @State private var searchScope: SearchScope = .all
    @State private var isSearchPresented = false
    @State private var unreadOnly = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<MessageSummary.ID> = []
    @State private var confirmTrashAll = false

    private var selection: MailboxSelection { store.selection ?? .unifiedInbox }
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// Server results, once they match what's typed. Until then the list filters the
    /// downloaded messages instantly.
    private var serverResults: ServerSearch? {
        guard !query.isEmpty, let search = store.serverSearch, search.isFor(query, searchScope, selection) else { return nil }
        return search
    }

    private var visibleMessages: [MessageSummary] {
        var list: [MessageSummary]
        if let serverResults {
            list = serverResults.results
        } else {
            list = store.messages(for: selection)
            if !query.isEmpty { list = list.filter(matchesLocally) }
        }
        if unreadOnly { list = list.filter { !$0.isSeen } }
        return list
    }

    private func matchesLocally(_ message: MessageSummary) -> Bool {
        let from = message.from.displayName.localizedCaseInsensitiveContains(query)
            || message.from.address.localizedCaseInsensitiveContains(query)
        switch searchScope {
        case .from: return from
        case .subject: return message.subject.localizedCaseInsensitiveContains(query)
        case .all:
            return from || message.subject.localizedCaseInsensitiveContains(query)
                || message.to.contains { $0.address.localizedCaseInsensitiveContains(query) }
                || message.preview.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedMessages: [MessageSummary] {
        visibleMessages.filter { selectedIDs.contains($0.id) }
    }

    private struct SearchKey: Hashable {
        var query: String
        var scope: SearchScope
        var selection: MailboxSelection
    }

    var body: some View {
        @Bindable var store = store
        let messages = visibleMessages
        Group {
            if isSelecting {
                List(selection: $selectedIDs) { listContent(messages) }
                    .environment(\.editMode, .constant(.active))
            } else {
                List(selection: $store.selectedMessageID) { listContent(messages) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if messages.isEmpty {
                if !query.isEmpty {
                    if store.isSearchingServer {
                        ProgressView("Searching all mail…")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else if store.isRefreshing(selection) {
                    ProgressView("Checking mail…")
                } else {
                    ContentUnavailableView(unreadOnly ? "No Unread Mail" : "No Mail",
                                           systemImage: unreadOnly ? "envelope.open" : "tray",
                                           description: Text("New messages appear here the moment they arrive."))
                }
            }
        }
        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Search all mail")
        .searchScopes($searchScope, activation: .onSearchPresentation) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        // Server search, a moment after typing stops (typing cancels the wait).
        .task(id: SearchKey(query: query, scope: searchScope, selection: selection)) {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(450))
                if Task.isCancelled { return }
            }
            await store.searchServer(query, scope: searchScope, in: selection)
        }
        .onChange(of: store.senderSearchRequest) { _, request in
            guard let request else { return }
            isSelecting = false
            searchScope = .from
            searchText = request.address
            isSearchPresented = true
            store.senderSearchRequest = nil
        }
        .onChange(of: selection) {
            isSelecting = false
            selectedIDs = []
        }
        .refreshable {
            if query.isEmpty {
                await store.refresh(selection)
            } else {
                await store.searchServer(query, scope: searchScope, in: selection)
            }
        }
        .navigationTitle(selection.title)
        .navigationSubtitle(subtitle)
        .task(id: selection) {
            if store.messages(for: selection).isEmpty { await store.refresh(selection) }
        }
        .toolbar { toolbarContent }
        .confirmationDialog("Move all \(serverResults?.total ?? 0) matching messages to the Trash?",
                            isPresented: $confirmTrashAll, titleVisibility: .visible) {
            Button("Trash \(serverResults?.total ?? 0) Messages", role: .destructive) {
                Task { await store.applyToAllMatches(.trash) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This includes messages that haven't been downloaded to this phone.")
        }
    }

    @ViewBuilder
    private func listContent(_ messages: [MessageSummary]) -> some View {
        if let serverResults {
            searchHeader(serverResults)
        } else if !query.isEmpty, store.isSearchingServer, !messages.isEmpty {
            Label("Searching all mail on the server…", systemImage: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }

        ForEach(messages) { message in
            MessageRow(message: message,
                       account: store.account(message.accountID),
                       showAccount: (selection == .unifiedInbox || serverResults != nil) && store.accounts.count > 1)
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

        if let serverResults, serverResults.canLoadMore {
            loadingRow.task { await store.loadMoreSearchResults() }
        } else if query.isEmpty, store.canLoadMore(selection), !unreadOnly {
            loadingRow.task { await store.loadMore(selection) }
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    /// "1,234 messages on the server" with actions that cover every match.
    private func searchHeader(_ search: ServerSearch) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(search.total) \(search.total == 1 ? "message" : "messages") on the server")
                    .font(.subheadline.weight(.semibold))
                Text(scopeDescription(search))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if search.total > 0 {
                Menu {
                    Button {
                        Task { await store.applyToAllMatches(.markRead) }
                    } label: {
                        Label("Mark All \(search.total) as Read", systemImage: "envelope.open")
                    }
                    if canArchiveAll(search) {
                        Button {
                            Task { await store.applyToAllMatches(.archive) }
                        } label: {
                            Label("Archive All \(search.total)", systemImage: "archivebox")
                        }
                    }
                    Button(role: .destructive) {
                        confirmTrashAll = true
                    } label: {
                        Label("Trash All \(search.total)", systemImage: "trash")
                    }
                } label: {
                    Label("All \(search.total)", systemImage: "checklist")
                        .font(.subheadline.weight(.semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    private func scopeDescription(_ search: ServerSearch) -> String {
        let place = search.selection == .unifiedInbox ? "all inboxes" : search.selection.title
        switch search.scope {
        case .from: return "From \u{201C}\(search.query)\u{201D} in \(place)"
        case .subject: return "Subject contains \u{201C}\(search.query)\u{201D} in \(place)"
        case .all: return "\u{201C}\(search.query)\u{201D} in sender, recipients or subject, in \(place)"
        }
    }

    private func canArchiveAll(_ search: ServerSearch) -> Bool {
        search.boxes.values.contains { box in
            store.archiveMailbox(for: box.accountID).map { $0.path != box.path } ?? false
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    isSelecting = false
                    selectedIDs = []
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(role: .destructive) {
                    let chosen = selectedMessages
                    finishSelecting()
                    Task { await store.apply(.trash, to: chosen) }
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .disabled(selectedIDs.isEmpty)
                Button {
                    let chosen = selectedMessages
                    finishSelecting()
                    Task { await store.apply(.archive, to: chosen) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(selectedIDs.isEmpty || !selectedMessages.contains(where: store.canArchive))
                Button {
                    let chosen = selectedMessages
                    finishSelecting()
                    store.moveRequest = MoveRequest(messages: chosen)
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .disabled(selectedIDs.isEmpty || Set(selectedMessages.map(\.accountID)).count != 1)
            }
            .visibilityPriority(.high)
            ToolbarOverflowMenu {
                Button {
                    selectedIDs = Set(visibleMessages.map(\.id))
                } label: {
                    Label("Select All", systemImage: "checklist.checked")
                }
                Button {
                    let chosen = selectedMessages
                    Task { await store.setSeen(chosen, true) }
                } label: {
                    Label("Mark as Read", systemImage: "envelope.open")
                }
                .disabled(selectedIDs.isEmpty)
                Button {
                    let chosen = selectedMessages
                    Task { await store.setSeen(chosen, false) }
                } label: {
                    Label("Mark as Unread", systemImage: "envelope.badge")
                }
                .disabled(selectedIDs.isEmpty)
                Button {
                    let chosen = selectedMessages
                    Task { await store.setFlagged(chosen, !chosen.allSatisfy(\.isFlagged)) }
                } label: {
                    Label("Flag", systemImage: "flag")
                }
                .disabled(selectedIDs.isEmpty)
            }
        } else {
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
                    isSelecting = true
                    selectedIDs = []
                } label: {
                    Label("Select Messages", systemImage: "checkmark.circle")
                }
                Button {
                    Task { await store.markAllRead(in: selection) }
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

    private func finishSelecting() {
        isSelecting = false
        selectedIDs = []
    }

    private var subtitle: String {
        if store.isRefreshing(selection) { return String(localized: "Checking for mail…") }
        let unread = store.unreadCount(selection)
        let count = unread > 0 ? unread.formatted() : ""
        if store.liveAccounts.isEmpty == false {
            return unread > 0 ? String(localized: "\(count) unread · Live") : String(localized: "Live")
        }
        return unread > 0 ? String(localized: "\(count) unread") : ""
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
        Button {
            store.showAll(from: message.from.address)
        } label: { Label("Show All from \(message.from.displayName)", systemImage: "person.crop.circle") }
        Button {
            store.moveRequest = MoveRequest(messages: [message])
        } label: { Label("Move to Folder…", systemImage: "folder") }
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

/// Picks a destination mailbox for "Move to Folder".
struct MoveToMailboxSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var request: MoveRequest

    private var accountID: UUID? {
        let ids = Set(request.messages.map(\.accountID))
        return ids.count == 1 ? ids.first : nil
    }

    private var destinations: [Mailbox] {
        guard let accountID else { return [] }
        let current = Set(request.messages.map(\.mailboxPath))
        return (store.mailboxes[accountID] ?? []).filter { $0.selectable && !current.contains($0.path) }
    }

    var body: some View {
        NavigationStack {
            List {
                if accountID == nil {
                    Text("Choose messages from one account to move them together.")
                        .foregroundStyle(.secondary)
                }
                ForEach(destinations) { box in
                    Button {
                        let messages = request.messages
                        dismiss()
                        Task { await store.move(messages, to: box) }
                    } label: {
                        Label(box.name, systemImage: box.role.symbol)
                    }
                }
            }
            .navigationTitle(request.messages.count == 1 ? "Move Message" : "Move \(request.messages.count) Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
        }
    }
}
