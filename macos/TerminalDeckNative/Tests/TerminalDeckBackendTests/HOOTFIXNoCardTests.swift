import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Asad, 11 Oct: "app itself will not ask any permissions at all". An AI app's key asking for a
/// change it may make runs at once as a standing approval: no card, nothing queued for later.
final class HOOTFIXNoCardTests: XCTestCase {
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.withLock { value } }
        func edit(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
    }
    final class Clock: BackendDeckCoreEventsClock, @unchecked Sendable {
        private let lock = NSLock(); private var instant = 1_800_000_000_000.0
        private var timers: [UUID: (Double, @Sendable () -> Void)] = [:]
        func now() -> Double { lock.withLock { instant } }
        func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID { let id = UUID(); lock.withLock { timers[id] = (instant + milliseconds, run) }; return id }
        func cancel(_ handle: UUID) { lock.withLock { timers[handle] = nil } }
        /// Move time and fire what came due.
        func move(by milliseconds: Double) {
            let due = lock.withLock { () -> [@Sendable () -> Void] in
                instant += milliseconds
                let ready = timers.filter { $0.value.0 <= instant }; ready.keys.forEach { timers[$0] = nil }; return ready.values.map(\.1)
            }
            due.forEach { $0() }
        }
    }
    static let args = NativeRPCValue.object([.init("server", .string("prod")), .init("action", .string("restart")), .init("token", .string("s3cret"))])

    /// present: the owner would answer an inline question (true/false) or nobody is there (nil).
    func rig(present: Bool?) async throws -> (control: BackendDeckCoreSecurityControl, runs: Box<Int>) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTFIXNoCard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runs = Box(0)
        let holder = Box<BackendDeckCoreSecurityConsentBroker?>(nil)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { question in
            guard let present else { return false }          // no window, no phone
            let current = holder.get()
            Task { _ = await current?.respond(id: question.id, approved: present, by: "window") }
            return true
        })
        holder.edit { $0 = broker }
        let control = try BackendDeckCoreSecurityControl(log: BackendDeckCoreSecurityActionLog(directory: dir), consent: broker, checkArguments: { _, _ in })
        try await control.register([.init(tool: try .init(id: "servers.manage", wireName: "servers_manage", description: "manage",
                inputSchema: .object([.init("type", .string("object"))]), tier: .alter),
            summary: { args, _ in "Restart server \(args["server"].string ?? "")" },
            ownerMustAnswer: { _ in true },
            redactArgs: { $0.setting("token", .string("[redacted]")) },
            run: { _, _ in runs.edit { $0 += 1 }; return .init(value: .object([.init("restarted", .bool(true))])) })])
        return (control, runs)
    }

    /// Whether anybody is at the window or not, and whoever calls, nobody is asked and nothing waits.
    func testNobodyIsAskedWhoeverCallsAndWhoeverIsThere() async throws {
        for present in [true, false, nil] as [Bool?] {
            let r = try await rig(present: present)
            let key = await r.control.call(name: "servers.manage", arguments: Self.args, options: .init(caller: .init(kind: .key, tiers: [.read, .act, .alter],
                keyID: "k-commander", keyName: "Commander", askFirst: true), reason: "The iMatch deploy is stuck and needs a restart."))
            XCTAssertTrue(key.ok, key.error ?? ""); XCTAssertEqual(key.value["restarted"].bool, true)
            XCTAssertEqual(key.row["confirmed"]["by"], .string("standing:key:k-commander"))
            let session = await r.control.call(name: "servers.manage", arguments: Self.args, options: .init(caller: .init(kind: .session, tiers: [.read, .act, .alter], sessionID: "s1")))
            XCTAssertTrue(session.ok, session.error ?? "")
            XCTAssertEqual(r.runs.get(), 2)
        }
        // A key without Full control is still refused: a change is still a change.
        let r = try await rig(present: nil)
        let work = await r.control.call(name: "servers.manage", arguments: Self.args, options: .init(caller: .init(kind: .key, tiers: [.read, .act], keyID: "k-work", askFirst: true)))
        XCTAssertEqual(work.refusal, .notGranted)
    }
}
