import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor FIXESIslandToolRig {
    var writes = 0, reads = 0, ownerRequests = 0
    var allow = false
    var current: NativeRPCValue = .object([.init("mode", .string("main"))])
    func authorize(tier: BackendMCPTier, owner: Bool) throws {
        if tier != .read {
            if owner { ownerRequests += 1 }
            guard owner && allow else { throw NativeRPCError(code: "denied", message: "The person said no.") }
        }
    }
    func read() -> NativeRPCValue { reads += 1; return .object([.init("showOn", current)]) }
    func write(_ raw: NativeRPCValue) -> NativeRPCValue { writes += 1; current = raw; return read() }
    func permit() { allow = true }
}
private actor FIXESIslandVisibilityGate {
    private var checks = 0
    func check() throws {
        checks += 1
        if checks > 1 { throw NativeRPCError(code: "access-denied", message: "Grant revoked during approval") }
    }
}

final class FIXESIslandMCPTests: XCTestCase {
    private func tools(_ rig: FIXESIslandToolRig, visible: @escaping @Sendable (BackendMCPCallContext) async throws -> Void = { _ in }) throws -> [BackendDeckToolsDefinition] {
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) },
            knownFolder: { _, folder in folder }, session: { _, _ in .null }, runnableProject: { _, folder in folder },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "stub") },
            authorize: { _, _, _, tier, _, owner in try await rig.authorize(tier: tier, owner: owner) }, record: { _, _, _, _ in })
        return try BackendFIXESIslandMCP.definitions(access: access, visible: visible,
            read: { await rig.read() }, configure: { await rig.write($0) })
    }
    private func context(_ tools: Set<String>, tier: BackendMCPTier, cancellation: BackendMCPCancellation = .init()) -> BackendMCPCallContext {
        .init(sessionID: "stub", machineID: "", projectRoot: nil, attended: true,
            allowedTools: tools, allowedTiers: [tier], cancellation: cancellation)
    }
    func testReadRunsFreelyAndChangeNeedsPersonBeforeWriting() async throws {
        let rig = FIXESIslandToolRig(), definitions = try tools(rig)
        let read = try XCTUnwrap(definitions.first { $0.spec.id == "hoot.island.read" })
        let change = try XCTUnwrap(definitions.first { $0.spec.id == "hoot.island.configure" })
        let value = try await read.handler(context([read.spec.id], tier: .read), .object([]))
        XCTAssertEqual(value.structuredContent?["showOn"]["mode"].string, "main")
        let patch = NativeRPCValue.object([.init("mode", .string("pointer"))])
        do { _ = try await change.handler(context([change.spec.id], tier: .alter), patch); XCTFail("Denied change wrote") } catch {}
        let deniedWrites = await rig.writes, requests = await rig.ownerRequests
        XCTAssertEqual(deniedWrites, 0); XCTAssertEqual(requests, 1)
        await rig.permit()
        let applied = try await change.handler(context([change.spec.id], tier: .alter), patch)
        XCTAssertEqual(applied.structuredContent?["showOn"]["mode"].string, "pointer")
        let writes = await rig.writes; XCTAssertEqual(writes, 1)
    }
    func testNarrowedGrantRevokedVisibilityAndCancellationNeverReachPreference() async throws {
        let rig = FIXESIslandToolRig(), definitions = try tools(rig), read = definitions[0]
        do { _ = try await read.handler(context([], tier: .read), .object([])); XCTFail("Missing grant read") } catch {}
        let revoked = try self.tools(rig, visible: { _ in throw NativeRPCError(code: "access-denied", message: "Grant revoked") })
        do { _ = try await revoked[0].handler(context([read.spec.id], tier: .read), .object([])); XCTFail("Revoked grant read") } catch {}
        let cancel = BackendMCPCancellation(); cancel.cancel()
        do { _ = try await read.handler(context([read.spec.id], tier: .read, cancellation: cancel), .object([])); XCTFail("Cancelled read") } catch {}
        let reads = await rig.reads; XCTAssertEqual(reads, 0)
    }
    func testGrantRevokedDuringApprovalCannotWrite() async throws {
        let rig = FIXESIslandToolRig(), gate = FIXESIslandVisibilityGate()
        await rig.permit()
        let definitions = try tools(rig, visible: { _ in try await gate.check() })
        let change = try XCTUnwrap(definitions.first { $0.spec.id == "hoot.island.configure" })
        do {
            _ = try await change.handler(context([change.spec.id], tier: .alter), .object([.init("mode", .string("pointer"))]))
            XCTFail("A grant revoked during approval wrote the screen choice")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        let writes = await rig.writes, ownerRequests = await rig.ownerRequests
        XCTAssertEqual(ownerRequests, 1); XCTAssertEqual(writes, 0)
    }
}
