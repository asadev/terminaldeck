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
