import Foundation
import CryptoKit
import Darwin

/// N18 (ssh2 in remote/ssh-verify.ts): byte-level SSH-2 encoding for the
/// authenticate-only loopback verifier. RFC 4251 §5 types only.
struct BackendNodelessSSHWriter {
    private(set) var bytes: [UInt8] = []
    init() {}
    mutating func byte(_ value: UInt8) { bytes.append(value) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }
    mutating func uint32(_ value: UInt32) {
        bytes += [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                  UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    mutating func string(_ value: [UInt8]) { uint32(UInt32(value.count)); bytes += value }
    mutating func string(_ value: String) { string(Array(value.utf8)) }
    mutating func nameList(_ names: [String]) { string(names.joined(separator: ",")) }
    /// Unsigned big-endian magnitude as an SSH mpint (two's complement, minimal).
    mutating func mpint(_ magnitude: [UInt8]) { string(BackendNodelessSSHWriter.mpintBody(magnitude)) }
    mutating func raw(_ value: [UInt8]) { bytes += value }
    static func mpintBody(_ magnitude: [UInt8]) -> [UInt8] {
        var trimmed = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = trimmed.first, first & 0x80 != 0 { trimmed.insert(0, at: 0) }
        return trimmed
    }
}

struct BackendNodelessSSHReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count - offset }
    private func short() -> BackendRemoteServeSSHSignal { .init(level: "protocol", message: "The SSH server sent a truncated message.") }
    mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw short() }
        defer { offset += 1 }; return bytes[offset]
    }
    mutating func bool() throws -> Bool { try byte() != 0 }
    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw short() }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
    mutating func raw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw short() }
        defer { offset += count }; return Array(bytes[offset..<offset + count])
    }
    mutating func string() throws -> [UInt8] { try raw(Int(try uint32())) }
    mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }
    mutating func nameList() throws -> [String] { try text().split(separator: ",").map(String.init) }
    /// Magnitude without the sign byte. Negative mpints are refused.
    mutating func mpint() throws -> [UInt8] {
        let body = try string()
        if let first = body.first, first & 0x80 != 0 { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH message carried a negative integer.") }
        return Array(body.drop(while: { $0 == 0 }))
    }
}

