import SwiftUI

/// Guides the person through the free push relay:
/// a Cloudflare Worker (free plan) checks every inbox each minute and pushes
/// new-mail notifications through ntfy (free) or Apple Push (paid developer account).
struct NotificationSetupView: View {
    @Environment(PushRelay.self) private var relay
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    private static let ntfyAppStore = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!
    private static let guide = URL(string: "https://github.com/westernpluto/DriftMail#instant-notifications-free")!

    var body: some View {
        @Bindable var relay = relay
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "bell.badge.waveform.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.drift)
                    Text("Instant notifications, free")
                        .font(.title3.weight(.bold))
                    Text("Your own Cloudflare Worker watches your inboxes around the clock on Cloudflare's free plan and pushes a notification as soon as mail arrives, even when DriftMail is closed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section {
                Button {
                    openURL(Self.guide)
                } label: {
                    Label("Open the 5-minute deploy guide", systemImage: "book.pages")
                }
                TextField("https://driftmail-relay.you.workers.dev", text: $relay.workerURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Pairing code", text: $relay.pairingCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("1 · Your relay")
            } footer: {
                Text("Deploy it with one click from GitHub Actions (free Cloudflare account, no credit card), then paste its address and the pairing code you chose. Only a phone with the pairing code can take control of your relay.")
            }

            Section {
                Picker("Deliver with", selection: $relay.delivery) {
                    ForEach(PushRelay.Delivery.allCases) { Text($0.title).tag($0) }
                }
                if relay.delivery == .ntfy {
                    Button {
                        openURL(Self.ntfyAppStore)
                    } label: {
                        Label("Get the free ntfy app", systemImage: "arrow.down.app")
                    }
                    LabeledContent("Topic") {
                        Text(relay.ntfyTopic)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button {
                        UIPasteboard.general.string = relay.ntfyTopic
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy topic", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    DisclosureGroup("Advanced") {
                        TextField("ntfy server", text: $relay.ntfyServer)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("New random topic") { relay.regenerateTopic(); copied = false }
                    }
                } else {
                    Text("Native push needs DriftMail signed with a paid Apple Developer account and your APNs key stored in the Worker. See the guide.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Device token", value: relay.apnsToken == nil ? "Not registered" : "Ready")
                }
            } header: {
                Text("2 · Delivery")
            } footer: {
                if relay.delivery == .ntfy {
                    Text("In ntfy, tap +, paste the topic and subscribe. Tapping a notification opens DriftMail on that message. The topic is a long random secret; keep it private.")
                }
            }

            Section {
                Toggle("Show sender and subject", isOn: $relay.showPreviews)
            } header: {
                Text("3 · Privacy")
            } footer: {
                Text("Turn this off to receive a plain \u{201C}New mail\u{201D} alert with no details passing through the notification service.")
            }

            Section {
                Button {
                    Task { await relay.sync() }
                } label: {
                    HStack {
                        Label("Connect Accounts to Relay", systemImage: "link")
                        Spacer()
                        if relay.isSyncing { ProgressView() }
                    }
                }
                .disabled(!relay.isConfigured || relay.isSyncing)
                .help("Pairs this phone using the pairing code, then uploads your accounts.")

                Button {
                    Task { await relay.sendTest() }
                } label: {
                    Label("Send Test Notification", systemImage: "paperplane")
                }
                .disabled(!relay.isConfigured)

                if let message = relay.lastMessage {
                    Label(message, systemImage: relay.lastSyncSucceeded == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(relay.lastSyncSucceeded == false ? .red : .green)
                }
            } header: {
                Text("4 · Connect")
            } footer: {
                Text("Your app passwords are sent over HTTPS to your own Worker and stored encrypted there so it can check mail for you. Only a phone that knows your pairing code can pair with the relay.")
            }

            if let status = relay.status, status.configured {
                Section("Relay status") {
                    ForEach(status.accounts) { account in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                            if let error = account.lastError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            } else {
                                Text("Watching").font(.caption).foregroundStyle(.green)
                            }
                        }
                    }
                    if let lastRun = status.lastRun {
                        LabeledContent("Last check", value: lastRun)
                    }
                }
            }

            if relay.isConfigured {
                Section {
                    Button("Disconnect Relay", role: .destructive) {
                        Task { await relay.disconnect() }
                    }
                }
            }
        }
        .navigationTitle("Instant Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            NotificationService.requestAuthorization()
            if relay.isConfigured { await relay.refreshStatus() }
        }
        .onChange(of: relay.delivery) { _, delivery in
            if delivery == .apns { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}
