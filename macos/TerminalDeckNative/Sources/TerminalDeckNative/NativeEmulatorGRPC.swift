import Foundation
import TerminalDeckNativeCore

// Finding 3, part B: the Android emulator's gRPC control port, spoken directly (EmulatorDirect.swift has
// the frame and message rules). Plain sockets and threads, no gRPC library: what the direct path needs and
// nothing more. Every frame from the emulator is checked; anything unexpected closes the connection, and
// the panel goes back to the device engine's video (screenrecord).

/// A plaintext HTTP/2 connection to the emulator's local gRPC port: a reading thread, ordered writes,
/// flow control both ways, header blocks skipped (a stream's end is its END_STREAM or a reset).
///
/// Writes never happen on the caller's thread: every frame is queued, in order, on one serial queue, so the
/// main thread never waits on the socket. The socket is written, shut and closed only under `socketLock`;
/// once closed its number is never used again (it may already belong to another file). A write that fails
/// or goes out only in part would leave a broken frame on the connection, so it shuts the connection; the
/// reading thread then ends it, every call ends, and the panel goes back to the device engine's video (screenrecord).
final class EmulatorGRPC: @unchecked Sendable {
    private struct Stream {
        var unpacker = GRPCMessage.Unpacker()
        var sendWindow: Int
        let message: @Sendable (Data) -> Void
        let ended: @Sendable (String) -> Void
    }

    private let fd: Int32
    private let authority: String
    private let token: String
    private let lock = NSLock()
    private var streams: [UInt32: Stream] = [:]
    private var nextStream: UInt32 = 1
    private var connectionWindow = 65_535
    private var peerInitialWindow = 65_535
    private var closed = false
    /// Messages waiting for the emulator to open its window again, in order, per call.
    private var backlog: [UInt32: [Data]] = [:]
    private static let backlogLimit = 512
    private let closedHandler: @Sendable (String) -> Void
    /// Every write, in the order it was queued; calls are queued under `lock`, so their numbers reach the
    /// wire in order and a call's messages always follow its headers.
    private let writer = DispatchQueue(label: "terminaldeck.emulator-grpc.write", qos: .userInteractive)
    private enum SocketState { case open, shut, closed }
    private let socketLock = NSLock()
    private var socketState = SocketState.open
    private var writeFailed = false
    /// What this side lets the emulator send before it says it has read it: ample for a PNG.
    private static let receiveWindow: UInt32 = 16 << 20

    private init(fd: Int32, port: Int, token: String, closed: @escaping @Sendable (String) -> Void) {
        self.fd = fd
        authority = "127.0.0.1:\(port)"
        self.token = token
        closedHandler = closed
    }

