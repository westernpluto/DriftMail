import SwiftUI

/// Everything that limits what your relay could ever do with your accounts.
struct RelaySecurityView: View {
    @Environment(MailStore.self) private var store
    @Environment(PushRelay.self) private var relay
    @Environment(\.openURL) private var openURL
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                ForEach(store.accounts) { account in
                    NavigationLink {
                        RelayPasswordView(account: account)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: relay.hasSeparatePassword(account) ? "checkmark.shield.fill" : "exclamationmark.shield")
                                .foregroundStyle(relay.hasSeparatePassword(account) ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email)
                                Text(relay.hasSeparatePassword(account) ? "Relay has its own password" : "Relay shares the phone's password")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Separate relay passwords")
            } footer: {
                Text("Give the relay its own app password for each account. If anything ever happened to your relay or Cloudflare account, you'd revoke just that password. Your phone keeps working, and your provider's security page shows exactly when the relay's password was last used.")
            }

            Section {
                if relay.isManagedByApp {
                    Label("Stored in this phone's Keychain for automatic relay updates", systemImage: "key.fill")
                        .font(.subheadline)
                    Button("Forget Cloudflare Token", role: .destructive) { confirmForget = true }
                } else {
                    Label("Not stored on this phone", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    if relay.relayUpdateAvailable {
                        Label("A relay update is available. Paste a Cloudflare token on the previous screen and tap Set Up Again to install it.", systemImage: "arrow.down.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Cloudflare token")
            } footer: {
                Text("Forgetting the token doesn't affect notifications. You'd paste a token again only to install relay updates. You can also delete the token in Cloudflare under My Profile → API Tokens.")
            }

            Section {
                Link(destination: URL(string: "https://dash.cloudflare.com/profile/authentication")!) {
                    Label("Add a passkey or two-factor authentication to Cloudflare", systemImage: "person.badge.key.fill")
                }
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                } label: {
                    Label("Hide notification previews when locked", systemImage: "lock.iphone")
                }
                Text("In notification settings, set Show Previews to When Unlocked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Recommended")
            } footer: {
                Text("A passkey on Cloudflare matters most: control of that account is the realistic way someone could reach your relay. Your relay also rejects pairing after 10 wrong codes per hour and keeps no request logs.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget the Cloudflare token?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Token", role: .destructive) { relay.forgetCloudflareToken() }
        } message: {
            Text("Notifications keep working. Relay updates will need a token pasted again.")
        }
    }
}

struct RelayPasswordView: View {
    @Environment(PushRelay.self) private var relay
    @Environment(\.openURL) private var openURL
    let account: MailAccount
    @State private var password = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                Text("Create a new app password named \u{201C}DriftMail relay\u{201D} and paste it here. Keep the one your phone uses as it is.")
                    .font(.subheadline)
                if let url = account.provider.appPasswordURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Create an app password", systemImage: "key.fill")
                    }
                }
                SecureField("Relay app password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Check and Use for Relay")
                        Spacer()
                        if isSaving { ProgressView() }
                    }
                }
                .disabled(password.isEmpty || isSaving)
                if let message {
                    Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(failed ? .red : .green)
                }
            } header: {
                Text(account.email)
            } footer: {
                Text("DriftMail signs in once to check the password, then sends it to your relay in place of the phone's.")
            }

            if relay.hasSeparatePassword(account) {
                Section {
                    Button("Stop Using Separate Password", role: .destructive) {
                        Task {
                            await relay.clearRelayPassword(for: account)
                            message = "The relay now uses the phone's password again."
                            failed = false
                        }
                    }
                } footer: {
                    Text("If you revoke the relay's password at your provider, notifications for this account stop until you add a new one here.")
                }
            }
        }
        .navigationTitle("Relay Password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await relay.setRelayPassword(password, for: account)
            password = ""
            failed = false
            message = relay.isConfigured ? "Saved. Your relay now uses this password." : "Saved. It'll be used when you connect the relay."
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}
