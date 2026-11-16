import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Delete rule, lane L6 (Asad, 14 Nov: "if AI is doing this ... It should be everywhere", "in all cases it should go to
/// thirty days ... even if AI is deleting", "we can keep bin away from AI access"): the AI tools delete everywhere by
/// default with no question, record the session's and agent's names in one group per call, reach only the caller's
/// projects, ignore a scope for tasks and agents, never show a Bin or a sidecar, and bring back both ways. Fakes only:
/// the kinds' owners are stand-ins for the owner lanes' `CloudDeleteOwning`.
@Suite("Cloud delete tools — everywhere, no question, Bin by hand")
struct CloudDeleteToolsTests {
    typealias Door = BackendCloudDeleteDoor
    typealias Tools = BackendCloudManagerTools

    actor FakeOwner: CloudDeleteOwning {
        var deleted: [(items: [CloudDeleteItem], scope: CloudDeleteScope, actor: CloudDeleteActor)] = []
        var brought: [(items: [CloudDeleteItem], to: CloudBringBackDestination)] = []
        var binAsked = 0
        let marks: [CloudNotHereItem]
        init(marks: [CloudNotHereItem] = []) { self.marks = marks }
        func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by: CloudDeleteActor) async throws -> CloudBinGroup {
            deleted.append((items, scope, by))
            return CloudBinGroup(id: by.group, by: by.by, macName: by.macName, session: by.session, agent: by.agent, at: by.at, items: items)
        }
        func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
            brought.append((items, to)); return items
        }
        func notHere() async throws -> [CloudNotHereItem] { marks }
        func binGroups() async throws -> [CloudBinGroup] { binAsked += 1; return [] }
        func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] { binAsked += 1; return [] }
        func deleteForGood(_ items: [CloudDeleteItem]) async throws { binAsked += 1 }
    }
    final class Asked: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(tier: BackendMCPTier, ownerMustAnswer: Bool)] = []
        func add(_ tier: BackendMCPTier, _ owner: Bool) { lock.withLock { calls.append((tier, owner)) } }
        var all: [(tier: BackendMCPTier, ownerMustAnswer: Bool)] { lock.withLock { calls } }
    }

    static let plan = Door.Target(item: .init(id: "memory:hoot/notes/plan.md", kind: "memory", name: "Plan", place: "hoot/notes/plan.md"),
                                  placeName: "Terminal Deck", folder: "/projects/a")
    static let other = Door.Target(item: .init(id: "memory:b/notes/idea.md", kind: "memory", name: "Idea", place: "b/notes/idea.md"),
                                   placeName: "Other project", folder: "/projects/b")
    static let task = Door.recordTarget(kind: "task", id: "local:1", name: "Write docs", placeName: nil, folder: "/projects/a")
    static let agent = Door.recordTarget(kind: "agent", id: "builder", name: "Builder", placeName: nil, folder: nil)
    static let sidecar = Door.Target(item: .init(id: "about/0b1c", kind: "cloudFolder", name: "about/0b1c", place: "about/0b1c"))

    func access(_ kind: BackendDeckToolsAppCaller.Kind, granted: Set<String> = ["/projects/a"], asked: Asked = Asked()) -> BackendDeckToolsAppAccess {
        BackendDeckToolsAppAccess(
            caller: { _ in .init(kind: kind, sessionID: kind == .session ? "s-7f3a" : nil, keyName: kind == .key ? "Writer app" : nil) },
            knownFolder: { _, folder in
                guard kind == .local || granted.contains(folder) else { throw NativeRPCError(code: "not-granted", message: "no") }
                return folder
            },
            session: { _, id in
                .object([.init("id", .string(id)), .init("title", .string("Night work")), .init("profileName", .string("Builder"))])
            },
            runnableProject: { _, folder in folder }, rpc: { _ in throw NativeRPCError.invalidArguments("Unused") },
            authorize: { _, _, _, tier, _, ownerMustAnswer in asked.add(tier, ownerMustAnswer) },
            record: { _, _, _, _ in })
    }
    func door(_ owners: [String: FakeOwner], targets: [Door.Target], gate: Bool) -> Door {
        Door(targets: { targets }, owners: { owners.mapValues { $0 as any CloudDeleteOwning } },
             folderOf: { item in item.kind == "memory" ? "/projects/a" : nil },
             thisMac: { .init(id: "device-1", name: "Mac mini") }, gateOpen: { gate }, now: { 1_794_100_000_000 })
    }
    /// Unattended (an AI working alone overnight) and without the "alter" class: nothing here may need a person.
    let context = BackendMCPCallContext(sessionID: "s-7f3a", machineID: "device-1", projectRoot: "/projects/a", attended: false,
                                        allowedTools: BackendCloudManagerTools.pageIDs, allowedTiers: [.read, .act], cancellation: .init())
    func call(_ id: String, _ fields: [NativeRPCValue.Field], access: BackendDeckToolsAppAccess, door: Door,
              actions: Tools.Actions = .none) async throws -> BackendMCPToolReply {
        let tools = try Tools.definitions(access: access, actions: actions, door: door)
        return try await #require(tools.first { $0.spec.id == id }).handler(context, .object(fields))
    }
    static func items(_ refs: [(kind: String, name: String)]) -> NativeRPCValue.Field {
        .init("items", .array(refs.map { .object([.init("kind", .string($0.kind)), .init("name", .string($0.name))]) }))
    }

    @Test func deleteIsEverywhereByDefaultWithNamesInOneGroupAndNoQuestion() async throws {
        let memory = FakeOwner(), tasks = FakeOwner(), asked = Asked()
        let reply = try await call(Tools.deleteID, [Self.items([("Memory", "Plan"), ("Tasks", "Write docs")])],
                                   access: access(.session, asked: asked),
                                   door: door(["memory": memory, "task": tasks], targets: [Self.plan, Self.task, Self.other], gate: false))
        #expect(!reply.isError)
        let notes = await memory.deleted, work = await tasks.deleted
        #expect(notes.count == 1 && work.count == 1)
        #expect(notes.first?.scope == .everywhere && work.first?.scope == .everywhere)
        #expect(notes.first?.items == [Self.plan.item] && work.first?.items == [Self.task.item])
        let actor = try #require(notes.first?.actor)
        #expect(actor.by == .ai && actor.session == "Night work" && actor.agent == "Builder" && actor.macName == "Mac mini" && actor.mac == "device-1")
        #expect(work.first?.actor == actor, "one group for the whole call, across kinds")
        #expect(UUID(uuidString: actor.group) != nil)
        #expect(asked.all.allSatisfy { $0.tier != .alter && !$0.ownerMustAnswer }, "no approval question")
        let answer = try #require(reply.structuredContent)
        #expect(answer["where"].string == CloudDeleteWords.everywhere)
        #expect(answer["deleted"].elements?.compactMap { $0["name"].string } == ["Plan", "Write docs"])
        #expect(answer["line"].string?.contains("Bin for 30 days") == true && answer["line"].string?.contains("only the person") == true)
        #expect(!(answer["group"].string ?? "").contains(actor.group), "names, never the group's id")
        // Two calls, two groups.
        _ = try await call(Tools.deleteID, [Self.items([("Memory", "Plan")])], access: access(.session),
                           door: door(["memory": memory], targets: [Self.plan], gate: false))
        let groups = Set(await memory.deleted.map { $0.actor.group })
        #expect(groups.count == 2)
    }

    @Test func cloudScopeIsRefusedWhileAnOlderMacExists() async throws {
        let memory = FakeOwner()
        let reply = try await call(Tools.deleteID, [Self.items([("Memory", "Plan")]), .init("scope", .string("cloud"))], access: access(.local),
                                   door: door(["memory": memory], targets: [Self.plan], gate: false))
        #expect(reply.isError)
        #expect(reply.structuredContent?["error"].string == CloudDeleteWords.cloudNeedsUpdatedMacs)
        #expect(await memory.deleted.isEmpty)
    }

    @Test func anItemOutsideTheCallersProjectsIsRefusedAndNothingIsDeleted() async throws {
        let memory = FakeOwner()
        let reply = try await call(Tools.deleteID, [Self.items([("Memory", "Plan"), ("Memory", "Idea")])], access: access(.key, granted: ["/projects/a"]),
                                   door: door(["memory": memory], targets: [Self.plan, Self.other], gate: true))
        #expect(reply.isError)
        #expect(await memory.deleted.isEmpty)
        // A key narrowed to some folders never reaches an item in no project; a session on this Mac does.
        let agents = FakeOwner()
        #expect(try await call(Tools.deleteID, [Self.items([("Agents", "Builder")])], access: access(.key),
                               door: door(["agent": agents], targets: [Self.agent], gate: true)).isError)
        #expect(!(try await call(Tools.deleteID, [Self.items([("Agents", "Builder")])], access: access(.session),
                                 door: door(["agent": agents], targets: [Self.agent], gate: true)).isError))
    }

    @Test func tasksAndAgentsIgnoreTheScope() async throws {
        let memory = FakeOwner(), tasks = FakeOwner(), agents = FakeOwner()
        let owners = ["memory": memory, "task": tasks, "agent": agents]
        let reply = try await call(Tools.deleteID, [Self.items([("Memory", "Plan"), ("Task", "Write docs"), ("Agent", "Builder")]), .init("scope", .string("cloud"))],
                                   access: access(.local), door: door(owners, targets: [Self.plan, Self.task, Self.agent], gate: true))
        #expect(!reply.isError)
        #expect(await memory.deleted.first?.scope == .cloud)
        #expect(await tasks.deleted.first?.scope == .everywhere)
        #expect(await agents.deleted.first?.scope == .everywhere)
        // Only tasks and agents: a closed gate does not refuse them, they simply go everywhere.
        let closed = try await call(Tools.deleteID, [Self.items([("Tasks", "Write docs")]), .init("scope", .string("cloud"))],
                                    access: access(.local), door: door(owners, targets: [Self.task], gate: false))
        #expect(!closed.isError)
        #expect(await tasks.deleted.last?.scope == .everywhere)
    }

    @Test func noRetiredToolIsRegistered() throws {
        let access = access(.local)
        let ids = Set(try Tools.definitions(access: access, actions: .none, door: .none).map(\.spec.id))
            .union(try BackendCloudArtifactsTools.definitions(access: access, actions: .none).map(\.spec.id))
            .union(try BackendCloudFolderTools.definitions(access: access, actions: .none).map(\.spec.id))
        #expect(ids.isDisjoint(with: Tools.retiredIDs))
        #expect(ids == Tools.pageIDs.union(BackendCloudArtifactsTools.pageIDs).union(BackendCloudFolderTools.pageIDs))
        #expect(BackendCloudArtifactsTools.pageIDs == [BackendCloudArtifactsTools.listID])
        for id in ["cloud.remove", "cloud.restore", "cloud.bin", "cloud.empty_bin", "cloud.cleanup_versions", "cloud.artifacts_remove", "cloud.artifacts_put_back"] {
            #expect(Tools.retiredIDs.contains(id))
        }
        // The start-up check never expects a retired tool, so supplying one is refused as "Extra".
        let expected = try BackendDeckToolsRegistration.expectedIDs(supplied: Tools.pageIDs.union(Tools.retiredIDs).union(BackendCloudArtifactsTools.pageIDs))
        #expect(expected.isDisjoint(with: Tools.retiredIDs))
        #expect(expected.isSuperset(of: Tools.pageIDs))
        // Every changing tool here is "act" (no question, works unattended); none is "alter".
        let tiers = try Tools.definitions(access: access, actions: .none, door: .none).map(\.spec.tier)
        #expect(!tiers.contains(.alter))
    }

    @Test func noListingShowsABinOrASidecar() async throws {
        let now: Int64 = 1_794_100_000_000
        let fixture = BackendCloudContentsFixture.fileManager(now: now)
        let made = try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: BackendCloudContentsFixture.snapshot(now: now),
                                                                 names: fixture.names, now: now))
        let actions = Tools.Actions(contents: { .init(contents: made.model, handles: made.handles) },
                                    read: { ref, _ in .init(item: try Tools.find(made.model, ref), versions: [], text: "text") },
                                    change: { _ in "done" })
        let listed = try await call(Tools.itemsID, [], access: access(.local), door: .none, actions: actions)
        let rows = listed.structuredContent?["items"].elements ?? []
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0["state"].string != "In the Bin" && $0["removedAt"].isNullish && $0["goesForGoodAt"].isNullish })
        let binNames = Set(made.model.bin.map(\.name)), liveNames = Set(made.model.items.filter { !BackendCloudNoteIdentity.isBin($0.state) }.map(\.name))
        for name in binNames.subtracting(liveNames) { #expect(!rows.contains { $0["name"].string == name }, "\(name)") }
        #expect(listed.structuredContent?["earlierVersionsKept"].isNullish == true, "nothing counts the keeper for a clean up")
        let targets = await Door.memoryTargets(.init(contents: made.model, handles: made.handles), folder: { _ in nil })
        for name in binNames.subtracting(liveNames) { #expect(!targets.contains { $0.item.name == name }) }
        // Sidecars: never an item to delete, never a not-here row.
        #expect(Tools.isSidecar("about/0b1c") && !Tools.isSidecar("notes/about.md"))
        let folder = FakeOwner(marks: [.init(item: Self.sidecar.item, mark: .notOnThisMac, at: now),
                                       .init(item: .init(id: "report.pdf", kind: "cloudFolder", name: "report.pdf", place: "report.pdf"), mark: .notOnThisMac, at: now)])
        let notHere = try await call(Tools.notHereID, [], access: access(.local), door: door(["cloudFolder": folder], targets: [Self.sidecar], gate: true))
        #expect(notHere.structuredContent?["items"].elements?.compactMap { $0["name"].string } == ["report.pdf"])
        #expect(try await call(Tools.deleteID, [Self.items([("Cloud folder", "about/0b1c")])], access: access(.local),
                               door: door(["cloudFolder": folder], targets: [Self.sidecar], gate: true)).isError)
        #expect(await folder.deleted.isEmpty)
        #expect(await folder.binAsked == 0, "no tool ever asks an owner for its Bin")
    }

    @Test func bringBackWorksBothWays() async throws {
        let now: Int64 = 1_794_100_000_000
        let away = CloudDeleteItem(id: "memory:hoot/notes/away.md", kind: "memory", name: "Away", place: "hoot/notes/away.md")
        let kept = CloudDeleteItem(id: "memory:hoot/notes/kept.md", kind: "memory", name: "Kept", place: "hoot/notes/kept.md")
        let memory = FakeOwner(marks: [.init(item: away, mark: .notOnThisMac, at: now), .init(item: kept, mark: .onlyOnThisMac, at: now - 1)])
        let memoryDoor = door(["memory": memory], targets: [], gate: true)
        let listed = try await call(Tools.notHereID, [], access: access(.session), door: memoryDoor)
        let states = listed.structuredContent?["items"].elements?.compactMap { $0["state"].string } ?? []
        #expect(states == [CloudDeleteWords.notOnThisMac, CloudDeleteWords.onlyOnThisMac])
        let reply = try await call(Tools.bringBackID, [Self.items([("Memory", "Away"), ("Memory", "Kept")])], access: access(.session), door: memoryDoor)
        #expect(!reply.isError)
        let brought = await memory.brought
        #expect(brought.contains { $0.items == [away] && $0.to == .thisMac })
        #expect(brought.contains { $0.items == [kept] && $0.to == .cloud })
        // An explicit destination that does not fit the item is said plainly; nothing else happens to it.
        let wrong = try await call(Tools.bringBackID, [Self.items([("Memory", "Away")]), .init("to", .string("cloud"))], access: access(.session), door: memoryDoor)
        #expect(wrong.isError)
        #expect(await memory.brought.count == 2)
        #expect(await memory.binAsked == 0)
    }
}
