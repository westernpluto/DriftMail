import Foundation

struct IMAPMailboxStatus: Sendable {
    var exists: Int = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
}

struct IMAPFetchResult: Sendable {
    var sequence: Int
    var uid: UInt32
    var flags: [String]
    var internalDate: Date?
    var body: [UInt8]?
}

/// A small IMAP4rev1 client covering what a mail app needs.
final class IMAPClient: @unchecked Sendable {
    private let socket: MailSocket
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    private(set) var selectedMailbox: String?

    init(host: String, port: Int) {
        socket = MailSocket(host: host, port: port, implicitTLS: true)
    }

    func close() { socket.close() }

    // MARK: Connection

    func connect() async throws {
        let greeting = try await readResponse(timeout: 30)
        if case .untagged(let u) = greeting, u.keyword == "BYE" {
            throw MailError.server(u.text)
        }
    }

    func login(username: String, password: String) async throws {
        do {
            try await run("LOGIN \(quote(username)) \(quote(password))")
        } catch MailError.server(let text) {
            throw MailError.authentication(text)
        }
        try await loadCapabilities()
    }

    func logout() async {
        _ = try? await run("LOGOUT")
        close()
    }

    private func loadCapabilities() async throws {
        try await run("CAPABILITY") { untagged in
            if untagged.keyword == "CAPABILITY" {
                self.capabilities = Set(untagged.text.uppercased().split(separator: " ").map(String.init))
            }
        }
    }

    // MARK: Mailboxes

    func listMailboxes(accountID: UUID) async throws -> [Mailbox] {
        var boxes: [Mailbox] = []
        try await run("LIST \"\" \"*\"") { untagged in
            guard untagged.keyword == "LIST", untagged.values.count >= 3 else { return }
            let flags = (untagged.values[0].list ?? []).compactMap { $0.text?.lowercased() }
            let delimiter = untagged.values[1].text ?? "/"
            guard let rawPath = untagged.values[2].text else { return }
            let path = rawPath
            let leaf = path.components(separatedBy: delimiter).last ?? path
            let display = IMAPClient.decodeModifiedUTF7(leaf)
            let selectable = !flags.contains("\\noselect") && !flags.contains("\\nonexistent")
            boxes.append(Mailbox(accountID: accountID, path: path,
                                 name: path.uppercased() == "INBOX" ? "Inbox" : display,
                                 role: IMAPClient.role(for: path, flags: flags),
                                 selectable: selectable))
        }
        return boxes.sorted { ($0.role.sortOrder, $0.name) < ($1.role.sortOrder, $1.name) }
    }

    static func role(for path: String, flags: [String]) -> MailboxRole {
        if path.uppercased() == "INBOX" { return .inbox }
        if flags.contains("\\sent") { return .sent }
        if flags.contains("\\drafts") { return .drafts }
        if flags.contains("\\trash") { return .trash }
        if flags.contains("\\junk") { return .junk }
        if flags.contains("\\archive") { return .archive }
        if flags.contains("\\all") { return .all }
        if flags.contains("\\flagged") { return .flagged }
        let lower = path.lowercased()
        if lower.hasSuffix("sent") || lower.hasSuffix("sent messages") || lower.hasSuffix("sent items") || lower.hasSuffix("sent mail") { return .sent }
        if lower.hasSuffix("drafts") { return .drafts }
        if lower.hasSuffix("trash") || lower.hasSuffix("deleted messages") || lower.hasSuffix("deleted items") || lower.hasSuffix("bin") { return .trash }
        if lower.hasSuffix("junk") || lower.hasSuffix("spam") || lower.hasSuffix("bulk mail") { return .junk }
        if lower.hasSuffix("archive") { return .archive }
        return .other
    }

    @discardableResult
    func select(_ mailbox: String, readOnly: Bool = false) async throws -> IMAPMailboxStatus {
        var status = IMAPMailboxStatus()
        let verb = readOnly ? "EXAMINE" : "SELECT"
        try await run("\(verb) \(quote(mailbox))") { untagged in
            if untagged.keyword == "EXISTS", let n = untagged.number { status.exists = n }
            if untagged.keyword == "OK" {
                status.uidValidity = IMAPClient.bracketNumber("UIDVALIDITY", in: untagged.text) ?? status.uidValidity
                status.uidNext = IMAPClient.bracketNumber("UIDNEXT", in: untagged.text) ?? status.uidNext
            }
        }
        selectedMailbox = mailbox
        return status
    }

