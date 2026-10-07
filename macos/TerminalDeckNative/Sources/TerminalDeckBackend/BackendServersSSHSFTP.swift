import Foundation
import TerminalDeckNativeCore

/// SFTP v3 over `ssh -S <private master> -s sftp`. Names stay length-prefixed
/// bytes; no ls output, shell redirects or path interpolation is involved.
final class BackendServersSSHSFTP: BackendServersSFTP, @unchecked Sendable {
    private let child: BackendServersSSHProcess, lock = NSLock(), version = BackendServersSSHOnce<UInt32>()
    private var buffer = Data(), nextID: UInt32 = 0, stopped = false
    private var pending: [UInt32: BackendServersSSHOnce<Packet>] = [:]
    private var subscriptions: [BackendServersUnsubscribe] = []
    struct Packet: Sendable { let type: UInt8; let bytes: Data }
    private init(_ child: BackendServersSSHProcess) {
        self.child = child
        subscriptions.append(child.onBytes { [weak self] in self?.received($0) })
        subscriptions.append(child.onClose { [weak self] in self?.close() })
        // Drain subsystem stderr without making it a secret/logging sink.
        subscriptions.append(child.stderr.listen { _ in })
    }
    static func open(_ child: BackendServersSSHProcess) async throws -> BackendServersSSHSFTP {
        let service = BackendServersSSHSFTP(child)
        do {
            var initial = Data([1]); initial.u32(3); try await service.send(initial)
            let deadline = Task { do { try await Task.sleep(for: .milliseconds(5000)); service.version.finish(.failure(BackendServersProblem("not-a-server", "This server will not let us list its folders. You can still type the path."))); service.close() } catch {} }
            defer { deadline.cancel() }
            let version = try await withTaskCancellationHandler { try await service.version.value() } onCancel: { service.close() }
            guard version >= 3 else { throw BackendServersProblem("not-a-server", "This server will not let us list its folders. You can still type the path.") }
            return service
        } catch { service.close(); throw error }
    }
    private func received(_ data: Data) {
        var answers: [(BackendServersSSHOnce<Packet>, Packet)] = [], versionAnswer: UInt32?, failure = false
        lock.withLock {
            guard !stopped else { return }; buffer.append(data)
            while buffer.count >= 4 {
                let count = Int(buffer.prefix(4).uint32)
                if count < 1 || count > 4 * 1024 * 1024 { failure = true; break }
                if buffer.count < count + 4 { break }
                let packet = Data(buffer[4..<(count + 4)]); buffer = Data(buffer.dropFirst(count + 4))
                let type = packet[0]
                if type == 2, packet.count >= 5 { versionAnswer = packet[1..<5].uint32; continue }
                guard packet.count >= 5 else { failure = true; break }
                let id = packet[1..<5].uint32
                if let gate = pending.removeValue(forKey: id) { answers.append((gate, .init(type: type, bytes: Data(packet.dropFirst(5))))) }
            }
        }
        if let versionAnswer { version.finish(.success(versionAnswer)) }
        for (gate, packet) in answers { gate.finish(.success(packet)) }
        if failure { close() }
    }
    private func send(_ packet: Data) async throws { var frame = Data(); frame.u32(UInt32(packet.count)); frame.append(packet); try await child.write(frame) }
    private func request(_ type: UInt8, payload: Data) async throws -> Packet {
        let gate = BackendServersSSHOnce<Packet>()
        let id: UInt32 = try lock.withLock {
            guard !stopped, pending.count < 64 else { throw BackendServersProblem("lost", "That connection is gone.") }
            repeat { nextID &+= 1 } while pending[nextID] != nil
            pending[nextID] = gate; return nextID
        }
        var bytes = Data([type]); bytes.u32(id); bytes.append(payload)
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(30000)); gate.finish(.failure(BackendServersProblem("no-answer", "The server started that but never finished it, so it was stopped."))); self.close() } catch {} }
        defer { deadline.cancel(); _ = lock.withLock { pending.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            do { try await send(bytes); return try await gate.value() } catch { close(); throw error }
        } onCancel: { gate.finish(.failure(CancellationError())); self.close() }
    }
    private func stringPayload(_ text: String) -> Data { var bytes = Data(); bytes.string(Data(text.utf8)); return bytes }
    private func require(_ packet: Packet, type: UInt8, path: String, allowEOF: Bool = false) throws -> BackendServersSFTPReader {
        if packet.type == 101 {
            var reader = BackendServersSFTPReader(packet.bytes), code = try reader.u32()
            if code == 0, type == 101 { return reader }
            if code == 1, allowEOF { return BackendServersSFTPReader(Data()) }
            throw BackendServersProblem.sftp(code, path: path)
        }
        guard packet.type == type else { throw BackendServersProblem("lost", "The server sent an unreadable file-transfer reply.") }
        return BackendServersSFTPReader(packet.bytes)
    }
    func realpath(_ path: String) async throws -> String {
        var reader = try require(await request(16, payload: stringPayload(path)), type: 104, path: path)
        guard try reader.u32() > 0 else { throw BackendServersProblem("no-such-folder", "There is nothing at \(path) on this server.") }
        return String(decoding: try reader.string(), as: UTF8.self)
    }
    func list(_ path: String) async throws -> [BackendServersRemoteEntry] {
        var opened = try require(await request(11, payload: stringPayload(path)), type: 102, path: path)
        let handle = try opened.string(); var payload = Data(); payload.string(handle)
        var results: [BackendServersRemoteEntry] = []
        do {
            while true {
                try Task.checkCancellation()
                let packet = try await request(12, payload: payload)
                if packet.type == 101 { var status = BackendServersSFTPReader(packet.bytes); if try status.u32() == 1 { break } }
                var reader = try require(packet, type: 104, path: path)
                let count = try reader.u32(); guard count <= 65536 else { throw BackendServersProblem("lost", "The server sent an unreadable folder listing.") }
                for _ in 0..<count {
                    let name = String(decoding: try reader.string(), as: UTF8.self); _ = try reader.string()
                    let attrs = try reader.attributes(), mode = attrs.permissions ?? 0
                    results.append(.init(name: name, kind: mode & 0o170000 == 0o040000 ? "folder" : mode & 0o170000 == 0o120000 ? "link" : "file"))
                }
                guard results.count <= 65536 else { throw BackendServersProblem("lost", "The server sent too many names in that folder.") }
            }
        } catch { _ = try? await request(4, payload: payload); throw error }
        _ = try? await request(4, payload: payload); return results
    }
    func size(_ path: String) async throws -> Int {
        var reader = try require(await request(17, payload: stringPayload(path)), type: 105, path: path)
        guard let size = try reader.attributes().size, size <= UInt64(Int.max) else { throw BackendServersProblem("lost", "The server could not say how big that file is.") }
        return Int(size)
    }
    func read(_ path: String, from: Int, length: Int) async throws -> Data {
        var payload = stringPayload(path); payload.u32(1); payload.u32(0)
        var opened = try require(await request(3, payload: payload), type: 102, path: path)
        let handle = try opened.string(); var closePayload = Data(); closePayload.string(handle)
        do {
            var read = closePayload; read.u64(UInt64(max(0, from))); read.u32(UInt32(clamping: max(0, min(length, 4 * 1024 * 1024 - 32))))
            let packet = try await request(5, payload: read)
            if packet.type == 101 { var status = BackendServersSFTPReader(packet.bytes); if try status.u32() == 1 { _ = try? await request(4, payload: closePayload); return Data() } }
            var reader = try require(packet, type: 103, path: path); let bytes = try reader.string()
            _ = try? await request(4, payload: closePayload); return bytes
        } catch { _ = try? await request(4, payload: closePayload); throw error }
    }
    func mkdir(_ path: String) async throws { var payload = stringPayload(path); payload.u32(0); _ = try require(await request(14, payload: payload), type: 101, path: path) }
    func put(localPath: String, remotePath: String) async throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath)); defer { try? input.close() }
        var payload = stringPayload(remotePath); payload.u32(2 | 8 | 16); payload.u32(0)
        var opened = try require(await request(3, payload: payload), type: 102, path: remotePath)
        let handle = try opened.string(); var closePayload = Data(); closePayload.string(handle)
        do {
            var offset: UInt64 = 0
            while let bytes = try input.read(upToCount: 32768), !bytes.isEmpty {
                try Task.checkCancellation(); var write = closePayload; write.u64(offset); write.string(bytes)
                _ = try require(await request(6, payload: write), type: 101, path: remotePath); offset += UInt64(bytes.count)
            }
            _ = try require(await request(4, payload: closePayload), type: 101, path: remotePath)
        } catch { _ = try? await request(4, payload: closePayload); throw error }
    }
    func rename(_ from: String, to: String) async throws { var payload = stringPayload(from); payload.string(Data(to.utf8)); _ = try require(await request(18, payload: payload), type: 101, path: to) }
    func unlink(_ path: String) async throws { _ = try require(await request(13, payload: stringPayload(path)), type: 101, path: path) }
    func close() {
        let gates = lock.withLock { () -> [BackendServersSSHOnce<Packet>] in guard !stopped else { return [] }; stopped = true; let old = Array(pending.values); pending = [:]; buffer = Data(); return old }
        for gate in gates { gate.finish(.failure(CancellationError())) }
        version.finish(.failure(BackendServersProblem("not-a-server", "This server will not let us list its folders. You can still type the path.")))
        child.close()
    }
    deinit { for cancel in subscriptions { cancel() }; close() }
}

