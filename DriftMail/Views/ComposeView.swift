import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposeContext: Identifiable {
    enum Mode {
        case new
        case reply(MessageSummary)
        case replyAll(MessageSummary)
        case forward(MessageSummary)
    }

    let id = UUID()
    var mode: Mode
    var to: String = ""

    var isForward: Bool {
        if case .forward = mode { return true }
        return false
    }

    var original: MessageSummary? {
        switch mode {
        case .new: nil
        case .reply(let m), .replyAll(let m), .forward(let m): m
        }
    }
}

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let context: ComposeContext

    @State private var accountID: UUID?
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var text = ""
    @State private var showCcBcc = false
    @State private var attachments: [OutgoingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var originalBody: MessageBody?
    @State private var prepared = false
    @FocusState private var focus: Field?

    enum Field { case to, subject, body }

    private var account: MailAccount? {
        store.accounts.first { $0.id == accountID } ?? store.accounts.first
    }

    private var canSend: Bool {
        !isSending && account != nil && !MIME.parseAddresses(to + "," + cc + "," + bcc).filter { $0.address.contains("@") }.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let original = context.original {
                    // iPhone Duo: on the wide inner display the message being answered sits
                    // beside the editor (split around the fold when partially folded). In a
                    // vertical layout, such as the outer display, only the editor is shown.
                    ArrangementView {
                        editor
                    } secondary: {
                        OriginalMessagePane(summary: original, message: originalBody)
                    }
                    .arrangementViewStyle(.split.axes(.horizontal))
                } else {
                    editor
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .disabled(isSending)
            .task { await prepare() }
            .onChange(of: photoItems) { _, items in Task { await importPhotos(items) } }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .alert("Couldn't Send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sendError ?? "")
            }
        }
        .interactiveDismissDisabled(!text.isEmpty || !to.isEmpty)
    }

    private var title: String {
        switch context.mode {
        case .new: String(localized: "New Message")
        case .reply, .replyAll: String(localized: "Reply")
        case .forward: String(localized: "Forward")
        }
    }

    // MARK: Editor

    private var editor: some View {
        ScrollView {
            VStack(spacing: 0) {
                if store.accounts.count > 1 {
                    fieldRow("From") {
                        Picker("From", selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                            ForEach(store.accounts) { account in
                                Text(account.email).tag(Optional(account.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Spacer()
                    }
                }
                fieldRow("To") {
                    TextField("", text: $to, axis: .vertical)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .to)
                    if !showCcBcc {
                        Button("Cc/Bcc") { withAnimation { showCcBcc = true } }
                            .font(.subheadline)
                    }
                }
                if showCcBcc {
                    fieldRow("Cc") {
                        TextField("", text: $cc).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    fieldRow("Bcc") {
                        TextField("", text: $bcc).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                fieldRow("Subject") {
                    TextField("", text: $subject).focused($focus, equals: .subject)
                }
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                HStack(spacing: 6) {
                                    Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                    Text(attachment.filename).lineLimit(1)
                                    Button {
                                        attachments.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .accessibilityLabel("Remove \(attachment.filename)")
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    Divider()
                }
                TextEditor(text: $text)
                    .focused($focus, equals: .body)
                    .frame(minHeight: 320)
                    .scrollDisabled(true)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            // Top alignment, not baseline: an empty multi-line field (To) has no text
            // baseline, which pushed the field and its cursor below the label. Label and
            // field share a font, so their first lines line up by their tops.
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                content()
            }
            .padding(.horizontal)
            .padding(.vertical, 11)
            Divider().padding(.leading)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Close stays at the top of the vertical bar on iPhone Duo.
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel) {
                dismiss()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
        }
        // Send is the prominent "done" action, pinned to the trailing edge.
        ToolbarItem(placement: .topBarPinnedTrailing) {
            Button {
                Task { await send() }
            } label: {
                // Always a title + symbol (never a custom spinner view), so the button
                // can stay in the vertical side toolbar on iPhone Duo while sending.
                Label(isSending ? "Sending…" : "Send", systemImage: "paperplane.fill")
                    .symbolEffect(.pulse, isActive: isSending)
            }
            .buttonStyle(.glassProminent)
            .disabled(!canSend)
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            PhotosPicker(selection: $photoItems, matching: .images) {
                Label("Add Photo", systemImage: "photo.on.rectangle")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("Attach File", systemImage: "paperclip")
            }
        }
    }

    // MARK: Logic

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        to = context.to
        guard let original = context.original else {
            accountID = store.selectionAccountID ?? store.accounts.first?.id
            focus = .to
            return
        }
        accountID = original.accountID
        let me = store.account(original.accountID)?.email.lowercased()
        switch context.mode {
        case .reply:
            to = (original.replyTo.first ?? original.from).address
            subject = MessageBuilder.replySubject(original.subject)
        case .replyAll:
            let primary = (original.replyTo.first ?? original.from).address
            let others = (original.to + original.cc).map(\.address).filter { $0.lowercased() != me && $0 != primary }
            to = primary
            if !others.isEmpty { cc = others.joined(separator: ", "); showCcBcc = true }
            subject = MessageBuilder.replySubject(original.subject)
        case .forward:
            subject = MessageBuilder.forwardSubject(original.subject)
        case .new:
            break
        }
        focus = to.isEmpty ? .to : .body
        if let loaded = try? await store.body(for: original) {
            originalBody = loaded
            let plain = loaded.plainText ?? loaded.html.map(MIME.htmlToText) ?? original.preview
            if case .forward = context.mode {
                text = "\n\n---------- Forwarded message ----------\nFrom: \(original.from.displayName) <\(original.from.address)>\nDate: \(original.date.formatted())\nSubject: \(original.subject)\n\n\(plain)"
                attachments = loaded.visibleAttachments.map {
                    OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
                }
            } else {
                text = MessageBuilder.quoted(plain.trimmingCharacters(in: .whitespacesAndNewlines), from: original.from, date: original.date)
            }
        }
    }

    private func send() async {
        guard let account else { return }
        isSending = true
        defer { isSending = false }
        var references: String?
        var inReplyTo: String?
        if let original = context.original, !context.isForward {
            inReplyTo = original.messageID
            references = [original.references, original.messageID].compactMap { $0 }.joined(separator: " ")
        }
        let message = OutgoingMessage(
            from: EmailAddress(name: account.displayName.isEmpty ? nil : account.displayName, address: account.email),
            to: MIME.parseAddresses(to),
            cc: MIME.parseAddresses(cc),
            bcc: MIME.parseAddresses(bcc),
            subject: subject,
            body: text,
            inReplyTo: inReplyTo,
            references: references?.isEmpty == true ? nil : references,
            attachments: attachments)
        do {
            try await store.send(message, from: account)
            dismiss()
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let type = item.supportedContentTypes.first ?? .jpeg
                let ext = type.preferredFilenameExtension ?? "jpg"
                attachments.append(OutgoingAttachment(filename: "Photo \(attachments.count + 1).\(ext)",
                                                      mimeType: type.preferredMIMEType ?? "image/jpeg", data: data))
            }
        }
        photoItems = []
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent,
                                                  mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data))
        }
    }
}

/// The message being replied to, shown beside the editor on wide layouts.
struct OriginalMessagePane: View {
    var summary: MessageSummary
    var message: MessageBody?

    private var bodyText: String {
        message?.plainText ?? message?.html.map(MIME.htmlToText) ?? summary.preview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AvatarView(address: summary.from, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.from.displayName).font(.subheadline.weight(.semibold))
                        Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(summary.subject).font(.headline)
                Text(bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.softDrift)
    }
}
