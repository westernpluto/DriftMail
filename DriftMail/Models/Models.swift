import Foundation

/// How the SMTP connection is secured.
enum SMTPSecurity: String, Codable, CaseIterable, Sendable, Identifiable {
    case tls        // implicit TLS, usually port 465
    case startTLS   // plain connection upgraded with STARTTLS, usually port 587

    var id: String { rawValue }
    var label: String { self == .tls ? "SSL/TLS" : "STARTTLS" }
}

struct MailAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var displayName: String          // the sender name people see
    var email: String
    var providerID: String
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int
    var smtpSecurity: SMTPSecurity
    var username: String
    var colorIndex: Int = 0

    var provider: MailProvider { MailProvider.preset(id: providerID) }

    /// Short label used in the unified inbox and sidebar.
    var shortLabel: String {
        if let domain = email.split(separator: "@").last {
            return String(domain)
        }
        return email
    }
}

struct EmailAddress: Codable, Hashable, Sendable {
    var name: String?
    var address: String

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return address
    }

    /// Up to two initials, for avatars.
    var initials: String {
        let source = displayName
        let words = source
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first }
        if letters.isEmpty { return "?" }
        return String(letters).uppercased()
    }

    /// RFC 5322 form, encoding the name if needed.
    var headerValue: String {
        guard let name, !name.isEmpty else { return address }
        return "\(MIME.encodeHeaderWord(name)) <\(address)>"
    }
}

enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts, archive, all, junk, trash, flagged, other

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .all: "tray.2"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .flagged: "flag"
        case .other: "folder"
        }
    }

    var sortOrder: Int {
        switch self {
        case .inbox: 0
        case .flagged: 1
        case .drafts: 2
        case .sent: 3
        case .archive: 4
        case .all: 5
        case .junk: 6
        case .trash: 7
        case .other: 8
        }
    }
}

struct Mailbox: Identifiable, Codable, Hashable, Sendable {
    var accountID: UUID
    var path: String          // IMAP name, as the server reports it
    var name: String          // human readable leaf name
    var role: MailboxRole
    var selectable: Bool = true

    var id: String { "\(accountID.uuidString)|\(path)" }
}

enum MailboxSelection: Hashable, Codable, Sendable {
    case unifiedInbox
    case mailbox(Mailbox)

    var title: String {
        switch self {
        case .unifiedInbox: "All Inboxes"
        case .mailbox(let box): box.name
        }
    }
}

struct MessageSummary: Identifiable, Codable, Hashable, Sendable {
    var accountID: UUID
    var mailboxPath: String
    var uid: UInt32
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var replyTo: [EmailAddress]
    var subject: String
    var date: Date
    var preview: String
    var isSeen: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
    var messageID: String?
    var references: String?
    /// The whole message's size in bytes, when known (used to skip prefetching huge ones).
    var size: Int? = nil

    var id: String { "\(accountID.uuidString)|\(mailboxPath)|\(uid)" }
    var mailboxKey: String { "\(accountID.uuidString)|\(mailboxPath)" }
}

struct MailAttachment: Identifiable, Hashable, Sendable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var contentID: String?
    var isInline: Bool

    var symbol: String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.contains("zip") { return "doc.zipper" }
        return "doc"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

struct MessageBody: Sendable {
    var plainText: String?
    var html: String?
    var attachments: [MailAttachment]

    var visibleAttachments: [MailAttachment] { attachments.filter { !$0.isInline } }
}

enum MailError: LocalizedError {
    case connectionClosed
    case timeout
    case server(String)
    case protocolError(String)
    case authentication(String)
    case missingPassword
    case notFound

    var errorDescription: String? {
        switch self {
        case .connectionClosed: "The mail server closed the connection."
        case .timeout: "The mail server took too long to respond."
        case .server(let text): text.isEmpty ? "The mail server reported an error." : text
        case .protocolError(let text): "Unexpected response from server: \(text)"
        case .authentication(let text): "Sign-in failed. Check the email and app password. \(text)"
        case .missingPassword: "No password is saved for this account."
        case .notFound: "That message could not be found."
        }
    }
}

extension Array where Element: Identifiable {
    /// Keeps the first element for each ID. Lists must never show two rows with the
    /// same ID (SwiftUI's List can crash on duplicates).
    func uniquedByID() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
