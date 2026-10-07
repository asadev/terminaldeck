import Foundation
import Dispatch
import Darwin
import TerminalDeckNativeCore

private enum AccountSocketIO {
    static let maximumFrame = 1024 * 1024
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard path.hasPrefix("/"), !path.contains("\0"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BackendAccountFailure("The native account socket path is invalid or too long.") }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { output in for index in bytes.indices { output[index] = UInt8(bitPattern: bytes[index]) } }
        return address
    }
    static func socketOptions(_ fd: Int32) {
        var noPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var result = Data(count: count), position = 0
        while position < count {
            let read = result.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress?.advanced(by: position), count - position, 0) }
            if read < 0 && errno == EINTR { continue }
            guard read > 0 else { throw BackendAccountFailure("The native account socket did not deliver a complete response.") }
            position += read
        }
        return result
    }
    static func readFrame(_ fd: Int32) throws -> Data {
        let header = try read(fd, count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumFrame) else { throw BackendAccountFailure("The native account message exceeds its size limit.") }
        return try read(fd, count: Int(length))
    }
    static func writeFrame(_ data: Data, fd: Int32) throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw BackendAccountFailure("The native account answer exceeds its size limit.") }
        var length = UInt32(data.count).bigEndian
        let framed = withUnsafeBytes(of: &length) { Data($0) } + data
        var position = 0
        while position < framed.count {
            let written = framed.withUnsafeBytes { Darwin.send(fd, $0.baseAddress?.advanced(by: position), framed.count - position, 0) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw BackendAccountFailure("The native account socket could not send its answer.") }
            position += written
        }
    }
}

/// Only same-UID clients can reach this 0600 Unix socket; tickets additionally
/// bind each credential request to one launch and its config-directory hash.
final class BackendAccountUnixServer: @unchecked Sendable {
    private let path: String
    private let source: any DispatchSourceRead
    private let handler: @Sendable (Data, Int32) async -> Data
    private let lock = NSLock()
    private var stopped = false
    private var clients = Set<Int32>()
    init(path: String, handler: @escaping @Sendable (Data, Int32) async -> Data) throws {
        self.path = path; self.handler = handler
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw BackendAccountFailure("The native account socket could not be inspected.") }
            var address = try AccountSocketIO.address(path)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            Darwin.close(probe)
            guard result != 0 else { throw BackendAccountFailure("An account vault is already serving this data directory. Stop its complete owner before native takeover.") }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { throw BackendAccountFailure("The account socket path contains a file that this runtime may not replace.") }
            guard Darwin.unlink(path) == 0 else { throw BackendAccountFailure("The stale account socket could not be removed.") }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BackendAccountFailure("The native account socket could not be created.") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = try AccountSocketIO.address(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { Darwin.close(descriptor); throw BackendAccountFailure("The native account socket could not bind.") }
        guard chmod(path, 0o600) == 0, listen(descriptor, 16) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(descriptor); Darwin.unlink(path); throw BackendAccountFailure("The native account socket could not be secured and started.")
        }
        // A session's credential lookup waits on this (TS: the main event loop),
        // so it is not background work.
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in self?.accept(descriptor) }
        source.resume()
    }
    private func accept(_ descriptor: Int32) {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { return }
            var user: uid_t = 0, group: gid_t = 0
            guard getpeereid(client, &user, &group) == 0, user == geteuid() else { Darwin.close(client); continue }
            var peerPID: Int32 = 0, peerSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerSize) == 0, peerPID > 0 else { Darwin.close(client); continue }
            lock.lock()
            let allowed = !stopped && clients.count < 32
            if allowed { clients.insert(client) }
            lock.unlock()
            guard allowed else { Darwin.close(client); continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            // BSD accept() hands back the listener's O_NONBLOCK: a request still in
            // flight would read as EAGAIN and be dropped. Blocking, bounded by the
            // 4-second socket timeouts.
            let flags = fcntl(client, F_GETFL)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { finish(client); continue }
            AccountSocketIO.socketOptions(client)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let request = try AccountSocketIO.readFrame(client)
                    Task { [peerPID] in
                        let answer = await handler(request, peerPID)
                        try? AccountSocketIO.writeFrame(answer, fd: client)
                        finish(client)
                    }
                } catch { finish(client) }
            }
        }
    }
    private func finish(_ fd: Int32) { lock.lock(); clients.remove(fd); lock.unlock(); Darwin.close(fd) }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let active = clients
        lock.unlock()
        source.cancel()
        // Keep ownership of each FD until its own handler closes it; closing
        // now could reuse a number while a late credential answer writes to it.
        for fd in active { _ = shutdown(fd, SHUT_RDWR) }
        Darwin.unlink(path)
    }
    deinit { stop() }
}

