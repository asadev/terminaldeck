import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
#if RNM_FOCUSED_BACKEND
import RNMFocusedCompatibility
#endif

final class RNMHootCompatibilityTests: XCTestCase {
    func testEveryMCPSpellingKeepsTheSameOperationGrant() {
        for suffix in ["state", "run", "instructions", "memory"] {
            let names = ["hoot." + suffix, "hoot_" + suffix, "copilot." + suffix, "copilot_" + suffix]
            for called in names {
                for granted in names {
                    XCTAssertTrue(RNMHootMCPCompatibility.permits(called, granted: [granted]))
                }
                XCTAssertFalse(RNMHootMCPCompatibility.permits(called, granted: ["hoot_chat_ask"]))
                XCTAssertFalse(RNMHootMCPCompatibility.permits(called, granted: []))
            }
        }
        XCTAssertFalse(RNMHootMCPCompatibility.permits("copilot_state_extra", granted: ["hoot_state"]))
        XCTAssertEqual(RNMHootMCPCompatibility.canonicalName("copilot_state_extra"), "copilot_state_extra")
        XCTAssertEqual(RNMHootMCPCompatibility.canonicalName("copilot.state"), "hoot.state")
        XCTAssertEqual(RNMHootMCPCompatibility.canonicalName("copilot_state"), "hoot_state")
        XCTAssertFalse(RNMHootMCPCompatibility.permits("hoot_run", granted: ["copilot_state"]))
    }

    func testHiddenAliasSharesActualHandlerAndCallerFence() async throws {
        let tool = try BackendMCPTool(id: "hoot.state", wireName: "hoot_state", description: "Read Hoot state.",
            inputSchema: .object([.init("type", .string("object"))]), tier: .read)
        let handler: BackendNativeMCPServer.Handler = { context, _ in
            guard context.sessionID == "owner-session", context.machineID == "owner-machine",
                  context.allowedTiers.contains(.read), !context.cancellation.isCancelled else {
                throw NativeRPCError(code: "access-denied", message: "The existing caller fence refused the call.")
            }
            return .value(.object([.init("session", .string(context.sessionID))]))
        }
        let contributions = try RNMHootMCPCompatibility.registrations([(tool, handler)])
        XCTAssertEqual(contributions.count, 2)
        XCTAssertEqual(contributions.filter { $0.0.advertised }.map { $0.0.wireName }, ["hoot_state"])
        let alias = try XCTUnwrap(contributions.first { $0.0.id == "copilot.state" })
        XCTAssertEqual(alias.0.wireName, "copilot_state")
        XCTAssertEqual(alias.0.tier, tool.tier)
        XCTAssertEqual(alias.0.inputSchema, tool.inputSchema)
        XCTAssertEqual(alias.0.description, tool.description)

        for (spec, registeredHandler) in contributions {
            let otherGrant = spec.id == "hoot.state" ? "copilot_state" : "hoot_state"
            XCTAssertTrue(RNMHootMCPCompatibility.permits(spec.id, granted: [otherGrant]))
            let allowed = BackendMCPCallContext(sessionID: "owner-session", machineID: "owner-machine", projectRoot: nil,
                attended: true, allowedTools: [otherGrant], allowedTiers: [.read], cancellation: .init())
            let reply = try await registeredHandler(allowed, .object([]))
            XCTAssertEqual(reply.structuredContent?["session"], .string("owner-session"))
            let denied = BackendMCPCallContext(sessionID: "another-session", machineID: "owner-machine", projectRoot: nil,
                attended: true, allowedTools: [otherGrant], allowedTiers: [.read], cancellation: .init())
            do { _ = try await registeredHandler(denied, .object([])); XCTFail("An alias lost the caller fence") }
            catch let failure as NativeRPCError { XCTAssertEqual(failure.code, "access-denied") }
            let cancelled = BackendMCPCancellation(); cancelled.cancel()
            let revoked = BackendMCPCallContext(sessionID: "owner-session", machineID: "owner-machine", projectRoot: nil,
                attended: true, allowedTools: [otherGrant], allowedTiers: [.read], cancellation: cancelled)
            do { _ = try await registeredHandler(revoked, .object([])); XCTFail("An alias lost cancellation") }
            catch let failure as NativeRPCError { XCTAssertEqual(failure.code, "access-denied") }
        }
    }

