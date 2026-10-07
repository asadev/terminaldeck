import Foundation
import Darwin
import TerminalDeckNativeCore

/// Original native implementation of OpenSSH PROTOCOL.mux §9 and RFC 4254.
/// This only attaches to the supplied, already authenticated local master.
/// It does not dial a remote host, change host-key policy, or invoke a wrapper.
/// Primary protocol: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.mux
/// Exit requests are forwarded by clientloop.c/channel_proxy_upstream before
/// the ordinary OpenSSH client handler: RFC 4254 §6.10 preserves the signal.
public final class BackendServersSSHProxy: @unchecked Sendable {
    private let controlSocket: URL
    private let isCurrent: @Sendable () -> Bool
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "native.servers.ssh-proxy", qos: .utility)
    private var descriptor: Int32 = -1
    private var stopped = false
    private var active = false
    private var cancelled = false
    private var generation: UUID?
    private var activeFollow: BackendServersSSHProxyFollow?
    public init(controlSocket: URL, isCurrent: @escaping @Sendable () -> Bool) {
        self.controlSocket = controlSocket; self.isCurrent = isCurrent
    }
    public func execute(command: String, stdin: Data?, timeoutMilliseconds: Int = 30_000,
                        maximumOutputBytes: Int = 4 * 1024 * 1024) async throws -> BackendServersRunResult {
        try Task.checkCancellation()
        let state = try BackendServersSSHProxySession(command: command, stdin: stdin ?? Data(), maximumOutputBytes: maximumOutputBytes)
        guard (1...30_000).contains(timeoutMilliseconds) else { throw NativeRPCError.invalidArguments("An SSH command deadline must be between 1 and 30000 milliseconds.") }
        let attempt = UUID()
        try lock.withLock {
            guard !stopped else { throw Self.lost() }
            guard !active else { throw NativeRPCError(code: "unavailable", message: "This SSH proxy already has a command open.") }
            active = true; cancelled = false; generation = attempt
        }
        defer { lock.withLock { if generation == attempt { active = false; generation = nil } } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do { continuation.resume(returning: try drive(state, timeoutMilliseconds: timeoutMilliseconds)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { [self] in cancelCurrent(attempt) }
    }
    /// Shutdown wakes a pending connect, poll, read or write. The worker alone
    /// closes the descriptor, preventing close/reuse races with another thread.
    public func close() {
        let follow = lock.withLock { stopped = true; if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }; return activeFollow }
        follow?.wakeAborted()
    }
    private func cancelCurrent(_ attempt: UUID) {
        let follow = lock.withLock { () -> BackendServersSSHProxyFollow? in guard generation == attempt else { return nil }; cancelled = true; if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }; return activeFollow }
        follow?.wakeAborted()
    }
    public func follow(command: String, maximumStderrBytes: Int = 8192) async throws -> any BackendServersFollow {
        try Task.checkCancellation()
        let state = try BackendServersSSHProxySession(command: command, stdin: Data(), maximumOutputBytes: 4 * 1024 * 1024, streaming: true, maximumStderrBytes: maximumStderrBytes)
        let attempt = UUID()
        let stream = BackendServersSSHProxyFollow { [weak self] in self?.close() }
        try lock.withLock {
            guard !stopped else { throw Self.lost() }
            guard !active else { throw NativeRPCError(code: "unavailable", message: "This SSH proxy already has a channel open.") }
            active = true; cancelled = false; generation = attempt; activeFollow = stream
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        var opened = false
                        defer { lock.withLock { if generation == attempt { active = false; generation = nil; activeFollow = nil } } }
                        do {
                            let result = try drive(state, timeoutMilliseconds: 30_000, stream: stream) {
                                opened = true; continuation.resume(returning: stream)
                            }
                            stream.finish(.init(code: result.code, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                        } catch {
                            if !opened { continuation.resume(throwing: error) }
                            // drive supplies the bounded complaint on a dropped
                            // or cancelled already-open follow channel.
                        }
                    }
                }
            } onCancel: { [self] in cancelCurrent(attempt) }
        } catch {
            lock.withLock { if generation == attempt && descriptor < 0 { active = false; generation = nil; activeFollow = nil } }
            throw error
        }
    }
    private static func lost() -> BackendServersProblem { .init("lost", "That connection is gone.") }
    private func check(_ deadline: UInt64?) throws {
        let flags = lock.withLock { (stopped, cancelled) }
        if flags.1 { throw CancellationError() }
        guard !flags.0, isCurrent() else { throw Self.lost() }
        if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline {
            throw BackendServersProblem("no-answer", "The server started that but never finished it, so it was stopped.")
        }
    }
    private func connect(_ deadline: UInt64) throws -> Int32 {
        try check(deadline)
        let path = controlSocket.path
        guard controlSocket.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else { throw NativeRPCError.invalidArguments("The SSH control socket must be an absolute local path.") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw NativeRPCError.invalidArguments("The SSH control socket path is too long.") }
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFSOCK, metadata.st_uid == geteuid(), (metadata.st_mode & 0o077) == 0 else {
            throw NativeRPCError(code: "unavailable", message: "The private SSH proxy control socket is unavailable.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.initializeMemory(as: UInt8.self, repeating: 0); raw.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.lost() }
        do {
            let flags = Darwin.fcntl(fd, F_GETFL)
            guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Self.lost() }
            var yes: Int32 = 1
            guard Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Self.lost() }
            try lock.withLock {
                if cancelled { throw CancellationError() }; guard !stopped else { throw Self.lost() }; descriptor = fd
            }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if result != 0 {
                guard errno == EINPROGRESS else { throw Self.lost() }
                while true {
                    try check(deadline); let events = try wait(fd, readable: false, writable: true, deadline: deadline)
                    if events & Int16(POLLOUT | POLLERR | POLLHUP) == 0 { continue }
                    var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw Self.lost() }; break
                }
            }
            var peerUID: uid_t = 0; var peerGID: gid_t = 0
            guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else { throw NativeRPCError(code: "unavailable", message: "The SSH proxy socket belongs to a different account.") }
            try check(deadline); return fd
        } catch {
            lock.withLock { if descriptor == fd { descriptor = -1 } }; Darwin.close(fd); throw error
        }
    }
    private func wait(_ fd: Int32, readable: Bool, writable: Bool, deadline: UInt64?) throws -> Int16 {
        try check(deadline)
        var item = pollfd(fd: fd, events: Int16((readable ? POLLIN : 0) | (writable ? POLLOUT : 0)), revents: 0)
        let timeout: Int32
        if let deadline {
            let remaining = (deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000
            timeout = Int32(min(100, max(1, remaining)))
        } else { timeout = -1 } // A quiet follow wakes on fd readiness/shutdown.
        let result = Darwin.poll(&item, 1, timeout)
        if result < 0 { if errno == EINTR { return 0 }; throw Self.lost() }
        try check(deadline); if item.revents & Int16(POLLNVAL) != 0 { throw Self.lost() }; return item.revents
    }
    private func drive(_ initial: BackendServersSSHProxySession, timeoutMilliseconds: Int,
                       stream: BackendServersSSHProxyFollow? = nil, ready: (() -> Void)? = nil) throws -> BackendServersRunResult {
        var session = initial; var framer = BackendServersSSHProxyFramer()
        let openingDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        var deadline: UInt64? = openingDeadline
        var announced = false
        var fd: Int32 = -1
        defer {
            lock.withLock { if descriptor == fd { descriptor = -1 } }
            if fd >= 0 { Darwin.close(fd) }
        }
        fd = try connect(openingDeadline)
        var pending = [session.begin()]; var offset = 0; var scratch = [UInt8](repeating: 0, count: 32_768)
        do { while true {
            try check(deadline)
            if pending.isEmpty, let input = try session.nextInput() { pending.append(input) }
            if session.finished && pending.isEmpty { return session.result }
            if let stream, announced, pending.isEmpty, !stream.canReceive { stream.waitForDemand(); try check(deadline) }
            // Drain queued credit replies before reading another large burst;
            // this bounds a peer sending many very small data packets.
            let reading = !session.finished && pending.count < 256 && (!announced || (stream?.canReceive ?? true))
            let events = try wait(fd, readable: reading, writable: !pending.isEmpty, deadline: deadline)
            if session.finished && events & Int16(POLLHUP) != 0 { return session.result }
            if events & Int16(POLLIN | POLLHUP) != 0, reading {
                let count = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    for frame in try framer.feed(Data(scratch.prefix(count))) {
                        // A lost/replaced authenticated master never gets a new
                        // channel-open or exec, even between two frames.
                        try check(deadline)
                        pending += try session.receive(frame)
                        if let stream {
                            for bytes in session.takeStreamedStdout() { try stream.push(bytes) }
                            if session.execAccepted && !announced { announced = true; deadline = nil; ready?() }
                        }
                        guard pending.count <= 4096 else { throw BackendServersSSHProxyWire.invalid("too many pending channel replies") }
                    }
                } else if count == 0 { throw Self.lost() }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Self.lost() }
            }
            if events & Int16(POLLOUT) != 0, let first = pending.first {
                try check(deadline)
                let count = first.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress!.advanced(by: offset), first.count - offset) }
                if count > 0 { offset += count; if offset == first.count { pending.removeFirst(); offset = 0 } }
                else if count == 0 { throw Self.lost() }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Self.lost() }
            }
            if events & Int16(POLLERR) != 0 { throw Self.lost() }
        } } catch {
            if let stream, announced { stream.finish(.init(code: nil, stderr: session.followStderr)) }
            throw error
        }
    }
}

