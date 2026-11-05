import Foundation

/// Sends one message over SMTP (implicit TLS or STARTTLS) with AUTH PLAIN/LOGIN.
enum SMTPClient {
    static func send(account: MailAccount, password: String, envelopeFrom: String,
                     recipients: [String], message: Data) async throws {
        let implicit = account.smtpSecurity == .tls
        let socket = MailSocket(host: account.smtpHost, port: account.smtpPort, implicitTLS: implicit)
        defer { socket.close() }

        _ = try await reply(socket, expect: [220])
        var capabilities = try await ehlo(socket)
        if !implicit {
            try await socket.write("STARTTLS\r\n")
            _ = try await reply(socket, expect: [220])
            socket.startTLS()
            capabilities = try await ehlo(socket)
        }

        let auth = capabilities.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased() ?? "AUTH PLAIN LOGIN"
        do {
            if auth.contains("PLAIN") {
                let token = Data("\0\(account.username)\0\(password)".utf8).base64EncodedString()
                try await socket.write("AUTH PLAIN \(token)\r\n")
                _ = try await reply(socket, expect: [235])
            } else {
                try await socket.write("AUTH LOGIN\r\n")
                _ = try await reply(socket, expect: [334])
                try await socket.write(Data(account.username.utf8).base64EncodedString() + "\r\n")
                _ = try await reply(socket, expect: [334])
                try await socket.write(Data(password.utf8).base64EncodedString() + "\r\n")
                _ = try await reply(socket, expect: [235])
            }
        } catch MailError.server(let text) {
            throw MailError.authentication(text)
        }

        try await socket.write("MAIL FROM:<\(envelopeFrom)>\r\n")
        _ = try await reply(socket, expect: [250])
        for recipient in recipients {
            try await socket.write("RCPT TO:<\(recipient)>\r\n")
            _ = try await reply(socket, expect: [250, 251])
        }
        try await socket.write("DATA\r\n")
        _ = try await reply(socket, expect: [354])
        try await socket.write(dotStuff(message))
        try await socket.write("\r\n.\r\n")
        _ = try await reply(socket, expect: [250])
        try? await socket.write("QUIT\r\n")
    }

    private static func ehlo(_ socket: MailSocket) async throws -> [String] {
        try await socket.write("EHLO driftmail.app\r\n")
        return try await reply(socket, expect: [250])
    }

    /// Reads a (possibly multi-line) reply and returns its text lines.
    private static func reply(_ socket: MailSocket, expect codes: [Int]) async throws -> [String] {
        var lines: [String] = []
        var code = 0
        while true {
            let line = try await socket.readLine(timeout: 60).utf8String
            guard line.count >= 3, let value = Int(line.prefix(3)) else {
                throw MailError.protocolError(line)
            }
            code = value
            lines.append(String(line.dropFirst(4)))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " { break }
        }
        guard codes.contains(code) else {
            throw MailError.server("\(code) \(lines.joined(separator: " "))")
        }
        return lines
    }

    /// Normalises line endings to CRLF and escapes lines starting with a dot.
    private static func dotStuff(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let stuffed = text.components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        return Data(stuffed.utf8)
    }
}
