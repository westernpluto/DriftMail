import SwiftUI

/// Free instant notifications in three steps:
/// 1. ntfy app + topic, 2. a Cloudflare token, 3. one tap that deploys the relay
/// to the person's own Cloudflare account, pairs this phone and sends a test.
struct NotificationSetupView: View {
    @Environment(PushRelay.self) private var relay
    @Environment(\.openURL) private var openURL
    @State private var cloudflareToken = ""
    @State private var copied = false
    @State private var showManual = false
    @State private var showKeyImporter = false
    @State private var manualKeyID = ""
    @State private var keyError: String?

    private static let ntfyAppStore = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!

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
                    Text("DriftMail sets up a tiny relay in your own free Cloudflare account. It stays connected to your inboxes around the clock, even when DriftMail is closed, and notifies you within seconds of new mail arriving.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            if relay.isConfigured && relay.lastSyncSucceeded != false && !relay.isSettingUp {
                connectedSection
            }

            if relay.canUseNativePush {
                nativePushSection
            } else if relay.delivery == .ntfy {
                Section {
                    Button {
                        openURL(Self.ntfyAppStore)
                    } label: {
                        Label("Install ntfy (free)", systemImage: "arrow.down.app")
                    }
                    Button {
                        UIPasteboard.general.string = relay.ntfyTopic
                        copied = true
                    } label: {
                        Label(copied ? "Topic copied. Paste it in ntfy." : "Copy my topic",
                              systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                } header: {
                    Text("1 · Get notified with ntfy")
                } footer: {
                    Text("In ntfy, tap +, paste the topic and tap Subscribe. Tapping a notification opens DriftMail on that message.")
                }
            }

            Section {
                Link(destination: CloudflareSetup.signUpURL) {
                    Label("Create a free Cloudflare account", systemImage: "person.crop.circle.badge.plus")
                }
                Link(destination: CloudflareSetup.createTokenURL) {
                    Label("Create a DriftMail token", systemImage: "key.fill")
                }
                HStack {
                    SecureField("Cloudflare token", text: $cloudflareToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { strings in
                        cloudflareToken = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
            } header: {
                Text("2 · Connect Cloudflare")
            } footer: {
                Text("The token link opens Cloudflare with everything filled in. Scroll down, tap Continue to summary, then Create Token, and copy it. No credit card is needed.")
            }

            Section {
                Button {
                    Task { await relay.setUpAutomatically(cloudflareToken: cloudflareToken) }
                } label: {
                    HStack {
                        Label(relay.isManagedByApp ? "Set Up Again" : "Set Up Notifications", systemImage: "wand.and.stars")
                            .font(.headline)
                        Spacer()
                        if relay.isSettingUp { ProgressView() }
                    }
                }
                .disabled(cloudflareToken.trimmingCharacters(in: .whitespaces).isEmpty || relay.isSettingUp)

                if let step = relay.setupProgress {
                    Text(step).font(.footnote).foregroundStyle(.secondary)
                }
                statusMessage
            } header: {
                Text("3 · One tap")
            } footer: {
                Text("DriftMail creates the relay, pairs it with this phone using a secret code only this phone knows, uploads your accounts and sends a test notification. Updates to the relay are installed automatically.")
            }

            Section {
                NavigationLink {
                    RelaySecurityView()
                } label: {
                    Label("Security", systemImage: "lock.shield")
                }
            } footer: {
                Text("Separate relay passwords, the stored Cloudflare token, and recommended settings.")
            }

            Section {
                Toggle("Show sender and subject", isOn: $relay.showPreviews)
                    .onChange(of: relay.showPreviews) { _, _ in Task { await relay.syncIfConfigured() } }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Applies to ntfy. Turned off, the relay never reads sender or subject and ntfy only sees \u{201C}New mail\u{201D}. Native notifications are always private. Your app passwords are stored encrypted in your own Cloudflare account so the relay can watch your inbox.")
            }

            Section {
                DisclosureGroup("Manual setup & advanced", isExpanded: $showManual) {
                    Picker("Deliver with", selection: $relay.delivery) {
                        ForEach(PushRelay.Delivery.allCases) { Text($0.title).tag($0) }
                    }
                    if relay.delivery == .apns {
                        LabeledContent("Device token", value: relay.apnsToken == nil ? "Not registered" : "Ready")
                    }
                    TextField("Relay address", text: $relay.workerURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Pairing code", text: $relay.pairingCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ntfy server", text: $relay.ntfyServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("New random ntfy topic") { relay.regenerateTopic(); copied = false }
                    Button {
                        Task { await relay.sync() }
                    } label: {
                        HStack {
                            Text("Connect with these settings")
                            Spacer()
                            if relay.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(!relay.isConfigured || relay.isSyncing)
                }
            } footer: {
                Text("Use this if you deployed the relay yourself from GitHub Actions, or for native Apple push with a paid developer account.")
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

    /// Shown in builds signed with push (TestFlight / your developer account).
    private var nativePushSection: some View {
        Section {
            Link(destination: URL(string: "https://developer.apple.com/account/resources/authkeys/add")!) {
                Label("Create an Apple Push key", systemImage: "key.horizontal.fill")
            }
            Button {
                showKeyImporter = true
            } label: {
                Label(relay.hasAPNsKey ? "Key \(relay.apnsKeyID) added. Replace…" : "Choose the .p8 key file",
                      systemImage: relay.hasAPNsKey ? "checkmark.circle.fill" : "doc.badge.plus")
            }
            if keyError != nil {
                TextField("Key ID (10 characters)", text: $manualKeyID)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Text(keyError ?? "").font(.footnote).foregroundStyle(.red)
            }
            if relay.hasAPNsKey && relay.isManagedByApp && relay.delivery != .apns {
                Button {
                    Task { await relay.enableNativePush() }
                } label: {
                    Label("Switch to Native Notifications", systemImage: "bell.badge.fill")
                }
                .disabled(relay.isSettingUp)
            }
        } header: {
            Text("1 · Native notifications")
        } footer: {
            Text("This build is signed with your Apple Developer account, so DriftMail can show its own notifications. They're private: the relay only learns that a message arrived, and your phone fetches the sender and subject straight from your provider. In your developer account, create a key with Apple Push Notifications service enabled, download it to Files, and choose it here. The Team ID and bundle ID are filled in automatically.")
        }
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                try relay.importAPNsKey(contents: contents, filename: url.lastPathComponent, keyID: manualKeyID)
                keyError = nil
            } catch {
                keyError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = relay.lastMessage {
            Label(message, systemImage: relay.lastSyncSucceeded == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(relay.lastSyncSucceeded == false ? .red : .green)
        }
    }

    private var connectedSection: some View {
        Section {
            Label("Notifications are on", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            if relay.isEndToEndEncrypted {
                Label("Private: your phone fetches sender and subject itself. The relay and Apple never see them.", systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
            if let status = relay.status, status.configured {
                ForEach(status.accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email)
                        if let error = account.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else {
                            Text("Watching").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button {
                Task { await relay.sendTest() }
            } label: {
                Label("Send Test Notification", systemImage: "paperplane")
            }
        } header: {
            Text("Status")
        }
    }
}
