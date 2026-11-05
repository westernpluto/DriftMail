import SwiftUI

struct SettingsView: View {
    @Environment(MailStore.self) private var store
    @Environment(PushRelay.self) private var relay
    @Environment(\.dismiss) private var dismiss
    @State private var addProvider: MailProvider?
    @State private var editing: MailAccount?
    @State private var confirmRemove: MailAccount?

    var body: some View {
        NavigationStack {
            List {
                Section("Accounts") {
                    ForEach(store.accounts) { account in
                        Button {
                            editing = account
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: account.provider.symbol)
                                    .font(.title2)
                                    .foregroundStyle(Theme.accountColor(account))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.email).foregroundStyle(.primary)
                                    Text(account.provider.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.liveAccounts.contains(account.id) { LiveBadge() }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                confirmRemove = account
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    Menu {
                        ForEach(MailProvider.all) { provider in
                            Button {
                                addProvider = provider
                            } label: {
                                Label(provider.name, systemImage: provider.symbol)
                            }
                        }
                    } label: {
                        Label("Add Account", systemImage: "plus.circle.fill")
                    }
                }

                Section {
                    NavigationLink {
                        NotificationSetupView()
                    } label: {
                        NotificationStatusRow()
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("While DriftMail is open it stays connected and new mail appears instantly. Set up the free relay to be notified when the app is closed.")
                }

                Section("Storage") {
                    Button {
                        Persistence.clearBodies()
                    } label: {
                        Label("Clear Downloaded Messages", systemImage: "internaldrive")
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Link(destination: URL(string: "https://github.com/westernpluto/DriftMail")!) {
                        Label("Source & Relay Setup Guide", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("DriftMail is free and talks directly to your mail providers.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
            }
            .sheet(item: $addProvider) { provider in
                AccountSetupView(provider: provider)
            }
            .sheet(item: $editing) { account in
                AccountSetupView(provider: account.provider, existing: account)
            }
            .confirmationDialog("Remove this account from DriftMail?",
                                isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                                titleVisibility: .visible,
                                presenting: confirmRemove) { account in
                Button("Remove \(account.email)", role: .destructive) {
                    store.removeAccount(account)
                }
            } message: { _ in
                Text("Mail stays on the server. You can add the account again at any time.")
            }
        }
    }
}