    /// Connects (two seconds at most) and starts reading. Never on the main thread.
    static func connect(port: Int, token: String, closed: @escaping @Sendable (String) -> Void) throws -> EmulatorGRPC {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EmulatorDirectError("No socket for the emulator.") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if started != 0 && errno != EINPROGRESS { Darwin.close(fd); throw EmulatorDirectError("The emulator's control port did not answer.") }
        var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var problem: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&wait, 1, 2_000) == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &problem, &size) == 0, problem == 0 else {
            Darwin.close(fd); throw EmulatorDirectError("The emulator's control port did not answer.")
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        // A write never waits long: an emulator that stops reading ends the direct path instead.
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connection = EmulatorGRPC(fd: fd, port: port, token: token, closed: closed)
        var hello = H2Frame.preface
        hello.append(H2Frame.settings([(0x2, 0), (0x4, receiveWindow)]).encoded)   // no push; a large window
        hello.append(H2Frame.windowUpdate(stream: 0, increment: receiveWindow - 65_535).encoded)
        guard connection.writeNow(hello) else {
            connection.close("hello")
            connection.closeSocket()   // the reading thread that would close it never started
            throw EmulatorDirectError("The emulator closed its control port.")
        }
        let thread = Thread { connection.readLoop() }
        thread.name = "terminaldeck.emulator-grpc"
        thread.qualityOfService = .userInteractive
        thread.start()
        return connection
    }

    /// Opens a call: its headers, and its first message when there is one. `last`: nothing more will be sent.
    @discardableResult
    func call(_ method: String, message: Data?, last: Bool, onMessage: @escaping @Sendable (Data) -> Void,
              onEnd: @escaping @Sendable (String) -> Void) -> UInt32? {
        let fields: [(String, String)] = [(":method", "POST"), (":scheme", "http"), (":path", EmulatorWire.service + method),
                                          (":authority", authority), ("content-type", "application/grpc"), ("te", "trailers"),
                                          ("authorization", "Bearer " + token), ("user-agent", "terminal-deck")]
        let block = H2Frame.headerBlock(fields)
        let id: UInt32? = lock.withLock {
            guard !closed else { return nil }
            let id = nextStream
            nextStream += 2
            streams[id] = Stream(sendWindow: peerInitialWindow, message: onMessage, ended: onEnd)
            queue(H2Frame(.headers, flags: H2Frame.endHeaders | (message == nil && last ? H2Frame.endStream : 0), stream: id,
                          payload: block).encoded)
            return id
        }
        guard let id else { return nil }
        if let message, !send(stream: id, message: message, last: last) { cancel(stream: id); return nil }
        return id
    }

    /// One more message on an open call, queued (never written on this thread). When the emulator's window
    /// is full it waits, in order, until the emulator opens it again; false only when the call is gone (or
    /// hopelessly behind). A write that then fails ends the whole connection.
    @discardableResult
    func send(stream id: UInt32, message: Data, last: Bool = false) -> Bool {
        let payload = GRPCMessage.wrap(message)
        guard payload.count <= 16_384 else { return false }
        // Queued under the lock: two messages can never overtake each other.
        return lock.withLock {
            guard !closed, var stream = streams[id] else { return false }
            let waiting = backlog[id] ?? []
            if !waiting.isEmpty || connectionWindow < payload.count || stream.sendWindow < payload.count {
                guard waiting.count < Self.backlogLimit else { return false }
                backlog[id] = waiting + [H2Frame(.data, flags: last ? H2Frame.endStream : 0, stream: id, payload: payload).encoded]
                return true
            }
            connectionWindow -= payload.count
            stream.sendWindow -= payload.count
            streams[id] = stream
            queue(H2Frame(.data, flags: last ? H2Frame.endStream : 0, stream: id, payload: payload).encoded)
            return true
        }
    }

    /// The emulator opened its window: what waited goes now, oldest first, as far as the window allows.
    private func flushBacklog() {
        lock.withLock {
            for id in Array(backlog.keys) {
                guard var stream = streams[id] else { backlog[id] = nil; continue }
                var waiting = backlog[id] ?? []
                while let frame = waiting.first {
                    let size = frame.count - 9
                    guard connectionWindow >= size, stream.sendWindow >= size else { break }
                    connectionWindow -= size
                    stream.sendWindow -= size
                    queue(frame)
                    waiting.removeFirst()
                }
                streams[id] = stream
                backlog[id] = waiting.isEmpty ? nil : waiting
            }
        }
    }

    /// Stops one call (the screen stream while the panel is hidden).
    func cancel(stream id: UInt32) {
        lock.withLock {
            backlog[id] = nil
            if streams.removeValue(forKey: id) != nil { queue(H2Frame(.reset, stream: id, payload: Data([0, 0, 0, 0x8])).encoded) }   // CANCEL
        }
    }

    func close(_ reason: String) {
        let (wasOpen, ending) = lock.withLock { () -> (Bool, [Stream]) in
            guard !closed else { return (false, []) }
            closed = true
            let all = Array(streams.values)
            streams = [:]
            return (true, all)
        }
        guard wasOpen else { return }
        shutdownSocket()
        for stream in ending { stream.ended(reason) }
        closedHandler(reason)
    }

    // MARK: Inside

    /// Onto the write queue, in order. The caller may hold `lock`; nothing here waits.
    private func queue(_ data: Data) {
        writer.async { [self] in _ = writeNow(data) }
    }

    /// The whole frame or nothing more on this connection: a failed or partial write shuts the socket,
    /// and the reading thread ends the connection. Never on the main thread (connect, and the write queue).
    private func writeNow(_ data: Data) -> Bool {
        socketLock.withLock {
            guard socketState == .open else { return false }
            let whole = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let sent = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if sent <= 0 { return false }
                    offset += sent
                }
                return true
            }
            if !whole {
                writeFailed = true
                socketState = .shut
                shutdown(fd, SHUT_RDWR)
            }
            return whole
        }
    }

    /// Wakes the reading thread; the socket stays open (its number stays ours) until that thread closes it.
    private func shutdownSocket() {
        socketLock.withLock {
            guard socketState == .open else { return }
            socketState = .shut
            shutdown(fd, SHUT_RDWR)
        }
    }

    /// Only once, under the same lock as every write: no write can reach a number the system has reused.
    private func closeSocket() {
        socketLock.withLock {
            guard socketState != .closed else { return }
            socketState = .closed
            Darwin.close(fd)
        }
    }

    private func readLoop() {
        var parser = H2FrameParser()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else {
                let ours = socketLock.withLock { writeFailed }
                close(ours ? "The emulator stopped taking what this app sends." : "The emulator closed its control port.")
                break
            }
            for frame in parser.push(Data(buffer[0..<count])) { handle(frame) }
            if parser.failed { close("The emulator sent a frame this app cannot read."); break }
            if lock.withLock({ closed }) { break }
        }
        closeSocket()
    }

    private func handle(_ frame: H2Frame) {
        switch frame.kind {
        case .settings:
            guard frame.flags & H2Frame.ack == 0 else { return }
            for (identifier, value) in frame.settingsPairs where identifier == 0x4 && value <= 0x7FFF_FFFF {
                lock.withLock {
                    let delta = Int(value) - peerInitialWindow
                    peerInitialWindow = Int(value)
                    for key in streams.keys { streams[key]?.sendWindow += delta }
                }
            }
            flushBacklog()
            queue(H2Frame(.settings, flags: H2Frame.ack).encoded)
        case .ping:
            if frame.flags & H2Frame.ack == 0, frame.payload.count == 8 { queue(H2Frame(.ping, flags: H2Frame.ack, payload: frame.payload).encoded) }
        case .windowUpdate:
            guard let increment = frame.windowIncrement else { return }
            lock.withLock {
                if frame.stream == 0 { connectionWindow += Int(increment) } else { streams[frame.stream]?.sendWindow += Int(increment) }
            }
            flushBacklog()
        case .data:
            guard let bytes = frame.dataBytes else { close("The emulator sent a broken frame."); return }
            if !frame.payload.isEmpty {
                var updates = H2Frame.windowUpdate(stream: 0, increment: UInt32(frame.payload.count)).encoded
                if frame.flags & H2Frame.endStream == 0 { updates.append(H2Frame.windowUpdate(stream: frame.stream, increment: UInt32(frame.payload.count)).encoded) }
                queue(updates)
            }
            let delivery: (messages: [Data], stream: Stream?, failed: Bool) = lock.withLock {
                guard var stream = streams[frame.stream] else { return ([], nil, false) }
                let messages = stream.unpacker.push(bytes)
                let failed = stream.unpacker.failed
                streams[frame.stream] = stream
                return (messages, stream, failed)
            }
            if let stream = delivery.stream { for message in delivery.messages { stream.message(message) } }
            if delivery.failed { end(frame.stream, "The emulator sent a message this app cannot read.") }
            else if frame.flags & H2Frame.endStream != 0 { end(frame.stream, "The emulator ended the call.") }
        case .headers:
            if frame.flags & H2Frame.endStream != 0 { end(frame.stream, "The emulator ended the call.") }
        case .reset:
            end(frame.stream, "The emulator stopped the call.")
        case .goAway:
            close("The emulator is closing its control port.")
        case .pushPromise:
            close("The emulator pushed a stream that was never asked for.")
        default:
            break   // PRIORITY, CONTINUATION (header blocks are not read), unknown kinds
        }
    }

    private func end(_ id: UInt32, _ reason: String) {
        let stream = lock.withLock { backlog[id] = nil; return streams.removeValue(forKey: id) }
        stream?.ended(reason)
    }
}

struct EmulatorDirectError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A one-way flag set on the gRPC reading thread when the first screenshot's bytes arrive and read when the
/// call ends on that same thread: it tells a call that produced a picture apart from one that produced
/// nothing, so a unary reply's normal END_STREAM is not read as a failure (the NativeDeviceDirectEmulator race).
final class GotFirstScreenshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