/// All frame/state parsing is pure, so tests exercise actual encoded packets
/// without executing a product, connecting a socket, or simulating a signal.
enum BackendServersSSHProxyWire {
    static let maximumFrame = 1_048_576
    static func invalid(_ why: String) -> NativeRPCError { .init(code: "ssh-proxy-protocol", message: "The SSH proxy sent an invalid packet: \(why).") }
    static func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "This SSH master does not provide the native proxy protocol required to preserve remote exit signals.") }
    static func u32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    static func string(_ data: Data) -> Data { u32(UInt32(data.count)) + data }
    static func string(_ text: String) -> Data { string(Data(text.utf8)) }
    static func frame(_ body: Data) -> Data { u32(UInt32(body.count)) + body }
    static func ssh(_ type: UInt8, _ payload: Data) -> Data { frame(Data([0, type]) + payload) }
    struct Reader {
        let data: Data; var offset = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - offset }
        mutating func byte() throws -> UInt8 { guard remaining >= 1 else { throw invalid("short byte") }; defer { offset += 1 }; return data[data.startIndex + offset] }
        mutating func uint32() throws -> UInt32 { guard remaining >= 4 else { throw invalid("short integer") }; var value: UInt32 = 0; for _ in 0..<4 { value = (value << 8) | UInt32(try byte()) }; return value }
        mutating func bytes() throws -> Data { let length = Int(try uint32()); guard length <= remaining else { throw invalid("string length") }; defer { offset += length }; return Data(data[(data.startIndex + offset)..<(data.startIndex + offset + length)]) }
        mutating func text() throws -> String { let raw = try bytes(); guard let s = String(data: raw, encoding: .utf8), !raw.contains(0) else { throw invalid("invalid text") }; return s }
        mutating func boolean() throws -> Bool { try byte() != 0 }
        func end() throws { guard remaining == 0 else { throw invalid("unexpected trailing data") } }
    }
}

