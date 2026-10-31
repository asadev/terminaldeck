import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("AGT agents: org fields in the TAG store, MCP tools, agent file writer")
struct AGTDirectoryTests {
    private func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendTaskValues.object(pairs) }
    private func profile(_ id: String, _ pairs: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        object([("id", .string(id)), ("name", .string(id.capitalized)), ("provider", .string("claude"))] + pairs)
    }
    private func memory() async throws -> BackendTaskConfiguration {
        let config = try BackendTaskConfiguration(persistence: .init(directory: URL(fileURLWithPath: "/AGT-memory"), ownership: .memory))
        try await config.start()
        return config
    }

    actor Calls {
        var tiers: [(String, BackendMCPTier)] = []
        func add(_ tool: String, _ tier: BackendMCPTier) { tiers.append((tool, tier)) }
    }

    private func service(_ config: BackendTaskConfiguration, calls: Calls, key: String? = "key-1", deny: Bool = false) -> BackendAGTDirectoryService {
        let authority = BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { _ in }, visible: { _, _ in true }, project: { _, _ in },
            authorize: { _, tool, _, tier in
                await calls.add(tool, tier)
                if deny && tier != .read { throw NativeRPCError(code: "not-granted", message: "The owner said no.") }
            },
            actorName: { _ in "Key" }, callerKeyID: { _ in key })
        let live: BackendAGTDirectoryService.LiveRead = { _ in
            let hoot = AWWatchAgent.decode(.object([.init("id", .string("hoot-row")), .init("sourceID", .string("hoot")), .init("kind", .string("hoot")),
                                                    .init("name", .string("Hoot")), .init("state", .string("idle"))]))!
            return ([hoot], [], [])
        }
        return BackendAGTDirectoryService(config: config, authority: authority, live: live)
    }
    private func context(tiers: Set<BackendMCPTier> = [.read, .act, .alter]) -> BackendMCPCallContext {
        BackendMCPCallContext(sessionID: "s", machineID: "", projectRoot: nil, attended: true, allowedTools: Set(BackendAGTDirectoryTools.ids),
                              allowedTiers: tiers, cancellation: BackendMCPCancellation())
    }

    @Test func savedProfileUsesCanonicalEffectiveChoicesRatherThanNullDirectoryModel() async throws {
        let config = try await memory(); _ = try await config.saveAgent(profile("probe").setting("provider", .string("codex")))
        let base = service(config, calls: Calls())
        let expected = NativeRPCValue.object([.init("effective", .object([.init("model", .string("gpt-6.1-sol")), .init("effort", .string("xhigh"))])), .init("choiceLine", .string("Codex · from its own settings; gpt-6.1-sol · effort xhigh · from the app defaults"))])
        let reader = BackendAGTDirectoryService(config: config, authority: base.authority, live: base.live,
            profileRead: { _, id in
                #expect(id == "probe")
                return expected
            })
        let actual = try await reader.invoke("agents.profile", arguments: object([("id", .string("probe"))]), caller: context())
        #expect(actual == expected.setting("sessions", .array([]))) // R25: profile detail includes its runs.
    }
    @Test func oldProfilesKeepTheirExactShapeAndNewFieldsAreOptional() throws {
        let old = try BackendTaskConfiguration.cleanAgent(profile("legacy"), others: [])
        #expect(!old.has("icon") && !old.has("reportsTo"))
        let new = try BackendTaskConfiguration.cleanAgent(profile("new", [("icon", .string("sf:hammer")), ("reportsTo", .string("@hoot"))]), others: [])
        #expect(new["icon"].string == "sf:hammer" && new["reportsTo"].string == "@hoot")
        for bad: [(String, NativeRPCValue)] in [[("icon", .string("emoji:nope"))], [("reportsTo", .string("Not An Id"))]] {
            do { _ = try BackendTaskConfiguration.cleanAgent(profile("bad", bad), others: []); Issue.record("Accepted \(bad)") } catch {}
        }
    }

    @Test func savesWithoutTheFieldsKeepThemAndLoopsAreRefused() async throws {
        let config = try await memory()
        _ = try await config.saveAgent(profile("lead"))
        _ = try await config.saveAgent(profile("worker", [("icon", .string("emoji:🐝")), ("reportsTo", .string("lead"))]))
        // An editor from before AGT sends the whole row without the new fields.
        _ = try await config.saveAgent(profile("worker", [("role", .string("Builds"))]))
        #expect(try await config.agent("worker")?["icon"].string == "emoji:🐝")
        #expect(try await config.agent("worker")?["reportsTo"].string == "lead")
        for (id, boss, words) in [("lead", "worker", "already reports to"), ("lead", "lead", "itself"), ("lead", "nobody", "no agent called")] {
            do { _ = try await config.saveAgent(profile(id, [("reportsTo", .string(boss))])); Issue.record("Accepted \(id) → \(boss)") }
            catch { #expect(error.localizedDescription.contains(words), "\(error.localizedDescription)") }
        }
        // Clearing is explicit null; removing a manager makes its reports independent.
        _ = try await config.saveAgent(profile("worker", [("icon", .null)]))
        #expect(try await config.agent("worker")?.has("icon") == false)
        try await config.removeAgent("lead")
        #expect(try await config.agent("worker")?["reportsTo"].isNullish == true)
    }

    @Test func readsAreFreeAndListEveryoneWithOrgInfo() async throws {
        let config = try await memory(), calls = Calls()
        _ = try await config.saveAgent(profile("lead", [("defaultProject", .string("/w/app")), ("reportsTo", .string("@hoot"))]))
        _ = try await config.saveAgent(profile("worker", [("defaultProject", .string("/w/app")), ("reportsTo", .string("lead"))]))
        let tools = service(config, calls: calls)
        let directory = try await tools.invoke("agents.directory", arguments: .object([]), caller: context(tiers: [.read]))
        #expect(directory["agents"].elements?.compactMap { $0["id"].string } == ["@hoot", "lead", "worker"])
        #expect(directory["groups"].elements?.compactMap { $0["title"].string } == ["Every project", "app"])
        #expect(directory["agents"].elements?[2]["reportsTo"].string == "lead")
        let chart = try await tools.invoke("agents.org_chart", arguments: .object([]), caller: context(tiers: [.read]))
        #expect(chart["trees"].elements?.first?["reports"].elements?.first?["reports"].elements?.first?["id"].string == "worker")
        let one = try await tools.invoke("agents.profile", arguments: .object([.init("id", .string("lead"))]), caller: context(tiers: [.read]))
        #expect(one["reports"].elements?.first?["id"].string == "worker")
        #expect(one["reportsToName"].string == "Hoot")
        #expect(await calls.tiers.allSatisfy { $0.1 == .read })
    }

    @Test func changesAskFirstAndNeedTheAlterTier() async throws {
        let config = try await memory(), calls = Calls()
        _ = try await config.saveAgent(profile("lead"))
        _ = try await config.saveAgent(profile("worker"))
        let tools = service(config, calls: calls)
        _ = try await tools.invoke("agents.set_icon", arguments: .object([.init("id", .string("worker")), .init("icon", .string("emoji:🦊"))]), caller: context())
        _ = try await tools.invoke("agents.set_reports_to", arguments: .object([.init("id", .string("worker")), .init("reportsTo", .string("lead"))]), caller: context())
        #expect(try await config.agent("worker")?["icon"].string == "emoji:🦊")
        #expect(try await config.agent("worker")?["reportsTo"].string == "lead")
        #expect(await calls.tiers.map(\.1) == [.alter, .alter])
        do { _ = try await tools.invoke("agents.set_reports_to", arguments: .object([.init("id", .string("lead")), .init("reportsTo", .string("worker"))]), caller: context()); Issue.record("Loop accepted") }
        catch { #expect(error.localizedDescription.contains("already reports to")) }
        do { _ = try await tools.invoke("agents.set_icon", arguments: .object([.init("id", .string("worker")), .init("icon", .null)]), caller: context(tiers: [.read])); Issue.record("Read tier changed an agent") }
        catch { #expect((error as? NativeRPCError)?.code == "not-granted") }
        let refused = service(config, calls: calls, deny: true)
        do { _ = try await refused.invoke("agents.set_icon", arguments: .object([.init("id", .string("worker")), .init("icon", .null)]), caller: context()); Issue.record("Saved without the owner's yes") }
        catch { #expect(try await config.agent("worker")?["icon"].string == "emoji:🦊") }
        do { _ = try await tools.invoke("agents.set_icon", arguments: .object([.init("id", .string("@hoot")), .init("icon", .string("emoji:🦊"))]), caller: context()); Issue.record("Hoot changed") }
        catch { #expect(error.localizedDescription.contains("built in")) }
    }

    @Test func aKeyMayNarrowButNeverWiden() async throws {
        let config = try await memory(), calls = Calls()
        _ = try await config.saveAgent(profile("inspector", [("allowedTools", .array([.string("Read"), .string("Grep")])),
                                                             ("permissionMode", .string("default")), ("blockedTools", .array([.string("Edit")]))]))
        let tools = service(config, calls: calls)
        func edit(_ fields: [(String, NativeRPCValue)]) async throws {
            _ = try await tools.invoke("agents.edit_profile", arguments: .object([.init("id", .string("inspector")),
                .init("fields", .object(fields.map { .init($0.0, $0.1) }))]), caller: context())
        }
        try await edit([("allowedTools", .array([.string("Read")])), ("permissionMode", .string("plan")), ("role", .string("Reviews only"))])
        #expect(try await config.agent("inspector")?["allowedTools"].elements == [.string("Read")])
        for (fields, words): ([(String, NativeRPCValue)], String) in [
            ([("allowedTools", .array([.string("Read"), .string("Bash")]))], "Adding Bash"),
            ([("permissionMode", .string("acceptEdits"))], "Changing permission mode"),
            ([("blockedTools", .array([]))], "Removing the Edit block"),
            ([("keepAliveUntilClose", .bool(true))], "Keeping the agent open"),
            ([("sourceFile", .string("/tmp/x.md"))], "cannot be changed here")] {
            do { try await edit(fields); Issue.record("Widened with \(fields)") }
            catch { #expect(error.localizedDescription.contains(words), "\(error.localizedDescription)") }
        }
        #expect(try await config.agent("inspector")?["permissionMode"].string == "plan")
    }

    @Test func theAgentFileChangesOnlyItsFrontmatter() throws {
        let fixtures = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("TAGAgentFixtures")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AGT-source-" + UUID().uuidString)
        let folder = root.appendingPathComponent(".claude/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("inspector.md")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("inspector.md"), to: file)
        let before = try #require(try BackendTAGAgentImport.read(file))
        try BackendAGTSourceWriter.update(file: file, directory: folder, description: "Checks work: carefully, with evidence",
                                          model: .some("sonnet"), tools: .some(["Read", "Grep"]))
        let after = try #require(try BackendTAGAgentImport.read(file))
        #expect(after.name == before.name)
        #expect(after.description == "Checks work: carefully, with evidence")
        #expect(after.model == "sonnet")
        #expect(after.tools == ["Read", "Grep"])
        #expect(after.prompt == before.prompt)
        do { try BackendAGTSourceWriter.update(file: root.appendingPathComponent("elsewhere.md"), directory: folder, description: "x", model: nil, tools: nil); Issue.record("Wrote outside the agents folder") } catch {}
    }
    @Test func backslashesAndQuotesInADescriptionKeepTheAgentFileReadable() throws {
        #expect(try BackendAGTSourceWriter.scalar(#"Fix C:\build paths"#) == #"'Fix C:\build paths'"#)
        #expect(try BackendAGTSourceWriter.scalar("Checks: carefully") == #""Checks: carefully""#)
        for description in [#"Fix C:\build paths"#, #"Say "hi" to Bob's C:\dir"#, "It's: fine"] {
            let file = "---\nname: worker\ndescription: \(try BackendAGTSourceWriter.scalar(description))\n---\nInstructions"
            #expect(try #require(try BackendTAGAgentImport.parse(file)).description == description)
        }
    }
    @Test func aSyncKeepsTheModelTheOwnerPickedWhenTheFileHasNone() throws {
        let root = URL(fileURLWithPath: "/work/project/.claude/agents"), file = root.appendingPathComponent("worker.md")
        let existing = profile("worker", [("model", .string("opus"))])
        let plain = try #require(try BackendTAGAgentImport.parse("---\nname: worker\ndescription: Worker\n---\nInstructions"))
        #expect(BackendTAGAgentImport.merge(plain, existing: existing, directory: root, file: file)["model"].string == "opus")
        let pinned = try #require(try BackendTAGAgentImport.parse("---\nname: worker\ndescription: Worker\nmodel: sonnet\n---\nInstructions"))
        #expect(BackendTAGAgentImport.merge(pinned, existing: existing, directory: root, file: file)["model"].string == "sonnet")
    }
}
