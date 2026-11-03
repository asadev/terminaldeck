import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendServersSetupPortFixtures {
    static let root: URL = {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }()
    static func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    static func capture(_ pattern: String, _ text: String) -> String? { BackendServersSetupTape.capture(pattern, text) }
    static func rawSwiftLiteral(_ name: String, from text: String) throws -> String {
        let mark = "static let " + name + " = #\"\"\"\n"
        let start = try #require(text.range(of: mark)?.upperBound)
        let end = try #require(text[start...].range(of: "\n\"\"\"#")?.lowerBound)
        return String(text[start..<end])
    }
}

final class BackendServersSetupPortSignal: @unchecked Sendable {
    private let lock = NSLock(); private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func send() { let old = lock.withLock { signalled = true; let old = waiters; waiters = []; return old }; for waiter in old { waiter.resume() } }
    func wait() async { await withCheckedContinuation { waiter in let now = lock.withLock { if signalled { return true }; waiters.append(waiter); return false }; if now { waiter.resume() } } }
}
final class BackendServersSetupPortLog: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var values: [String] { lock.withLock { lines } }
    func count(_ value: String) -> Int { values.filter { $0 == value }.count }
}
final class BackendServersSetupPortShell: BackendServersShell, @unchecked Sendable {
    private let lock = NSLock(); private var sent: [String] = []
    private var data: [UUID: @Sendable (String) -> Void] = [:], ended: [UUID: @Sendable () -> Void] = [:]
    let writesChanged = BackendServersSetupPortSignal()
    private let handler: @Sendable (String, BackendServersSetupPortShell) -> Void
    init(handler: @escaping @Sendable (String, BackendServersSetupPortShell) -> Void = { _, _ in }) { self.handler = handler }
    var writes: [String] { lock.withLock { sent } }
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe {
        let id = UUID(); lock.withLock { data[id] = listener }; return { [weak self] in self?.lock.withLock { self?.data[id] = nil } }
    }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe {
        let id = UUID(); lock.withLock { ended[id] = listener }; return { [weak self] in self?.lock.withLock { self?.ended[id] = nil } }
    }
    func emit(_ text: String) { let callbacks = lock.withLock { Array(data.values) }; for callback in callbacks { callback(text) } }
    func write(_ text: String) { lock.withLock { sent.append(text) }; writesChanged.send(); handler(text, self) }
    func resize(_ size: BackendServersTerminalSize) {}
    func close() { let callbacks = lock.withLock { Array(ended.values) }; for callback in callbacks { callback() } }
}