struct BackendServersSSHProxyFramer {
    private var buffered = Data()
    mutating func feed(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= BackendServersSSHProxyWire.maximumFrame + 4 else { throw BackendServersSSHProxyWire.invalid("oversize socket chunk") }
        buffered.append(bytes); var frames: [Data] = []; var used = 0
        while buffered.count - used >= 4 {
            var reader = BackendServersSSHProxyWire.Reader(Data(buffered[(buffered.startIndex + used)..<(buffered.startIndex + used + 4)]))
            let size = Int(try reader.uint32())
            guard size >= 2, size <= BackendServersSSHProxyWire.maximumFrame else { throw BackendServersSSHProxyWire.invalid("frame length outside limits") }
            if buffered.count - used < size + 4 { break }
            frames.append(Data(buffered[(buffered.startIndex + used + 4)..<(buffered.startIndex + used + 4 + size)])); used += size + 4
        }
        if used > 0 { buffered.removeFirst(used) }
        guard buffered.count <= BackendServersSSHProxyWire.maximumFrame + 4 else { throw BackendServersSSHProxyWire.invalid("unbounded partial packet") }
        return frames
    }
}

struct BackendServersSSHProxySession {
    private enum Phase: Equatable { case hello, proxy, opening, exec, running, closed }
    private var phase: Phase = .hello
    private let command: String, input: Data, maximumOutput: Int
    private let streaming: Bool, maximumStderr: Int
    private var streamedStdout: [Data] = []
    private(set) var execAccepted = false
    private let commandBytes: Int
    private var commandCursor: String.UTF8View.Index? = nil
    private var inputOffset = 0, sentEOF = false, receivedEOF = false
    private var remote: UInt32?, remoteWindow: UInt32 = 0, remotePacket: UInt32 = 0
    private var localWindow: UInt32 = receiveWindow
    private var output = Data(), errorOutput = Data(), truncated = false
    private var exitCode: UInt32?, exitSignal: String?
    static let receiveWindow: UInt32 = 1_048_576
    static let maximumPacket: UInt32 = 32_768
    init(command: String, stdin: Data, maximumOutputBytes: Int, streaming: Bool = false, maximumStderrBytes: Int = 8192) throws {
        let count = command.utf8.count
        // The unpadded exec packet has 19 bytes before the command. Its wire
        // length is uint32; large commands are streamed, not copied as a frame.
        guard count <= Int(UInt32.max) - 19 else { throw NativeRPCError.invalidArguments("The SSH exec request exceeds its uint32 packet-length field.") }
        guard maximumOutputBytes > 0, maximumOutputBytes <= 4 * 1024 * 1024 else { throw NativeRPCError.invalidArguments("SSH output is limited to 4 MiB for one command.") }
        guard (0...8192).contains(maximumStderrBytes) else { throw NativeRPCError.invalidArguments("SSH follow stderr is limited to 8192 bytes.") }
        self.command = command; commandBytes = count; input = stdin; maximumOutput = maximumOutputBytes; self.streaming = streaming; maximumStderr = maximumStderrBytes
    }
    var finished: Bool { phase == .closed }
    var retainedOutputBytes: Int { output.count + errorOutput.count }
    var followStderr: String { String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    mutating func takeStreamedStdout() -> [Data] { let chunks = streamedStdout; streamedStdout.removeAll(keepingCapacity: true); return chunks }
    var result: BackendServersRunResult { .init(code: exitSignal == nil ? exitCode.map(Int.init) : nil, signal: exitSignal, stdout: String(decoding: output, as: UTF8.self), stderr: String(decoding: errorOutput, as: UTF8.self), truncated: truncated) }
    func begin() -> Data { BackendServersSSHProxyWire.frame(BackendServersSSHProxyWire.u32(1) + BackendServersSSHProxyWire.u32(4)) }
    mutating func receive(_ packet: Data) throws -> [Data] {
        let w = BackendServersSSHProxyWire.self; var r = BackendServersSSHProxyWire.Reader(packet)
        if phase == .hello {
            guard try r.uint32() == 1, try r.uint32() == 4 else { throw w.unavailable() }
            while r.remaining > 0 { _ = try r.text(); _ = try r.bytes() }
            phase = .proxy; return [w.frame(w.u32(0x1000000f) + w.u32(1))]
        }
        if phase == .proxy {
            let type = try r.uint32(), request = try r.uint32()
            guard request == 1 else { throw w.invalid("mux request identifier") }
            guard type == 0x8000000f else { throw w.unavailable() }; try r.end(); phase = .opening
            return [w.ssh(90, w.string("session") + w.u32(0) + w.u32(Self.receiveWindow) + w.u32(Self.maximumPacket))]
        }
        guard phase != .closed, try r.byte() == 0 else { throw w.invalid("padding or closed channel") }
        let type = try r.byte()
        if type == 90 { // Never accept a reverse session/agent/X11/forwarding.
            _ = try r.text(); let sender = try r.uint32(); _ = try r.uint32(); _ = try r.uint32()
            return [w.ssh(92, w.u32(sender) + w.u32(1) + w.string("This proxy did not request that channel.") + w.string(""))]
        }
        if type == 80 { _ = try r.text(); let reply = try r.boolean(); return reply ? [w.ssh(82, Data())] : [] }
        guard try r.uint32() == 0 else { throw w.invalid("recipient channel identifier") }
        if type == 91 {
            guard phase == .opening else { throw w.invalid("unexpected channel confirmation") }
            remote = try r.uint32(); remoteWindow = try r.uint32(); remotePacket = try r.uint32(); try r.end()
            guard remotePacket > 0 else { throw w.invalid("zero remote packet size") }
            phase = .exec
            let prefix = Data([0, 98]) + w.u32(remote!) + w.string("exec") + Data([1]) + w.u32(UInt32(commandBytes))
            if commandBytes <= Int(Self.maximumPacket) { return [w.frame(prefix + Data(command.utf8))] }
            commandCursor = command.utf8.startIndex
            return [w.u32(UInt32(commandBytes + 19)) + prefix]
        }
        if type == 92 {
            guard phase == .opening else { throw w.invalid("unexpected open failure") }
            let reason = try r.uint32(), description = try r.text(); _ = try r.text(); try r.end()
            throw BackendServersProblem("lost", description.isEmpty ? "The server refused to open that command (\(reason))." : "The server refused to open that command: \(description)")
        }
        guard let remote else { throw w.invalid("channel packet before confirmation") }
        switch type {
        case 93:
            let credit = try r.uint32(); try r.end()
            let addition = remoteWindow.addingReportingOverflow(credit); guard !addition.overflow else { throw w.invalid("remote window overflow") }; remoteWindow = addition.partialValue
        case 99:
            guard phase == .exec, commandCursor == nil else { throw w.invalid("unexpected request success") }; try r.end(); phase = .running; execAccepted = true
        case 100:
            guard phase == .exec else { throw w.invalid("unexpected request failure") }; try r.end(); throw BackendServersProblem("lost", "The server refused to start that command.")
        case 94, 95:
            guard phase == .running || phase == .exec, !receivedEOF else { throw w.invalid("data outside an open stream") }
            let extended = type == 95 ? try r.uint32() : 0
            let data = try r.bytes(); try r.end()
            guard data.count <= Int(Self.maximumPacket), data.count <= Int(localWindow) else { throw w.invalid("receive window or packet exceeded") }
            localWindow -= UInt32(data.count)
            if type == 94 || extended == 1 { take(data, stderr: type == 95) }
            localWindow += UInt32(data.count)
            return data.isEmpty ? [] : [w.ssh(93, w.u32(remote) + w.u32(UInt32(data.count)))]
        case 96: try r.end(); receivedEOF = true
        case 97:
            guard phase == .running else { throw BackendServersProblem("lost", "The server closed that command before it started.") }
            try r.end(); phase = .closed; return [w.ssh(97, w.u32(remote))]
        case 98:
            let name = try r.text(), reply = try r.boolean(); var accepted = false
            if name == "exit-status" {
                let status = try r.uint32(); try r.end()
                if exitCode == nil && exitSignal == nil { exitCode = status }; accepted = true
            }
            else if name == "exit-signal" {
                let signal = try r.text(); _ = try r.boolean(); _ = try r.text(); _ = try r.text(); try r.end()
                guard !signal.isEmpty, signal.utf8.count <= 256 else { throw w.invalid("exit signal name") }
                // ssh2's public close callback uses SIG + the RFC wire name.
                // The source ignores later exit records after the first one.
                if exitCode == nil && exitSignal == nil { exitSignal = "SIG" + signal }; accepted = true
            }
            else if name == "eow@openssh.com" { try r.end(); accepted = true }
            return reply ? [w.ssh(accepted ? 99 : 100, w.u32(remote))] : []
        default: throw w.invalid("unsupported channel message \(type)")
        }
        return []
    }
    private mutating func take(_ data: Data, stderr: Bool) {
        if streaming {
            if stderr { errorOutput.append(contentsOf: data.prefix(max(0, maximumStderr - errorOutput.count))) }
            else if !data.isEmpty { streamedStdout.append(data) }
            return
        }
        // Match source connection.ts: test the aggregate before accepting the
        // whole chunk. One final packet can cross the threshold; truncated is
        // set only when a later chunk is discarded. Packet validation bounds
        // that overshoot to maximumPacket - 1 bytes.
        guard output.count + errorOutput.count < maximumOutput else { truncated = true; return }
        if stderr { errorOutput.append(data) } else { output.append(data) }
    }
    mutating func nextInput() throws -> Data? {
        if phase == .exec, let cursor = commandCursor {
            let text = command.utf8
            let end = text.index(cursor, offsetBy: Int(Self.maximumPacket), limitedBy: text.endIndex) ?? text.endIndex
            commandCursor = end == text.endIndex ? nil : end
            return Data(text[cursor..<end])
        }
        guard phase == .running, let remote, !sentEOF else { return nil }
        let w = BackendServersSSHProxyWire.self
        if inputOffset == input.count { sentEOF = true; return w.ssh(96, w.u32(remote)) }
        guard remoteWindow > 0 else { return nil }
        let size = min(min(input.count - inputOffset, Int(remoteWindow)), min(Int(remotePacket), Int(Self.maximumPacket)))
        let data = Data(input[(input.startIndex + inputOffset)..<(input.startIndex + inputOffset + size)])
        inputOffset += size; remoteWindow -= UInt32(size)
        return w.ssh(94, w.u32(remote) + w.string(data))
    }
}

/// Subscriber callbacks are serialized with producer delivery, including the
/// first bounded pre-subscription bytes. Delivered stdout has no history/cap.
/// NSCondition supplies subscription/close wakeups without a timer or polling.
final class BackendServersSSHProxyFollow: BackendServersFollow, @unchecked Sendable {
    private let state = NSLock(), delivery = NSRecursiveLock(), demand = NSCondition()
    private let abortProxy: @Sendable () -> Void
    private var byteListeners: [UUID: @Sendable (Data) -> Void] = [:]
    private var endListeners: [UUID: @Sendable (BackendServersFollowEnd) -> Void] = [:]
    private var pending = Data()
    private var end: BackendServersFollowEnd?
    private var closedLocal = false, aborted = false
    static let demandHighWater = 65_536
    static let maximumPendingBytes = 131_072
    init(abortProxy: @escaping @Sendable () -> Void) { self.abortProxy = abortProxy }
    var pendingByteCount: Int { state.withLock { pending.count } }
    var canReceive: Bool { state.withLock { aborted || !byteListeners.isEmpty || pending.count < Self.demandHighWater } }
    func waitForDemand() {
        demand.lock(); defer { demand.unlock() }
        while !canReceive { demand.wait() }
    }
    private func wake() { demand.lock(); demand.broadcast(); demand.unlock() }
    func wakeAborted() { state.withLock { aborted = true }; wake() }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe {
        let id = UUID()
        delivery.withLock {
            let initial = state.withLock { () -> Data in
                guard !closedLocal else { return Data() }
                if end == nil { byteListeners[id] = listener }
                let bytes = pending; pending = Data(); return bytes
            }
            if !initial.isEmpty { listener(initial) }
        }
        wake()
        return { [weak self] in _ = self?.state.withLock { self?.byteListeners.removeValue(forKey: id) } }
    }
    func onEnd(_ listener: @escaping @Sendable (BackendServersFollowEnd) -> Void) -> BackendServersUnsubscribe {
        let id = UUID()
        delivery.withLock {
            let already = state.withLock { () -> BackendServersFollowEnd? in
                if closedLocal { return nil }
                if let end { return end }
                endListeners[id] = listener; return nil
            }
            if let already { listener(already) }
        }
        return { [weak self] in _ = self?.state.withLock { self?.endListeners.removeValue(forKey: id) } }
    }
    func push(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        try delivery.withLock {
            let listeners = try state.withLock { () throws -> [@Sendable (Data) -> Void] in
                guard !closedLocal, end == nil else { return [] }
                if byteListeners.isEmpty {
                    guard pending.count + bytes.count <= Self.maximumPendingBytes else { throw BackendServersSSHProxyWire.invalid("pre-subscriber output exceeded its bounded queue") }
                    pending.append(bytes); return []
                }
                return Array(byteListeners.values)
            }
            for listener in listeners { listener(bytes) }
        }
    }
    func finish(_ value: BackendServersFollowEnd) {
        delivery.withLock {
            let listeners = state.withLock { () -> [@Sendable (BackendServersFollowEnd) -> Void] in
                guard !closedLocal, end == nil else { return [] }
                end = value; byteListeners.removeAll()
                let callbacks = Array(endListeners.values); endListeners.removeAll(); return callbacks
            }
            for listener in listeners { listener(value) }
        }
        wakeAborted()
    }
    func close() {
        let first = state.withLock { () -> Bool in
            guard !closedLocal, end == nil else { return false }
            closedLocal = true; pending = Data(); byteListeners.removeAll(); endListeners.removeAll(); return true
        }
        if first { abortProxy(); wakeAborted() }
    }
}