    private static func bracketNumber(_ key: String, in text: String) -> UInt32? {
        guard let range = text.range(of: "[\(key) ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return UInt32(digits)
    }

    // MARK: Fetching

    /// Fetches UIDs and flags for a range of sequence numbers.
    func fetchFlags(sequenceRange: ClosedRange<Int>) async throws -> [IMAPFetchResult] {
        try await fetch("FETCH \(sequenceRange.lowerBound):\(sequenceRange.upperBound) (UID FLAGS)")
    }

    /// Fetches flags, date and the first bytes of each message (enough for headers and a preview).
    func fetchPreviews(uids: [UInt32], previewBytes: Int = 16384) async throws -> [IMAPFetchResult] {
        guard !uids.isEmpty else { return [] }
        return try await fetch("UID FETCH \(IMAPClient.uidSet(uids)) (UID FLAGS INTERNALDATE BODY.PEEK[]<0.\(previewBytes)>)")
    }

    func fetchFullMessage(uid: UInt32) async throws -> [UInt8] {
        let results = try await fetch("UID FETCH \(uid) (UID BODY.PEEK[])")
        guard let body = results.first(where: { $0.uid == uid })?.body else { throw MailError.notFound }
        return body
    }

    private func fetch(_ command: String) async throws -> [IMAPFetchResult] {
        var results: [IMAPFetchResult] = []
        try await run(command) { untagged in
            guard untagged.keyword == "FETCH", let seq = untagged.number,
                  let items = untagged.values.first?.list else { return }
            var result = IMAPFetchResult(sequence: seq, uid: 0, flags: [], internalDate: nil, body: nil)
            var index = 0
            while index + 1 < items.count {
                let key = (items[index].text ?? "").uppercased()
                let value = items[index + 1]
                switch key {
                case "UID": result.uid = UInt32(value.text ?? "") ?? 0
                case "FLAGS": result.flags = (value.list ?? []).compactMap { $0.text }
                case "INTERNALDATE": result.internalDate = value.text.flatMap(IMAPClient.parseInternalDate)
                default:
                    if key.hasPrefix("BODY[") || key.hasPrefix("RFC822") { result.body = value.bytes }
                }
                index += 2
            }
            if result.uid != 0 { results.append(result) }
        }
        return results
    }

    // MARK: Changing messages

    func store(uids: [UInt32], add: Bool, flags: [String]) async throws {
        guard !uids.isEmpty else { return }
        let op = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        try await run("UID STORE \(IMAPClient.uidSet(uids)) \(op) (\(flags.joined(separator: " ")))")
    }

    func move(uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        let set = IMAPClient.uidSet(uids)
        if capabilities.contains("MOVE") {
            try await run("UID MOVE \(set) \(quote(destination))")
        } else {
            try await run("UID COPY \(set) \(quote(destination))")
            try await store(uids: uids, add: true, flags: ["\\Deleted"])
            if capabilities.contains("UIDPLUS") {
                try await run("UID EXPUNGE \(set)")
            } else {
                try await run("EXPUNGE")
            }
        }
    }

    func deletePermanently(uids: [UInt32]) async throws {
        try await store(uids: uids, add: true, flags: ["\\Deleted"])
        if capabilities.contains("UIDPLUS") {
            try await run("UID EXPUNGE \(IMAPClient.uidSet(uids))")
        } else {
            try await run("EXPUNGE")
        }
    }

    func append(to mailbox: String, message: Data, flags: [String] = ["\\Seen"]) async throws {
        let tag = nextTag()
        try await socket.write("\(tag) APPEND \(quote(mailbox)) (\(flags.joined(separator: " "))) {\(message.count)}\r\n")
        while true {
            let response = try await readResponse()
            if case .continuation = response { break }
            if case .tagged(_, _, let text) = response { throw MailError.server(text) }
        }
        try await socket.write(message)
        try await socket.write("\r\n")
        try await waitForTag(tag, handler: nil)
    }

    // MARK: IDLE

    /// Waits until the server reports a mailbox change or `seconds` pass.
    /// Returns true when something changed.
    func idle(seconds: TimeInterval) async throws -> Bool {
        guard capabilities.contains("IDLE") else {
            try await Task.sleep(for: .seconds(min(seconds, 120)))
            try await run("NOOP")
            return true
        }
        let tag = nextTag()
        try await socket.write("\(tag) IDLE\r\n")
        while true {
            let response = try await readResponse()
            if case .continuation = response { break }
            if case .tagged(_, _, let text) = response { throw MailError.server(text) }
        }
        var changed = false
        let deadline = Date().addingTimeInterval(seconds)
        while !changed && Date() < deadline && !Task.isCancelled {
            do {
                let response = try await readResponse(timeout: max(1, deadline.timeIntervalSinceNow))
                if case .untagged(let u) = response, ["EXISTS", "EXPUNGE", "FETCH", "RECENT"].contains(u.keyword) {
                    changed = true
                }
            } catch MailError.timeout {
                break
            }
        }
        try await socket.write("DONE\r\n")
        try await waitForTag(tag, handler: nil)
        return changed
    }

    // MARK: Command plumbing

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "D%04d", tagCounter)
    }

    /// Quick health check for a connection that has sat unused: fails fast
    /// (instead of after the 90-second command timeout) if it silently died.
    func noop(timeout: TimeInterval) async throws {
        try await run("NOOP", timeout: timeout)
    }

    @discardableResult
    private func run(_ command: String, timeout: TimeInterval = 90, handler: ((IMAPUntagged) -> Void)? = nil) async throws -> String {
        let tag = nextTag()
        try await socket.write("\(tag) \(command)\r\n")
        return try await waitForTag(tag, timeout: timeout, handler: handler)
    }

    @discardableResult
    private func waitForTag(_ tag: String, timeout: TimeInterval = 90, handler: ((IMAPUntagged) -> Void)?) async throws -> String {
        while true {
            let response = try await readResponse(timeout: timeout)
            switch response {
            case .untagged(let untagged):
                if untagged.keyword == "BYE" && handler == nil { continue }
                handler?(untagged)
            case .tagged(let responseTag, let status, let text):
                guard responseTag == tag else { continue }
                if status == "OK" { return text }
                throw MailError.server(text)
            case .continuation:
                continue
            }
        }
    }

    private func readResponse(timeout: TimeInterval = 60) async throws -> IMAPResponse {
        var segments: [IMAPRawResponse.Segment] = []
        var line = try await socket.readLine(timeout: timeout)
        while true {
            segments.append(.text(line))
            guard let length = IMAPResponseParser.literalLength(line) else { break }
            let literal = try await socket.readBytes(length, timeout: 90)
            segments.append(.literal(literal))
            line = try await socket.readLine(timeout: 90)
        }
        return IMAPResponseParser.parse(IMAPRawResponse(segments: segments))
    }

    private func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: Helpers

    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var start = sorted.first ?? 0
        var previous = start
        for uid in sorted.dropFirst() {
            if uid == previous + 1 { previous = uid; continue }
            parts.append(start == previous ? "\(start)" : "\(start):\(previous)")
            start = uid
            previous = uid
        }
        if !sorted.isEmpty { parts.append(start == previous ? "\(start)" : "\(start):\(previous)") }
        return parts.joined(separator: ",")
    }

    private static let internalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static func parseInternalDate(_ string: String) -> Date? {
        internalDateFormatter.date(from: string.trimmingCharacters(in: .whitespaces))
    }

    /// Decodes IMAP's modified UTF-7 mailbox names (RFC 3501 §5.1.3).
    static func decodeModifiedUTF7(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]
            if ch == "&", let end = input[index...].firstIndex(of: "-") {
                let encoded = input[input.index(after: index)..<end]
                if encoded.isEmpty {
                    output.append("&")
                } else {
                    var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                    while base64.count % 4 != 0 { base64.append("=") }
                    if let data = Data(base64Encoded: base64),
                       let decoded = String(data: data, encoding: .utf16BigEndian) {
                        output.append(decoded)
                    }
                }
                index = input.index(after: end)
            } else {
                output.append(ch)
                index = input.index(after: index)
            }
        }
        return output
    }
}
