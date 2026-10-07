import Foundation
@preconcurrency import Network
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Remote host loopback transport")
struct BackendRemoteServeTransportTests {
    private let connectionID = UUID()
    @Test func candidatesAndProcessWideBudgetKeepTheirSourceRules() {
        #expect(BackendRemoteServeTransportLoopback.candidates(ipv4: nil, ipv6: nil) == [.ipv4, .ipv6])
        #expect(BackendRemoteServeTransportLoopback.candidates(ipv4: true, ipv6: true) == [.ipv4, .ipv6])
        #expect(BackendRemoteServeTransportLoopback.candidates(ipv4: false, ipv6: true) == [.ipv6])
        #expect(BackendRemoteServeTransportLoopback.candidates(ipv4: false, ipv6: false) == [.ipv4])
        let budget = BackendRemoteServeTransportStreamBudget(ceiling: 1)
        #expect(budget.take()); #expect(!budget.take()); budget.give(); budget.give(); #expect(budget.take()); budget.give()
        #expect(BackendRemoteServeTransportStreamBudget.maximum == 256)
    }
    @Test func reservedPortsNeverReachTheWireOrDialer() async throws {
        let source = BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false, ipv4: true, ipv6: false), .init(port: 8443, process: "native", guessed: false)], reserved: [8443])
        let fixture = fixture(source)
        let offered = try await fixture.hub.handle(message("ports"), context: context())
        #expect(offered.first?.value["ports"] == .array([.object([.init("port", .number(5173)), .init("process", .string("node")), .init("guessed", .bool(false))])]))
        let refused = try await fixture.hub.handle(message("tunnel.open", id: "a", port: 8443), context: context())
        #expect(refused.first?.value["message"].string == "Nothing is listening on port 8443 on that computer any more.")
        #expect(fixture.sockets.dials.isEmpty)
        await fixture.hub.closeAll()
    }
    @Test func freshScansPreventDiallingAStoppedPortAndFailuresReturnAnEmptyOffer() async throws {
        let source = BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false)])
        let fixture = fixture(source)
        _ = try await fixture.hub.handle(message("ports"), context: context())
        await source.replace([])
        let refused = try await fixture.hub.handle(message("tunnel.open", id: "a", port: 5173), context: context())
        #expect(refused.first?.kind == .tunnelClosed && fixture.sockets.dials.isEmpty)
        await source.fail()
        let offered = try await fixture.hub.handle(message("ports"), context: context())
        #expect(offered.first?.value["ports"] == .array([]))
        await fixture.hub.closeAll()
    }
    @Test func scanCancellationNeverInstallsTheTunnelAfterThePhoneClosesIt() async throws {
        let source = BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false)])
        let fixture = fixture(source)
        await source.holdScan()
        let open = Task { try await fixture.hub.handle(message("tunnel.open", id: "a", port: 5173), context: context()) }
        await source.waitUntilScanning()
        let close = try await fixture.hub.handle(message("tunnel.close", id: "a"), context: context())
        #expect(close.first?.value["message"].string == "Closed on the phone.")
        await source.releaseScan()
        #expect(try await open.value.isEmpty)
        #expect(await fixture.hub.list().isEmpty && fixture.sockets.dials.isEmpty)
        await fixture.hub.closeAll()
    }
    @Test func tunnelPinsTheProvenFamilyAndFifthTunnelIsRefused() async throws {
        let source = BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false)])
        let fixture = fixture(source, reachable: [.ipv6])
        for n in 0..<4 {
            let opened = try await fixture.hub.handle(message("tunnel.open", id: "t\(n)", port: 5173), context: context())
            #expect(opened.first?.kind == .tunnelOpened)
        }
        let fifth = try await fixture.hub.handle(message("tunnel.open", id: "t4", port: 5173), context: context())
        #expect(fifth.first?.value["message"].string == "This phone already has 4 ports open. Close one first.")
        _ = try await fixture.hub.handle(message("net.open", channel: "c", tunnel: "t0"), context: context())
        #expect(fixture.sockets.dials.last?.host == .ipv6)
        #expect(await fixture.hub.list().count == 4)
        await fixture.hub.closeAll()
    }
    @Test func unreachablePortSaysWhichLoopbacksRefusedIt() async throws {
        let source = BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false)])
        let fixture = fixture(source, reachable: [])
        let answer = try await fixture.hub.handle(message("tunnel.open", id: "a", port: 5173), context: context())
        #expect(answer.first?.value["message"].string == "Port 5173 is listed as listening but refused a connection on 127.0.0.1 and ::1. Whatever holds it is not accepting connections.")
        #expect(await fixture.hub.list().isEmpty)
        await fixture.hub.closeAll()
    }
    @Test func acknowledgementsWaitForTheSocketWriteAndPhoneCloseFlushes() async throws {
        let fixture = fixture(BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false)]))
        _ = try await fixture.hub.handle(message("tunnel.open", id: "a", port: 5173), context: context())
        _ = try await fixture.hub.handle(message("net.open", channel: "c", tunnel: "a"), context: context())
        let socket = try #require(fixture.sockets.latest)
        socket.holdWrite()
        let write = Task { try await fixture.hub.handle(message("net.data", channel: "c", bytes: Data("phone bytes".utf8)), context: context()) }
        await socket.waitUntilWriting()
        #expect(await fixture.wire.count == 0)
        socket.releaseWrite()
        let ack = try await write.value
        #expect(ack.first?.value == .object([.init("t", .string("net.ack")), .init("ch", .string("c")), .init("bytes", .number(11))]))
        _ = try await fixture.hub.handle(message("net.close", channel: "c"), context: context())
        await socket.waitUntilClosed()
        #expect(socket.flushed)
        #expect(await fixture.wire.count == 0)
        await fixture.hub.closeAll()
    }
    @Test func bytesAreChunkedAndAFullWindowWaitsForCredit() async throws {
        let fixture = fixture(BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false)]))
        _ = try await fixture.hub.handle(message("tunnel.open", id: "a", port: 5173), context: context())
        _ = try await fixture.hub.handle(message("net.open", channel: "c", tunnel: "a"), context: context())
        let socket = try #require(fixture.sockets.latest)
        socket.feed(Data(repeating: 120, count: 524_288))
        await fixture.wire.waitForBytes(262_144)
        for _ in 0..<20 { await Task.yield() }
        let first = await fixture.wire.messages
        let received = first.reduce(0) { $0 + (Data(base64Encoded: $1.value["data"].string ?? "")?.count ?? 0) }
        #expect(received >= 262_144 && received < 524_288)
        #expect(first.allSatisfy { (Data(base64Encoded: $0.value["data"].string ?? "")?.count ?? 0) <= 24_576 })
        _ = try await fixture.hub.handle(message("net.ack", channel: "c", amount: received), context: context())
        await fixture.wire.waitForBytes(524_288)
        await fixture.hub.closeAll(); #expect(!socket.flushed)
    }
    @Test func wholeAppLimitAndEveryTeardownReturnTheBudget() async throws {
        let budget = BackendRemoteServeTransportStreamBudget(ceiling: 1)
        let fixture = fixture(BackendRemoteServeTransportTestPorts(ports: [.init(port: 5173, process: "node", guessed: false)]), budget: budget)
        _ = try await fixture.hub.handle(message("tunnel.open", id: "a", port: 5173), context: context())
        let ghost = try await fixture.hub.handle(message("net.open", channel: "ghost", tunnel: "missing"), context: context())
        #expect(ghost.first?.kind == .netClose)
        for n in 0..<5 {
            #expect(try await fixture.hub.handle(message("net.open", channel: "c\(n)", tunnel: "a"), context: context()).isEmpty)
            let refused = try await fixture.hub.handle(message("net.open", channel: "other", tunnel: "a"), context: context())
            #expect(refused.first?.value["ch"].string == "other")
            _ = try await fixture.hub.handle(message("net.close", channel: "c\(n)"), context: context())
            await fixture.hub.waitForDrains()
        }
        await fixture.hub.closeAll(); #expect(budget.take()); budget.give()
    }
    /// Real Network TCP behavior, independently of the bookkeeping test doubles.
    /// This is written for the combined integration gate; it has not been run.
    @Test func nativeSocketRoundTripsLoopbackBytesAndFlushesBeforeFIN() async throws {
        let queue = DispatchQueue(label: "BackendRemoteServeTransportTests.echo")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let accepted = BackendRemoteServeTransportTestAccepted()
        listener.newConnectionHandler = { peer in
            accepted.keep(peer); peer.start(queue: queue)
            peer.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { bytes, _, _, _ in
                peer.send(content: bytes, completion: .contentProcessed { _ in
                    peer.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                })
            }
        }
        defer { listener.cancel(); accepted.close() }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let gate = BackendRemoteServeTransportTestListenerReady(continuation)
            listener.stateUpdateHandler = { state in
                switch state { case .ready: if let port = listener.port { gate.finish(.success(Int(port.rawValue))) }; case .failed(let error): gate.finish(.failure(error)); case .cancelled: gate.finish(.failure(CancellationError())); default: break }
            }
            listener.start(queue: queue)
        }
        let socket = try BackendRemoteServeTransportTCPFactory().connect(port: port, host: .ipv4)
        defer { socket.discard() }
        try await socket.ready(timeoutMilliseconds: 5_000)
        let bytes = Data("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        try await socket.write(bytes)
        var received = Data()
        while received.count < bytes.count { let read = try await socket.read(maximumBytes: 65_536); received.append(read.data); if read.ended { break } }
        #expect(received == bytes)
        await socket.flushAndClose(lingerMilliseconds: 5_000)
    }
    private func context() -> BackendRemoteHostContext {
        .init(connectionID: connectionID, deviceID: "device", kind: .mine, address: "sealed", peerPublicKey: nil, claimedCapabilities: [],
              reach: .init(kind: .mine, unrestricted: true, folders: ["/work"], accounts: nil, drivesWindows: true))
    }
    private func message(_ type: String, id: String? = nil, port: Int? = nil, channel: String? = nil, tunnel: String? = nil, bytes: Data? = nil, amount: Int? = nil) -> BackendRemoteClientMessage {
        var fields = [NativeRPCValue.Field("t", .string(type))]
        if let id { fields.append(.init("id", .string(id))) }; if let port { fields.append(.init("port", .number(Double(port)))) }
        if let channel { fields.append(.init("ch", .string(channel))) }; if let tunnel { fields.append(.init("tunnel", .string(tunnel))) }
        if let bytes { fields.append(.init("data", .string(bytes.base64EncodedString()))) }; if let amount { fields.append(.init("bytes", .number(Double(amount)))) }
        return .init(.object(fields))
    }
    private func fixture(_ source: BackendRemoteServeTransportTestPorts, reachable: Set<BackendRemoteServeTransportLoopback> = [.ipv4], budget: BackendRemoteServeTransportStreamBudget = .init()) -> (hub: BackendRemoteServeTransportTunnelHub, sockets: BackendRemoteServeTransportTestFactory, wire: BackendRemoteServeTransportTestWire) {
        let sockets = BackendRemoteServeTransportTestFactory(reachable: reachable), wire = BackendRemoteServeTransportTestWire()
        return (.init(connectionID: connectionID, ports: source, wire: wire, sockets: sockets, budget: budget), sockets, wire)
    }
}

