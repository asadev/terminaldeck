import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreMCPPoliciesTests: XCTestCase {
    func testSuppliedAuthorityWrapperIsKeptInsteadOfRegenerated() async throws {
        let originals = try BackendDeckCoreEventsTools.mcpPolicies()
        let scoped = originals.map { original in
            BackendDeckCoreSecurityToolPolicy(tool: original.tool, aliases: original.aliases, audience: original.audience,
                keyRequiresTasks: original.keyRequiresTasks, spendsDeviceInput: original.spendsDeviceInput,
                summary: original.summary, precheck: original.precheck, escalate: original.escalate,
                ownerMustAnswer: original.ownerMustAnswer, redactArgs: original.redactArgs,
                run: { _, context in
                    guard context.caller.kind == .key, context.caller.keyID == "key-one" else {
                        throw NativeRPCError(code: "access-denied", message: "The authenticated wrapper was lost.")
                    }
                    return .init(value: .object([.init("key", .string(context.caller.keyID!)), .init("call", .string(context.callID))]))
                })
        }
        let resolved = try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckCoreEventsUnavailableMCPProvider(), supplied: scoped)
        let policy = try XCTUnwrap(resolved.first { $0.tool.id == "mcp.list" })
        let cancellation = BackendMCPCancellation()
        let native = BackendMCPCallContext(sessionID: "", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["mcp.list"], allowedTiers: [.read], cancellation: cancellation)
        let context = BackendDeckCoreSecurityCallContext(native: native, caller: .init(kind: .key, tiers: [.read], keyID: "key-one"),
            callID: "request-one", attended: true, granted: nil, sessionLimits: .missing, now: { 0 },
            startedByCopilot: { _ in false }, noteStarted: { _ in })
        let result = try await policy.run(.object([]), context)
        XCTAssertEqual(result.value["key"], .string("key-one"))
        XCTAssertEqual(result.value["call"], .string("request-one"))
    }

    func testPolicyOverrideCannotOmitDuplicateOrDowngradeSourceOperations() throws {
        let originals = try BackendDeckCoreEventsTools.mcpPolicies()
        XCTAssertThrowsError(try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckCoreEventsUnavailableMCPProvider(), supplied: []))
        XCTAssertThrowsError(try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckCoreEventsUnavailableMCPProvider(), supplied: originals + [originals[0]]))
        let changed = try originals.map { policy -> BackendDeckCoreSecurityToolPolicy in
            guard policy.tool.id == "mcp.call" else { return policy }
            let tool = try BackendMCPTool(id: policy.tool.id, wireName: policy.tool.wireName, description: policy.tool.description,
                inputSchema: policy.tool.inputSchema, tier: .read)
            return .init(tool: tool, summary: policy.summary, run: policy.run)
        }
        XCTAssertThrowsError(try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckCoreEventsUnavailableMCPProvider(), supplied: changed))
    }
}
