import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct AGTGapCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
}

/// AGENTS-GAP (Asad, 11 Oct): "there should not be any limit in the app, and fill the gap for hoot". Each test here
/// fails on the code before it: the 50-agent cap (and the agent settings' own 50), Hoot's "A key may only narrow an
/// existing owner task profile" and "Grouped agent changes need a granted task key", and imported names reset to ids.
@Suite("AGENTS-GAP: no agent limit, Hoot hires like the New Agent screen, display names")
struct AGTAgentsGapTests {
    private func value(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendTaskValues.object(pairs) }
    private func strings(_ list: [String]) -> NativeRPCValue { .array(list.map(NativeRPCValue.string)) }

    @Test func noLimitOnHowManyAgentsOrOnHowManyHaveSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AGTGap-limit-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let config = try BackendTaskConfiguration(persistence: persistence)
        let ags = BackendAGSStore(persistence: persistence, cipher: AGTGapCipher())
        try await config.start(); try await ags.start(); try await config.bindAGS(ags)
        for index in 1...75 {
            _ = try await config.saveAgent(value([("id", .string("agent-\(index)")), ("name", .string("Agent \(index)")), ("provider", .string("claude"))]))
        }
        #expect(try await config.allAgents().count == 75)
        #expect(try await ags.profile("agent-75") != nil, "the 51st and later agents keep their settings too")
        // The settings record still reads back whole with more than 50 agents in it.
        let reread = BackendAGSStore(persistence: persistence, cipher: AGTGapCipher())
        try await reread.start()
        #expect(try await reread.profile("agent-60") != nil)
        try await config.stop()
    }

    @Test func hootHiresThroughTheToolWithEveryNewAgentFieldAndManyInOneRequest() async throws {
        let clock = BackendCrmTaskClockParityVirtualClock()
        clock.set(BackendCrmTime.parseInstant("2026-10-11T09:00:00Z")!.timeIntervalSince1970 * 1000)
        clock.setReadStep(0)
        try await BackendTaskClockContext.withClock(clock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
            let agsPersistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/AGTGap-hire-memory"), ownership: .memory)
            let ags = BackendAGSStore(persistence: agsPersistence, cipher: AGTGapCipher())
            try await ags.start(); try await r.f.config.bindAGS(ags)
            // The caller "hoot" has no key: before, a new id was refused ("A key may only narrow an existing owner task profile").
            let hire = value([("name", .string("iOS Engineer")), ("icon", .string("sf:iphone")), ("reportsTo", .string(AGTDirectory.hootID)),
                ("seat", .string("ios-engineer")), ("provider", .string("claude")), ("account", .string("work")), ("model", .string("opus")),
                ("effort", .string("high")), ("instructions", .string("Build the iPhone app.")), ("toolsPreferred", strings(["Read"])),
                ("toolsAvoided", strings(["WebFetch"])), ("blockedTools", strings(["Bash"])), ("skills", strings(["resume"])),
                ("maxConcurrent", .number(3)), ("maxRunMinutes", .number(120)), ("keepAliveUntilClose", .bool(true)),
                ("permissionMode", .string("acceptEdits")), ("verifyCommand", .string("swift test"))])
            let saved = try await r.call("tasks.agents", value([("do", .string("save")), ("agent", hire)]))
            #expect(saved["saved"]["id"].string == "ios-engineer")
            let row = try #require(try await r.f.config.agent("ios-engineer"))
            #expect(row["name"].string == "iOS Engineer" && row["icon"].string == "sf:iphone" && row["reportsTo"].string == AGTDirectory.hootID)
            #expect(row["seat"].string == "ios-engineer" && row["account"].string == "work" && row["effort"].string == "high")
            #expect(row["keepAliveUntilClose"].bool == true && row["permissionMode"].string == "acceptEdits" && row["maxConcurrent"].number == 3)
            #expect(row["skills"] == strings(["resume"]) && row["blockedTools"] == strings(["Bash"]) && row["verifyCommand"].string == "swift test")
            #expect(row["instructions"].string == "Build the iPhone app." && row["creatorKeyId"].isNullish)
            let settings = try #require(try await ags.profile("ios-engineer"))
            #expect(settings.keepOpen && settings.permissionMode == "acceptEdits")

            // Several new agents in ONE request (one consent): before, "Grouped agent changes need a granted task key".
            // The first reports to the second, which is new in the same request.
            let team = NativeRPCValue.array([
                value([("name", .string("Junior")), ("provider", .string("claude")), ("reportsTo", .string("lead-dev"))]),
                value([("name", .string("Lead Dev")), ("provider", .string("claude")), ("seat", .string("lead-dev"))])])
            let many = try await r.call("tasks.agents", value([("do", .string("save-many")), ("agents", team)]))
            #expect(many["saved"].elements?.compactMap { $0["id"].string } == ["junior", "lead-dev"])
            #expect(try await r.f.config.agent("junior")?["reportsTo"].string == "lead-dev")

            // A shared narrowing change for existing agents applies to all of them.
            _ = try await r.call("tasks.agents", value([("do", .string("save-many")), ("ids", strings(["junior", "lead-dev"])), ("agent", value([("skillsOff", .bool(true))]))]))
            #expect(try await r.f.config.agent("junior")?["skillsOff"].bool == true)
            #expect(try await r.f.config.agent("lead-dev")?["skillsOff"].bool == true)

            // A caller without the widening right (this fixture gives it to nobody): widening an EXISTING agent is refused.
            let wide = await r.refused("tasks.agents", value([("do", .string("save-many")), ("ids", strings(["junior", "lead-dev"])), ("agent", value([("keepAliveUntilClose", .bool(true))]))]))
            #expect(wide.contains("needs the owner"), Comment(rawValue: wide))
            #expect(try await r.f.config.agent("junior")?["keepAliveUntilClose"].bool == false)
            #expect(try await r.f.config.agent("lead-dev")?["keepAliveUntilClose"].bool == false)
            let single = await r.refused("tasks.agents", value([("do", .string("save")), ("agent", value([("id", .string("junior")), ("permissionMode", .string("bypassPermissions"))]))]))
            #expect(single.contains("needs the owner"), Comment(rawValue: single))
            #expect(try await r.f.config.agent("junior")?["permissionMode"].isNullish == true)
            // There is no count cap: more than 50 agents through the tool, in pieces of 50 per request.
            for piece in 0..<2 {
                let list = (1...30).map { value([("name", .string("Worker \(piece)-\($0)")), ("provider", .string("claude"))]) }
                _ = try await r.call("tasks.agents", value([("do", .string("save-many")), ("agents", .array(list))]))
            }
            #expect(try await r.f.config.allAgents().count == 1 + 1 + 2 + 60)
        }
    }

    /// The task tools as the app registers them, with the caller's agent scope chosen by its machine id.
    private func scopedTools(_ scope: @escaping @Sendable (String) -> BackendTaskAgentScope) async throws -> BackendCrmTaskToolsParityFixture {
        let io = try await BackendCrmTaskDetailParityNativeIO.make(notify: true)
        let f = io.fixture
        try await f.config.removeAgent("tester")
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { [] }, start: { _,_,_,_,_ in throw NativeRPCError(code: "test-process", message: "No process may be launched by these tests.") }, send: { _,_ in }, stop: { _ in }, setControl: { _,_,_ in }, check: { _,_ in (true, "fake verification") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: f.store, configuration: f.config, goals: f.goals, access: access, workspace: { $0.project }, problem: { _ in })
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/private/tmp/agtgap-scope-inert"), ownership: .memory)
        let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in nil }, post: { _,_ in throw NativeRPCError(code: "test-network", message: "No network may be used by these tests.") }, onCommentID: { _,_ in }, problem: { _ in })
        let view = BackendTaskStateView(store: f.store, configuration: f.config, goals: f.goals, outbox: outbox, keyViews: { [] })
        let planning = BackendGoalPlanning(goals: f.goals, tasks: f.store, configuration: f.config, local: f.local, detail: f.detail)
        let server = BackendNativeMCPServer(), audit = BackendCrmTaskToolsParityAudit()
        let authority = BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { _ in }, visible: { _, _ in true }, project: { _, _ in },
            authorize: { _, _, _, tier in await audit.record(tier) }, actorName: { $0.machineID }, agentScope: { scope($0.machineID) },
            widensAgents: { ["hoot", "alpha-lead"].contains($0.machineID) })
        _ = try await BackendTaskMCP.register(server: server, view: view, local: f.local, engine: engine, detail: f.detail, planning: planning, api: nil, indexed: true, authority: authority)
        return BackendCrmTaskToolsParityFixture(f: f, server: server, engine: engine, planning: planning, audit: audit, io: io, registrations: await server.registrations())
    }

    /// Asad, 11 Oct: "will every lead agent be able to create its sub agents and modify them?" Yes: a project's lead adds
    /// and changes its own project's agents (they report under it); never another project's, Hoot or itself; a seat's
    /// agent at work adds none (it asks its lead for hands); Hoot does all of it everywhere.
    @Test func aLeadAddsAndChangesItsOwnProjectsAgentsOnlyAndASeatAgentAddsNone() async throws {
        let clock = BackendCrmTaskClockParityVirtualClock()
        clock.set(BackendCrmTime.parseInstant("2026-10-11T09:00:00Z")!.timeIntervalSince1970 * 1000)
        clock.setReadStep(0)
        try await BackendTaskClockContext.withClock(clock) {
            let r = try await scopedTools { who in who == "alpha-lead" ? .project("alpha", lead: "alpha-lead") : who == "seat" ? .none : .everything }
            func save(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { value([("do", .string("save")), ("agent", value(fields))]) }
            // Hoot hires the lead of "alpha" and an agent of "beta".
            _ = try await r.call("tasks.agents", save([("name", .string("Alpha Lead")), ("provider", .string("claude")), ("projectId", .string("alpha"))]))
            _ = try await r.call("tasks.agents", save([("name", .string("Beta Worker")), ("provider", .string("claude")), ("projectId", .string("beta")), ("maxRunMinutes", .number(45))]))
            // The lead adds an agent: its project and manager are the lead's.
            _ = try await r.call("tasks.agents", save([("name", .string("Alpha Builder")), ("provider", .string("claude")), ("seat", .string("builder")), ("skills", strings(["resume"]))]), caller: "alpha-lead")
            let built = try #require(try await r.f.config.agent("alpha-builder"))
            #expect(built["projectId"].string == "alpha" && built["reportsTo"].string == "alpha-lead" && built["seat"].string == "builder")
            // Asad, 12 Oct: nothing pre-selected: no run limit; keep open from the one default.
            #expect(built["maxRunMinutes"].number == 0 && built["keepAliveMinutes"].number == Double(TasksLimits.defaultKeepAliveMinutes))
            // ... changes it (model, a shorter longest run, its skills) and pauses and resumes it.
            _ = try await r.call("tasks.agents", save([("id", .string("alpha-builder")), ("model", .string("opus")), ("maxRunMinutes", .number(30)), ("skills", strings(["resume", "review"]))]), caller: "alpha-lead")
            let changed = try #require(try await r.f.config.agent("alpha-builder"))
            #expect(changed["model"].string == "opus" && changed["maxRunMinutes"].number == 30 && changed["skills"] == strings(["resume", "review"]))
            _ = try await r.call("tasks.agents", value([("do", .string("pause")), ("id", .string("alpha-builder"))]), caller: "alpha-lead")
            _ = try await r.call("tasks.agents", value([("do", .string("resume")), ("id", .string("alpha-builder"))]), caller: "alpha-lead")
            #expect(try await r.f.config.agent("alpha-builder")?["status"].string == "active")
            // The lead may also WIDEN its own agents (turn the 30-minute limit back off, keep it open until closed).
            _ = try await r.call("tasks.agents", save([("id", .string("alpha-builder")), ("maxRunMinutes", .number(0)), ("keepAliveUntilClose", .bool(true))]), caller: "alpha-lead")
            let widened = try #require(try await r.f.config.agent("alpha-builder"))
            #expect(widened["maxRunMinutes"].number == 0 && widened["keepAliveUntilClose"].bool == true)
            // Hoot may widen any agent: Beta Worker's run limit off (before: "needs the owner").
            _ = try await r.call("tasks.agents", save([("id", .string("beta-worker")), ("maxRunMinutes", .number(0))]))
            #expect(try await r.f.config.agent("beta-worker")?["maxRunMinutes"].number == 0)
            // ... and through agents_edit_profile too is the same rule (directory tools use the same authority).
            // Refused: another project's agent (change, pause, a new one put there), and removing itself.
            let other = await r.refused("tasks.agents", save([("id", .string("beta-worker")), ("model", .string("opus"))]), caller: "alpha-lead")
            #expect(other.contains("lead"), Comment(rawValue: other))
            _ = await r.refused("tasks.agents", value([("do", .string("pause")), ("id", .string("beta-worker"))]), caller: "alpha-lead")
            _ = await r.refused("tasks.agents", save([("name", .string("Smuggled")), ("provider", .string("claude")), ("projectId", .string("beta"))]), caller: "alpha-lead")
            _ = await r.refused("tasks.agents", value([("do", .string("remove")), ("id", .string("alpha-lead"))]), caller: "alpha-lead")
            #expect(try await r.f.config.agent("beta-worker")?["model"].isNullish == true)
            #expect(try await r.f.config.agent("smuggled") == nil)
            // A seat's agent at work adds no agents.
            let seat = await r.refused("tasks.agents", save([("name", .string("Seat Hire")), ("provider", .string("claude")), ("projectId", .string("alpha"))]), caller: "seat")
            #expect(seat.contains("Only Hoot and a project's lead"), Comment(rawValue: seat))
            #expect(try await r.f.config.agent("seat-hire") == nil)
        }
    }

    @Test func importedAgentsShowTheirDisplayNameAndASyncKeepsTheOwnersName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AGTGap-names-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project/.claude/agents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nname: hoot-builder\ndisplay_name: Hoot Builder\ndescription: Builds Hoot\n---\nBuild Hoot.\n".utf8).write(to: folder.appendingPathComponent("hoot-builder.md"))
        let plain = folder.appendingPathComponent("store-website.md")
        try Data("---\nname: store-website\ndescription: Runs the store\nmax_run_minutes: 90\n---\nRun the store.\n".utf8).write(to: plain)
        let config = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("data"), ownership: .exclusive))
        try await config.start()
        _ = try await config.importAgents(folder: root.appendingPathComponent("project").path)
        #expect(try await config.agent("hoot-builder")?["name"].string == "Hoot Builder", "display_name is the name people see")
        #expect(try await config.agent("hoot-builder")?["claudeAgent"].string == "hoot-builder", "the id Claude Code needs stays")
        #expect(try await config.agent("store-website")?["name"].string == "store-website", "a brand-new import with no display_name uses the id")
        let row = try #require(try await config.agent("store-website"))
        #expect(row["maxRunMinutes"].number == 90, "a brand-new import takes the file's run limit")
        // The owner renames it and turns its run limit off.
        _ = try await config.saveAgent(row.setting("name", .string("Store & Website")).setting("maxRunMinutes", .number(0)))
        // The file changes and syncs again: the owner's name stays (before, every sync put the id back), and the run
        // limit the owner turned off stays off (before, a sync put the file's 90 back).
        try Data("---\nname: store-website\ndescription: Runs the store and the site\nmax_run_minutes: 90\n---\nRun the store.\n".utf8).write(to: plain)
        _ = try await config.importAgents(folder: root.appendingPathComponent("project").path)
        let synced = try #require(try await config.agent("store-website"))
        #expect(synced["name"].string == "Store & Website" && synced["role"].string == "Runs the store and the site")
        #expect(synced["maxRunMinutes"].number == 0, "a sync never puts a run limit back")
        #expect(try await config.agent("hoot-builder")?["name"].string == "Hoot Builder")
        try await config.stop()
    }
}
