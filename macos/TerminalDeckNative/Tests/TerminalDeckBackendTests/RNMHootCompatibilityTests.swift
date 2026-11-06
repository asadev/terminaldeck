import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HootToolNamesTests: XCTestCase {
    func testOnlyHootIdsAndWireNamesShareAnOperationGrant() {
        for suffix in ["state", "run", "instructions", "memory"] {
            let id = "hoot." + suffix, wire = "hoot_" + suffix
            XCTAssertTrue(BackendMCPToolNames.permits(id, granted: [wire]))
            XCTAssertTrue(BackendMCPToolNames.permits(wire, granted: [id]))
            for legacy in ["copilot." + suffix, "copilot_" + suffix] {
                XCTAssertFalse(BackendMCPToolNames.permits(id, granted: [legacy]))
                XCTAssertFalse(BackendMCPToolNames.permits(legacy, granted: [id, wire]))
                XCTAssertFalse(BackendTAGToolPolicy.permits(server: "deck-control", id: id, wire: wire, allowed: [legacy], denied: []))
            }
            XCTAssertFalse(BackendMCPToolNames.permits(id, granted: ["hoot_chat_ask"]))
            XCTAssertFalse(BackendMCPToolNames.permits(id, granted: []))
            XCTAssertFalse(BackendTAGToolPolicy.permits(server: "deck-control", id: id, wire: wire, allowed: nil, denied: [wire]))
        }
    }

    func testProfileRulesKeepRegisteredNamesServerScopeAndDenyPriority() {
        for (id, wire) in [("ordinary.internal", "actual_read"), ("read", "read"), ("hoot.state", "hoot_state")] {
            for rule in [id, wire, "mcp__deck-control", "mcp__deck-control__" + wire] {
                XCTAssertTrue(BackendTAGToolPolicy.permits(server: "deck-control", id: id, wire: wire, allowed: [rule], denied: []))
                XCTAssertFalse(BackendTAGToolPolicy.permits(server: "deck-control", id: id, wire: wire, allowed: [rule], denied: [wire]))
            }
            XCTAssertFalse(BackendTAGToolPolicy.permits(server: "deck-control", id: id, wire: wire, allowed: [], denied: []))
            XCTAssertFalse(BackendTAGToolPolicy.permits(server: "deck-control", id: id, wire: wire, allowed: ["mcp__other"], denied: []))
        }
        XCTAssertFalse(BackendTAGToolPolicy.permits(server: "deck-control", id: "ordinary_internal", wire: "actual_read", allowed: ["mcp__deck-control__ordinary_internal"], denied: []))
    }

    func testOneSpecificationPreservesMetadataHandlerAndRegistersNoHiddenAlias() async throws {
        let spec = try BackendMCPTool(id: "hoot.state", wireName: "hoot_state", description: "Read Hoot state.",
            inputSchema: .object([.init("type", .string("object"))]), tier: .read)
        let definition = BackendDeckToolsDefinition(spec: spec, title: "Hoot state", index: "Read Hoot.") { context, _ in
            guard context.sessionID == "owner", !context.cancellation.isCancelled else { throw NativeRPCError(code: "access-denied", message: "Caller refused") }
            return .value(.bool(true))
        }
        let metadata: BackendDeckCoreCatalogueMetadata = definition
        XCTAssertEqual(metadata.wireValue, spec.wireValue)
        XCTAssertEqual(metadata.advertisedValue["title"], .string("Hoot state"))
        let registry = try BackendDeckCoreCatalogueRegistry(metadata: [metadata])
        XCTAssertNotNil(registry.resolve("hoot_state"))
        XCTAssertNil(registry.resolve("copilot_state"))
        XCTAssertNil(registry.resolve("copilot.state"))
        let areas = try BackendDeckToolsSupport.areas(definitions: [definition])
        let server = BackendNativeMCPServer()
        try await areas[0].register(on: server)
        let registered = await server.registrations()
        XCTAssertEqual(registered.map { $0.0.id }, ["hoot.state"])
        let handler = try XCTUnwrap(registered.first?.1)
        let owner = BackendMCPCallContext(sessionID: "owner", machineID: "machine", projectRoot: nil, attended: true, allowedTools: ["hoot_state"], allowedTiers: [.read], cancellation: .init())
        let reply = try await handler(owner, .object([]))
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.content.first?["text"].string, "true")
        let outsider = BackendMCPCallContext(sessionID: "other", machineID: "machine", projectRoot: nil, attended: true, allowedTools: ["hoot_state"], allowedTiers: [.read], cancellation: .init())
        do { _ = try await handler(outsider, .object([])); XCTFail("Caller fence was lost") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        XCTAssertThrowsError(try BackendDeckToolsSupport.area(id: "app", definitions: [spec]))
        XCTAssertThrowsError(try BackendDeckToolsSupport.areas(definitions: [definition, definition]))
        let source = try BackendDeckToolsAppMetadata.entries().filter { $0.spec.id.hasPrefix("hoot.") }
        XCTAssertEqual(source.count, 4)
        XCTAssertTrue(source.allSatisfy { $0.aliases.isEmpty })
    }

    func testNativeChannelsHaveOneNameAndOneRegistration() async throws {
        let registry = NativeChannelRegistry()
        try await registry.register("hoot:state", ownerID: "test") { _, _ in .bool(true) }
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "test")
        let value = try await registry.invoke("hoot:state", context: context, arguments: [])
        XCTAssertEqual(value, .bool(true))
        let hasLegacy = await registry.has("copilot:state")
        XCTAssertFalse(hasLegacy)
        do { _ = try await registry.invoke("copilot:state", context: context, arguments: []); XCTFail("Legacy route still answered") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "missing-handler") }
        XCTAssertEqual(Set(BackendHootChatChannels.invokes).count, BackendHootChatChannels.invokes.count)
        // 9 since b1a97421 (6 Nov): Hoot's Fork has its own route.
        XCTAssertEqual(BackendHootChatChannels.invokes.count, 9)
        XCTAssertTrue(BackendHootChatChannels.invokes.contains("hoot:chat:fork"))
    }

    /// 26 Oct 2026 (ec412557, accepted): TestFlight 0.20.0 phones still send Hoot's frames as `copilot.*`, and a
    /// refusal closed their link every second. Those frames are read as `hoot.*` on the way in, so inside the Mac
    /// there is still one name; nothing is answered as `copilot.*` and `copilot` is never advertised.
    func testRemoteHootFramesAreCanonicalAndAnOlderPhonesFramesReadAsHoot() throws {
        for suffix in ["hello", "state", "start", "files", "stop"] {
            guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string("hoot." + suffix))])) else { return XCTFail("Canonical frame refused") }
            XCTAssertEqual(message.type, "hoot." + suffix)
            guard case .message(let older) = BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string("copilot." + suffix))])) else { return XCTFail("An older phone's frame was refused") }
            XCTAssertEqual(older.type, "hoot." + suffix, "read under its one name")
        }
        guard case .refused = BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string("copilot."))])) else { return XCTFail("A bare prefix was answered") }
        let outbound = try BackendRemoteServerMessage(.copilotState, fields: [.init("state", .object([]))])
        XCTAssertEqual(outbound.value["t"], .string("hoot.state"))
        guard case .refused = BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string("hoot.answer")), .init("id", .string("q"))])) else { return XCTFail("Payload validation was lost") }
        XCTAssertFalse(BackendRemoteProtocol.capabilities.contains("copilot"))
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("hoot"))
    }
}
