import SwiftUI
import QuickLook

struct MessageDetailView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var summary: MessageSummary

    @State private var body_: MessageBody?
    @State private var loadError: String?
    @State private var htmlHeight: CGFloat = 200
    @State private var showDetails = false
    @State private var previewURL: URL?
    /// Plain text for Share, made once in the background (not on every redraw).
    @State private var shareText: String?
    /// Remote images were allowed for this message (Load Images) while blocking is on.
    @State private var allowRemoteContent = false
    @AppStorage(RemoteContent.blockKey) private var blockRemoteImages = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The text stays at a readable width, but the tint spans the whole
                // column so it can extend under the side toolbar on iPhone Duo.
                header
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background {
                        Theme.softDrift
                            .backgroundExtensionEffect()
                    }
                if let html = body_?.html {
                    let blocking = blockRemoteImages && !allowRemoteContent && HTMLView.hasRemoteContent(html)
                    if blocking {
                        remoteContentBar
                    }
                    // HTML email: the full column, edge to edge like Apple Mail. The email's
                    // own layout decides its margins (simple ones get margins in HTMLView).
                    HTMLView(html: html, height: $htmlHeight, blockRemoteContent: blocking) { address in
                        store.compose = ComposeContext(mode: .new, to: address)
                    }
                    .frame(height: htmlHeight)
                    .id(blocking)  // rebuilt without the block after Load Images
                }
                VStack(alignment: .leading, spacing: 0) {
                    if body_?.html == nil {
                        content
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    if let attachments = body_?.visibleAttachments, !attachments.isEmpty {
                        attachmentGrid(attachments)
                            .padding()
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: summary.id) { await load() }
        .quickLookPreview($previewURL)
        .toolbar { toolbarContent }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.subject.isEmpty ? String(localized: "(No subject)") : summary.subject)
                .font(.title2.weight(.bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                AvatarView(address: summary.from, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.from.displayName).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        withAnimation(.snappy) { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showDetails ? summary.from.address : recipientsLine)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(showDetails ? 180 : 0))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        VStack(alignment: .leading, spacing: 4) {
                            addressLine("To", summary.to)
                            if !summary.cc.isEmpty { addressLine("Cc", summary.cc) }
                            if let account = store.account(summary.accountID) {
                                HStack(spacing: 6) {
                                    AccountDot(account: account)
                                    Text(account.email)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding()
    }

    private var recipientsLine: String {
        let names = summary.to.map(\.displayName)
        if names.isEmpty { return String(localized: "to undisclosed recipients") }
        return String(localized: "to \(names.joined(separator: ", "))")
    }

    private func addressLine(_ label: String, _ addresses: [EmailAddress]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(addresses.map { $0.name != nil ? "\($0.displayName) <\($0.address)>" : $0.address }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Body

    private var remoteContentBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("Remote images are blocked to protect your privacy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Load Images") { allowRemoteContent = true }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if let body = body_ {
            if body.html != nil {
                EmptyView()  // shown full width above
            } else {
                Text(body.plainText ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        } else if let loadError {
            ContentUnavailableView {
                Label("Couldn't Load Message", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary.preview).foregroundStyle(.secondary)
                ProgressView().frame(maxWidth: .infinity)
            }
            .padding(.vertical)
        }
    }

    /// iPhone Duo guidance: prefer an even number of grid columns so content divides cleanly at the fold.
    private func attachmentGrid(_ attachments: [MailAttachment]) -> some View {
        let columnCount = horizontalSizeClass == .regular ? 4 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
        return VStack(alignment: .leading, spacing: 10) {
            Label("\(attachments.count) Attachment\(attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(attachments) { attachment in
                    Button {
                        previewURL = write(attachment)
                    } label: {
                        AttachmentTile(attachment: attachment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func write(_ attachment: MailAttachment) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Security: the file name comes from the sender. Keep only a plain name (no
        // folders, "..", control characters or hidden-file dots) so it can't escape `dir`.
        var scalars = attachment.filename.unicodeScalars
        scalars.removeAll { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }
        var safeName = String(scalars).trimmingCharacters(in: .whitespaces)
        while safeName.hasPrefix(".") { safeName.removeFirst() }
        safeName = String(safeName.prefix(120))
        let url = dir.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        do {
            try attachment.data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Toolbar
    //
    // Every item has a title and a symbol so iPhone Duo can show it vertically,
    // horizontally or in the overflow menu. Reply is kept visible longest.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.compose = ComposeContext(mode: .reply(summary))
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Menu {
                Button {
                    store.compose = ComposeContext(mode: .replyAll(summary))
                } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                Button {
                    store.compose = ComposeContext(mode: .forward(summary))
                } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            } label: {
                Label("More Replies", systemImage: "arrowshape.turn.up.right.circle")
            }
        }
        .visibilityPriority(.high)

        ToolbarItemGroup(placement: .secondaryAction) {
            if store.canArchive(summary) {
                Button {
                    store.archive(summary)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
            Button(role: .destructive) {
                store.trash(summary)
            } label: {
                Label("Trash", systemImage: "trash")
            }
        }

        ToolbarOverflowMenu {
            Button {
                store.setSeen(currentSummary, !currentSummary.isSeen)
            } label: {
                Label(currentSummary.isSeen ? "Mark as Unread" : "Mark as Read",
                      systemImage: currentSummary.isSeen ? "envelope.badge" : "envelope.open")
            }
            Button {
                store.toggleFlag(currentSummary)
            } label: {
                Label(currentSummary.isFlagged ? "Unflag" : "Flag", systemImage: "flag")
            }
            if store.mailbox(.junk, for: summary.accountID) != nil {
                Button {
                    store.moveToJunk(summary)
                } label: {
                    Label("Move to Junk", systemImage: "xmark.bin")
                }
            }
            Button {
                store.moveRequest = MoveRequest(messages: [currentSummary])
            } label: {
                Label("Move to Folder…", systemImage: "folder")
            }
            Button {
                store.showAll(from: summary.from.address)
            } label: {
                Label("Show All from \(summary.from.displayName)", systemImage: "person.crop.circle")
            }
            if let text = shareText {
                ShareLink(item: "\(summary.subject)\n\n\(text)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// The latest copy from the store, so flag/read state is current.
    private var currentSummary: MessageSummary { store.message(id: summary.id) ?? summary }

    private func load() async {
        loadError = nil
        do {
            let loaded = try await store.body(for: summary)
            // Blocking rules must exist before the email renders, or images could slip through.
            if blockRemoteImages { await RemoteContent.prepare() }
            withAnimation(.easeOut(duration: 0.2)) { body_ = loaded }
            shareText = await Task.detached(priority: .utility) {
                loaded.plainText ?? loaded.html.map(MIME.htmlToText)
            }.value
            store.setSeen(currentSummary, true)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct AttachmentTile: View {
    var attachment: MailAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                if attachment.mimeType.hasPrefix("image/"), let image = UIImage(data: attachment.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(.rect(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: attachment.symbol)
                        .font(.title)
                        .foregroundStyle(Theme.drift)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipped()
            Text(attachment.filename).font(.caption.weight(.medium)).lineLimit(1)
            Text(attachment.sizeLabel).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attachment.filename), \(attachment.sizeLabel)")
    }
}
