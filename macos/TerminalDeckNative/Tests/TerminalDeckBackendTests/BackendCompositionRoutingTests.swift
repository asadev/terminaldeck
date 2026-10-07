import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Written for the combined gate. No sockets, processes, credential providers,
/// files or production state are opened by these routing fixtures.
struct BackendCompositionRoutingTests {
    private func root() throws -> BackendCompositionRoot {
        try BackendCompositionRoot(dataRoot: URL(fileURLWithPath: "/tmp/native-routing-fixture"),
            state: NativeStateStore(), environment: [:], home: "/tmp")
    }

    @Test func absentRoutesRemainAvailableForNodeFallback() async throws {
        let graph = try root()
        #expect(await graph.hasInvoke("tasks:list") == false)
        #expect(await graph.hasSend("session:write") == false)
        try await graph.shutdown()
    }

    @Test func aHandlerRefusalKeepsItsNativeCode() async throws {
        let graph = try root()
        try await graph.registry.register("fixture:write", ownerID: "fixture") { _, _ in
            throw NativeRPCError(code: "access-denied", message: "The current grant was removed.")
        }
        try await graph.retain(.init(name: "fixture", domains: ["fixture"], ownerID: "fixture",
            invokes: ["fixture:write"], stop: {}))
        do {
            _ = try await graph.invoke("fixture:write", context: .init(caller: .nativeApp, ownerID: "native-app"), arguments: [])
            Issue.record("A native refusal must not turn into a Node retry.")
        } catch let failure as NativeRPCError { #expect(failure.code == "access-denied") }
        #expect(await graph.hasInvoke("fixture:write"))
        try await graph.shutdown()
    }

    @Test func anAreaCannotClaimAnotherAreasHandler() async throws {
        let graph = try root()
        try await graph.registry.register("fixture:read", ownerID: "original") { _, _ in .null }
        do {
            try await graph.retain(.init(name: "other", domains: ["other"], ownerID: "other",
                invokes: ["fixture:read"], stop: {}))
            Issue.record("Registration ownership must be checked, not just channel presence.")
        } catch let failure as NativeRPCError { #expect(failure.code == "composition-owner") }
        #expect(await graph.hasInvoke("fixture:read") == false)
        try await graph.shutdown()
    }

    @Test func launchManifestCannotGrowAfterSealing() async throws {
        let graph = try root()
        await graph.seal()
        do { try await graph.requireAssemblyOpen(); Issue.record("Late writers must wait for a new engine launch.") }
        catch let failure as NativeRPCError { #expect(failure.code == "composition-sealed") }
        try await graph.shutdown()
    }

    @Test func replacingOneMCPAreaPreservesOtherOwners() async throws {
        let server = BackendNativeMCPServer()
        let first = try BackendMCPTool(id: "one.read", wireName: "one_read", description: "one", inputSchema: .object([]), tier: .read)
        let second = try BackendMCPTool(id: "two.read", wireName: "two_read", description: "two", inputSchema: .object([]), tier: .read)
        try await server.replaceTools(ownerID: "one", tools: [(first, { @Sendable _, _ in .value(.null) })])
        try await server.replaceTools(ownerID: "two", tools: [(second, { @Sendable _, _ in .value(.null) })])
        try await server.replaceTools(ownerID: "one", tools: [])
        #expect(try await server.catalogue().map(\.id) == ["two.read"])
    }

    @Test func contextlessCallbacksKeepTheActualPeerIdentity() async throws {
        let registry = NativeChannelRegistry()
        try await registry.register("fixture:identity", ownerID: "fixture") { _, _ in
            .string(NativeCompositionCallContext.rpc?.ownerID ?? "absent")
        }
        let answer = try await registry.invoke("fixture:identity", context: .init(caller: .pairedDevice, ownerID: "actual-peer"), arguments: [])
        #expect(answer == .string("actual-peer"))
        #expect(NativeCompositionCallContext.rpc == nil)
        await registry.shutdown()
    }

    @Test func failedMCPReplacementLeavesTheExistingAreaIntact() async throws {
        let server = BackendNativeMCPServer()
        let first = try BackendMCPTool(id: "one.read", wireName: "one_read", description: "one", inputSchema: .object([]), tier: .read)
        let second = try BackendMCPTool(id: "two.read", wireName: "two_read", description: "two", inputSchema: .object([]), tier: .read)
        try await server.replaceTools(ownerID: "one", tools: [(first, { @Sendable _, _ in .value(.null) })])
        try await server.replaceTools(ownerID: "two", tools: [(second, { @Sendable _, _ in .value(.null) })])
        do {
            try await server.replaceTools(ownerID: "one", tools: [(second, { @Sendable _, _ in .value(.null) })])
            Issue.record("A contribution cannot steal another area's alias.")
        } catch {}
        #expect(try await server.catalogue().map(\.id) == ["one.read", "two.read"])
    }
}
