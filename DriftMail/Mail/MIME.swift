import Foundation

/// A parsed MIME entity (a whole message or one part of it).
struct MIMEPart: Sendable {
    var headers: [(name: String, value: String)]
    var contentType: String
    var parameters: [String: String]
    var rawBody: [UInt8]
    var children: [MIMEPart]

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.name == lower }?.value
    }

    var isMultipart: Bool { contentType.hasPrefix("multipart/") }

    var transferEncoding: String {
        (header("content-transfer-encoding") ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased()
    }

    var disposition: (type: String, params: [String: String]) {
        let (value, params) = MIME.parseParameterHeader(header("content-disposition") ?? "")
        return (value.lowercased(), params)
    }

    var filename: String? {
        if let name = disposition.params["filename"], !name.isEmpty { return MIME.decodeEncodedWords(name) }
        if let name = parameters["name"], !name.isEmpty { return MIME.decodeEncodedWords(name) }
        return nil
    }

    var contentID: String? {
        header("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
    }

    var decodedBody: Data {
        switch transferEncoding {
        case "base64": MIME.decodeBase64(rawBody)
        case "quoted-printable": MIME.decodeQuotedPrintable(rawBody)
        default: Data(rawBody)
        }
    }

    var decodedText: String {
        MIME.string(from: decodedBody, charset: parameters["charset"])
    }
}

enum MIME {
    // MARK: Parsing

    static func parse(_ bytes: [UInt8]) -> MIMEPart {
        let (rawHeaderBytes, body) = splitHeaderAndBody(bytes)
        let headerBytes = rejoinSplitCharacters(rawHeaderBytes)
        let headerText = String(data: Data(headerBytes), encoding: .utf8) ?? String(decoding: headerBytes, as: UTF8.self)
        let headers = parseHeaders(headerText)
        let typeHeader = headers.first { $0.name == "content-type" }?.value ?? "text/plain; charset=us-ascii"
        let (type, params) = parseParameterHeader(typeHeader)
        var part = MIMEPart(headers: headers, contentType: type.lowercased().isEmpty ? "text/plain" : type.lowercased(),
                            parameters: params, rawBody: body, children: [])
        if part.isMultipart {
            var sections: [[UInt8]] = []
            if let boundary = params["boundary"], !boundary.isEmpty {
                sections = splitMultipart(body, boundary: boundary)
            }
            // The declared boundary didn't match the body (mangled header, wrong case,
            // stray quotes): use the delimiter the body actually starts its parts with.
            if sections.isEmpty, let guessed = guessBoundary(body) {
                sections = splitMultipart(body, boundary: guessed)
            }
            part.children = sections.map(parse)
        } else if part.contentType == "message/rfc822" {
            part.children = [parse(Array(part.decodedBody))]
        }
        return part
    }

    /// Some senders put raw UTF-8 in headers and their servers fold long lines at a byte
    /// count, inside a multi-byte character (e.g. Japanese). Such a fold is removed
    /// entirely so the character is whole again; ordinary folds are left alone.
    static func rejoinSplitCharacters(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(where: { $0 >= 0x80 }) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            var fold = 0
            if bytes[i] == 13, i + 2 < bytes.count, bytes[i + 1] == 10, bytes[i + 2] == 32 || bytes[i + 2] == 9 {
                fold = 3
            } else if bytes[i] == 10, i + 1 < bytes.count, bytes[i + 1] == 32 || bytes[i + 1] == 9 {
                fold = 2
            }
            if fold > 0, i + fold < bytes.count, bytes[i + fold] & 0xC0 == 0x80, endsMidCharacter(out) {
                i += fold
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }

    /// True if `bytes` ends with an incomplete UTF-8 sequence.
    private static func endsMidCharacter(_ bytes: [UInt8]) -> Bool {
        var continuation = 0
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuation < 3 {
            continuation += 1
            index -= 1
        }
        guard index >= 0 else { return false }
        let lead = bytes[index]
        let needed = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
        return needed > continuation
    }

    /// The first "--something" line of a multipart body, as its boundary.
    static func guessBoundary(_ body: [UInt8]) -> String? {
        var lineStart = 0
        for i in 0...body.count where i == body.count || body[i] == 10 {
            var end = i
            if end > lineStart && body[end - 1] == 13 { end -= 1 }
            if end - lineStart > 2, body[lineStart] == 45, body[lineStart + 1] == 45 {
                let candidate = String(decoding: body[(lineStart + 2)..<end], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty, !candidate.hasSuffix("--") { return candidate }
            }
            lineStart = i + 1
            if lineStart > 8192 { break }  // the first delimiter is near the top
        }
        return nil
    }

    static func splitHeaderAndBody(_ bytes: [UInt8]) -> ([UInt8], [UInt8]) {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 10 {
                // "\n\n" or "\n\r\n"
                if i + 1 < bytes.count && bytes[i + 1] == 10 {
                    return (Array(bytes[..<i]), Array(bytes[(i + 2)...]))
                }
                if i + 2 < bytes.count && bytes[i + 1] == 13 && bytes[i + 2] == 10 {
                    return (Array(bytes[..<i]), Array(bytes[(i + 3)...]))
                }
            }
            i += 1
        }
        return (bytes, [])
    }

    static func parseHeaders(_ text: String) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                result.append((name, value))
            }
        }
        return result
    }

    /// Parses `value; key=val; key2="quoted"` headers, including RFC 2231 `key*=` forms.
    static func parseParameterHeader(_ header: String) -> (String, [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for ch in header {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == ";" && !inQuotes { pieces.append(current); current = ""; continue }
            current.append(ch)
        }
        pieces.append(current)
        let value = pieces.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String)]] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            var extended = false
            if key.hasSuffix("*") { key.removeLast(); extended = true }
            if extended { val = decodeRFC2231(val) }
            if let star = key.firstIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: []].append((index, val))
                continue
            }
            params[key] = val
        }
        for (key, parts) in continuations {
            params[key] = parts.sorted { $0.0 < $1.0 }.map(\.1).joined()
        }
        return (value, params)
    }

    private static func decodeRFC2231(_ value: String) -> String {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let charset = parts.count == 3 ? String(parts[0]) : "utf-8"
        let encoded = parts.count == 3 ? String(parts[2]) : value
        var bytes: [UInt8] = []
        let utf8 = Array(encoded.utf8)
        var j = 0
        while j < utf8.count {
            if utf8[j] == UInt8(ascii: "%"), j + 2 < utf8.count,
               let byte = UInt8(String(decoding: utf8[(j + 1)...(j + 2)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                j += 3
            } else {
                bytes.append(utf8[j])
                j += 1
            }
        }
        return string(from: Data(bytes), charset: charset.isEmpty ? "utf-8" : charset)
    }

    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [[UInt8]] = []
        var lineStart = 0
        var partStart: Int? = nil
        var i = 0
        while i <= body.count {
            if i == body.count || body[i] == 10 {
                var lineEnd = i
                if lineEnd > lineStart && body[lineEnd - 1] == 13 { lineEnd -= 1 }
                let length = lineEnd - lineStart
                if length >= delimiter.count && body[lineStart..<(lineStart + delimiter.count)].elementsEqual(delimiter) {
                    let rest = body[(lineStart + delimiter.count)..<lineEnd]
                    let isClosing = rest.starts(with: [45, 45])
                    let onlyWhitespace = rest.allSatisfy { $0 == 32 || $0 == 9 }
                    if isClosing || onlyWhitespace {
                        if let start = partStart {
                            var end = lineStart
                            // Drop the CRLF that belongs to the delimiter.
                            if end > start && body[end - 1] == 10 { end -= 1 }
                            if end > start && body[end - 1] == 13 { end -= 1 }
                            parts.append(Array(body[start..<max(start, end)]))
                        }
                        if isClosing { return parts }
                        partStart = min(i + 1, body.count)
                    }
                }
                lineStart = i + 1
            }
            i += 1
        }
        // Truncated message: keep what we have of the last part.
        if let start = partStart, start < body.count {
            parts.append(Array(body[start...]))
        }
        return parts
    }

    // MARK: Decoding

    static func decodeBase64(_ bytes: [UInt8]) -> Data {
        var clean = bytes.filter { b in
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47
        }
        // Restore padding instead of trimming: trimming to a multiple of 4 dropped the last
        // 1-2 bytes of any padded input, which turned the last character of each encoded
        // subject chunk (emoji, Japanese…) into "?" and cut the end off attachments.
        // A single leftover character can't encode a byte (truncated preview input).
        if clean.count % 4 == 1 { clean.removeLast() }
        clean.append(contentsOf: [UInt8](repeating: 61, count: (4 - clean.count % 4) % 4))  // "="
        let padded = Data(clean)
        if let data = Data(base64Encoded: padded) { return data }
        return Data()
    }

    static func decodeQuotedPrintable(_ bytes: [UInt8], underscoreIsSpace: Bool = false) -> Data {
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 1 < bytes.count && bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count && bytes[i + 1] == 13 && bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                if i + 1 >= bytes.count { break }
                out.append(b)
            } else if underscoreIsSpace && b == UInt8(ascii: "_") {
                out.append(32)
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    static func encoding(for charset: String?) -> String.Encoding {
        guard let charset = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased(),
              !charset.isEmpty else { return .utf8 }
        switch charset {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf == kCFStringEncodingInvalidId { return .utf8 }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    static func string(from data: Data, charset: String?) -> String {
        let enc = encoding(for: charset)
        if let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if enc == .utf8 || enc == .ascii {
            return String(decoding: data, as: UTF8.self)
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Decodes RFC 2047 encoded words such as `=?UTF-8?B?...?=`.
    ///
    /// Adjacent encoded words in the same charset are joined as bytes before decoding:
    /// many senders split a long subject in the middle of a multi-byte character such
    /// as an emoji, and decoding each word on its own turned those halves into "?".
    static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        var pending = Data()
        var pendingBase64 = ""
        var pendingCharset: String?

        func flushBase64() {
            if !pendingBase64.isEmpty { pending.append(decodeBase64(Array(pendingBase64.utf8))) }
            pendingBase64 = ""
        }
        func flush() {
            flushBase64()
            if !pending.isEmpty { result += string(from: pending, charset: pendingCharset) }
            pending = Data()
            pendingCharset = nil
        }

        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let charset = ns.substring(with: match.range(at: 1)).components(separatedBy: "*").first?.lowercased()
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let text = ns.substring(with: match.range(at: 3))

            // Whitespace between two encoded words is dropped; anything else ends the run.
            let inRun = !pending.isEmpty || !pendingBase64.isEmpty
            let adjacent = inRun && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !(adjacent && charset == pendingCharset) {
                flush()
                if !adjacent { result += between }
                pendingCharset = charset
            }
            if mode == "B" {
                // Normally each word is complete base64; some senders split the base64 text
                // itself across words, so collect it until it lines up on 4 characters.
                pendingBase64 += text.filter { !$0.isWhitespace }
                if pendingBase64.count % 4 == 0 { flushBase64() }
            } else {
                flushBase64()
                pending.append(decodeQuotedPrintable(Array(text.utf8), underscoreIsSpace: true))
            }
            last = match.range.location + match.range.length
        }
        flush()
        result += ns.substring(from: last)
        return result
    }

    // MARK: Addresses and dates

    static func parseAddresses(_ header: String?) -> [EmailAddress] {
        guard let header, !header.isEmpty else { return [] }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        for ch in header {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<": angle += 1; current.append(ch)
            case ">": angle = max(0, angle - 1); current.append(ch)
            case ",", ";":
                if inQuotes || angle > 0 { current.append(ch) } else { items.append(current); current = "" }
            default: current.append(ch)
            }
        }
        items.append(current)
        return items.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let address = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                name = decodeEncodedWords(name).replacingOccurrences(of: "\\\"", with: "\"")
                return EmailAddress(name: name.isEmpty ? nil : name, address: address)
            }
            // "addr (Name)" or bare address
            var address = trimmed
            var name: String? = nil
            if let paren = trimmed.firstIndex(of: "(") {
                address = String(trimmed[..<paren]).trimmingCharacters(in: .whitespaces)
                name = String(trimmed[trimmed.index(after: paren)...]).trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            }
            return EmailAddress(name: name, address: address)
        }
    }

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
         "d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz"].map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }
    }()

    static func parseDate(_ header: String?) -> Date? {
        guard var value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let paren = value.firstIndex(of: "(") { value = value[..<paren].trimmingCharacters(in: .whitespaces) }
        value = value.replacingOccurrences(of: "  ", with: " ")
        for f in dateFormatters {
            if let d = f.date(from: value) { return d }
        }
        return nil
    }

    // MARK: Extraction

    static func extractBody(_ root: MIMEPart) -> MessageBody {
        var plain: String?
        var html: String?
        var attachments: [MailAttachment] = []

        func walk(_ part: MIMEPart) {
            if part.isMultipart || part.contentType == "message/rfc822" {
                part.children.forEach(walk)
                return
            }
            let disposition = part.disposition.type
            let filename = part.filename
            let isText = part.contentType == "text/plain" || part.contentType == "text/html"
            if disposition == "attachment" || (filename != nil && !isText) {
                attachments.append(MailAttachment(
                    filename: filename ?? "Attachment",
                    mimeType: part.contentType,
                    data: part.decodedBody,
                    contentID: part.contentID,
                    isInline: disposition != "attachment" && part.contentID != nil))
                return
            }
            if part.contentType == "text/plain" {
                if plain == nil { plain = part.decodedText } else { plain! += "\n\n" + part.decodedText }
            } else if part.contentType == "text/html" {
                if html == nil { html = part.decodedText } else { html! += part.decodedText }
            } else if let cid = part.contentID {
                attachments.append(MailAttachment(filename: filename ?? cid, mimeType: part.contentType,
                                                  data: part.decodedBody, contentID: cid, isInline: true))
            }
        }
        walk(root)

        func isBlank(_ text: String?) -> Bool { text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
        if isBlank(html) { html = nil }
        if isBlank(plain) { plain = nil }
        // Nothing readable found: fall back to any text section, even one marked as an
        // attachment or an unusual text type, rather than showing an empty message.
        if html == nil && plain == nil {
            func anyText(_ part: MIMEPart) {
                if part.isMultipart || part.contentType == "message/rfc822" {
                    part.children.forEach(anyText)
                    return
                }
                guard part.contentType.hasPrefix("text/") || part.contentType.isEmpty else { return }
                let text = part.decodedText
                guard !isBlank(text) else { return }
                if part.contentType == "text/html" || text.range(of: "<html|<body|<table|<div",
                                                                   options: [.regularExpression, .caseInsensitive]) != nil {
                    if html == nil { html = text }
                } else if plain == nil {
                    plain = text
                }
            }
            anyText(root)
        }

        if var page = html {
            for attachment in attachments where attachment.contentID != nil {
                let uri = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
                page = page.replacingOccurrences(of: "cid:\(attachment.contentID!)", with: uri)
            }
            html = page
        }
        return MessageBody(plainText: plain, html: html, attachments: attachments)
    }

    /// Builds a summary from the first bytes of a message.
    static func summary(from bytes: [UInt8], accountID: UUID, mailbox: String, uid: UInt32,
                        flags: [String], internalDate: Date?) -> MessageSummary {
        let root = parse(bytes)
        let body = extractBody(root)
        let preview = previewText(from: body)
        let lowerFlags = flags.map { $0.lowercased() }
        let mixed = root.contentType == "multipart/mixed"
        return MessageSummary(
            accountID: accountID,
            mailboxPath: mailbox,
            uid: uid,
            from: parseAddresses(root.header("from")).first ?? EmailAddress(name: nil, address: "unknown"),
            to: parseAddresses(root.header("to")),
            cc: parseAddresses(root.header("cc")),
            replyTo: parseAddresses(root.header("reply-to")),
            subject: decodeEncodedWords(root.header("subject") ?? "").trimmingCharacters(in: .whitespaces),
            date: internalDate ?? parseDate(root.header("date")) ?? Date(),
            preview: preview,
            isSeen: lowerFlags.contains("\\seen"),
            isFlagged: lowerFlags.contains("\\flagged"),
            hasAttachments: mixed || !body.visibleAttachments.isEmpty,
            messageID: root.header("message-id"),
            references: root.header("references"))
    }

    private static func stripQuotes(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(">") }
            .joined(separator: "\n")
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        // Comments first (they often wrap CSS for old Outlook), including one cut off
        // by the 16 KB preview download.
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?(-->|$)", with: " ", options: .regularExpression)
        for tag in ["style", "script", "head", "title", "xml"] {
            // Whole blocks…
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
            // …and a block whose end was cut off by the preview download: without this
            // the stylesheet of a large newsletter showed up as the preview text.
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*$", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>|</h[1-6]>|</li>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*$", with: " ", options: .regularExpression)  // a cut-off tag
        return decodeEntities(text)
    }

    /// Decodes HTML entities, and drops the invisible characters newsletters pad
    /// their preheader with (so previews don't start with blank space).
    static func decodeEntities(_ input: String) -> String {
        var text = input
        // Numeric entities: &#8217; and &#x2019;
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let ns = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") || code.hasPrefix("X")
                    ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar) }
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            text = result
        }
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                        "&zwnj;": "", "&zwj;": "", "&shy;": "", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
                        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}",
                        "&hellip;": "\u{2026}", "&bull;": "\u{2022}", "&middot;": "\u{00B7}", "&copy;": "\u{00A9}",
                        "&reg;": "\u{00AE}", "&trade;": "\u{2122}", "&euro;": "\u{20AC}", "&pound;": "\u{00A3}"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)  // last
        // Invisible padding: combining grapheme joiner, zero-width chars, soft hyphen, BOM.
        let invisible: Set<Unicode.Scalar> = ["\u{034F}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}",
                                               "\u{00AD}", "\u{FEFF}"]
        text.unicodeScalars.removeAll { invisible.contains($0) }
        return text
    }

    /// The one-line preview shown under the subject in the message list.
    ///
    /// Built from the HTML version first, as Apple Mail does: the plain-text version of
    /// marketing mail is often just text with raw links, and some senders' plain parts
    /// even contain leftover MIME headers. Plain text is the fallback.
    static func previewText(from body: MessageBody) -> String {
        // Only the start matters for a preview; capping keeps huge HTML fast.
        let fromHTML = body.html.map { cleanPreview(htmlToText(String($0.prefix(300_000)))) } ?? ""
        let text = fromHTML.isEmpty ? (body.plainText.map { cleanPreview(stripQuotes(String($0.prefix(100_000)))) } ?? "") : fromHTML
        return String(text.prefix(240))
    }

    private static func cleanPreview(_ text: String) -> String {
        var t = text
        // MIME header lines that leaked into the text.
        t = t.replacingOccurrences(of: "(?m)^[ \\t]*(Content-[A-Za-z-]+|MIME-Version):[^\\n]*$", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        // Links: "<https://…>", "(https://…)" and bare URLs.
        t = t.replacingOccurrences(of: "[<(\\[](https?|mailto):[^>)\\]\\s]*[>)\\]]?", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\b(https?://|www\\.)\\S+", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        // "[image: Logo]" placeholders and divider lines.
        t = t.replacingOccurrences(of: "\\[image:[^\\]]*\\]", with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "[-_=*~|#]{3,}", with: " ", options: .regularExpression)
        return t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// True for a stored preview that is really markup or CSS (saved before this was fixed).
    static func looksLikeMarkup(_ preview: String) -> Bool {
        (preview.contains("{") && preview.contains("}") && preview.contains(":"))
            || preview.contains("<") && preview.contains(">")
            || preview.range(of: "&#[0-9x]", options: .regularExpression) != nil
            || preview.range(of: "Content-(Type|Transfer-Encoding):|https?://", options: [.regularExpression, .caseInsensitive]) != nil
            || preview.contains("\u{FFFD}")
    }

    // MARK: Encoding

    static func encodeHeaderWord(_ text: String) -> String {
        if text.allSatisfy({ $0.isASCII }) {
            if text.contains(where: { ",;:<>@\"()[]\\".contains($0) }) {
                return "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            return text
        }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }
}