/// What the helper reads and writes, and the real `security` it hands to.
/// Production is the process's own stdio and `/usr/bin/security`; tests inject
/// a recorder so the client runs in-process and never reaches a keychain.
struct BackendAccountShimIO: Sendable {
    var stdinIsTerminal: @Sendable () -> Bool
    var readStdin: @Sendable () -> Data
    var writeStdout: @Sendable (Data) -> Void
    var writeStderr: @Sendable (Data) -> Void
    /// TS `exec "$REAL" "$@"` (stdin nil: left untouched for the real command)
    /// and `printf '%s\n' "$INPUT" | "$REAL" "$@"`. Answers the exit code.
    var passThrough: @Sendable ([String], Data?) -> Int32
    /// TS `OUT=$("$REAL" "$@")`: stdout captured, stderr straight through.
    var capture: @Sendable ([String], Data?) -> (code: Int32, stdout: Data)

    static var standard: BackendAccountShimIO { standard(realSecurity: BackendAccountShimParsing.realSecurity) }
    /// The process's own stdio with `real` as the real `security` (production: /usr/bin/security).
    static func standard(realSecurity real: String) -> BackendAccountShimIO {
        BackendAccountShimIO(
            stdinIsTerminal: { isatty(STDIN_FILENO) != 0 },
            readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
            writeStdout: { try? FileHandle.standardOutput.write(contentsOf: $0) },
            writeStderr: { try? FileHandle.standardError.write(contentsOf: $0) },
            passThrough: { argv, input in BackendAccountSecurityShimClient.runReal(argv, input: input, real: real) },
            capture: { argv, input in BackendAccountSecurityShimClient.captureReal(argv, input: input, real: real) })
    }
}

