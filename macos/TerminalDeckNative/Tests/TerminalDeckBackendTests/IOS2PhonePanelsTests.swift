import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// IOS2: the Mac's Agents, Connected tasks and Docker pages on the owner's phone
/// (macos/round7/IOS2.md §2). The tools are faked at the port; the panel registry,
/// the wire protocol and (last test) the real remote host are real.
private typealias V = NativeRPCValue

private actor IOS2Calls {
    var calls: [(tool: String, args: V, tier: BackendMCPTier)] = []
    func add(_ tool: String, _ args: V, _ tier: BackendMCPTier) { calls.append((tool, args, tier)) }
    func tools() -> [String] { calls.map(\.tool) }
    func last(_ tool: String) -> (args: V, tier: BackendMCPTier)? { calls.last { $0.tool == tool }.map { ($0.args, $0.tier) } }
}

private func port(level: BackendINT2PhoneAccessLevel = .full, calls: IOS2Calls,
                  answer: @escaping @Sendable (String, V) throws -> V) -> BackendIOS2PanelPort {
    .init(call: { tool, args, _, _, tier in await calls.add(tool, args, tier); return try answer(tool, args) },
          level: { _, _ in level }, device: { _, _, _ in "phone-1" })
}
private let rpc = NativeRPCContext(caller: .pairedDevice, ownerID: "phone-1")
private func request(_ scope: String? = nil) -> BackendRemotePanelRequest { .init(path: "", scope: scope, query: nil) }
private func json(_ text: String) -> V { try! V.parseJSON(Data(text.utf8)) }
private func titles(_ value: V) -> [String] { (value["rows"].elements ?? []).compactMap { $0["title"].string } }
private func actionIDs(_ row: V) -> [String] { (row["actions"].elements ?? []).compactMap { $0["id"].string } }

