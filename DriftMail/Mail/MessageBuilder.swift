import Foundation

struct OutgoingAttachment: Identifiable, Hashable, Sendable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

struct OutgoingMessage: Sendable {
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var bcc: [EmailAddress]
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: String?
    var attachments: [OutgoingAttachment] = []

    var allRecipients: [String] { (to + cc + bcc).map(\.address) }
}

enum MessageBuilder {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func build(_ message: OutgoingMessage) -> Data {
        let domain = message.from.address.split(separator: "@").last.map(String.init) ?? "driftmail.app"
        var headers: [String] = []
        headers.append("Date: \(dateFormatter.string(from: Date()))")
        headers.append("From: \(message.from.headerValue)")
        if !message.to.isEmpty { headers.append("To: \(message.to.map(\.headerValue).joined(separator: ", "))") }
        if !message.cc.isEmpty { headers.append("Cc: \(message.cc.map(\.headerValue).joined(separator: ", "))") }
        headers.append("Subject: \(MIME.encodeHeaderWord(message.subject).replacingOccurrences(of: "\"", with: ""))")
        headers.append("Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>")
        if let inReplyTo = message.inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        if let references = message.references { headers.append("References: \(references)") }
        headers.append("MIME-Version: 1.0")
        headers.append("User-Agent: DriftMail")

        let textPart = [
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            wrapBase64(Data(message.body.utf8)),
        ].joined(separator: "\r\n")

        var output: String
        if message.attachments.isEmpty {
            output = (headers + [textPart]).joined(separator: "\r\n")
        } else {
            let boundary = "drift-\(UUID().uuidString)"
            headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            var parts = ["--\(boundary)", textPart]
            for attachment in message.attachments {
                let name = MIME.encodeHeaderWord(attachment.filename).replacingOccurrences(of: "\"", with: "")
                parts.append("--\(boundary)")
                parts.append([
                    "Content-Type: \(attachment.mimeType); name=\"\(name)\"",
                    "Content-Disposition: attachment; filename=\"\(name)\"",
                    "Content-Transfer-Encoding: base64",
                    "",
                    wrapBase64(attachment.data),
                ].joined(separator: "\r\n"))
            }
            parts.append("--\(boundary)--")
            output = headers.joined(separator: "\r\n") + "\r\n\r\n" + parts.joined(separator: "\r\n")
            return Data(output.utf8)
        }
        // Single part: the text part's content headers continue the message headers.
        return Data(output.utf8)
    }

    private static func wrapBase64(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }

    /// "Re: subject" without stacking prefixes.
    static func replySubject(_ subject: String) -> String {
        let lower = subject.lowercased()
        return lower.hasPrefix("re:") ? subject : "Re: \(subject)"
    }

    static func forwardSubject(_ subject: String) -> String {
        let lower = subject.lowercased()
        return lower.hasPrefix("fwd:") || lower.hasPrefix("fw:") ? subject : "Fwd: \(subject)"
    }

    static func quoted(_ body: String, from: EmailAddress, date: Date) -> String {
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        let quotedLines = body.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return "\n\nOn \(formatted), \(from.displayName) wrote:\n\(quotedLines)"
    }
}
