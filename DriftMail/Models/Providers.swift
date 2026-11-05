import Foundation

/// Server presets so people only type an email address and an app password.
struct MailProvider: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let domains: [String]
    let imapHost: String
    let imapPort: Int
    let smtpHost: String
    let smtpPort: Int
    let smtpSecurity: SMTPSecurity
    /// Where the person creates an app password for third-party mail apps.
    let appPasswordURL: URL?
    let appPasswordHelp: String
    /// The server saves sent mail itself, so DriftMail must not append a copy.
    let savesSentMailAutomatically: Bool

    static let gmail = MailProvider(
        id: "gmail", name: "Google", symbol: "g.circle.fill",
        domains: ["gmail.com", "googlemail.com"],
        imapHost: "imap.gmail.com", imapPort: 993,
        smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls,
        appPasswordURL: URL(string: "https://myaccount.google.com/apppasswords"),
        appPasswordHelp: "Turn on 2-Step Verification, then create an app password named DriftMail and paste the 16 letters here.",
        savesSentMailAutomatically: true)

    static let icloud = MailProvider(
        id: "icloud", name: "iCloud", symbol: "icloud.fill",
        domains: ["icloud.com", "me.com", "mac.com"],
        imapHost: "imap.mail.me.com", imapPort: 993,
        smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS,
        appPasswordURL: URL(string: "https://account.apple.com/account/manage"),
        appPasswordHelp: "In your Apple Account, open Sign-In and Security → App-Specific Passwords, create one for DriftMail and paste it here.",
        savesSentMailAutomatically: false)

    static let yahoo = MailProvider(
        id: "yahoo", name: "Yahoo", symbol: "y.circle.fill",
        domains: ["yahoo.com", "ymail.com", "rocketmail.com"],
        imapHost: "imap.mail.yahoo.com", imapPort: 993,
        smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpSecurity: .tls,
        appPasswordURL: URL(string: "https://login.yahoo.com/account/security"),
        appPasswordHelp: "In Yahoo Account Security, choose Generate app password and paste it here.",
        savesSentMailAutomatically: true)

    static let fastmail = MailProvider(
        id: "fastmail", name: "Fastmail", symbol: "f.circle.fill",
        domains: ["fastmail.com", "fastmail.fm"],
        imapHost: "imap.fastmail.com", imapPort: 993,
        smtpHost: "smtp.fastmail.com", smtpPort: 465, smtpSecurity: .tls,
        appPasswordURL: URL(string: "https://app.fastmail.com/settings/security/apppasswords"),
        appPasswordHelp: "In Fastmail Settings → Privacy & Security, create an app password with IMAP and SMTP access.",
        savesSentMailAutomatically: false)

    static let aol = MailProvider(
        id: "aol", name: "AOL", symbol: "a.circle.fill",
        domains: ["aol.com"],
        imapHost: "imap.aol.com", imapPort: 993,
        smtpHost: "smtp.aol.com", smtpPort: 465, smtpSecurity: .tls,
        appPasswordURL: URL(string: "https://login.aol.com/account/security"),
        appPasswordHelp: "In AOL Account Security, choose Generate app password and paste it here.",
        savesSentMailAutomatically: true)

    static let zoho = MailProvider(
        id: "zoho", name: "Zoho", symbol: "z.circle.fill",
        domains: ["zoho.com", "zohomail.com"],
        imapHost: "imap.zoho.com", imapPort: 993,
        smtpHost: "smtp.zoho.com", smtpPort: 465, smtpSecurity: .tls,
        appPasswordURL: URL(string: "https://accounts.zoho.com/home#security/app_password"),
        appPasswordHelp: "Enable IMAP in Zoho Mail settings, then create an application-specific password.",
        savesSentMailAutomatically: false)

    static let custom = MailProvider(
        id: "custom", name: "Other IMAP", symbol: "envelope.circle.fill",
        domains: [],
        imapHost: "", imapPort: 993,
        smtpHost: "", smtpPort: 465, smtpSecurity: .tls,
        appPasswordURL: nil,
        appPasswordHelp: "Enter the IMAP and SMTP servers from your provider. Use an app password if your provider offers them.",
        savesSentMailAutomatically: false)

    static let all: [MailProvider] = [.gmail, .icloud, .yahoo, .fastmail, .aol, .zoho, .custom]

    static func preset(id: String) -> MailProvider {
        all.first { $0.id == id } ?? .custom
    }

    static func guess(for email: String) -> MailProvider? {
        guard let domain = email.split(separator: "@").last?.lowercased() else { return nil }
        return all.first { $0.domains.contains(domain) }
    }
}