/// A loopback TCP socket with one absolute deadline. Every wait uses poll(2);
/// `cancel()` shuts the socket down from any thread so a blocked wait returns.
final class BackendNodelessSSHSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    private let deadline: Date
    init(deadline: Date) { self.deadline = deadline }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        lock.withLock {
            cancelled = true
            if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }
    func close() {
        lock.withLock {
            if fd >= 0 { _ = Darwin.close(fd); fd = -1 }
        }
    }
    private func descriptor() throws -> Int32 {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            guard fd >= 0 else { throw BackendRemoteServeSSHSignal(level: "client-socket", message: "The SSH connection is closed.") }
            return fd
        }
    }
    private func waitMilliseconds() throws -> Int32 {
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw BackendRemoteServeSSHSignal(level: "client-timeout", code: "ETIMEDOUT", message: "Timed out while waiting for the SSH handshake.") }
        return Int32(min(left * 1000, Double(Int32.max)).rounded(.up))
    }
    private func wait(_ events: Int32) throws {
        while true {
            let socket = try descriptor()
            var poller = pollfd(fd: socket, events: Int16(events), revents: 0)
            let ready = Darwin.poll(&poller, 1, try waitMilliseconds())
            if isCancelled { throw CancellationError() }
            if ready > 0 { return }
            if ready == 0 { continue } // waitMilliseconds throws once the deadline passed
            if errno == EINTR { continue }
            throw BackendRemoteServeSSHSignal(level: "client-socket", code: "EPOLL", message: "The SSH connection could not be watched.")
        }
    }

    /// Dial 127.0.0.1 only (the port is the sole parameter).
    func connectLoopback(port: Int) throws {
        guard (1...65535).contains(port) else { throw BackendRemoteServeSSHSignal(level: "client-socket", code: "EINVAL", message: "Invalid SSH port.") }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw BackendRemoteServeSSHSignal(level: "client-socket", code: "ESOCKET", message: "Could not open a socket.") }
        var one: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        let stored: Bool = lock.withLock {
            guard !cancelled else { return false }
            fd = socket; return true
        }
        guard stored else { _ = Darwin.close(socket); throw CancellationError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw Self.connectFailure(errno, port: port) }
            try wait(POLLOUT)
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(socket, SOL_SOCKET, SO_ERROR, &failure, &size)
            guard failure == 0 else { throw Self.connectFailure(failure, port: port) }
        }
    }
    private static func connectFailure(_ code: Int32, port: Int) -> BackendRemoteServeSSHSignal {
        let name = code == ECONNREFUSED ? "ECONNREFUSED" : code == ETIMEDOUT ? "ETIMEDOUT" : "ECONNECT"
        return .init(level: code == ETIMEDOUT ? "client-timeout" : "client-socket", code: name, message: "connect \(name) 127.0.0.1:\(port)")
    }

    func write(_ data: [UInt8]) throws {
        var sent = 0
        while sent < data.count {
            let socket = try descriptor()
            let count = data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress!.advanced(by: sent), data.count - sent, 0) }
            if count > 0 { sent += count; continue }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { try wait(POLLOUT); continue }
            if isCancelled { throw CancellationError() }
            throw BackendRemoteServeSSHSignal(level: "client-socket", code: "EPIPE", message: "The SSH connection closed while sending.")
        }
    }
    func read(exactly count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var have = 0
        while have < count {
            let socket = try descriptor()
            let got = buffer.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress!.advanced(by: have), count - have, 0) }
            if got > 0 { have += got; continue }
            if got < 0 && (errno == EAGAIN || errno == EINTR) { try wait(POLLIN); continue }
            if isCancelled { throw CancellationError() }
            throw BackendRemoteServeSSHSignal(level: "client-socket", code: "ECONNRESET", message: "Connection lost before handshake")
        }
        return buffer
    }
    /// One identification/preamble line without CR LF; at most `limit` bytes.
    func readLine(limit: Int = 8192) throws -> String {
        var line: [UInt8] = []
        while true {
            let next = try read(exactly: 1)[0]
            if next == 0x0a { break }
            line.append(next)
            guard line.count <= limit else { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH server's greeting is too long.") }
        }
        if line.last == 0x0d { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }
}

/// RFC 4253 §6 binary packets: plaintext until NEWKEYS, then
/// aes128-gcm@openssh.com / aes256-gcm@openssh.com (RFC 5647 as OpenSSH uses it:
/// clear 4-byte length as AAD, 12-byte nonce = 4-byte fixed + 64-bit counter).
struct BackendNodelessSSHPackets {
    static let maximumPacket = 256 * 1024
    struct Direction {
        let key: SymmetricKey
        let fixed: [UInt8]
        var counter: UInt64
        init(key: [UInt8], iv: [UInt8]) {
            self.key = SymmetricKey(data: key); fixed = Array(iv.prefix(4))
            counter = iv.dropFirst(4).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        mutating func nonce() throws -> AES.GCM.Nonce {
            var bytes = fixed
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift))) }
            counter &+= 1
            return try AES.GCM.Nonce(data: bytes)
        }
    }
    var outgoing: Direction?
    var incoming: Direction?

    static func padded(_ payload: [UInt8], block: Int, lengthCovered: Bool) -> [UInt8] {
        let base = (lengthCovered ? 5 : 1) + payload.count
        var padding = block - base % block
        if padding < 4 { padding += block }
        var body: [UInt8] = [UInt8(padding)] + payload
        body += (0..<padding).map { _ in UInt8.random(in: 0...255) }
        return body
    }
    mutating func seal(_ payload: [UInt8]) throws -> [UInt8] {
        guard var direction = outgoing else {
            let body = Self.padded(payload, block: 8, lengthCovered: true)
            var writer = BackendNodelessSSHWriter(); writer.uint32(UInt32(body.count)); writer.raw(body)
            return writer.bytes
        }
        let body = Self.padded(payload, block: 16, lengthCovered: false)
        var length = BackendNodelessSSHWriter(); length.uint32(UInt32(body.count))
        let box = try AES.GCM.seal(Data(body), using: direction.key, nonce: try direction.nonce(), authenticating: Data(length.bytes))
        outgoing = direction
        return length.bytes + Array(box.ciphertext) + Array(box.tag)
    }
    mutating func receive(from socket: BackendNodelessSSHSocket) throws -> [UInt8] {
        let header = try socket.read(exactly: 4)
        let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
        guard length >= 5, length <= Self.maximumPacket else { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH server sent an invalid packet length.") }
        let body: [UInt8]
        if var direction = incoming {
            guard length % 16 == 0 else { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH server sent a misaligned packet.") }
            let sealed = try socket.read(exactly: length + 16)
            let box = try AES.GCM.SealedBox(nonce: try direction.nonce(), ciphertext: Data(sealed.prefix(length)), tag: Data(sealed.suffix(16)))
            do { body = Array(try AES.GCM.open(box, using: direction.key, authenticating: Data(header))) }
            catch { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH packet failed its integrity check.") }
            incoming = direction
        } else {
            body = try socket.read(exactly: length)
        }
        let padding = Int(body[0])
        guard padding >= 4, padding < body.count else { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH server sent invalid padding.") }
        return Array(body[1..<(body.count - padding)])
    }
}
