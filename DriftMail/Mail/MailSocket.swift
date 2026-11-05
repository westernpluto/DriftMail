import Foundation

/// A buffered TCP connection with TLS, built on URLSessionStreamTask so it
/// supports both implicit TLS (IMAPS/SMTPS) and STARTTLS upgrades.
final class MailSocket: @unchecked Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private let task: URLSessionStreamTask
    private var buffer: [UInt8] = []
    private var readIndex = 0

    init(host: String, port: Int, implicitTLS: Bool) {
        task = MailSocket.session.streamTask(withHostName: host, port: port)
        task.resume()
        if implicitTLS { task.startSecureConnection() }
    }

    deinit { task.cancel() }

    func startTLS() {
        task.startSecureConnection()
    }

    func close() {
        task.closeWrite()
        task.closeRead()
        task.cancel()
    }

    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    func write(_ data: Data) async throws {
        do {
            try await task.write(data, timeout: 60)
        } catch {
            throw Self.map(error)
        }
    }

    /// Reads one line and returns it without the trailing CRLF.
    func readLine(timeout: TimeInterval = 60) async throws -> [UInt8] {
        while true {
            if let end = findCRLF() {
                let line = Array(buffer[readIndex..<end])
                readIndex = end + 2
                compact()
                return line
            }
            try await fill(timeout: timeout)
        }
    }

    func readBytes(_ count: Int, timeout: TimeInterval = 60) async throws -> [UInt8] {
        while buffer.count - readIndex < count {
            try await fill(timeout: timeout)
        }
        let bytes = Array(buffer[readIndex..<(readIndex + count)])
        readIndex += count
        compact()
        return bytes
    }

    private func findCRLF() -> Int? {
        guard buffer.count - readIndex >= 2 else { return nil }
        var index = readIndex
        let last = buffer.count - 1
        while index < last {
            if buffer[index] == 13 && buffer[index + 1] == 10 { return index }
            index += 1
        }
        return nil
    }

    private func compact() {
        if readIndex > 64 * 1024 || readIndex == buffer.count {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private func fill(timeout: TimeInterval) async throws {
        let result: (Data?, Bool)
        do {
            result = try await task.readData(ofMinLength: 1, maxLength: 512 * 1024, timeout: timeout)
        } catch {
            throw Self.map(error)
        }
        if let data = result.0, !data.isEmpty {
            buffer.append(contentsOf: data)
        } else if result.1 {
            throw MailError.connectionClosed
        }
    }

    private static func map(_ error: Error) -> Error {
        if let urlError = error as? URLError, urlError.code == .timedOut { return MailError.timeout }
        return error
    }
}

extension Array where Element == UInt8 {
    var utf8String: String {
        String(decoding: self, as: UTF8.self)
    }
}
