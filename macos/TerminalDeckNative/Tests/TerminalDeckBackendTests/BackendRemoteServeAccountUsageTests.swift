import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeAccountUsageTests: XCTestCase {
    private static func profile(_ id: String = "work") -> BackendAccountProfile {
        .init(id: id, name: "Work login", provider: "claude", configDir: "/private/account-path", system: false, color: "--accent", createdAt: 1)
    }
    private static func established(_ id: String?) -> BackendAccountSessionReading {
        .init(provider: "claude", configDir: "/private/account-path", profileId: id, profileName: "Old login", source: "spawn", email: nil, reason: nil)
    }
    func testAccountProjectionSendsIdentityButNoPrivateProbeFields() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [Self.profile()] }, attribution: { _ in Self.established("work") }, probe: { _ in
            .init(state: .signedIn, account: "work@example.com", plan: "max", detail: "Signed in as work@example.com.")
        })
        let value = try await service.read("session")
        XCTAssertEqual(value.current["id"], .string("work")); XCTAssertEqual(value.current["signIn"]["account"], .string("work@example.com"))
        XCTAssertEqual(value.current["color"], .string("--accent")); XCTAssertEqual(value.current["configDir"], .missing)
        XCTAssertEqual(value.current["signIn"]["command"], .missing); XCTAssertEqual(value.current["signIn"]["checkedAt"], .missing)
    }
    func testNativeSignInAdapterProjectsOnlyFourPublicFields() throws {
        let raw = BackendAppAccountSignInReport(profileId: "work", provider: "claude", state: "signed-in", account: "work@example.com", plan: "max", detail: "Signed in.", command: "/private/path/claude auth status", checkedAt: 42)
        let projected = try BackendRemoteServeAccountSignInAdapter.project(raw).wireValue
        XCTAssertEqual(projected["account"], .string("work@example.com")); XCTAssertEqual(projected.fields?.count, 4)
        XCTAssertEqual(projected["command"], .missing); XCTAssertEqual(projected["checkedAt"], .missing); XCTAssertEqual(projected["profileId"], .missing)
    }
    func testAccountAttributionNeverFallsBackAndFailedProbeOmitsSignIn() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [Self.profile()] }, attribution: { _ in nil }, probe: { _ in throw Failure.probe })
        let value = try await service.read("unknown")
        XCTAssertEqual(value.current, .null); XCTAssertEqual(value.accounts.count, 1); XCTAssertEqual(value.accounts[0]["signIn"], .missing)
    }
    func testDeletedButEstablishedProfileIsReportedWithoutAnUnmadeProbe() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [Self.profile()] }, attribution: { _ in Self.established("deleted") })
        let value = try await service.read("session")
        XCTAssertEqual(value.current["id"], .string("deleted")); XCTAssertEqual(value.current["name"], .string("Old login"))
        XCTAssertEqual(value.current["signIn"], .missing); XCTAssertEqual(value.current["system"], .bool(false))
    }
    func testIncompleteAccountAndLoginOperationsAreNotAdvertisedByFactories() {
        let service = BackendRemoteServeAccountService(profiles: { [Self.profile()] }, attribution: { _ in nil })
        let trust = BackendRemoteTrustStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        XCTAssertNil(service.accountFeature(trust: trust, gate: .init(trust: trust, manager: manager))); XCTAssertNil(service.loginFeature())
    }
    func testPlanAndContextCannotReachExpensiveRefresh() async throws {
        let calls = Calls()
        let service = BackendRemoteServeUsageService(plan: { _ in await calls.add("plan"); return .object([.init("from", .string("shared report"))]) },
            refresh: { _, _ in await calls.add("expensive"); return .object([]) }, context: { _, _ in await calls.add("context"); return .object([]) })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "test")
        _ = try await service.reading(sessionID: "s", want: "plan", rpcContext: context)
        _ = try await service.reading(sessionID: "s", want: "context", rpcContext: context)
        let actual = await calls.read(); XCTAssertEqual(actual, ["plan", "context"])
    }
    func testEmptyUsageShapesAndTimestampsMatchThePhoneContract() {
        let context = BackendRemoteServeUsageService.empty(want: "context", detail: "No session s is running.", now: 42)
        XCTAssertEqual(context["state"], .string("not-reported")); XCTAssertEqual(context["tokens"], .null)
        XCTAssertEqual(context["observedAt"], .number(42)); XCTAssertEqual(context["reportedAt"], .number(0))
        let refresh = BackendRemoteServeUsageService.empty(want: "refresh", detail: "absent", now: 42)
        XCTAssertEqual(refresh["outcome"], .string("unwatched")); XCTAssertEqual(refresh["spawned"], .bool(false)); XCTAssertEqual(refresh["report"]["assembledAt"], .number(42))
        let plan = BackendRemoteServeUsageService.empty(want: "plan", detail: "absent", now: 42)
        XCTAssertEqual(plan["readings"], .array([])); XCTAssertEqual(plan["sessionId"], .null); XCTAssertEqual(plan["report"], .missing)
    }
    private enum Failure: Error { case probe }
    private actor Calls {
        var events: [String] = []
        func add(_ event: String) { events.append(event) }
        func read() -> [String] { events }
    }
}
