import SwiftUI

/// Free instant notifications:
/// 1. choose Apple Push or ntfy, 2. finish that method's one-time step,
/// 3. a Cloudflare token, 4. one tap that deploys the relay to the person's own
/// Cloudflare account, pairs this phone and sends a test.
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

            deliveryChoiceSection

            if relay.hasChosenDelivery {
                if relay.delivery == .apns {
                    nativePushSection
                } else {
                    ntfySection
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
                Text("3 · Connect Cloudflare")
            } footer: {
                Text("The token link opens Cloudflare with everything filled in. Scroll down, tap Continue to summary, then Create Token, and copy it. No credit card is needed.")
            }

            Section {
                Button {
                    Task { await relay.setUpAutomatically(cloudflareToken: cloudflareToken) }
                } label: {
                    HStack {
                        Label(setupButtonTitle, systemImage: "wand.and.stars")
                            .font(.headline)
                        Spacer()
                        if relay.isSettingUp { ProgressView() }
                    }
                }
                .disabled(!canStartSetup)

                if let step = relay.setupProgress {
                    Text(step).font(.footnote).foregroundStyle(.secondary)
                }
                statusMessage
            } header: {
                Text("4 · One tap")
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
                Text("On: your relay reads each new message\u{2019}s sender and subject so notifications appear instantly. With Apple Push they are encrypted so only this phone can read them; Apple never sees them. Off: the relay never reads them, ntfy shows \u{201C}New mail\u{201D}, and Apple Push notifications take a few seconds longer while your phone fetches them itself. Your app passwords are stored encrypted in your own Cloudflare account so the relay can watch your inbox.")
            }

            Section {
                DisclosureGroup("Manual setup & advanced", isExpanded: $showManual) {
                    if relay.delivery == .apns {
                        LabeledContent("Apple Push device token", value: relay.apnsToken == nil ? "Not registered" : "Ready")
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
                Text("Use this if you deployed the relay yourself from GitHub Actions. It uses the delivery method chosen above; for Apple Push, set the relay's APNS_* secrets in the deploy workflow.")
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
            Toggle("Private notifications", isOn: Binding(
                get: { relay.privateNotifications },
                set: { relay.privateNotifications = $0; Task { await relay.syncIfConfigured() } }))
            Text(relay.privateNotifications
                 ? "Notifications are end-to-end encrypted: Apple only ever sees ciphertext, and only this phone can read the sender and subject. If Send Test Notification shows only \u{201C}New mail\u{201D}, your signing tool didn't set up DriftMail's notification extension: turn this off."
                 : "The relay includes sender and subject in the notification (Apple sees them in transit). Use this if your signing tool doesn't support DriftMail's notification extension.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // Why the latest notification showed only "New mail", if it did.
            // Kept even after later notifications succeed, so an occasional
            // "New mail" can still be explained afterwards.
            if relay.privateNotifications, let failure = NotificationDiagnostics.lastFailure {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last notification without details: \(failure.date.formatted(date: .abbreviated, time: .standard)), \(failure.account). \(failure.reason).")
                        if let success = NotificationDiagnostics.lastSuccess, success > failure.date {
                            Text("Later notifications loaded fine (latest \(success.formatted(date: .abbreviated, time: .standard))).")
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }
        } header: {
            Text("2 · Add your Apple Push key")
        } footer: {
            Text("In your developer account, create a key with Apple Push Notifications service enabled, download it to Files, and choose it here. The Team ID and bundle ID are filled in automatically.")
        }
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                try relay.importAPNsKey(contents: contents, filename: url.lastPathComponent, keyID: manualKeyID)
                keyError = nil
                // Finishing a switch to Apple Push on a running relay.
                if relay.isConfigured && relay.delivery == .apns { Task { await relay.reconfigure() } }
            } catch {
                keyError = error.localizedDescription
            }
        }
    }

    // MARK: Choice

    private var deliveryChoiceSection: some View {
        Section {
            DeliveryOptionRow(
                title: "Apple Push",
                subtitle: "DriftMail's own notifications. Private: your phone fetches the sender and subject itself, so the relay and Apple never see them.",
                symbol: "apple.logo",
                badge: relay.canUseNativePush ? "Recommended" : nil,
                unavailableReason: relay.canUseNativePush ? nil : "Needs DriftMail signed with a paid Apple Developer account: TestFlight, or sideloaded with your developer account.",
                isSelected: relay.hasChosenDelivery && relay.delivery == .apns
            ) { relay.choose(.apns) }

            DeliveryOptionRow(
                title: "ntfy app",
                subtitle: "Through the free ntfy app. Works with any build, including sideloaded ones. The ntfy server sees sender and subject unless you turn previews off.",
                symbol: "bell.badge",
                badge: relay.canUseNativePush ? nil : "Free",
                unavailableReason: nil,
                isSelected: relay.hasChosenDelivery && relay.delivery == .ntfy
            ) { relay.choose(.ntfy) }
        } header: {
            Text("1 · How should DriftMail notify you?")
        } footer: {
            if relay.isConfigured {
                Text("Switching updates your relay automatically.")
            } else {
                Text("You can switch later at any time.")
            }
        }
    }

    private var ntfySection: some View {
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
            Text("2 · Subscribe in ntfy")
        } footer: {
            Text("In ntfy, tap +, paste the topic and tap Subscribe. Tapping a notification opens DriftMail on that message.")
        }
    }

    private var setupButtonTitle: String {
        guard relay.hasChosenDelivery else { return "Choose a notification method first" }
        let method = relay.delivery == .apns ? "Apple Push" : "ntfy"
        return relay.isManagedByApp ? "Set Up Again with \(method)" : "Set Up with \(method)"
    }

    private var canStartSetup: Bool {
        guard relay.hasChosenDelivery, !relay.isSettingUp else { return false }
        if relay.delivery == .apns && (!relay.canUseNativePush || !relay.hasAPNsKey) { return false }
        let hasToken = !cloudflareToken.trimmingCharacters(in: .whitespaces).isEmpty || relay.isManagedByApp
        return hasToken
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
            Label("Notifications are on: \(relay.delivery == .apns ? "Apple Push" : "ntfy")", systemImage: "checkmark.seal.fill")
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

/// One selectable delivery method.
struct DeliveryOptionRow: View {
    var title: String
    var subtitle: String
    var symbol: String
    var badge: String?
    var unavailableReason: String?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(unavailableReason == nil ? AnyShapeStyle(Theme.drift) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.15), in: .capsule)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    if let unavailableReason {
                        Label(unavailableReason, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
