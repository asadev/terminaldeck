import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("ORG manager alias: existing approval and profile save",
       .enabled(if: ProcessInfo.processInfo.environment["ORG_FOCUSED_TESTS"] == "1", "WIP ORG"))
struct ORGMCPTests {
    actor Calls {
        var changes: [String] = []
        var taskChecks = 0
        func change(_ name: String) { changes.append(name) }
        func taskCheck() { taskChecks += 1 }
    }

    private func args(_ manager: NativeRPCValue, id: String = "worker") -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("managerId", manager)])
    }
    private func profile(_ id: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(id)), .init("provider", .string("claude")),
            .init("allowedTools", .array([.string("Read")])), .init("blockedTools", .array([.string("Edit")])),
            .init("permissionMode", .string("plan")), .init("skillsOff", .bool(true))])
    }
    private func memory() async throws -> BackendTaskConfiguration {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ORG-" + UUID().uuidString + ".noindex")
        let config = try BackendTaskConfiguration(persistence: .init(directory: scratch, ownership: .memory),
                                                 creatorHistoryURL: scratch.appendingPathComponent("actions.jsonl"))
        try await config.start()
        _ = try await config.saveAgent(profile("lead"))
        _ = try await config.saveAgent(profile("worker"))
        return config
    }
    private func service(_ config: BackendTaskConfiguration, calls: Calls, deny: Bool = false) -> BackendAGTDirectoryService {
        let authority = BackendTaskToolAuthority(requireTasks: { _ in await calls.taskCheck() }, requireHoot: { _ in },
            visible: { _, _ in true }, project: { _, _ in }, authorize: { _, name, _, tier in
                await calls.change(name)
                if deny && tier == .alter { throw NativeRPCError(code: "not-granted", message: "The owner said no.") }
            }, actorName: { _ in "ORG stub" }, callerKeyID: { _ in "org-key" })
        return BackendAGTDirectoryService(config: config, authority: authority)
    }
    private func caller(_ tiers: Set<BackendMCPTier> = [.read, .alter]) -> BackendMCPCallContext {
        .init(sessionID: "ORG-stub", machineID: "", projectRoot: nil, attended: true,
              allowedTools: Set(BackendORGMCP.ids + BackendAGTDirectoryTools.ids), allowedTiers: tiers,
              cancellation: BackendMCPCancellation())
    }

    @Test func aliasAcceptsManagersAndClearWhilePreservingRestrictions() async throws {
        let config = try await memory(), calls = Calls(), tools = service(config, calls: calls)
        let before = try #require(try await config.agent("worker"))
        for manager in [NativeRPCValue.string("lead"), .string("@hoot"), .null] {
            _ = try await BackendORGMCP.invoke(arguments: args(manager), caller: caller(), service: tools)
            let row = try #require(try await config.agent("worker"))
            #expect(row["reportsTo"].isNullish ? manager == .null : row["reportsTo"] == manager)
            for field in ["name", "provider", "allowedTools", "blockedTools", "permissionMode", "skillsOff"] {
                #expect(row[field] == before[field])
            }
        }
        #expect(await calls.changes == Array(repeating: "agents.set_reports_to", count: 3))
        #expect(await calls.taskChecks == 3)
    }

    @Test func deniedApprovalReadTierAndLoopsCannotSave() async throws {
        let config = try await memory(), calls = Calls()
        let allowed = service(config, calls: calls)
        let denied = service(config, calls: calls, deny: true)
        do {
            _ = try await BackendORGMCP.invoke(arguments: args(.string("lead")), caller: caller(), service: denied)
            Issue.record("Saved after approval refusal")
        } catch { #expect((error as? NativeRPCError)?.code == "not-granted") }
        #expect(try await config.agent("worker")?["reportsTo"].isNullish == true)
        do {
            _ = try await BackendORGMCP.invoke(arguments: args(.string("lead")), caller: caller([.read]), service: allowed)
            Issue.record("Read tier changed manager")
        } catch { #expect((error as? NativeRPCError)?.code == "not-granted") }
        _ = try await BackendORGMCP.invoke(arguments: args(.string("lead")), caller: caller(), service: allowed)
        for (id, manager) in [("lead", "worker"), ("worker", "worker"), ("worker", "unknown")] {
            do {
                _ = try await BackendORGMCP.invoke(arguments: args(.string(manager), id: id), caller: caller(), service: allowed)
                Issue.record("Accepted invalid manager")
            } catch {}
        }
        #expect(try await config.agent("worker")?["reportsTo"].string == "lead")
        #expect(try await config.agent("lead")?["reportsTo"].isNullish == true)
    }

    @Test func malformedInputIsRefusedBeforeAuthorityAndCannotWidenFields() async throws {
        let config = try await memory(), calls = Calls(), tools = service(config, calls: calls)
        for bad in [args(.bool(false)), args(.number(2)), args(.string("")),
                    NativeRPCValue.object([.init("id", .string("worker"))]),
                    args(.null).setting("allowedTools", .array([.string("Bash")])),
                    NativeRPCValue.array([])] {
            do {
                _ = try await BackendORGMCP.invoke(arguments: bad, caller: caller(), service: tools)
                Issue.record("Accepted malformed manager request")
            } catch {}
        }
        #expect(await calls.changes.isEmpty)
        #expect(await calls.taskChecks == 0)
        #expect(try await config.agent("worker")?["allowedTools"].elements == [.string("Read")])
    }

    @Test func aliasIsRegisteredAlongsideLegacyToolsAndRemovedWithItsOwner() async throws {
        let config = try await memory(), calls = Calls(), server = BackendNativeMCPServer()
        let tools = service(config, calls: calls), owner = "ORG-test-owner"
        try await BackendAGTDirectoryTools.install(server: server, service: tools, ownerID: owner)
        try await BackendORGMCP.install(service: tools, server: server, ownerID: owner)
        let registered = await server.registrations().map { $0.0 }
        #expect(Set(registered.map(\.id)) == Set(BackendAGTDirectoryTools.readIDs + BackendAGTDirectoryTools.changeIDs + BackendORGMCP.ids))
        let spec = try #require(registered.first { $0.id == BackendORGMCP.toolID })
        #expect(spec.wireName == "agents_set_manager" && spec.tier == .alter)
        #expect(spec.inputSchema["required"].elements == [.string("id"), .string("managerId")])
        await server.removeTools(ownerID: owner)
        #expect(await server.registrations().isEmpty)
    }

    @Test func aliasOnlyGrantKeepsCanonicalApprovalWithoutGrantingLegacyTools() async throws {
        let config = try await memory(), calls = Calls(), tools = service(config, calls: calls)
        let context = BackendMCPCallContext(sessionID: "ORG-alias-only", machineID: "", projectRoot: nil,
            attended: true, allowedTools: [BackendORGMCP.toolID], allowedTiers: [.alter], cancellation: BackendMCPCancellation())
        _ = try await BackendORGMCP.invoke(arguments: args(.string("lead")), caller: context, service: tools)
        #expect(try await config.agent("worker")?["reportsTo"].string == "lead")
        #expect(await calls.changes == ["agents.set_reports_to"])
        #expect(context.allowedTools == [BackendORGMCP.toolID])
    }
}
