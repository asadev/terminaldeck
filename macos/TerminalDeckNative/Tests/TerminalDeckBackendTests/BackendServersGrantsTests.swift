import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("Server control is local, scoped, expiring and in-memory")
struct BackendServersGrantsTests {
    @Test func localGrantCannotSpreadToAnotherServerOrCaller() throws {
        let clock = BackendServersGrantsTestClock(), grants = BackendServersGrants(assistantName: "Test assistant", now: { clock.now }, knows: { ["one", "two"].contains($0) })
        #expect(grants.state("one") == nil)
        let state = try grants.grant("one", asker: "local")
        #expect(state.expiresAt == clock.now + 3_600_000 && state.grantedAt == clock.now)
        #expect(grants.granted("one", asker: "local") && !grants.granted("two", asker: "local"))
        for caller in ["remote", "session", "key"] {
            #expect(!grants.granted("one", asker: caller))
            do { _ = try grants.grant("two", asker: caller); Issue.record("Granted to \(caller)") } catch let issue as BackendServersGrantRefused { #expect(issue.reason == "not-local") }
        }
        do { _ = try grants.grant("unknown", asker: "local"); Issue.record("Granted unknown server") } catch let issue as BackendServersGrantRefused { #expect(issue.reason == "unknown-server") }
        clock.advance(3_600_000); #expect(!grants.granted("one", asker: "local") && grants.state("one") == nil && grants.list().isEmpty)
    }
    @Test func ceilingNewestOrderAndRevoke() throws {
        let clock = BackendServersGrantsTestClock(), grants = BackendServersGrants(assistantName: "Test assistant", now: { clock.now })
        let longest = try grants.grant("one", asker: "local", forMilliseconds: 100_000_000)
        #expect(longest.expiresAt - longest.grantedAt == BackendServersGrants.maximumGrantMilliseconds)
        clock.advance(1); _ = try grants.grant("two", asker: "local")
        #expect(grants.list().map(\.serverId) == ["two", "one"])
        grants.revoke("two"); grants.revoke("two"); #expect(grants.list().count == 1)
        grants.revokeAll(); #expect(grants.list().isEmpty)
        #expect(BackendServersGrants(assistantName: "Test assistant").list().isEmpty)
    }
    @Test func capacityAndExpiredSlotReuse() throws {
        let clock = BackendServersGrantsTestClock(), grants = BackendServersGrants(assistantName: "Test assistant", now: { clock.now })
        for n in 0..<64 { _ = try grants.grant(String(n), asker: "local", forMilliseconds: 5) }
        #expect(throws: BackendServersGrantRefused.self) { try grants.grant("65", asker: "local") }
        _ = try grants.grant("0", asker: "local", forMilliseconds: 5)
        clock.advance(5); #expect(try grants.grant("65", asker: "local").serverId == "65")
    }
}
private final class BackendServersGrantsTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var at: Double = 1000
    var now: Double { lock.withLock { at } }
    func advance(_ amount: Double) { lock.withLock { at += amount } }
}
