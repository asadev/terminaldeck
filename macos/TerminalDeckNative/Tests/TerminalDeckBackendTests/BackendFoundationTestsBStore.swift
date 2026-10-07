import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendFoundationTestsBProjectEvents: @unchecked Sendable {
    private let lock = NSLock(); private var values: [[String]] = []
    func append(_ value: [String]) { lock.withLock { values.append(value) } }
    func read() -> [[String]] { lock.withLock { values } }
}
final class BackendFoundationTestsBStore: XCTestCase {
    private func session(_ cwd: String = "/Users/asad/Projects/terminaldeck") -> NativeRPCValue { .object([.init("cwd", .string(cwd)), .init("provider", .string("claude")), .init("profileId", .null), .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(42))]) }
    private func disk(_ fixture: BackendFoundationTestsBFixture) throws -> NativeRPCValue { try .parseJSON(Data(contentsOf: fixture.file("state.json"))) }
    func testOrderedSessionsImmediateWriteCopyEmptyAndOtherStateUntouched() async throws {
        let fixture = try BackendFoundationTestsBFixture("state-sessions"), store = try NativeStateStore(file: fixture.file("state.json"), ownership: .exclusive)
        let saved = [session("/a"), session("/b"), session("/a")]
        try await store.setOpenSessions(saved)
        let read = await store.getOpenSessions(); XCTAssertEqual(read, saved); XCTAssertEqual(try disk(fixture)["openSessions"], .array(saved))
        var copy = read; copy.reverse(); let after = await store.getOpenSessions(); XCTAssertEqual(after, saved)
        let preferences = await store.getPreferences(); _ = try await store.addProject("/Users/asad/Projects/terminaldeck")
        try await store.setOpenSessions([session("/written")]); XCTAssertEqual(try disk(fixture)["openSessions"], .array([session("/written")]))
        let keptPreferences = await store.getPreferences(), projects = await store.getProjects(); XCTAssertEqual(keptPreferences, preferences); XCTAssertTrue(projects.contains { $0["path"].string == "/Users/asad/Projects/terminaldeck" })
        try await store.setOpenSessions([]); let empty = await store.getOpenSessions(); XCTAssertTrue(empty.isEmpty); XCTAssertEqual(try disk(fixture)["openSessions"], .array([]))
        await store.close()
    }
    func testOlderStateMissingAndMalformedOpenSessionsReadAsEmpty() async throws {
        for open in [NativeRPCValue.missing, .string("all of them")] {
            let fixture = try BackendFoundationTestsBFixture("state-legacy")
            let original = NativeRPCValue.object([.init("version", .number(1)), .init("projects", .array([.object([.init("path", .string("/x")), .init("lastOpenedAt", .number(1))])])), .init("openSessions", open)])
            try original.encodedJSON().write(to: fixture.file("state.json"))
            let store = try NativeStateStore(file: fixture.file("state.json"), ownership: .exclusive)
            let sessions = await store.getOpenSessions(), projects = await store.getProjects(); XCTAssertTrue(sessions.isEmpty); XCTAssertEqual(projects.count, 1)
            await store.close()
        }
    }
    func testProjectAddedRemovedDuplicateAndMissingNotifications() async throws {
        let fixture = try BackendFoundationTestsBFixture("state-events"), store = try NativeStateStore(file: fixture.file("state.json"), ownership: .exclusive), seen = BackendFoundationTestsBProjectEvents()
        let subscription = await store.onProjectsChanged { seen.append($0) }
        _ = try await store.addProject("/Users/asad/Projects/one"); XCTAssertEqual(seen.read(), [["/Users/asad/Projects/one"]])
        _ = try await store.addProject("/Users/asad/Projects/one"); XCTAssertEqual(seen.read().count, 1)
        try await store.removeProject("/Users/asad/Projects/never"); XCTAssertEqual(seen.read().count, 1)
        try await store.removeProject("/Users/asad/Projects/one"); XCTAssertEqual(seen.read(), [["/Users/asad/Projects/one"], []])
        await subscription.cancelAndWait(); _ = try await store.addProject("/Users/asad/Projects/two"); XCTAssertEqual(seen.read().count, 2)
        await store.close()
    }
    func testThrowingListenerDoesNotStopProjectBeingOpened() async throws {
        let fixture = try BackendFoundationTestsBFixture("state-listener-error"), store = try NativeStateStore(file: fixture.file("state.json"), ownership: .exclusive)
        let subscription = await store.onProjectsChanged { _ in throw NativeRPCError(code: "fixture", message: "listener is broken") }
        _ = try await store.addProject("/Users/asad/Projects/one")
        let projects = await store.getProjects(); XCTAssertEqual(projects.map { $0["path"].string }, ["/Users/asad/Projects/one"])
        await subscription.cancelAndWait(); await store.close()
    }
    func testAccountFactsUnknownMergePersistForgetAndRemainSeparate() async throws {
        let fixture = try BackendFoundationTestsBFixture("state-accounts"), store = try NativeStateStore(file: fixture.file("state.json"), ownership: .exclusive), account = "/Users/asad/Library/Application Support/terminaldeck/profiles/one"
        let unknown = await store.getAccountLimit("/never/seen"); XCTAssertEqual(unknown, .null)
        _ = try await store.setAccountLimit(account, patch: .object([.init("billing", .string("api"))]))
        _ = try await store.setAccountLimit(account, patch: .object([.init("answer", .string("no-limits"))]))
        let combined = await store.getAccountLimit(account); XCTAssertEqual(combined["billing"].string, "api"); XCTAssertEqual(combined["answer"].string, "no-limits")
        XCTAssertEqual(try disk(fixture)["accountLimits"][account]["answer"].string, "no-limits")
        _ = try await store.setAccountLimit("/a", patch: .object([.init("answer", .string("no-limits"))])); _ = try await store.setAccountLimit("/b", patch: .object([.init("billing", .string("subscription"))]))
        let a = await store.getAccountLimit("/a"), b = await store.getAccountLimit("/b"); XCTAssertEqual(a["answer"].string, "no-limits"); XCTAssertEqual(b["answer"], .missing)
        try await store.forgetAccountLimit(account); let forgotten = await store.getAccountLimit(account); XCTAssertEqual(forgotten, .null); XCTAssertEqual(try disk(fixture)["accountLimits"][account], .missing)
        await store.close()
    }
    func testLegacyAndHandEditedAccountLimitMapAreUnknown() async throws {
        for raw in [NativeRPCValue.missing, .array([.string("not"), .string("a"), .string("map")])] {
            let fixture = try BackendFoundationTestsBFixture("state-account-legacy")
            try NativeRPCValue.object([.init("version", .number(1)), .init("projects", .array([])), .init("accountLimits", raw)]).encodedJSON().write(to: fixture.file("state.json"))
            let store = try NativeStateStore(file: fixture.file("state.json"), ownership: .exclusive), unknown = await store.getAccountLimit("/never/seen")
            XCTAssertEqual(unknown, .null); await store.close()
        }
    }
}
