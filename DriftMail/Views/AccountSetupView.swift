import SwiftUI

struct AccountSetupView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let provider: MailProvider
    var existing: MailAccount? = nil

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var smtpSecurity: SMTPSecurity = .tls
    @State private var showAdvanced = false
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var loaded = false

    private var isCustom: Bool { provider.id == MailProvider.custom.id }

    private var canSubmit: Bool {
        let hasPassword = existing != nil || !password.isEmpty
        return !isWorking && email.contains("@") && hasPassword && !imapHost.isEmpty && !smtpHost.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: provider.symbol)
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.color(for: provider.id))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).font(.headline)
                            Text("IMAP & SMTP").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Account") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: email) { _, newValue in
                            if !showAdvanced { username = newValue }
                        }
                    SecureField(existing == nil ? "App password" : "New app password (optional)", text: $password)
                        .textContentType(.password)
                }

                Section {
                    Text(provider.appPasswordHelp)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let url = provider.appPasswordURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Create an app password", systemImage: "key.fill")
                        }
                    }
                } header: {
                    Text("App password")
                }

                Section {
                    DisclosureGroup("Server settings", isExpanded: $showAdvanced) {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        LabeledContent("IMAP server") {
                            TextField("imap.example.com", text: $imapHost)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        LabeledContent("IMAP port") {
                            TextField("993", text: $imapPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        LabeledContent("SMTP server") {
                            TextField("smtp.example.com", text: $smtpHost)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        LabeledContent("SMTP port") {
                            TextField("465", text: $smtpPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        Picker("SMTP security", selection: $smtpSecurity) {
                            ForEach(SMTPSecurity.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } footer: {
                    Text("IMAP uses SSL/TLS. DriftMail stores your password in the iOS Keychain on this device.")
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isWorking { ProgressView() } else { Label("Sign In", systemImage: "checkmark") }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSubmit)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            name = existing.displayName
            email = existing.email
            username = existing.username
            imapHost = existing.imapHost
            imapPort = String(existing.imapPort)
            smtpHost = existing.smtpHost
            smtpPort = String(existing.smtpPort)
            smtpSecurity = existing.smtpSecurity
        } else {
            imapHost = provider.imapHost
            imapPort = String(provider.imapPort)
            smtpHost = provider.smtpHost
            smtpPort = String(provider.smtpPort)
            smtpSecurity = provider.smtpSecurity
            showAdvanced = isCustom
        }
    }

    private func submit() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        var account = existing ?? MailAccount(displayName: "", email: "", providerID: provider.id, imapHost: "", imapPort: 993,
                                              smtpHost: "", smtpPort: 465, smtpSecurity: .tls, username: "")
        account.displayName = name.trimmingCharacters(in: .whitespaces)
        account.email = trimmedEmail
        account.username = username.isEmpty ? trimmedEmail : username.trimmingCharacters(in: .whitespaces)
        account.imapHost = imapHost.trimmingCharacters(in: .whitespaces)
        account.imapPort = Int(imapPort) ?? 993
        account.smtpHost = smtpHost.trimmingCharacters(in: .whitespaces)
        account.smtpPort = Int(smtpPort) ?? 465
        account.smtpSecurity = smtpSecurity
        // App passwords are often shown with spaces ("abcd efgh ijkl mnop").
        let cleanPassword = provider.id == MailProvider.gmail.id ? password.replacingOccurrences(of: " ", with: "") : password
        do {
            if existing == nil {
                try await store.addAccount(account, password: cleanPassword)
            } else {
                try await store.updateAccount(account, password: cleanPassword.isEmpty ? nil : cleanPassword)
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