private let directory = json(#"""
{"agents":[
 {"id":"@hoot","kind":"hoot","name":"Hoot","role":"","icon":"sf:bird","project":"","projectName":"","provider":"claude","status":"live","statusLabel":"Ready","live":null,"activity":"Ready","reportsTo":null,"machine":"This Mac"},
 {"id":"critic","kind":"profile","profileId":"critic","name":"Critic","role":"Reviews changes","icon":"emoji:🦉","project":"/p/web","projectName":"imatch-web","provider":"codex","model":"gpt-5","status":"active","statusLabel":"Working","live":"working","activity":"Reading","taskTitle":"Check login","reportsTo":"inspector","machine":"This Mac"},
 {"id":"inspector","kind":"profile","profileId":"inspector","name":"Inspector","role":"Lead","icon":"sf:checkmark.seal","project":"/p/web","projectName":"imatch-web","provider":"claude","status":"active","statusLabel":"Ready","live":null,"activity":"Ready for work","reportsTo":"@hoot","machine":"This Mac"}],
 "groups":[{"title":"Every project","agents":["@hoot"]},{"title":"imatch-web","folder":"/p/web","agents":["inspector","critic"]}],
 "total":3,"notices":[]}
"""#)

@Suite("IOS2 phone pages")
struct IOS2PhonePanelsTests {
    @Test func theProtocolCarriesThePagesAndMoreClaims() {
        // Older phones may still ask for "approvals": the frame parses, but no Mac page answers it.
        #expect(BackendRemotePanelRegistry.Domain(rawValue: "approvals") == nil)
        for panel in ["agents", "connected-tasks", "docker"] {
            guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(#"{"t":"panel.read","panel":"\#(panel)","scope":"agent:critic"}"#) else {
                Issue.record("panel.read \(panel) was refused"); continue
            }
            #expect(message["panel"].string == panel)
            #expect(BackendRemotePanelRegistry.Domain(rawValue: panel) != nil)
        }
        // A newer phone claims 26 names (22 old ones first); all are kept now (old Macs keep 24).
        let claims = (0..<30).map { "cap\($0)" }
        let hello = V.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string("x")),
                              .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])),
                              .init("capabilities", .array(claims.map(V.string)))])
        guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(hello) else { Issue.record("hello refused"); return }
        #expect(message["capabilities"].elements?.count == 30)
        #expect(BackendRemoteProtocol.limits["MAX_CLIENT_CAPABILITIES"] == 48)
    }

    @Test func agentsListGroupsByProjectWithIconsBadgesAndAProfileLink() async throws {
        let calls = IOS2Calls()
        let provider = BackendIOS2PhonePanels.agents(port: port(calls: calls) { _, _ in directory })
        let value = try await provider.read(request(), rpc)
        #expect(titles(value) == ["Hoot", "Inspector", "Critic"])
        let critic = try #require(value["rows"].elements?.last)
        #expect(critic["group"].string == "imatch-web" && critic["icon"].string == "emoji:🦉" && critic["badge"].string == "Task agent")
        #expect(critic["status"].string == "ok" && critic["open"].string == "agent:critic" && critic["value"].string == "Working")
        let facts = (critic["facts"].elements ?? []).map { ($0["label"].string ?? "") + "=" + ($0["value"].string ?? "") }
        #expect(facts.contains("Reports to=Inspector") && facts.contains("Coding AI=Codex · gpt-5") && facts.contains("Doing now=Reading · Check login"))
        #expect(value["view"] == .missing)
        #expect(await calls.last("agents.directory")?.args["group"].string == "project")
        let byManager = try await provider.read(request("group:reportsTo"), rpc)
        #expect(byManager["view"].string == "group:reportsTo")
        #expect(await calls.last("agents.directory")?.args["group"].string == "reportsTo")
    }

    @Test func aProfileOffersEditingOnlyToAFullPhoneAndForTaskAgents() async throws {
        let profile = directory["agents"].elements![1].setting("reportsToName", .string("Inspector"))
            .setting("reports", .array([])).setting("recentTasks", .array([json(#"{"id":"t1","title":"Check login","state":"done","updatedAt":1}"#)]))
            .setting("settings", json(#"{"effort":"high","permissionMode":"plan","allowedTools":["Read"]}"#))
        let answer: @Sendable (String, V) throws -> V = { tool, args in
            tool == "agents.profile" ? (args["id"].string == "@hoot" ? directory["agents"].elements![0] : profile) : directory
        }
        let calls = IOS2Calls()
        let full = BackendIOS2PhonePanels.agents(port: port(calls: calls, answer: answer))
        let page = try await full.read(request("agent:critic"), rpc)
        #expect(page["view"].string == "agent:critic" && page["title"].string == "Critic")
        let header = try #require(page["rows"].elements?.first)
        #expect(actionIDs(header) == ["edit", "reports", "icon"])
        let reports = try #require(header["actions"].elements?[1]["fields"].elements?.first)
        #expect(reports["choices"].elements?.compactMap(\.string) == ["", "@hoot", "inspector"])
        #expect(reports["choiceLabels"]["inspector"].string == "Inspector" && reports["choiceLabels"][""].string == "Independent")
        #expect(titles(page).contains("Check login"))
        // Look access: same page, no buttons. Hoot: never editable.
        let look = BackendIOS2PhonePanels.agents(port: port(level: .look, calls: IOS2Calls(), answer: answer))
        #expect(actionIDs(try #require(try await look.read(request("agent:critic"), rpc)["rows"].elements?.first)).isEmpty)
        #expect(actionIDs(try #require(try await full.read(request("agent:@hoot"), rpc)["rows"].elements?.first)).isEmpty)
        // Changes go to the Mac's own tools at the alter tier.
        guard let act = full.act else { Issue.record("no act"); return }
        let panel = request("agent:critic")
        let saved = try await act(.init(panel: panel, action: "edit", id: "critic", fields: ["name": "Critic", "role": "Reviews", "model": "", "effort": "low"]), rpc)
        #expect(saved["notice"].string == "Saved.")
        let edit = try #require(await calls.last("agents.edit_profile"))
        #expect(edit.tier == .alter && edit.args["fields"]["role"].string == "Reviews" && edit.args["fields"]["model"] == .null)
        _ = try await act(.init(panel: panel, action: "reports", id: "critic", fields: ["reportsTo": ""]), rpc)
        #expect(await calls.last("agents.set_reports_to")?.args["reportsTo"] == .null)
        await #expect(throws: NativeRPCError.self) {
            _ = try await act(.init(panel: panel, action: "edit", id: "critic", fields: ["instructions": "x"]), rpc)
        }
        await #expect(throws: NativeRPCError.self) {
            _ = try await act(.init(panel: panel, action: "icon", id: "inspector", fields: ["icon": "sf:star"]), rpc)
        }
    }

    @Test func orgChartIsIndentedDepthFirst() async throws {
        let chart = json(#"{"trees":[{"id":"@hoot","name":"Hoot","role":"","icon":"sf:bird","status":"Ready","reports":[{"id":"inspector","name":"Inspector","role":"Lead","icon":"sf:checkmark.seal","status":"Ready","reports":[{"id":"critic","name":"Critic","role":"","icon":"emoji:🦉","status":"Working","reports":[]}]}]}],"independent":[{"id":"solo","name":"Solo","kind":"profile","icon":"sf:person"}]}"#)
        let value = try await BackendIOS2PhonePanels.agents(port: port(calls: IOS2Calls()) { _, _ in chart }).read(request("org"), rpc)
        let rows = value["rows"].elements ?? []
        #expect(rows.map { $0["title"].string ?? "" } == ["Hoot", "Inspector", "Critic", "Solo"])
        #expect(rows.map { Int($0["level"].number ?? -1) } == [0, 1, 2, 0])
        #expect(rows.map { $0["group"].string ?? "" } == ["Hoot's team", "Hoot's team", "Hoot's team", "Independent"])
    }

    @Test func connectedTasksListOpenAndChangeThroughTheSameTools() async throws {
        let systems = json(#"{"systems":[{"id":"sys-1","name":"iLoop","changes":"ask","enabled":true,"statuses":["todo","doing","done"],"doneStatus":"done"}]}"#)
        let list = json(#"{"readAt":"2026-10-09T10:00:00Z","tasks":[{"id":"42","title":"Call the landlord","status":"todo","dueDate":"2020-01-01","board":"Leads","assignee":{"id":"u1","name":"Asad"},"assignedToMe":true},{"id":"43","title":"Send listing","status":"done","raisedByMe":true}]}"#)
        let detail = json(#"{"id":"42","title":"Call the landlord","status":"todo","dueDate":"2020-01-01","assignee":{"id":"u1","name":"Asad"},"description":"Line one\nLine two","people":[{"id":"u1","name":"Asad"},{"id":"u2","name":"Sara"}],"subtasks":[{"title":"Find number","done":true}],"checklists":[{"title":"Before","items":[{"title":"Read notes","done":false}]}],"comments":[{"by":"Sara","at":"2026-10-08","body":"Done?"}],"activity":[{"text":"status: open → todo","by":"Asad","at":"2026-10-07"}],"handoff":null}"#)
        let calls = IOS2Calls()
        let answer: @Sendable (String, V) throws -> V = { tool, _ in
            switch tool { case "connected_tasks.systems": systems; case "connected_tasks.list": list; case "connected_tasks.get": detail
            case "agents.directory": directory; default: .object([]) }
        }
        let provider = BackendIOS2PhonePanels.connectedTasks(port: port(calls: calls, answer: answer))
        let page = try await provider.read(request("pile:assigned_to_me"), rpc)
        #expect(page["title"].string == "iLoop" && titles(page) == ["Call the landlord", "Send listing"])
        let first = try #require(page["rows"].elements?.first)
        #expect(first["status"].string == "warn" && first["badge"].string == "Assigned to you" && first["open"].string == "task:sys-1|42")
        #expect(page["scopes"].elements?.first { $0["on"].bool == true }?["id"].string == "pile:assigned_to_me")
        #expect(await calls.last("connected_tasks.list")?.args["pile"].string == "assigned_to_me")
        let task = try await provider.read(request("task:sys-1|42"), rpc)
        let header = try #require(task["rows"].elements?.first)
        #expect(actionIDs(header) == ["status", "due", "assignee", "comment", "hand"])
        #expect(header["body"].string == "Line one\nLine two")
        let groups = Set((task["rows"].elements ?? []).compactMap { $0["group"].string })
        #expect(groups == ["Subtasks", "Checklist: Before", "Comments", "Activity"])
        guard let act = provider.act else { Issue.record("no act"); return }
        _ = try await act(.init(panel: request("task:sys-1|42"), action: "status", id: "42", fields: ["status": "doing"]), rpc)
        let update = try #require(await calls.last("connected_tasks.update"))
        #expect(update.tier == .alter && update.args["status"].string == "doing" && update.args["system"].string == "sys-1" && update.args["task"].string == "42")
        _ = try await act(.init(panel: request("task:sys-1|42"), action: "hand", id: "42", fields: ["agent": "critic", "mark_done": "yes"]), rpc)
        #expect(await calls.last("connected_tasks.hand_to_agent")?.args["mark_done"].bool == true)
        await #expect(throws: NativeRPCError.self) {
            _ = try await act(.init(panel: request("task:sys-1|42"), action: "due", id: "42", fields: ["due_date": "next week"]), rpc)
        }
        // Read only on the Mac: the page shows, no buttons, and says why.
        let offSystems = json(#"{"systems":[{"id":"sys-1","name":"iLoop","changes":"off","enabled":true,"statuses":[]}]}"#)
        let off = BackendIOS2PhonePanels.connectedTasks(port: port(calls: IOS2Calls()) { tool, args in
            tool == "connected_tasks.systems" ? offSystems : try answer(tool, args)
        })
        let offPage = try await off.read(request("task:sys-1|42"), rpc)
        #expect(actionIDs(try #require(offPage["rows"].elements?.first)).isEmpty && offPage["note"].string?.contains("read only") == true)
        let none = BackendIOS2PhonePanels.connectedTasks(port: port(calls: IOS2Calls()) { _, _ in json(#"{"systems":[]}"#) })
        #expect(try await none.read(request(), rpc)["note"].string?.contains("Connect one on the Mac") == true)
    }

    @Test func openedConnectedTaskKeepsItsSystemAfterReorderAndRejectsRemoval() async throws {
        let calls = IOS2Calls()
        let first = json(#"{"id":"sys|one","name":"First","statuses":["todo"],"changes":"ask"}"#)
        let second = json(#"{"id":"other","name":"Other","statuses":["todo"],"changes":"ask"}"#)
        func provider(_ systems: [V]) -> BackendRemotePanelProvider {
            BackendIOS2PhonePanels.connectedTasks(port: port(calls: calls) { tool, _ in
                switch tool {
                case "connected_tasks.systems": .object([.init("systems", .array(systems))])
                case "connected_tasks.list": json(#"{"readAt":"now","tasks":[{"id":"42","title":"Task","status":"todo"}]}"#)
                case "connected_tasks.get": json(#"{"id":"42","title":"Task","status":"todo"}"#)
                default: .object([])
                }
            })
        }
        let page = try await provider([first, second]).read(request(), rpc)
        let scope = try #require(page["rows"].elements?.first?["open"].string)
        #expect(scope == "task:sys%7Cone|42")
        let change = BackendRemotePanelActionRequest(panel: request(scope), action: "status", id: "42", fields: ["status": "todo"])
        let reordered = provider([second, first])
        _ = try await reordered.act?(change, rpc)
        #expect(await calls.last("connected_tasks.update")?.args["system"].string == "sys|one")
        let removed = provider([second])
        await #expect(throws: NativeRPCError.self) { _ = try await removed.act?(change, rpc) }
        #expect(await calls.last("connected_tasks.update")?.args["system"].string == "sys|one")
    }

    @Test func dockerIsReadOnlyEverywhereAndOpensServersAndContainers() async throws {
        let servers = json(#"{"servers":[{"id":"s1","name":"iMatch production","address":"178.104.99.108","username":"admin","sshAlias":"imza-server","lookOnly":true}]}"#)
        let containers = json(#"{"containers":[{"id":"abc123","name":"coolify-sentinel","image":"sentinel:1","state":"running","status":"Up 2 days","labels":{"com.docker.compose.project":"coolify"},"ports":[{"privatePort":80,"publicPort":8080,"type":"tcp"}]}]}"#)
        let inspect = json(#"{"id":"abc123","name":"coolify-sentinel","image":"sentinel:1","state":"running","status":"Up 2 days","created":1760000000,"ports":[],"mounts":[{"destination":"/data"}],"environment":[{"name":"TOKEN","value":"••••"}]}"#)
        let calls = IOS2Calls()
        let provider = BackendIOS2PhonePanels.docker(port: port(calls: calls) { tool, _ in
            switch tool {
            case "servers.look": servers; case "docker.containers.list": containers; case "docker.containers.inspect": inspect
            case "docker.status": json(#"{"available":true,"version":"29.3.1"}"#)
            case "docker.logs": json(#"{"records":[{"source":"stdout","text":"ready\n"},{"source":"stdout","text":"listening\n"}]}"#)
            default: .object([])
            }
        })
        #expect(provider.act == nil)
        let list = try await provider.read(request(), rpc)
        #expect(titles(list) == ["This Mac", "iMatch production"])
        let server = try #require(list["rows"].elements?.last)
        #expect(server["badge"].string == "Look only" && server["open"].string == "server:s1" && server["detail"].string == "imza-server")
        let tab = try await provider.read(request("server:s1"), rpc)
        #expect(tab["title"].string == "iMatch production · Docker 29.3.1" && tab["note"].string?.contains("Read only on the phone") == true)
        let row = try #require(tab["rows"].elements?.first)
        #expect(row["group"].string == "coolify" && row["status"].string == "ok" && row["open"].string == "container:s1|abc123" && actionIDs(row).isEmpty)
        #expect((tab["scopes"].elements ?? []).count == 5)
        let container = try await provider.read(request("container:s1|abc123"), rpc)
        let logs = try #require(container["rows"].elements?.last)
        #expect(logs["body"].string == "ready\nlistening\n" || logs["body"].string == "ready\nlistening")
        #expect((container["rows"].elements?.first?["facts"].elements ?? []).contains { $0["value"].string == "1 (values hidden)" })
        #expect(await calls.tools().allSatisfy { !BackendDockerMCP.changes(tool: $0) || $0 == "servers.look" })
    }

    @Test func dockerReadsArePermittedOnlyForAPhonesReads() {
        let phone = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read], deviceID: "phone-1")
        #expect(BackendDockerMCPServerApproval.ownerPhoneRead(phone, changing: false))
        #expect(!BackendDockerMCPServerApproval.ownerPhoneRead(phone, changing: true))
        #expect(!BackendDockerMCPServerApproval.ownerPhoneRead(.init(kind: .remote, tiers: [.read], deviceID: nil), changing: false))
        #expect(!BackendDockerMCPServerApproval.ownerPhoneRead(.init(kind: .key, tiers: [.read], deviceID: "x"), changing: false))
    }

    @Test func aLongPageIsTrimmedToFitThePhoneAndSaysSo() {
        let rows = (0..<200).map { n in V.object([.init("id", .string("r\(n)")), .init("title", .string("Row \(n)")),
                                                  .init("body", .string(String(repeating: "x", count: 2_000)))]) }
        let value = BackendIOS2PhonePanels.payload(request("task:0|1"), rows: rows)
        #expect(((try? value.encodedJSON().count) ?? .max) <= BackendIOS2PhonePanels.byteBudget)
        #expect(value["rows"].elements?.first?["id"].string == "r0" && value["note"].string?.contains("Shortened") == true)
    }

    @Test func choiceNamesTravelWithTheIDsOnTheExistingTaskForm() {
        // The shared form helper keeps ids in `choices` (older phones) and adds `choiceLabels`.
        let field = BackendIOS2PhonePanels.field("agent", "Agent", choices: [("a1", "Critic")])
        #expect(field["choices"].elements == [.string("a1")] && field["choiceLabels"]["a1"].string == "Critic")
    }
}

/// The real remote host: the Mac has no Approvals page any more (nothing ever waited there), so a
/// phone that claims `panels.approvals` is not offered it and falls back to Hoot's own questions.
@Suite("IOS2 approvals over the real host", .serialized)
struct IOS2ApprovalsHostTests {
    private actor Wire {
        var frames: [V] = []
        func receive(_ text: String) throws { frames.append(try V.parseJSON(Data(text.utf8))) }
        func rows(_ type: String) -> [V] { frames.filter { $0["t"].string == type } }
    }

    @Test func claimedPhoneIsNotOfferedTheApprovalsPage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IOS2-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        let deviceID = device.device.id
        let port = BackendIOS2PanelPort(call: { _, _, _, _, _ in .null },
            level: { _, _ in await trust.phoneAccess(deviceID) ?? .look },
            device: { _, _, _ in
                guard let current = BackendINT2PhonePanelCaller.current else { throw NativeRPCError(code: "access-denied", message: "no connection") }
                return current.deviceID
            })
        let panels = BackendRemotePanelRegistry()
        try await panels.register(.agents, provider: BackendIOS2PhonePanels.agents(port: port))
        try await host.register(try await panels.feature())
        try await host.start()
        defer { Task { await host.stop(); await trust.close() } }

        func connect(_ claims: [String]) async throws -> (UUID, Wire) {
            let wire = Wire()
            let timer = clock.scheduled.value() + 1
            guard let id = await host.accept(.init(address: "fixture", send: { try await wire.receive($0) }, close: { _, _ in })) else {
                throw NativeRPCError(code: "fixture", message: "rejected")
            }
            await clock.scheduled.wait(timer)
            let hello = V.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
                .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])),
                .init("capabilities", .array(claims.map(V.string)))])
            await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
            try await waitFor { await wire.rows("welcome").count == 1 }
            return (id, wire)
        }
        let claims = ["github", "devices", "settings", "watch", "device.access", "hoot.events", "link.open"]
            + ["artifacts", "store", "readiness", "mcp", "tasks", "goals", "memory", "plugins", "staysfixed", "settings", "ai-apps",
               "simulators", "github", "hooks", "servers", "agents", "approvals", "connected-tasks", "docker"].map { "panels." + $0 }
        let (id, wire) = try await connect(claims)
        let offered = await wire.rows("welcome").first?["capabilities"].elements ?? []
        #expect(offered.contains(.string("panels.agents")) && !offered.contains(.string("panels.approvals")))
        await host.receive(id, text: #"{"t":"panel.read","panel":"approvals"}"#)
        try await waitFor { await wire.frames.count > 1 }
        #expect(await wire.rows("panel.rows").isEmpty)
    }

    private func waitFor(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeRPCError(code: "fixture-timeout", message: "The host did not answer.")
    }
}
