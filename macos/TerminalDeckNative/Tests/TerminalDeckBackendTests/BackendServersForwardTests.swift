import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Server localhost forwarding decisions and ordered bytes")
struct BackendServersForwardTests {
    @Test func emptyPortNeverTouchesAKnownServiceAndRefusedConnectMeansForwardingWorks() async {
        #expect(BackendServersForward.deadPort([1, 2, 4]) == 3)
        let allowed = await BackendServersForward.askWhetherItForwards({ _, _ in .refused(.unreachable, message: "nothing listening") }, listening: [8000])
        #expect(allowed.known == "yes")
        let unknown = await BackendServersForward.askWhetherItForwards({ _, _ in .refused(.unknown, message: "cannot ask") })
        #expect(unknown == .init(known: "cannot", why: "cannot ask"))
        let denied = await BackendServersForward.askWhetherItForwards({ _, _ in .refused(.prohibited, message: "settings") }, listening: [8000])
        #expect(denied == .init(known: "no", why: BackendServersForward.willNotForward))
    }
    @Test func permitOpenRefusalAboutEmptyPortIsNotBelievedUntilARealPortIsAsked() async {
        let calls = BackendServersForwardTestCalls(), channel = BackendServersForwardTestChannel()
        let answer = await BackendServersForward.askWhetherItForwards({ host, port in calls.add(host, port); return port == 8000 ? .opened(channel) : .refused(.prohibited, message: "empty port outside allow-list") }, listening: [8000, 3000])
        #expect(answer.known == "yes" && calls.ports == [1, 8000] && channel.closed == 1)
        #expect(BackendServersForward.whyNot(.prohibited, port: 8000, name: "box") == BackendServersForward.willNotForward)
        #expect(BackendServersForward.whyNot(.unreachable, port: 8000, name: "box") == "Nothing is answering on port 8000 on box.")
        #expect(BackendServersForward.whyNot(.unknown, port: 8000, name: "box") == "box could not be asked about port 8000 just now.")
    }
    @Test func provesBothLoopbacksBeforeOpeningAndProhibitedStopsImmediately() async {
        let calls = BackendServersForwardTestCalls(), frames = BackendServersForwardTestFrames(), channel = BackendServersForwardTestChannel()
        let host = BackendServersSshTunnelHost(forward: { address, port in calls.add(address, port); return address == "::1" ? .opened(channel) : .refused(.unreachable, message: "nothing") }, name: "box", send: { await frames.add($0) })
        await host.handle(.object([.init("t", .string("tunnel.open")), .init("id", .string("one")), .init("port", .number(8000))]))
        #expect(calls.hosts == ["127.0.0.1", "::1"] && channel.closed == 1)
        #expect(await host.openPorts() == [8000]); #expect(await frames.values.last?["t"].string == "tunnel.opened")
        let forbidden = BackendServersSshTunnelHost(forward: { address, port in calls.add(address, port); return .refused(.prohibited, message: "no") }, name: "box", send: { await frames.add($0) })
        let before = calls.ports.count
        await forbidden.handle(.object([.init("t", .string("tunnel.open")), .init("id", .string("two")), .init("port", .number(8000))]))
        #expect(calls.ports.count == before + 1)
        #expect(await frames.values.last?["message"].string == BackendServersForward.willNotForward)
        await host.closeAll()
    }
    @Test func closeCancelsAnUnfinishedOpen() async throws {
        let gate = BackendServersSSHOnce<BackendServersForwardResult>(), started = BackendServersSSHOnce<Bool>(), frames = BackendServersForwardTestFrames(), channel = BackendServersForwardTestChannel()
        let host = BackendServersSshTunnelHost(forward: { _, _ in started.finish(.success(true)); return (try? await gate.value()) ?? .refused(.unknown, message: "gone") }, name: "box", send: { await frames.add($0) })
        let opening = Task { await host.handle(.object([.init("t", .string("tunnel.open")), .init("id", .string("one")), .init("port", .number(8000))])) }
        _ = try await started.value()
        await host.handle(.object([.init("t", .string("tunnel.close")), .init("id", .string("one"))]))
        gate.finish(.success(.opened(channel))); await opening.value
        let openPorts = await host.openPorts()
        #expect(channel.closed == 1 && openPorts.isEmpty)
        #expect(await frames.values.filter { $0["t"].string == "tunnel.opened" }.isEmpty)
    }
    @Test func browserRequestWaitsForTheChannelThenAcknowledgesWhatWasWritten() async throws {
        let gate = BackendServersSSHOnce<BackendServersForwardResult>(), started = BackendServersSSHOnce<Bool>(), calls = BackendServersForwardTestCalls(), frames = BackendServersForwardTestFrames()
        let proof = BackendServersForwardTestChannel(), channel = BackendServersForwardTestChannel()
        let host = BackendServersSshTunnelHost(forward: { address, port in calls.add(address, port); if calls.ports.count == 1 { return .opened(proof) }; started.finish(.success(true)); return (try? await gate.value()) ?? .refused(.unknown, message: "gone") }, name: "box", send: { await frames.add($0) })
        await host.handle(.object([.init("t", .string("tunnel.open")), .init("id", .string("one")), .init("port", .number(8000))]))
        let opening = Task { await host.handle(.object([.init("t", .string("net.open")), .init("ch", .string("request")), .init("tunnel", .string("one"))])) }
        _ = try await started.value()
        let request = Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        await host.handle(.object([.init("t", .string("net.data")), .init("ch", .string("request")), .init("data", .string(request.base64EncodedString()))]))
        #expect(channel.writes.isEmpty)
        gate.finish(.success(.opened(channel))); await opening.value
        #expect(channel.writes == [request])
        #expect(await frames.values.contains { $0["t"].string == "net.ack" && $0["bytes"].number == Double(request.count) })
        await host.handle(.object([.init("t", .string("net.close")), .init("ch", .string("request"))]))
        #expect(channel.ended == 1 && channel.closed == 0)
        await host.closeAll()
    }
    @Test func flowControlChunksAndDiscardOnShutdown() async throws {
        let frames = BackendServersForwardTestFrames(), calls = BackendServersForwardTestCalls(), channel = BackendServersForwardTestChannel()
        let host = BackendServersSshTunnelHost(forward: { address, port in calls.add(address, port); return .opened(calls.ports.count == 1 ? BackendServersForwardTestChannel() : channel) }, name: "box", send: { await frames.add($0) })
        await host.handle(.object([.init("t", .string("tunnel.open")), .init("id", .string("one")), .init("port", .number(8000))]))
        await host.handle(.object([.init("t", .string("net.open")), .init("ch", .string("request")), .init("tunnel", .string("one"))]))
        channel.bytes.send(Data(repeating: 7, count: 288 * 1024))
        await host.flushPendingEvents()
        let chunks = await frames.values.filter { $0["t"].string == "net.data" }.compactMap { $0["data"].string.flatMap { Data(base64Encoded: $0) } }
        #expect(chunks.reduce(0) { $0 + $1.count } == 288 * 1024 && chunks.allSatisfy { $0.count <= 24576 })
        #expect(channel.paused > 0)
        await host.handle(.object([.init("t", .string("net.ack")), .init("ch", .string("request")), .init("bytes", .number(288 * 1024))]))
        #expect(channel.resumed > 0)
        await host.closeAll(); #expect(channel.closed == 1)
    }
}
final class BackendServersForwardTestChannel: BackendServersDuplex, @unchecked Sendable {
    let bytes = BackendServersSSHEvents<Data>(), ends = BackendServersSSHEvents<Bool>(), closes = BackendServersSSHEvents<Bool>()
    private let lock = NSLock(); private var written: [Data] = [], endCount = 0, closeCount = 0, pauseCount = 0, resumeCount = 0
    var writes: [Data] { lock.withLock { written } }; var ended: Int { lock.withLock { endCount } }; var closed: Int { lock.withLock { closeCount } }; var paused: Int { lock.withLock { pauseCount } }; var resumed: Int { lock.withLock { resumeCount } }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { bytes.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ends.listen { _ in listener() } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closes.listen { _ in listener() } }
    func write(_ bytes: Data) async throws { lock.withLock { written.append(bytes) } }
    func end() async throws { lock.withLock { endCount += 1 } }
    func close() { lock.withLock { closeCount += 1 } }
    func pause() { lock.withLock { pauseCount += 1 } }; func resume() { lock.withLock { resumeCount += 1 } }
}
final class BackendServersForwardTestCalls: @unchecked Sendable {
    private let lock = NSLock(); private var calls: [(String, Int)] = []
    func add(_ host: String, _ port: Int) { lock.withLock { calls.append((host, port)) } }
    var ports: [Int] { lock.withLock { calls.map { $0.1 } } }; var hosts: [String] { lock.withLock { calls.map { $0.0 } } }
}
actor BackendServersForwardTestFrames { private(set) var values: [NativeRPCValue] = []; func add(_ value: NativeRPCValue) { values.append(value) } }
