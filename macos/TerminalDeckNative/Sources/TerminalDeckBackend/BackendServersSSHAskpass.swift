import Foundation
import Darwin
import TerminalDeckNativeCore

/// The native helper must dispatch --servers-askpass BEFORE normal helper/RPC
/// startup: exit(BackendServersSSHAskpass.run(arguments: CommandLine.arguments,
/// environment: ProcessInfo.processInfo.environment)). This function opens only
/// the private same-user socket named by the parent; it never reads a key file.
public enum BackendServersSSHAskpass {
    public static let dispatchArgument = "--servers-askpass", socketEnvironment = "TERMINALDECK_SERVERS_ASKPASS_SOCKET"
    public static func run(arguments: [String], environment: [String: String]) -> Int32 {
        guard let at = arguments.firstIndex(of: dispatchArgument), arguments.count > at + 1,
              let path = environment[socketEnvironment], !path.isEmpty, path.utf8.count < 104 else { return 1 }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 1 }; defer { Darwin.close(fd) }
        guard connectUnix(fd, path: path) == 0 else { return 1 }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return 1 }
        let prompt = arguments[(at + 1)...].joined(separator: " ")
        guard prompt.utf8.count <= 8192, let request = try? JSONEncoder().encode(prompt), request.count <= 16384 else { return 1 }
        do {
            var framed = request; framed.append(10); try write(fd, framed)
            let answer = try readLine(fd, maximum: 128 * 1024)
            guard let value = try? JSONDecoder().decode(String.self, from: answer) else { return 1 }
            // stdout is the protocol demanded by OpenSSH, never a log sink.
            FileHandle.standardOutput.write(Data((value + "\n").utf8)); return 0
        } catch { return 1 }
    }
    static func connectUnix(_ descriptor: Int32, path: String) -> Int32 {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for i in bytes.indices { raw[i] = bytes[i] } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    static func readLine(_ descriptor: Int32, maximum: Int) throws -> Data {
        var output = Data(), byte: UInt8 = 0
        while output.count <= maximum {
            let n = Darwin.read(descriptor, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { throw CancellationError() }
            if byte == 10 { return output }; output.append(byte)
        }
        throw NativeRPCError(code: "unavailable", message: "The private sign-in request exceeded its limit.")
    }
    static func write(_ descriptor: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in var offset = 0; while offset < raw.count { let n = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw CancellationError() }; offset += n } }
    }
}

/// One explicit credential, scoped to one private connection directory. The
/// source password challenge behavior is preserved: each challenge gets the
/// same value. No global socket, map, keychain, environment secret, or argv
/// secret exists. Socket access is restricted to the current OS user.
final class BackendServersSSHAskpassBroker: @unchecked Sendable {
    let socket: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var current: Set<Int32> = []
    private var stopped = false
    private let answer: @Sendable (String) -> String?
    init(directory: URL, answer: @escaping @Sendable (String) -> String?) { socket = directory.appendingPathComponent("ask"); self.answer = answer }
    func start() throws {
        let path = socket.path; guard path.utf8.count < 104 else { throw NativeRPCError(code: "unavailable", message: "The explicit SSH scratch root is too long for a private sign-in socket.") }
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CancellationError() }
        var noPipe: Int32 = 1; _ = setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in let bytes = Array(path.utf8) + [0]; for i in bytes.indices { raw[i] = bytes[i] } }
        let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.chmod(path, 0o600) == 0, Darwin.listen(listener, 4) == 0 else { Darwin.close(listener); throw NativeRPCError(code: "unavailable", message: "The private native sign-in socket could not be opened.") }
        lock.withLock { fd = listener }
        DispatchQueue(label: "native.servers.askpass", qos: .userInitiated).async { [weak self] in self?.acceptLoop(listener) }
    }
    private func acceptLoop(_ listener: Int32) {
        while !lock.withLock({ stopped }) {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); continue }
            var noPipe: Int32 = 1; _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var deadline = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
            let accepted = lock.withLock { if stopped { return false }; current.insert(client); return true }
            guard accepted else { Darwin.close(client); return }
            defer { _ = lock.withLock { current.remove(client) }; Darwin.close(client) }
            do {
                let raw = try BackendServersSSHAskpass.readLine(client, maximum: 16384)
                guard let prompt = try? JSONDecoder().decode(String.self, from: raw), let value = answer(prompt), let encoded = try? JSONEncoder().encode(value) else { continue }
                var framed = encoded; framed.append(10); try BackendServersSSHAskpass.write(client, framed)
            } catch { continue }
        }
    }
    func close() {
        let changed = lock.withLock { () -> (Bool, [Int32]) in guard !stopped else { return (false, []) }; stopped = true; let old = [fd] + Array(current); fd = -1; return (true, old) }
        guard changed.0 else { return }
        let descriptors = changed.1
        for descriptor in descriptors where descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
        if let listener = descriptors.first, listener >= 0 { Darwin.close(listener) }
        Darwin.unlink(socket.path)
    }
    deinit { close() }
}