struct BackendServersSFTPReader {
    let bytes: Data; private(set) var at = 0
    init(_ bytes: Data) { self.bytes = bytes }
    mutating func u32() throws -> UInt32 { try take(4).uint32 }
    mutating func u64() throws -> UInt64 { try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    mutating func string() throws -> Data { let count = try u32(); guard count <= 4 * 1024 * 1024 else { throw malformed() }; return try take(Int(count)) }
    mutating func take(_ count: Int) throws -> Data { guard count >= 0, at + count <= bytes.count else { throw malformed() }; defer { at += count }; return Data(bytes[at..<(at + count)]) }
    mutating func attributes() throws -> (size: UInt64?, permissions: UInt32?) {
        let flags = try u32(); var size: UInt64?, permissions: UInt32?
        if flags & 1 != 0 { size = try u64() }; if flags & 2 != 0 { _ = try u32(); _ = try u32() }
        if flags & 4 != 0 { permissions = try u32() }; if flags & 8 != 0 { _ = try u32(); _ = try u32() }
        if flags & 0x80000000 != 0 { let count = try u32(); guard count <= 128 else { throw malformed() }; for _ in 0..<count { _ = try string(); _ = try string() } }
        return (size, permissions)
    }
    private func malformed() -> BackendServersProblem { .init("lost", "The server sent an unreadable file-transfer reply.") }
}
private extension Data {
    var uint32: UInt32 { prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func u32(_ value: UInt32) { append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    mutating func u64(_ value: UInt64) { u32(UInt32(truncatingIfNeeded: value >> 32)); u32(UInt32(truncatingIfNeeded: value)) }
    mutating func string(_ value: Data) { u32(UInt32(value.count)); append(value) }
}
