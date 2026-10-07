import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Intentionally thin ingress into the actual shared Safari inbox. It does not
/// repair missing source result fields or invent a second request desk. Tests
/// retain their TS expectations, exposing the documented native-ingress gaps.
struct BackendDeckToolsSessionsPortLiftIngress: BackendDeckToolsSessionsLiftRequests {
    let inbox: BackendBrowserWorkersLiftRequests
    let workers: NativeRPCValue
    func file(askedBy: String, from: String, into: [String], reason: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let caller = BackendBrowserScrapingCaller(ownerID: "fixture", sessionID: context.sessionID, machineID: context.machineID, attended: context.attended, remote: false)
        let args = BackendDeckToolsSupport.object([("from", .string(from)), ("into", .array(into.map(NativeRPCValue.string))), ("reason", reason)])
        // Actual actor has no askedBy ingress yet; do not fake that field here.
        return try await inbox.file(args, caller: caller, workers: workers)
    }
}

@MainActor final class BackendDeckToolsSessionsPortLiftTests: XCTestCase {
    private typealias V = BackendDeckToolsSessionsPortValues
    private func rig() async -> (BackendDeckToolsSessionsPortRig, BackendDeckToolsSessionsPortLiftIngress, BackendDeckCoreSecurityTestBox<Int>) {
        let changed = BackendDeckCoreSecurityTestBox(0)
        let inbox = BackendBrowserWorkersLiftRequests(profiles: { _ in [.init(id: "p-default", name: "Default"), .init(id: "w1", name: "Worker 1")] }, authorize: { _, _, _, _, _ in }, changed: { changed.edit { $0 += 1 } })
        let ingress = BackendDeckToolsSessionsPortLiftIngress(inbox: inbox, workers: V.object([("workers", .array([V.object([("profileId", .string("w1")), ("name", .string("Worker 1"))])]))]))
        let runtime = BackendDeckToolsSessionsPortRig(); await runtime.setCaller(.init(kind: .session, sessionID: "s1", callID: "call-1"))
        return (runtime, ingress, changed)
    }
    private func call(_ args: NativeRPCValue, runtime: BackendDeckToolsSessionsPortRig, ingress: BackendDeckToolsSessionsPortLiftIngress,
                      attended: Bool = true) async throws -> BackendMCPToolReply {
        let definitions = try BackendDeckToolsSessionsArea.liftDefinitions(runtime: runtime, requests: ingress)
        return try await V.handler("browser.lift_request", in: definitions)(V.context(attended: attended, sessionID: "s1"), args)
    }
    private func read(_ ingress: BackendDeckToolsSessionsPortLiftIngress) async throws -> [NativeRPCValue] {
        try await ingress.inbox.list(.init(ownerID: "fixture", sessionID: "s1", machineID: "", attended: true, remote: false)).elements ?? []
    }
    func testLiftAskL97FilesOnlyARequestAndReturnsActualResolvedNames() async throws {
        let (runtime, ingress, changed) = await rig()
        let reply = try await call(V.object([("from", .string("Default")), ("reason", .string("The marina run needs signed-in workers."))]), runtime: runtime, ingress: ingress)
        XCTAssertFalse(reply.isError); XCTAssertEqual(reply.structuredContent?["asked"], .bool(true)); XCTAssertEqual(reply.structuredContent?["repeated"], .bool(false))
        XCTAssertEqual(reply.structuredContent?["from"], .string("Default")); XCTAssertEqual(reply.structuredContent?["into"], .array([.string("Worker 1")]))
        let rows = try await read(ingress); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["reason"], .string("The marina run needs signed-in workers.")); XCTAssertEqual(changed.get(), 1)
        XCTAssertTrue(reply.structuredContent?["note"].string?.contains("Do not retry") == true)
        XCTAssertFalse(reply.structuredContent?.compact.contains("cookie") == true)
    }
    func testLiftAskL120RepeatedAskUsesSameSharedInboxRow() async throws {
        let (runtime, ingress, _) = await rig()
        let first = try await call(V.object([("from", .string("Default"))]), runtime: runtime, ingress: ingress)
        let again = try await call(V.object([("from", .string("Default"))]), runtime: runtime, ingress: ingress)
        XCTAssertFalse(again.isError); XCTAssertEqual(again.structuredContent?["repeated"], .bool(true))
        XCTAssertEqual(again.structuredContent?["requestId"], first.structuredContent?["requestId"])
        let rows = try await read(ingress); XCTAssertEqual(rows.count, 1)
    }
    func testLiftAskL131UnknownProfileUsesDeskSentenceAndNeverReturnsEmptySuccess() async throws {
        let (runtime, ingress, _) = await rig()
        let reply = try await call(V.object([("from", .string("Nope"))]), runtime: runtime, ingress: ingress)
        XCTAssertTrue(reply.isError); XCTAssertTrue(V.error(reply).contains("no profile called \"Nope\""))
        let rows = try await read(ingress); XCTAssertEqual(rows, [])
    }
    func testLiftAskL139PairedDeviceCannotAskForOwnersLogins() async throws {
        let (runtime, ingress, _) = await rig(); await runtime.setCaller(.init(kind: .remote, deviceID: "d1", callID: "call-1"))
        let reply = try await call(V.object([("from", .string("Default"))]), runtime: runtime, ingress: ingress)
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["refusal"], .string("not-granted"))
        let rows = try await read(ingress); XCTAssertEqual(rows, [])
    }
    func testLiftAskL147UnattendedAskStopsWithDoNotRetryBeforeInboxWrite() async throws {
        let (runtime, ingress, _) = await rig()
        let reply = try await call(V.object([("from", .string("Default"))]), runtime: runtime, ingress: ingress, attended: false)
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["refusal"], .string("not-permitted-unattended")); XCTAssertTrue(V.error(reply).contains("Do not retry"))
        let rows = try await read(ingress); XCTAssertEqual(rows, [])
    }
}
