import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// SETTINGS-TRUTH (12 Oct), lane TRUTH-A: settings that said one thing and did another now do what they say.
@Suite("TRUTH-A: settings that do what they say", .serialized)
struct TRUTHAFixesTests {
    private struct Cipher: BackendAccountVaultCipher {
        func available() -> Bool { true }
        func prepareForWrites(existingVault: Bool) throws {}
        func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
        func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
    }

    // #10: a Look-only key with "Your tasks" on could create, assign and cancel tasks on the local tasks address.
    @Test func aLookOnlyKeyCannotChangeTasksOnTheTasksAddress() {
        let look = NativeRPCValue.object([.init("id", .string("k")), .init("level", .string("look")), .init("tasks", .bool(true))])
        let body = Data(#"{"title":"Fix it","project":"/p/shop","assignee":"alpha"}"#.utf8)
        for method in ["POST", "post"] { #expect(BackendTaskKeyAccess.refusal(key: look, method: method, body: body) == BackendTaskKeyAccess.lookOnlyRefusal) }
        #expect(BackendTaskKeyAccess.refusal(key: look, method: "POST", body: Data()) == BackendTaskKeyAccess.lookOnlyRefusal)
        #expect(BackendTaskKeyAccess.refusal(key: look, method: "GET", body: Data()) == nil)
        let work = look.setting("level", .string("work"))
        #expect(BackendTaskKeyAccess.refusal(key: work, method: "POST", body: body) == nil)
        #expect(BackendTaskKeyAccess.refusal(key: look.setting("level", .string("full")), method: "POST", body: body) == nil)
        // The key's folders hold for the work it sends; a sibling sharing a prefix is outside.
        #expect(BackendTaskKeyAccess.refusal(key: work.setting("folders", .array([.string("/p/other")])), method: "POST", body: body) == BackendTaskKeyAccess.folderRefusal)
        #expect(BackendTaskKeyAccess.refusal(key: work.setting("folders", .array([.string("/p/sho")])), method: "POST", body: body) == BackendTaskKeyAccess.folderRefusal)
        #expect(BackendTaskKeyAccess.refusal(key: work.setting("folders", .array([.string("/p")])), method: "POST", body: body) == nil)
        // A key made for a CRM exists to send tasks.
        #expect(BackendTaskKeyAccess.refusal(key: look.setting("crmOnly", .bool(true)), method: "POST", body: body) == nil)
    }

    // Row 51: a routine whose "Who does it" is an agent failed on every run.
    private struct HootRunner: BackendRoutinesRunner { func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome { .init(ok: true, output: "hoot ran it") } }
    private actor Made { var inputs: [NativeRPCValue] = []; func add(_ value: NativeRPCValue) { inputs.append(value) } }
    @Test func aRoutineGivenToAnAgentBecomesThatAgentsTask() async throws {
        let made = Made()
        let runner = BackendROUTINESRunner(hoot: HootRunner(), profile: { id in
            id == "alpha" ? .object([.init("id", .string("alpha")), .init("name", .string("Alpha"))]) : nil
        }, profileRun: { request, agent in
            // The production agent run (routines21AgentRun) files this exact task input.
            await made.add(BackendRoutines21TaskWaiter.taskInput(request: request, agent: agent))
            return .init(ok: true, output: "\(agent["name"].string ?? "") was given this as a task (local:1).")
        })
        let routine = BackendRoutinesRoutine(id: "nightly", name: "Nightly check", triggers: [], folder: "/p/shop", prompt: "Check the build.",
                                             unknown: ["agent-id": ["alpha"]], unknownKeyOrder: ["agent-id"])
        let outcome = await runner.run(.init(routine: routine, runId: "r1", cause: .manual(by: "person"), chain: []))
        #expect(outcome.ok, "\(outcome.error ?? "")")
        let input = try #require(await made.inputs.first)
        #expect(input["assignee"].string == "alpha")
        #expect(input["project"].string == "/p/shop")
        #expect(input["title"].string == "Routine: Nightly check")
        #expect(input["instructions"].string?.hasSuffix("Check the build.") == true)
        // Hoot's routines still run as Hoot's; an agent that is gone still fails clearly.
        let hoot = BackendRoutinesRoutine(id: "h", name: "H", triggers: [], folder: "/p/shop", prompt: "x")
        #expect(await runner.run(.init(routine: hoot, runId: "r2", cause: .manual(by: "person"), chain: [])).output == "hoot ran it")
        let gone = BackendRoutinesRoutine(id: "g", name: "G", triggers: [], folder: "/p/shop", prompt: "x", unknown: ["agent-id": ["beta"]], unknownKeyOrder: ["agent-id"])
        #expect(await runner.run(.init(routine: gone, runId: "r3", cause: .manual(by: "person"), chain: [])).ok == false)
        #expect(await made.inputs.count == 1)
    }

    // Row 54: "Let a device in" from Alerts approved the device but gave it no access, so it was refused everything.
    @Test func theAlertsCardLetsADeviceInWithTheAccessItPromised() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TRUTHA-device-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let mine = try await trust.redeem(try await trust.createPairingOffer().token, name: "Phone", address: "test", publicKey: nil)
        #expect(try await trust.compositionApprove(mine.device.id, kind: .mine, folders: [], accountMode: .string("all"), accounts: []))
        #expect(await trust.phoneAccess(mine.device.id) == .full)
        try await trust.requirePhoneAccess(mine.device.id, message: "input")
        let guest = try await trust.redeem(try await trust.createPairingOffer().token, name: "Guest", address: "test", publicKey: nil)
        #expect(try await trust.compositionApprove(guest.device.id, kind: .guest, folders: [.string(directory.path)], accountMode: .string("selected"), accounts: []))
        #expect(await trust.phoneAccess(guest.device.id) == .work)
        try await trust.requirePhoneAccess(guest.device.id, message: "list")
        await trust.close(); try await trust.open()
        #expect(await trust.phoneAccess(mine.device.id) == .full)
        await trust.close()
    }

    // Settings › Agents defaults: once any default was saved, a session a paired phone started refused to start.
    @Test func savedAgentDefaultsNeverStopADeviceSessionStarting() async throws {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/truth-a-ags-memory"), ownership: .memory)
        let store = BackendAGSStore(persistence: persistence, cipher: Cipher())
        try await store.start()
        try await store.saveDefaults(.init(providers: ["claude": AGSAgentSettings(model: "app-model")]), expectedRevision: 0)
        let config = try BackendTaskConfiguration(persistence: persistence)
        try await config.start(); try await config.bindAGS(store)
        let launch = BackendINT2AGSLaunch(store: store, configuration: config, defaultProvider: { "claude" }, taskProfile: { _ in nil })
        let input = BackendCreateSessionInput(cwd: "/tmp", provider: "claude")
        let here = try await launch.resolve(input, context: .init())
        #expect(here.agentSettings?.model == "app-model")
        let phone = BackendLaunchContext(deviceBoundary: .init(deviceKey: "phone", folder: "/tmp"))
        let started = try await launch.resolve(input, context: phone)
        #expect(started.agentSettings == nil)
        // Settings the device itself asked for are still never silently dropped.
        var asked = input; asked.agentSettings = AGSAgentSettings(model: "asked-model")
        await #expect(throws: NativeRPCError.self) { _ = try await launch.resolve(asked, context: phone) }
    }

    // Servers › "Show only these apps": the apps.* tools still reached a hidden app.
    @Test func aHiddenAppIsRefusedAndLeftOutOfTheList() async throws {
        let shown = BackendServersShownApps()
        try await shown.requireShown(serverID: "s", appID: "a1") { "crm" }
        shown.set("s", ["shop"])
        try await shown.requireShown(serverID: "s", appID: "a2") { "shop" }
        await #expect(throws: NativeRPCError.self) { try await shown.requireShown(serverID: "s", appID: "a1") { "crm" } }
        try await shown.requireShown(serverID: "s", appID: "new-app") { nil }
        try await shown.requireShown(serverID: "s", appID: nil) { "crm" }
        try await shown.requireShown(serverID: "other", appID: "a1") { "crm" }
        let rows = shown.shownRows("s", .array([.object([.init("name", .string("shop"))]), .object([.init("name", .string("crm"))])]))
        #expect(rows.elements?.compactMap { $0["name"].string } == ["shop"])
    }

    // Row 48: "Hoot leads for now" was saved but the vacant lead seat refused all work.
    @Test func hootLeadsForNowTakesTheVacantLeadSeatsWork() async throws {
        let project = PROJProject(id: "tra", name: "Truth A", folders: ["/p/tra"], lead: "", leadName: "")
        var deps = BackendAGTLeadSeats.Dependencies(projects: { [project] }, sessions: { [] }, tell: { _, _ in }, tasks: { [] }, task: { _ in nil },
                                                    told: { _, _ in }, note: { _, _, _ in }, handToAgent: { _, _ in })
        let refused = BackendAGTLeadSeats(deps)
        await #expect(throws: (any Error).self) { _ = try await refused.assignment("lead:tra") }
        deps.hootLeads = { $0 == "tra" }
        let held = try await BackendAGTLeadSeats(deps).assignment("lead:tra")
        #expect(held["kind"].string == "hoot")
    }

    // Rows 42/46: "Linked servers" reach every brief for work in the project.
    @Test func linkedServersBecomeOneBriefLine() {
        #expect(BackendTaskEngine.linkedServersLine("prod, staging ,") == "Servers linked to this project: prod, staging (reach them with the servers tools, such as servers_look).")
        #expect(BackendTaskEngine.linkedServersLine(" ") == nil)
        #expect(BackendTaskEngine.linkedServersLine(nil) == nil)
    }

    // TRUTH-A2 row 92: saving a routine turned "alert session-blocked" into a bare "alert" and could not save session-idle.
    @Test func aRoutineKeepsItsAlertAndIdleArgument() {
        var alert = ROUTINESDraft.read(id: "blocked", text: "# Blocked agent\nwhen: alert session-blocked\nin: /p/shop\n---\nLook.")
        #expect(alert.trigger == "alert session-blocked")
        alert.event = "session-failed"; #expect(alert.trigger == "session-failed")
        let idle = ROUTINESDraft.read(id: "stuck", text: "# Stuck\nwhen: session-idle 20m\nin: /p/shop\n---\nLook.")
        #expect(idle.trigger == "session-idle 20m")
        var fresh = ROUTINESDraft(id: "new"); fresh.whenKind = "event"; fresh.event = "session-idle"
        #expect(fresh.trigger == "session-idle 15m")
        var files = ROUTINESDraft.read(id: "f", text: "# F\nwhen: file-change src/**\nin: /p/shop\n---\nLook.")
        #expect(files.trigger == "file-change src/**"); files.glob = "docs/**"; #expect(files.trigger == "file-change docs/**")
    }
}