public enum BackendAccountSecurityShimClient {
    public static var capabilities: String { #"{"protocol":3,"securityShim":true,"credentialReceipts":true,"securityCapture":true}"# }
    /// The fourth helper argument: this run's socket, which the session's
    /// environment must name exactly (TS keychain-shim.ts rule 1).
    public static let socketMarker = "--vault-socket="

    static func verifyHelper(_ executable: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw BackendAccountFailure("The native account security helper is missing or not executable.") }
        let child = Process(), output = Pipe()
        child.executableURL = executable; child.arguments = ["vault:capabilities"]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 4); timer.setEventHandler { if child.isRunning { child.terminate() } }; timer.resume()
        let result = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit(); timer.cancel()
        guard child.terminationStatus == 0, result.count <= 1024, let json = try? NativeRPCValue.parseJSON(result),
              json["protocol"].number == 3, json["securityShim"].bool == true, json["credentialReceipts"].bool == true,
              json["securityCapture"].bool == true else {
            throw BackendAccountFailure("The bundled helper does not implement the native account-vault protocol. Managed logins cannot be launched.")
        }
    }

    /// Wire this before the helper's ordinary JSON-operation entrypoint. The
    /// first three arguments name environment keys, never values or secrets;
    /// the fourth (`--vault-socket=`) is this run's socket path.
    /// Output is solely the agent-requested security result, not a diagnostic.
    public static func main(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        main(arguments: arguments, environment: environment, io: .standard)
    }
    /// The same client over a stand-in `security` at an absolute path — for a test helper binary only, so an
    /// end-to-end test never reaches a real keychain. The bundled helper always uses the entry point above.
    public static func main(arguments: [String], environment: [String: String], realSecurity: String) -> Int32 {
        guard realSecurity.hasPrefix("/") else { return 1 }
        return main(arguments: arguments, environment: environment, io: .standard(realSecurity: realSecurity))
    }

    /// TS keychain-shim.ts `securityShimScript`, in the same order — the order is the safety case.
    static func main(arguments: [String], environment: [String: String], io: BackendAccountShimIO) -> Int32 {
        guard arguments.count >= 3 else { return 1 }
        let keys = Array(arguments.prefix(3))
        guard keys.allSatisfy({ $0.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil }) else { return 1 }
        var argv = Array(arguments.dropFirst(3)), expected: String?
        if let first = argv.first, first.hasPrefix(socketMarker) { expected = String(first.dropFirst(socketMarker.count)); argv.removeFirst() }
        let named = environment[keys[0]] ?? ""
        // 1. Not this run's vault: the real command, argv and stdin untouched.
        if let expected { guard named == expected else { return io.passThrough(argv, nil) } }
        else if named.isEmpty { return io.passThrough(argv, nil) }
        // 2. No ticket: the real command, untouched.
        guard let ticket = environment[keys[1]], !ticket.isEmpty else { return io.passThrough(argv, nil) }
        // Interactive mode only as the agent uses it: `-i` alone, stdin not a terminal.
        let interactive = argv == ["-i"] && !io.stdinIsTerminal()
        let input = interactive ? stripTrailingNewlines(String(decoding: io.readStdin(), as: UTF8.self)) : ""
        let piped: Data? = interactive ? Data((input + "\n").utf8) : nil
        do {
            // 3. Ask the app. Ticket, argv and stdin travel in the frame, never argv.
            let payload = NativeRPCValue.object([.init("ticket", .string(ticket)), .init("argv", .array(argv.map(NativeRPCValue.string))), .init("stdin", .string(input))])
            let response = try exchange(payload, path: named)
            switch response.kind {
            case "pass":
                return io.passThrough(argv, piped)
            case "capture":
                let ran = io.capture(argv, piped)
                let out = stripTrailingNewlines(String(decoding: ran.stdout, as: UTF8.self))
                let report = NativeRPCValue.object([.init("operation", .string("captured")), .init("ticket", .string(ticket)),
                    .init("code", .number(Double(ran.code))), .init("argv", .array(argv.map(NativeRPCValue.string))), .init("stdout", .string(out))])
                _ = try? exchange(report, path: named)
                if !out.isEmpty { io.writeStdout(Data((out + "\n").utf8)) }
                return ran.code
            case "exit":
                guard (0...255).contains(response.code) else { throw BackendAccountFailure("The account vault returned an invalid security response.") }
                let out = stripTrailingNewlines(response.stdout)
                let err = response.stderr.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
                if !out.isEmpty { io.writeStdout(Data((out + "\n").utf8)) }
                if !err.isEmpty { io.writeStderr(Data((err + "\n").utf8)) }
                if response.code == 0, let receipts = response.lookupReceipts, !receipts.isEmpty {
                    let ack = NativeRPCValue.object([.init("operation", .string("lookup-ack")), .init("ticket", .string(ticket)),
                        .init("receipts", .array(receipts.map(NativeRPCValue.string)))])
                    guard try exchange(ack, path: named).code == 0 else { throw BackendAccountFailure("The credential reread was not accepted by its session owner.") }
                }
                return Int32(response.code)
            default:
                throw BackendAccountFailure("The account vault returned an invalid security response.")
            }
        } catch {
            // 4. The app did not answer. A session started on a login the agent
            // keeps itself goes to the real command, as it would have without the app.
            if environment[keys[2]] == "agent" { return io.passThrough(argv, piped) }
            // Anything naming one of the agent's own login items fails closed: a
            // lookup is "not found", a write or delete is refused. The rest is the real command.
            let text = argv.joined(separator: " ") + " " + input
            guard namesAgentLogin(text) else { return io.passThrough(argv, piped) }
            if text.contains("add-generic-password") || text.contains("delete-generic-password") {
                io.writeStderr(Data("security: the app that keeps this login is not answering, so nothing was changed.\n".utf8))
                return 1
            }
            io.writeStderr(Data((BackendAccountShimParsing.notFoundText + "\n").utf8))
            return BackendAccountShimParsing.exitNotFound
        }
    }

    /// TS `case "$* $INPUT" in *'Claude Code'*'-credentials'*|*'Claude Code-'[0-9a-f]{8}*)`.
    static func namesAgentLogin(_ text: String) -> Bool {
        text.range(of: "Claude Code[\\s\\S]*-credentials", options: .regularExpression) != nil
            || text.range(of: "Claude Code-[0-9a-f]{8}", options: .regularExpression) != nil
    }
    /// The shell's `$(...)`: trailing newlines removed.
    static func stripTrailingNewlines(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.unicodeScalars.last, last == "\n" { result = Substring(result.unicodeScalars.dropLast()) }
        return String(result)
    }

    /// One framed request and its framed answer, on a fresh same-UID connection.
    static func exchange(_ payload: NativeRPCValue, path: String) throws -> BackendAccountShimAnswer {
        var address = try AccountSocketIO.address(path)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw BackendAccountFailure("The account helper could not create its socket.") }
        defer { Darwin.close(socket) }
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        AccountSocketIO.socketOptions(socket)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw BackendAccountFailure("The native account vault is not answering.") }
        try AccountSocketIO.writeFrame(try payload.encodedJSON(), fd: socket)
        return try JSONDecoder().decode(BackendAccountShimAnswer.self, from: AccountSocketIO.readFrame(socket))
    }

    static func runReal(_ argv: [String], input: Data?, real: String = BackendAccountShimParsing.realSecurity) -> Int32 {
        if input == nil {
            let values = ([real] + argv).map { strdup($0) } + [nil]
            defer { for pointer in values { if let pointer { free(pointer) } } }
            values.withUnsafeBufferPointer { _ = execv(real, $0.baseAddress!) }
            return 1
        }
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: real); child.arguments = argv
        child.standardInput = pipe; child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
        do { try child.run(); try pipe.fileHandleForWriting.write(contentsOf: input!); try pipe.fileHandleForWriting.close(); child.waitUntilExit(); return child.terminationStatus }
        catch { if child.isRunning { child.terminate() }; return 1 }
    }
    static func captureReal(_ argv: [String], input: Data?, real: String = BackendAccountShimParsing.realSecurity) -> (code: Int32, stdout: Data) {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: real); child.arguments = argv
        child.standardOutput = output; child.standardError = FileHandle.standardError
        let pipe = input == nil ? nil : Pipe()
        if let pipe { child.standardInput = pipe }
        do { try child.run() } catch { return (1, Data()) }
        if let pipe, let input {
            let writer = pipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async { try? writer.write(contentsOf: input); try? writer.close() }
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return (child.terminationStatus, stdout)
    }
}