private actor BackendRemoteServeTransportTestPorts: BackendRemoteServeTransportPortSource {
    private var ports: [BackendRemoteServeTransportPort], reserved: Set<Int>, failed = false, holding = false, scanning = false
    private var release: CheckedContinuation<Void, Never>?, started: CheckedContinuation<Void, Never>?
    init(ports: [BackendRemoteServeTransportPort], reserved: Set<Int> = []) { self.ports = ports; self.reserved = reserved }
    func reservedPorts() -> Set<Int> { reserved }
    func scan(context: BackendRemoteHostContext) async throws -> [BackendRemoteServeTransportPort] {
        if failed { throw NativeRPCError(code: "unavailable", message: "scan failed") }
        if holding { scanning = true; started?.resume(); started = nil; await withCheckedContinuation { release = $0 } }
        return ports
    }
    func replace(_ ports: [BackendRemoteServeTransportPort]) { self.ports = ports }
    func fail() { failed = true }
    func holdScan() { holding = true }
    func waitUntilScanning() async { if !scanning { await withCheckedContinuation { started = $0 } } }
    func releaseScan() { holding = false; release?.resume(); release = nil }
}
private actor BackendRemoteServeTransportTestWire: BackendRemoteServeTransportWire {
    private(set) var messages: [BackendRemoteServerMessage] = []
    private var total = 0, target = 0
    private var waiter: CheckedContinuation<Void, Never>?
    var count: Int { messages.count }
    func send(connectionID: UUID, message: BackendRemoteServerMessage) {
        messages.append(message); total += Data(base64Encoded: message.value["data"].string ?? "")?.count ?? 0
        if total >= target { waiter?.resume(); waiter = nil }
    }
    func waitForBytes(_ target: Int) async { if total < target { self.target = target; await withCheckedContinuation { waiter = $0 } } }
}
private final class BackendRemoteServeTransportTestFactory: BackendRemoteServeTransportSocketFactory, @unchecked Sendable {
    struct Dial { let port: Int, host: BackendRemoteServeTransportLoopback }
    private let lock = NSLock(), reachable: Set<BackendRemoteServeTransportLoopback>
    private var calls: [Dial] = [], last: BackendRemoteServeTransportTestSocket?
    init(reachable: Set<BackendRemoteServeTransportLoopback>) { self.reachable = reachable }
    var dials: [Dial] { lock.lock(); defer { lock.unlock() }; return calls }
    var latest: BackendRemoteServeTransportTestSocket? { lock.lock(); defer { lock.unlock() }; return last }
    private func record(_ port: Int, _ host: BackendRemoteServeTransportLoopback) { lock.lock(); calls.append(.init(port: port, host: host)); lock.unlock() }
    func probe(port: Int, host: BackendRemoteServeTransportLoopback, timeoutMilliseconds: Int) async -> Bool { record(port, host); return reachable.contains(host) }
    func connect(port: Int, host: BackendRemoteServeTransportLoopback) -> any BackendRemoteServeTransportSocket {
        record(port, host); let socket = BackendRemoteServeTransportTestSocket(); lock.lock(); last = socket; lock.unlock(); return socket
    }
}
private final class BackendRemoteServeTransportTestSocket: BackendRemoteServeTransportSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queued = Data(), closed = false, didFlush = false, hold = false, writing = false
    private var reader: (Int, CheckedContinuation<BackendRemoteServeTransportRead, Error>)?
    private var writer: CheckedContinuation<Void, Error>?, writeStarted: CheckedContinuation<Void, Never>?, closeWaiter: CheckedContinuation<Void, Never>?
    var flushed: Bool { lock.lock(); defer { lock.unlock() }; return didFlush }
    func ready(timeoutMilliseconds: Int) async throws {}
    func read(maximumBytes: Int) async throws -> BackendRemoteServeTransportRead {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: CancellationError()) }
            else if !queued.isEmpty { let data = Data(queued.prefix(maximumBytes)); queued.removeFirst(data.count); lock.unlock(); continuation.resume(returning: .init(data: data)) }
            else { reader = (maximumBytes, continuation); lock.unlock() }
        }
    }
    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); writing = true; let started = writeStarted; writeStarted = nil
            if hold { writer = continuation; lock.unlock(); started?.resume() }
            else { lock.unlock(); started?.resume(); continuation.resume() }
        }
    }
    func feed(_ bytes: Data) {
        lock.lock(); queued.append(bytes)
        if let (maximum, continuation) = reader { reader = nil; let data = Data(queued.prefix(maximum)); queued.removeFirst(data.count); lock.unlock(); continuation.resume(returning: .init(data: data)) }
        else { lock.unlock() }
    }
    func holdWrite() { lock.lock(); hold = true; lock.unlock() }
    func releaseWrite() { lock.lock(); let pending = writer; writer = nil; hold = false; lock.unlock(); pending?.resume() }
    func waitUntilWriting() async { await withCheckedContinuation { continuation in lock.lock(); if writing { lock.unlock(); continuation.resume() } else { writeStarted = continuation; lock.unlock() } } }
    func waitUntilClosed() async { await withCheckedContinuation { continuation in lock.lock(); if closed { lock.unlock(); continuation.resume() } else { closeWaiter = continuation; lock.unlock() } } }
    private func close(flush: Bool) { lock.lock(); closed = true; didFlush = flush; let pending = reader; reader = nil; let waiter = closeWaiter; closeWaiter = nil; lock.unlock(); pending?.1.resume(throwing: CancellationError()); waiter?.resume() }
    func flushAndClose(lingerMilliseconds: Int) async { close(flush: true) }
    func discard() { close(flush: false) }
}
private final class BackendRemoteServeTransportTestAccepted: @unchecked Sendable {
    private let lock = NSLock(); private var peers: [NWConnection] = []
    func keep(_ connection: NWConnection) { lock.lock(); peers.append(connection); lock.unlock() }
    func close() { lock.lock(); let old = peers; peers = []; lock.unlock(); old.forEach { $0.cancel() } }
}
private final class BackendRemoteServeTransportTestListenerReady: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Int, Error>?
    init(_ continuation: CheckedContinuation<Int, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Int, Error>) { lock.lock(); let pending = continuation; continuation = nil; lock.unlock(); pending?.resume(with: result) }
}