    func testTaskProfileCannotEvadeABlockByChangingSpelling() {
        for denied in ["hoot_state", "copilot_state", "hoot.state", "copilot.state", "mcp__deck-control__copilot_state"] {
            XCTAssertFalse(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: "hoot.state", wire: "hoot_state", allowed: nil, denied: [denied]))
            XCTAssertFalse(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: "copilot.state", wire: "copilot_state", allowed: ["hoot_state"], denied: [denied]))
        }
        XCTAssertTrue(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: "hoot.state", wire: "hoot_state", allowed: ["copilot_state"], denied: []))
        XCTAssertFalse(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: "hoot.run", wire: "hoot_run", allowed: ["copilot_state"], denied: []))
        XCTAssertFalse(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: "hoot.state", wire: "hoot_state", allowed: [], denied: []))
    }

    func testUnrelatedProfileOperationsKeepOriginalTAGCandidateSet() {
        let cases: [(id: String, wire: String)] = [
            ("read", "read"), ("ordinary_internal", "actual_read"),
            ("ordinary.internal", "actual_read"), ("ordinary_internal", "read"),
            ("plugin.read", "plugin_read"), ("copilot.custom", "copilot_custom")
        ]
        for operation in cases {
            let fullname = "mcp__deck-control__" + operation.wire
            XCTAssertTrue(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: operation.id,
                wire: operation.wire, allowed: [fullname], denied: []))
            XCTAssertFalse(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: operation.id,
                wire: operation.wire, allowed: nil, denied: [fullname]))
            let rules = [operation.id, operation.wire, fullname, "mcp__deck-control", "mcp__deck-control__" + operation.id,
                         "mcp__deck-control__hoot_state", "mcp__deck-control__copilot_state"]
            for rule in rules {
                let allowedSets: [[String]?] = [nil, [], [rule]]
                for allowed in allowedSets {
                    for denied in [[], [rule]] {
                        XCTAssertEqual(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: operation.id,
                            wire: operation.wire, allowed: allowed, denied: denied),
                            BackendTAGToolPolicy.permits(server: "deck-control", id: operation.id,
                                wire: operation.wire, allowed: allowed, denied: denied), "\(operation.id)/\(operation.wire)/\(rule)")
                    }
                }
            }
        }
        XCTAssertFalse(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: "ordinary_internal",
            wire: "actual_read", allowed: ["mcp__deck-control__ordinary_internal"], denied: []))
        XCTAssertFalse(RNMHootMCPCompatibility.profilePermits(server: "deck-control", id: "copilot.custom",
            wire: "copilot_custom", allowed: ["hoot_custom"], denied: []))
    }

    func testIncomingClientAliasesUseExistingSchemaAndTier() throws {
        for suffix in RNMHootWireCompatibility.clientSuffixes {
            let fields = clientFields(suffix)
            let old = object([("t", .string("copilot." + suffix))] + fields)
            let new = object([("t", .string("hoot." + suffix))] + fields)
            let parsedOld = BackendRemoteProtocol.parseClientMessage(old)
            let parsedNew = RNMHootWireCompatibility.parseIncomingClient(new)
            XCTAssertEqual(parsedNew, parsedOld, suffix)
            guard case .message(let message) = parsedNew else { XCTFail("Valid fixture refused: " + suffix); continue }
            XCTAssertEqual(message.type, "copilot." + suffix)
            XCTAssertEqual(BackendCopilotRemoteSurface.frameTier[message.type], BackendCopilotRemoteSurface.frameTier["copilot." + suffix])
        }
        let noAccess = BackendCopilotRemoteGrant(read: false, act: false, alter: false)
        XCTAssertFalse(BackendCopilotRemoteSurface.allowed(noAccess, verb: RNMHootWireCompatibility.incomingClientType("hoot.answer")))
    }

    func testRenamedClientCannotBypassPayloadValidation() {
        for value in [
            object([("t", .string("hoot.answer")), ("id", .string("q"))]),
            object([("t", .string("hoot.file.read")), ("id", .string("../../private"))]),
            object([("t", .string("hoot.say")), ("text", .string(String(repeating: "a", count: 16_385)))]),
            object([("t", .string("hoot.execute")), ("command", .string("arbitrary"))])
        ] {
            guard case .refused = RNMHootWireCompatibility.parseIncomingClient(value) else {
                XCTFail("Renamed request bypassed the sealed schema"); continue
            }
        }
    }

    func testIncomingServerAliasesUseExistingSchemaAndOutboundStaysLegacy() throws {
        for suffix in RNMHootWireCompatibility.serverSuffixes {
            let oldType = "copilot." + suffix
            let kind = try XCTUnwrap(BackendRemoteServerMessage.Kind(rawValue: oldType))
            let outbound = try BackendRemoteServerMessage(kind, fields: serverFields(suffix).map { .init($0.0, $0.1) })
            XCTAssertEqual(outbound.value["t"], .string(oldType))
            let incoming = outbound.value.setting("t", .string("hoot." + suffix))
            let normalized = RNMHootWireCompatibility.incomingServerEnvelope(incoming)
            let parsed = try BackendRemoteGuestFrames.parse(String(decoding: normalized.encodedJSON(), as: UTF8.self))
            XCTAssertEqual(parsed["t"], .string(oldType))
            XCTAssertTrue(try BackendRemoteProtocol.serialize(outbound).contains(oldType))
        }
        let unknown = object([("t", .string("hoot.execute"))])
        XCTAssertEqual(RNMHootWireCompatibility.incomingServerEnvelope(unknown), unknown)
        let malformed = object([("t", .string("hoot.ask")), ("question", .string("untrusted"))])
        let normalized = RNMHootWireCompatibility.incomingServerEnvelope(malformed)
        XCTAssertThrowsError(try BackendRemoteGuestFrames.parse(String(decoding: normalized.encodedJSON(), as: UTF8.self)))
    }

    func testOnlyKnownEnvelopeFieldsAreNormalized() {
        let nested = object([("t", .string("hoot.say")), ("text", .string("copilot.state"))])
        let ordinary = object([("t", .string("sessions")), ("hoot", nested), ("capabilities", .array([.string("hoot")]))])
        XCTAssertEqual(RNMHootWireCompatibility.incomingServerEnvelope(ordinary), ordinary)
        let hello = object([("t", .string("hello")), ("capabilities", .array([.string("hoot"), .string("hoot.files"), .string("hoot.events"), .number(7)]))])
        XCTAssertEqual(RNMHootWireCompatibility.incomingClientEnvelope(hello)["capabilities"], .array([.string("copilot"), .string("copilot.files"), .string("hoot.events"), .number(7)]))
        let welcome = object([("t", .string("welcome")), ("hoot", nested)])
        XCTAssertEqual(RNMHootWireCompatibility.incomingServerEnvelope(welcome)["copilot"], nested)
        let conflict = welcome.setting("copilot", .null)
        XCTAssertEqual(RNMHootWireCompatibility.incomingServerEnvelope(conflict)["copilot"], .null)
        XCTAssertEqual(RNMHootWireCompatibility.incomingServerEnvelope(nested)["text"], .string("copilot.state"))
        XCTAssertEqual(RNMHootWireCompatibility.incomingClientType("Hoot.say"), "Hoot.say")
        XCTAssertEqual(RNMHootWireCompatibility.incomingClientType("hoot.events"), "hoot.events")
    }

    func testNativeChannelAliasesAndPanelEnvelopeKeepPayloadUntouched() {
        for legacy in RNMHootChannelCompatibility.legacyChannels {
            let renamed = legacy.hasPrefix("machines:")
                ? "machines:hoot:" + legacy.dropFirst("machines:copilot:".count)
                : "hoot:" + legacy.dropFirst("copilot:".count)
            XCTAssertEqual(RNMHootChannelCompatibility.incomingChannel(renamed), legacy)
            XCTAssertEqual(RNMHootChannelCompatibility.incomingChannel(legacy), legacy)
        }
        let nested = object([("channel", .string("hoot:memory-write"))])
        let request = object([("channel", .string("hoot:state")), ("args", .array([nested, .string("copilot:state")]))])
        let normalized = RNMHootChannelCompatibility.incomingRequestEnvelope(request)
        XCTAssertEqual(normalized["channel"], .string("copilot:state"))
        XCTAssertEqual(normalized["args"], request["args"])
        for unknown in ["hoot:execute", "machines:hoot:execute", "other:hoot:state", "hoot:chat:ask"] {
            XCTAssertEqual(RNMHootChannelCompatibility.incomingChannel(unknown), unknown)
        }
    }

    private func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private func clientFields(_ suffix: String) -> [(String, NativeRPCValue)] {
        switch suffix {
        case "answer": return [("id", .string("question-1")), ("approved", .bool(false))]
        case "say": return [("text", .string("Hoot, hello."))]
        case "log": return [("limit", .number(2)), ("before", .string("row-1"))]
        case "interactive": return [("on", .bool(false))]
        case "file.read", "file.reset": return [("id", .string("yours"))]
        case "file.write": return [("id", .string("yours")), ("text", .string("Hoot instructions."))]
        case "memory.delete": return [("name", .string("fact.md"))]
        default: return []
        }
    }
    private func serverFields(_ suffix: String) -> [(String, NativeRPCValue)] {
        switch suffix {
        case "state": return [("state", .object([]))]
        case "chat": return [("run", .string("run-1")), ("messages", .array([]))]
        case "tool": return [("row", .object([]))]
        case "sessions": return [("sessions", .array([]))]
        case "log": return [("rows", .array([])), ("more", .bool(false))]
        case "pending": return [("questions", .array([]))]
        case "grant": return [("link", .object([]))]
        case "ask": return [("question", .object([]))]
        case "settled": return [("settled", .object([]))]
        case "files.rows": return [("files", .array([]))]
        default: return [("id", .string("yours")), ("text", .string("Hoot instructions."))]
        }
    }
}
