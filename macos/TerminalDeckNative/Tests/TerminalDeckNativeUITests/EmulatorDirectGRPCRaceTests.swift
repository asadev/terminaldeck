import Darwin
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Finding 6 (Asad, 23 Oct 2026): the Android emulator's direct path failed on every call and dropped to the
/// slower engine video (the ~20 s typing lag). The cause was a client-side race, not the emulator: a gRPC unary
/// reply (`getScreenshot`) always ends by closing the call — END_STREAM on its trailing headers — so `onEnd`
/// fires even on a fully successful reply. `onMessage` prepared the picture off the main thread (two queue
/// hops) while `onEnd` reached the main thread in one, so the end won the race and killed the path before the
/// picture was ever kept. The fix sets `GotFirstScreenshot` the instant the bytes arrive on the reading thread
/// — before `onEnd` runs on that same thread — so a delivered screenshot is never mistaken for an empty call.
///
/// These tests drive the real `EmulatorGRPC` over a loopback socket speaking scripted HTTP/2, with no emulator
/// and no GPU. They prove the two cases the fix turns on: a reply that delivers a message then closes (must be
/// kept), and a reply that closes with no message (a real failure to report).
@Suite struct EmulatorDirectGRPCRaceTests {
    @Test func aDeliveredScreenshotIsKeptEvenThoughTheCallThenCloses() throws {
        let server = try H2LoopbackServer()
        defer { server.stop() }
        server.serve(.unaryMessage(Data([9, 8, 7, 6])))

        let sink = EventSink()
        let flag = GotFirstScreenshot()
        let grpc = try EmulatorGRPC.connect(port: server.port, token: "tok") { reason in sink.closed(reason) }
        defer { grpc.close("test over") }

        grpc.call("getScreenshot", message: Data([1, 2, 3]), last: true,
                  onMessage: { data in flag.set(); sink.message(data) },
                  onEnd: { reason in sink.end(reason, flagSet: flag.isSet) })

        #expect(sink.waitForEnd(timeout: 3))
        // The reply's bytes were delivered whole, before the call closed.
        #expect(sink.messages == [Data([9, 8, 7, 6])])
        let end = try #require(sink.ended)
        // The crux of the fix: by the time the call's close reaches `onEnd`, the screenshot's arrival is
        // already recorded — so the path is NOT torn down. The old `frames == nil` check ran first and lost.
        #expect(end.flagSet == true)
        #expect(sink.messageSeenBeforeEnd)
    }

    @Test func anEmptyCallWithNoMessageIsReportedAsAFailure() throws {
        let server = try H2LoopbackServer()
        defer { server.stop() }
        server.serve(.trailersOnly)

        let sink = EventSink()
        let flag = GotFirstScreenshot()
        let grpc = try EmulatorGRPC.connect(port: server.port, token: "tok") { reason in sink.closed(reason) }
        defer { grpc.close("test over") }

        grpc.call("getScreenshot", message: Data([1, 2, 3]), last: true,
                  onMessage: { data in flag.set(); sink.message(data) },
                  onEnd: { reason in sink.end(reason, flagSet: flag.isSet) })

        #expect(sink.waitForEnd(timeout: 3))
        #expect(sink.messages.isEmpty)
        let end = try #require(sink.ended)
        // No screenshot arrived: the flag is clear, so `onEnd` correctly reports the empty call as a failure
        // (a refused token, an old emulator) — the visible state, never a silent drop.
        #expect(end.flagSet == false)
    }
}

/// Collects what the call reported, across the reading thread and the main thread, and lets the test wait.
private final class EventSink: @unchecked Sendable {
    struct End { let reason: String; let flagSet: Bool }
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var _messages: [Data] = []
    private var _ended: End?
    private var _messageBeforeEnd = false

    func message(_ data: Data) { lock.withLock { _messages.append(data) } }
    func end(_ reason: String, flagSet: Bool) {
        lock.withLock {
            _messageBeforeEnd = !_messages.isEmpty
            _ended = End(reason: reason, flagSet: flagSet)
        }
        done.signal()
    }
    func closed(_ reason: String) {}

    func waitForEnd(timeout: TimeInterval) -> Bool { done.wait(timeout: .now() + timeout) == .success }
    var messages: [Data] { lock.withLock { _messages } }
    var ended: End? { lock.withLock { _ended } }
    var messageSeenBeforeEnd: Bool { lock.withLock { _messageBeforeEnd } }
}

/// A tiny HTTP/2 server on 127.0.0.1 that accepts one connection, reads past the client's preface until the
/// request's HEADERS frame, then writes one scripted gRPC reply on that stream. Enough to exercise the real
/// client; it validates nothing about the request beyond "a call was opened".
private final class H2LoopbackServer: @unchecked Sendable {
    enum Reply { case unaryMessage(Data), trailersOnly }

    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var connFD: Int32 = -1
    private var stopped = false

    init() throws {
        // All work on a local fd, so no stored member is read by a closure before init finishes.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("no socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0   // the OS picks a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { Darwin.close(fd); throw Failure("bind/listen") }
        var named = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard gotName == 0 else { Darwin.close(fd); throw Failure("getsockname") }
        listenFD = fd
        port = Int(UInt16(bigEndian: named.sin_port))
    }

    func serve(_ reply: Reply) {
        let thread = Thread { [self] in accept(reply) }
        thread.name = "test.h2-loopback"
        thread.start()
    }

    func stop() {
        lock.withLock {
            stopped = true
            if connFD >= 0 { Darwin.close(connFD); connFD = -1 }
            Darwin.close(listenFD)
        }
    }

    private func accept(_ reply: Reply) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        lock.withLock { if stopped { Darwin.close(fd) } else { connFD = fd } }
        if lock.withLock({ stopped }) { return }

        // Read past the 24-byte connection preface, then parse frames until the request's HEADERS arrives.
        var parser = H2FrameParser()
        var prefaceLeft = 24
        var requestStream: UInt32?
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while requestStream == nil {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            var data = Data(buffer[0..<count])
            if prefaceLeft > 0 {
                let drop = min(prefaceLeft, data.count)
                data.removeFirst(drop)
                prefaceLeft -= drop
            }
            for frame in parser.push(data) where frame.kind == .headers {
                requestStream = frame.stream
                break
            }
        }
        guard let stream = requestStream else { return }

        var out = Data()
        out.append(H2Frame(.settings).encoded)
        out.append(H2Frame(.headers, flags: H2Frame.endHeaders, stream: stream,
                           payload: H2Frame.headerBlock([(":status", "200"), ("content-type", "application/grpc")])).encoded)
        if case let .unaryMessage(message) = reply {
            out.append(H2Frame(.data, stream: stream, payload: GRPCMessage.wrap(message)).encoded)
        }
        out.append(H2Frame(.headers, flags: H2Frame.endHeaders | H2Frame.endStream, stream: stream,
                           payload: H2Frame.headerBlock([("grpc-status", "0")])).encoded)
        _ = out.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if sent <= 0 { break }
                offset += sent
            }
            return offset
        }
        // Keep the connection open; the test closes the client, then `stop()` closes this side.
        while !lock.withLock({ stopped }) { Thread.sleep(forTimeInterval: 0.02) }
    }

    struct Failure: Error { let why: String; init(_ why: String) { self.why = why } }
}
