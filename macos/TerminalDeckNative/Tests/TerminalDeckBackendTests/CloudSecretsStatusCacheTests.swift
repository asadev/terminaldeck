import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 14 Nov (the 0220za watch): both Macs read `/secrets/status` 31 times in five minutes. Nothing that repeats by itself
/// may ask the service for the saved-passwords state: every reader takes the one kept answer, and only the socket's own
/// notice, a send to a saved-password route, his own look (page, press, Sync now) or 15 minutes make the next read fresh.
@Suite("Cloud saved passwords — one kept status answer")
struct CloudSecretsStatusCacheTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ method: String, _ path: String) { lock.withLock { paths.append(method + " " + path) } }
        var statusReads: Int { lock.withLock { paths.filter { $0 == "GET /secrets/status" }.count } }
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var at: Int64 = 1_800_000_000_000
        func now() -> Int64 { lock.withLock { at } }
        func advance(_ ms: Int64) { lock.withLock { at += ms } }
    }
    private static let status = CloudSecretsStatus(state: .ready, epoch: 1, version: CloudSequence(1), recoveryReady: true,
                                                   approvedDeviceCount: 2, pendingApprovals: [])
    private func control(_ counter: Counter, cache: BackendCloudSecretsStatusCache) -> BackendCloudSecretsControl {
        BackendCloudSecretsLean.control(send: { method, path, _, _ in
            counter.add(method, path)
            if method == "GET", path == "/secrets/status" { return try CloudSecretsCanonical.encode(Self.status) }
            struct Receipt: Encodable { let at: Int64 }
            return try CloudSecretsCanonical.encode(Receipt(at: 9_999_999_999_999))
        }, devices: { CloudDeviceList(devices: []) }, statusCache: cache)
    }

    @Test func tenMinutesOfReReadsAskTheServiceNoTimesAndASocketNoticeOnce() async throws {
        let clock = Clock(), counter = Counter()
        let sink = BackendCloudSecretsEventSink(statusCache: BackendCloudSecretsStatusCache(now: { clock.now() }))
        let control = control(counter, cache: sink.statusCache)
        // The first read (start-up) asks once.
        #expect(try await control.status() == Self.status)
        #expect(counter.statusReads == 1)
        // Ten minutes of re-reads every 10 seconds (the status line, the page, the start line, the tool, the facts read):
        // nothing changed, so the service is not asked again.
        for _ in 0..<60 {
            clock.advance(10_000)
            _ = try await control.status()
            _ = try await control.statusFacts()
        }
        #expect(counter.statusReads == 1)
        // A socket notice (saved passwords changed elsewhere): the next read asks once, and is kept again.
        sink.post(CloudEvent(v: 1, type: "vault", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        _ = try await control.status()
        _ = try await control.status()
        #expect(counter.statusReads == 2)
        // An event that says nothing about saved passwords (memory changed) does not.
        sink.post(CloudEvent(v: 1, type: "changed", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        _ = try await control.status()
        #expect(counter.statusReads == 2)
        // Something this Mac sends to a saved-password route: the next read is fresh.
        _ = try await control.publishedPolicy()   // a status read itself: kept
        #expect(counter.statusReads == 2)
        try? await control.publishPolicy(requestId: UUID().uuidString.lowercased(),
            policy: .init(askOnNewDevice: true, at: 1, by: UUID().uuidString.lowercased(), signature: "x"))
        _ = try await control.status()
        #expect(counter.statusReads == 3)
        // His own look (page opened, Check again, Sync now) invalidates.
        sink.statusCache.invalidate()
        _ = try await control.status()
        #expect(counter.statusReads == 4)
        // The slow fallback: at most once every 15 minutes with nothing else happening.
        clock.advance(14 * 60_000)
        _ = try await control.status()
        #expect(counter.statusReads == 4)
        clock.advance(61_000)
        _ = try await control.status()
        #expect(counter.statusReads == 5)
    }

    /// The floor (the 20-second trigger is unknown, so it holds whatever it is): twenty notices in one minute make ONE
    /// service read; a notice inside the minute is shown again when the minute is up; his press reads at once; every
    /// read says its reason in one guarded log line.
    @Test func twentyNoticesInAMinuteMakeOneReadAndAPressReadsAtOnce() async throws {
        let clock = Clock(), counter = Counter()
        // The follow-up's own wait never ends inside the test (the fake clock drives the minute); what was scheduled is
        // read from the sink, recorded when scheduled (the follow-up task may not have started yet: the first red).
        let cache = BackendCloudSecretsStatusCache(now: { clock.now() }, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let lines = LogLines()
        cache.use(log: lines.log)
        let sink = BackendCloudSecretsEventSink(statusCache: cache)
        let control = control(counter, cache: cache)
        _ = try await control.status()
        #expect(counter.statusReads == 1)
        clock.advance(60_000)
        // Twenty notices in the next minute, each followed by the readers it wakes.
        let types = ["vault", "approval", "devices", "hello"]
        for i in 0..<20 {
            sink.post(CloudEvent(v: 1, type: types[i % types.count], id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
            _ = try await control.status()
            _ = try await control.statusFacts()
            clock.advance(2_900)
        }
        #expect(counter.statusReads == 2)
        // The notices inside the minute are shown again when it is up (one follow-up per kind, under a minute away).
        let waits = sink.followUpsWaiting
        #expect(!waits.isEmpty && waits.values.allSatisfy { $0 > 0 && $0 <= 60_000 })
        #expect(waits.count <= types.count)
        // The approval request that came inside the minute is among them: it shows when the minute is up.
        #expect(waits["approval"] != nil)
        // When the minute is up, the stale answer is read once more.
        clock.advance(2_000)
        _ = try await control.status()
        _ = try await control.status()
        #expect(counter.statusReads == 3)
        // His press reads at once, even inside the minute.
        clock.advance(1_000)
        cache.invalidate("your press")
        _ = try await control.status()
        #expect(counter.statusReads == 4)
        // One line per service read, each naming its reason; nothing else written, and every line passes the scan.
        let reads = lines.all.filter { $0.hasPrefix(CloudSecretsLog.prefix + "status read (reason: ") }
        #expect(reads.count == 4)
        #expect(reads.first == CloudSecretsLog.prefix + "status read (reason: app start)")
        #expect(reads.last == CloudSecretsLog.prefix + "status read (reason: your press)")
        for line in lines.all { #expect(CloudSecretsLog.safe(line)) }
    }
}
