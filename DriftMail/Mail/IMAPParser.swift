import Foundation

/// A value in an IMAP response.
indirect enum IMAPValue: Sendable {
    case atom(String)
    case string([UInt8])     // quoted string or literal
    case list([IMAPValue])
    case nilValue

    var text: String? {
        switch self {
        case .atom(let s): s
        case .string(let bytes): bytes.utf8String
        case .nilValue, .list: nil
        }
    }

    var bytes: [UInt8]? {
        switch self {
        case .string(let b): b
        case .atom(let s): Array(s.utf8)
        default: nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    var int: Int? { text.flatMap { Int($0) } }
}

/// One complete server response; literals are kept as separate segments.
struct IMAPRawResponse: Sendable {
    enum Segment: Sendable {
        case text([UInt8])
        case literal([UInt8])
    }
    var segments: [Segment]

    var firstLine: String {
        if case .text(let t) = segments.first { return t.utf8String }
        return ""
    }
}

struct IMAPUntagged: Sendable {
    var number: Int?
    var keyword: String
    var values: [IMAPValue]
    var text: String
}

enum IMAPResponse: Sendable {
    case untagged(IMAPUntagged)
    case tagged(tag: String, status: String, text: String)
    case continuation(String)
}

enum IMAPResponseParser {
    private static let textKeywords: Set<String> = ["OK", "NO", "BAD", "BYE", "PREAUTH", "CAPABILITY", "ENABLED"]

    static func literalLength(_ line: [UInt8]) -> Int? {
        guard line.last == UInt8(ascii: "}") else { return nil }
        guard let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = line[(open + 1)..<(line.count - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    static func parse(_ raw: IMAPRawResponse) -> IMAPResponse {
        var cursor = IMAPCursor(segments: raw.segments)
        let line = raw.firstLine
        if line.hasPrefix("+") {
            return .continuation(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("* ") {
            cursor.advance(2)
            let first = cursor.readAtom()
            if let number = Int(first) {
                let keyword = cursor.readAtom().uppercased()
                let values = cursor.parseAll()
                return .untagged(IMAPUntagged(number: number, keyword: keyword, values: values, text: ""))
            }
            let keyword = first.uppercased()
            if textKeywords.contains(keyword) {
                return .untagged(IMAPUntagged(number: nil, keyword: keyword, values: [], text: cursor.restOfLine()))
            }
            return .untagged(IMAPUntagged(number: nil, keyword: keyword, values: cursor.parseAll(), text: ""))
        }
        let tag = cursor.readAtom()
        let status = cursor.readAtom().uppercased()
        return .tagged(tag: tag, status: status, text: cursor.restOfLine())
    }
}

/// Walks the segments of a raw response, treating literal segments as strings.
struct IMAPCursor {
    let segments: [IMAPRawResponse.Segment]
    private var segmentIndex = 0
    private var position = 0

    init(segments: [IMAPRawResponse.Segment]) {
        self.segments = segments
    }

    private var currentText: [UInt8]? {
        guard segmentIndex < segments.count, case .text(let t) = segments[segmentIndex] else { return nil }
        return t
    }

    private func peek() -> UInt8? {
        guard let text = currentText, position < text.count else { return nil }
        return text[position]
    }

    mutating func advance(_ n: Int = 1) { position += n }

    mutating func skipSpaces() {
        while peek() == UInt8(ascii: " ") { position += 1 }
    }

    mutating func readAtom() -> String {
        skipSpaces()
        guard let text = currentText else { return "" }
        let start = position
        var depth = 0
        while position < text.count {
            let c = text[position]
            if c == UInt8(ascii: "[") { depth += 1 }
            else if c == UInt8(ascii: "]") { depth = max(0, depth - 1) }
            else if depth == 0 && (c == 32 || c == UInt8(ascii: "(") || c == UInt8(ascii: ")")) { break }
            position += 1
        }
        return String(decoding: text[start..<position], as: UTF8.self)
    }

    mutating func restOfLine() -> String {
        skipSpaces()
        guard let text = currentText, position <= text.count else { return "" }
        let rest = String(decoding: text[position...], as: UTF8.self)
        position = text.count
        return rest
    }

    mutating func parseAll() -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            guard let c = peek() else { break }
            if c == UInt8(ascii: ")") { position += 1; continue }
            guard let value = parseValue() else { break }
            values.append(value)
        }
        return values
    }

    mutating func parseValue() -> IMAPValue? {
        skipSpaces()
        guard let c = peek() else { return nil }
        switch c {
        case UInt8(ascii: "("):
            position += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard let next = peek() else { break }
                if next == UInt8(ascii: ")") { position += 1; break }
                guard let item = parseValue() else { break }
                items.append(item)
            }
            return .list(items)
        case UInt8(ascii: "\""):
            position += 1
            var out: [UInt8] = []
            while let ch = peek() {
                position += 1
                if ch == UInt8(ascii: "\\"), let escaped = peek() {
                    out.append(escaped)
                    position += 1
                } else if ch == UInt8(ascii: "\"") {
                    break
                } else {
                    out.append(ch)
                }
            }
            return .string(out)
        case UInt8(ascii: "{"):
            // The literal's bytes are the next segment; text resumes after it.
            segmentIndex += 1
            var bytes: [UInt8] = []
            if segmentIndex < segments.count, case .literal(let lit) = segments[segmentIndex] {
                bytes = lit
                segmentIndex += 1
            }
            position = 0
            return .string(bytes)
        default:
            let atom = readAtom()
            if atom.isEmpty { position += 1; return nil }
            if atom.uppercased() == "NIL" { return .nilValue }
            return .atom(atom)
        }
    }
}
