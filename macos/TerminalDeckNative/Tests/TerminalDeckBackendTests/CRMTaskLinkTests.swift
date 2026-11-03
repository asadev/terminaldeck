import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// CRM-LINK-SPEC.md on the crm_task contract: the owner pin, the roster, every CRM field landing,
/// "From CRM" tasks that wake nobody, Hoot without a project, mentions, context-only comments,
/// the actor echo and the sync switch. No network: the engine is the recording fixture.
struct CRMTaskLinkTests {
    static let owner = "user:00000000-0000-4000-8000-0000000000aa"

    func rig(extraAgents: [NativeRPCValue] = []) async throws -> (BackendRoutinesTaskStoreParityRig, BackendTaskAPI) {
        let root = try routinesTaskScratch()
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let connection = routinesTaskObject([("keyId", .string("k1")), ("name", .string("iLoop CRM")), ("enabled", .bool(true)), ("eventsUrl", .null),
            ("eventsSecret", .string(BackendRoutinesTaskStoreParityRig.secret)), ("statuses", BackendTaskConfiguration.defaultStatuses), ("hootIdentity", .string("agent:hoot")),
            ("identities", .object([])), ("allowedSenders", routinesTaskText([Self.owner])), ("folders", routinesTaskText(["/work/crm"])), ("maxHops", .number(3)),
            ("ownerProfile", .string(Self.owner)), ("projects", routinesTaskText(["imatch", "crm"]))])
        try persistence.write("task-config.json", value: routinesTaskObject([("v", .number(1)), ("connections", .array([connection])), ("agents", .array([
            routinesTaskObject([("id", .string("builder")), ("name", .string("Builder")), ("projectId", .string("crm")), ("defaultProject", .string("/work/crm"))]),
            routinesTaskObject([("id", .string("tester")), ("name", .string("Tester")), ("projectId", .string("terminal-deck")), ("defaultProject", .string("/work/td"))])] + extraAgents))]))
        let rig = try await BackendRoutinesTaskStoreParityRig.make(root: root)
        return (rig, BackendTaskAPI(store: rig.store, configuration: rig.config, engine: rig.recorder))
    }

    func create(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        let base: [(String, NativeRPCValue)] = [("eventId", .string(UUID().uuidString)), ("externalTaskId", .string("t-" + UUID().uuidString.prefix(6))), ("title", .string("Call the owner")),
                            ("instructions", .string("He asked for the valuation.")), ("requestedBy", .string(Self.owner)), ("creator", .string(Self.owner))]
        return routinesTaskObject(base.filter { key in !fields.contains { $0.0 == key.0 } } + fields)
    }

    @Test func onlyTheOwnersProfileCanGiveWorkAnyoneElseIsRefusedAndNothingStarts() async throws {
        let (rig, api) = try await rig()
        let answer = try await api.call("create", keyID: "k1", input: create([("assignee", .string("agent:builder")), ("requestedBy", .string("user:someone-else"))]))
        #expect(!answer.ok && answer.code == "not_allowed")
        #expect(try await rig.store.all().isEmpty)
        #expect(await rig.recorder.accepted.isEmpty)
        let status = try await api.call("status", keyID: "k1", input: routinesTaskObject([("eventId", .string("e2")), ("externalTaskId", .string("x")), ("status", .string("Done")), ("changedBy", .string("user:someone-else"))]))
        #expect(status.code == "not_allowed")
    }

    @Test func rosterIsHootPlusTheLinkedProjectsAgentsWithSmallAvatars() async throws {
        let extras = [("archived", "archived", nil), ("paused", "paused", nil), ("symbol", "active", "sf:star@pink"), ("emoji", "active", "emoji:🦉")]
        let (_, api) = try await rig(extraAgents: extras.map { id, status, icon in
            routinesTaskObject([("id", .string(id)), ("name", .string(id.capitalized)), ("projectId", .string("crm")),
                ("status", .string(status)), ("statusAt", .number(123)), ("icon", icon.map(NativeRPCValue.string) ?? .null)])
        })
        let answer = try await api.call("roster", keyID: "k1", input: .object([]))
        let agents = try #require(answer.value["agents"].elements)
        #expect(agents.first?["handle"].string == "hoot" && agents.first?["project"].isNullish == true)
        #expect(agents.contains { $0["handle"].string == "builder" && $0["project"].string == "crm" && $0["identity"].string == "agent:builder" && $0["kind"].string == "agent" })
        #expect(!agents.contains { $0["handle"].string == "tester" }, "the Terminal Deck team is never offered to the CRM")
        #expect(!agents.contains { $0["handle"].string == "archived" })
        #expect(agents.contains { $0["handle"].string == "paused" && $0["available"].bool == false })
        let second = try await api.call("roster", keyID: "k1", input: .object([]))
        for agent in agents {
            let png = try #require(agent["avatar"]["png"].string.flatMap { Data(base64Encoded: $0) })
            #expect(png.count > 0 && png.count <= BackendCrmLink.maxAvatarBytes && png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            #expect(agent["avatar"]["bytes"].number == Double(png.count))
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            #expect(agent["avatar"]["sha256"].string == hash)
            #expect(second.value["agents"].elements?.first { $0["handle"] == agent["handle"] }?["avatar"]["sha256"].string == hash)
            if ["symbol", "emoji"].contains(agent["handle"].string ?? "") {
                let fallback = await BackendCrmLink.avatar(name: agent["displayName"].string!, seed: agent["handle"].string!)
                #expect(fallback["sha256"].string != hash, "the saved icon must be drawn instead of initials")
            }
        }
    }

    @Test func removedAgentsDisappearFromTheRoster() async throws {
        let (rig, api) = try await rig()
        try await rig.config.removeAgent("builder")
        let answer = try await api.call("roster", keyID: "k1", input: .object([]))
        #expect(answer.value["agents"].elements?.compactMap { $0["handle"].string } == ["hoot"])
    }

    @Test func aCreateForAProjectAgentLandsEveryCRMField() async throws {
        let (rig, api) = try await rig()
        var input = try NativeRPCValue.parseJSON(Data(RCVPresets.crmTasksSample.utf8))
        input = input.setting("assignee", .string("agent:builder")).setting("requestedBy", .string(Self.owner)).setting("eventId", .string("e-full"))
        let answer = try await api.call("create", keyID: "k1", input: input)
        #expect(answer.ok, "\(answer.message ?? "")")
        let task = try #require(try await rig.store.byID("k1:7f3a1c2e"))
        #expect(task.value["priority"].string == "High" && task.value["dueDate"].string == "2026-10-14" && task.value["board"].string == "Follow-ups")
        #expect(task.value["labels"].elements?.compactMap(\.string) == ["landlord", "follow-up"] && task.value["estimateMinutes"].number == 30)
        let custom = Set((task.value["crmFields"].elements ?? []).compactMap { $0["label"].string })
        #expect(custom.isSuperset(of: ["URL", "Budget", "Attachments", "Subtasks", "Comments", "Followers", "Related"]))
        #expect(task.value["instructions"].string?.contains("## Details from the CRM") == true && task.value["instructions"].string?.contains("Due date: 2026-10-14") == true)
        #expect(task.value["projectId"].string == "crm" && task.project == "/work/crm")
        #expect(await rig.recorder.accepted == ["k1:7f3a1c2e"])
        // What the Receiver's Check connection expects is what landed.
        let snapshot = BackendTaskFieldLanding.snapshot(task)
        let expected = BackendCrmLink.fields(input)
        #expect(expected.keys.allSatisfy { snapshot.values[$0] == expected.text($0) })
        #expect(expected.custom.allSatisfy { snapshot.custom[$0.label] != nil })
    }

    @Test func aTaskGivenToAsadWaitsInFromCRMAndOthersCommentsAreContextOnly() async throws {
        let (rig, api) = try await rig()
        let input = create([("externalTaskId", .string("asad-1")), ("board", .string("From CRM"))])
        #expect(try await api.call("create", keyID: "k1", input: input).ok)
        let task = try #require(try await rig.store.byID("k1:asad-1"))
        #expect(task.assigneeKind == "none" && task.value["board"].string == "From CRM" && task.value["labels"].elements?.first?.string == "From CRM")
        #expect(task.value["process"].string == "idle")
        let comment = routinesTaskObject([("eventId", .string("c1")), ("externalTaskId", .string("asad-1")), ("author", .string("user:colleague")), ("authorName", .string("Umer")),
                                          ("body", .string("@builder can you do this?")), ("mentions", routinesTaskText(["agent:builder"])), ("contextOnly", .bool(true))])
        let answer = try await api.call("comment", keyID: "k1", input: comment)
        #expect(answer.ok && answer.value["outcome"].string == "kept_as_context")
        let noneReassigned = await rig.recorder.reassigned.isEmpty, noReplies = await rig.recorder.replies.isEmpty
        #expect(noneReassigned && noReplies)
    }

    /// #576: "@sam" asks sam only, never samantha; an address is not a mention.
    @Test func aMentionMatchesAWholeNameOnly() {
        #expect(BackendCrmLink.mentions("@sam please take the auth part", "@sam"))
        #expect(BackendCrmLink.mentions("thanks, @sam.", "@sam"))
        #expect(!BackendCrmLink.mentions("@samantha please take the auth part", "@sam"))
        #expect(!BackendCrmLink.mentions("write to me@sam today", "@sam"))
        #expect(BackendCrmLink.mentions("@samantha and @sam both", "@sam"))
        #expect(!BackendCrmLink.mentions("@ab", "@a"))
    }

    @Test func hootTakesATaskWithNoProjectAndAMentionOnAnUnlinkedTaskGivesIt() async throws {
        let (rig, api) = try await rig()
        #expect(try await api.call("create", keyID: "k1", input: create([("externalTaskId", .string("h-1")), ("assignee", .string("agent:hoot"))])).ok)
        let hoot = try #require(try await rig.store.byID("k1:h-1"))
        #expect(hoot.assigneeKind == "hoot" && hoot.value["instructions"].string?.contains("No project came with this task") == true)
        #expect(hoot.value["instructions"].string?.contains("(linked: imatch, crm)") == true, "Hoot is told the connection's own projects (U33)")
        let mention = routinesTaskObject([("eventId", .string("m1")), ("externalTaskId", .string("new-1")), ("author", .string(Self.owner)),
                                          ("body", .string("@builder please price this")), ("mentions", routinesTaskText(["agent:builder"]))])
        #expect(try await api.call("comment", keyID: "k1", input: mention).value["outcome"].string == "accepted")
        let made = try #require(try await rig.store.byID("k1:new-1"))
        #expect(made.agentID == "builder" && made.value["instructions"].string?.contains("please price this") == true)
        // U33: the comment is named after the person who wrote it (their CRM name, else this Mac's owner), never a built-in name.
        #expect(made.value["instructions"].string?.contains(DeckOwner.name + "’s comment: @builder please price this") == true)
        let named = routinesTaskObject([("eventId", .string("m2")), ("externalTaskId", .string("new-2")), ("author", .string(Self.owner)), ("authorName", .string("Sam Lee")),
                                        ("body", .string("@builder check the total")), ("mentions", routinesTaskText(["agent:builder"]))])
        #expect(try await api.call("comment", keyID: "k1", input: named).value["outcome"].string == "accepted")
        #expect(try await rig.store.byID("k1:new-2")?.value["instructions"].string?.contains("Sam Lee’s comment: @builder check the total") == true)
        // No projects on the connection reaches Hoot only: none are built in.
        #expect(BackendCrmLink.projects(routinesTaskObject([("keyId", .string("k2"))])).isEmpty)
    }

    @Test func aPersonHeldTaskSpeaksAsTheCRMProfileAndSyncOffSendsNothing() async throws {
        let (rig, api) = try await rig()
        #expect(try await api.call("create", keyID: "k1", input: create([("externalTaskId", .string("p-1"))])).ok)
        let task = try #require(try await rig.store.byID("k1:p-1"))
        #expect(BackendCrmLink.outgoingActor("none", task: task) == Self.owner)
        #expect(BackendCrmLink.outgoingActor("agent:builder", task: task) == "agent:builder")
        _ = try await BackendCrmLink.sync(task, on: false, store: rig.store)
        let off = try #require(try await rig.store.byID(task.id))
        try await BackendTaskOutbox.outgoing(store: rig.store, outbox: rig.outbox)(off, routinesTaskObject([("type", .string("task.comment")), ("actor", .null)]))
        #expect(await rig.outbox.list().isEmpty)
    }

    @Test func crmSyncIsIndexedForHootSessionsAndTasksKeysAndRoundTrips() async throws {
        let (rig, api) = try await rig()
        #expect(try await api.call("create", keyID: "k1", input: create([("externalTaskId", .string("sync-tool"))])).ok)
        let server = BackendNativeMCPServer()
        let planning = BackendGoalPlanning(goals: rig.goals, tasks: rig.store, configuration: rig.config, local: rig.local, detail: rig.detail)
        let authority = BackendTaskToolAuthority(requireTasks: { caller in
            guard caller.machineID != "no-tasks" else { throw NativeRPCError(code: "not-granted", message: "No tasks grant") }
        }, requireHoot: { _ in throw NativeRPCError(code: "not-granted", message: "Hoot only") },
            visible: { caller, _ in caller.machineID != "other-key" }, project: { _, _ in },
            authorize: { _, _, args, tier in #expect(tier == (args["on"].isNullish ? .read : .act)) }, actorName: { _ in "Hoot" })
        _ = try await BackendTaskMCP.register(server: server, view: rig.view, local: rig.local, engine: rig.engine,
            detail: rig.detail, planning: planning, api: api, indexed: true, authority: authority)
        let sync = try #require(await server.registrations().first { $0.0.id == "tasks.crm_sync" })
        #expect(sync.0.tier == .read)
        let metadata = try BackendDeckCoreSupplementMetadata.entries(specs: [sync.0])
        let registry = try BackendDeckCoreCatalogueRegistry(metadata: metadata)
        #expect(registry.resolve("tasks_crm_sync")?.tool.id == "tasks.crm_sync")
        #expect(BackendDeckCoreCatalogueDescribe.areaOf(sync.0.id) == "agents")
        for caller in [BackendDeckCoreSecurityCaller.local,
                       BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "worker"),
                       BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act], keyID: "k1", tasks: true)] {
            let described = try BackendDeckCoreCatalogueDescribe.answer(routinesTaskObject([("tools", routinesTaskText(["tasks_crm_sync"]))]), catalogue: metadata, granted: nil, caller: caller)
            #expect(described.value.compact.contains("tasks_crm_sync"))
            #expect(try registry.listing(caller: caller).map(\.advertisedValue).map(\.compact).joined().contains("tasks_crm_sync"))
        }
        #expect(!metadata[0].visible(to: nil, caller: .init(kind: .key, tiers: [.read, .act], keyID: "k1", tasks: false)))
        func context(_ machine: String, _ tiers: Set<BackendMCPTier> = [.read, .act]) -> BackendMCPCallContext {
            .init(sessionID: "worker", machineID: machine, projectRoot: nil, attended: true,
                  allowedTools: [], allowedTiers: tiers, cancellation: .init())
        }
        let args = routinesTaskObject([("task", .string("k1:sync-tool"))])
        func state(_ reply: BackendMCPToolReply) throws -> Bool? {
            let text = reply.content.compactMap { $0["text"].string }.joined()
            return try NativeRPCValue.parseJSON(Data(text.utf8))["syncToCRM"].bool
        }
        for caller in [context("hoot"), context("session"), context("k1")] {
            #expect(try state(await sync.1(caller, args)) == true)
            #expect(try state(await sync.1(caller, args.setting("on", .bool(false)))) == false)
            #expect(try state(await sync.1(caller, args)) == false)
            #expect(try state(await sync.1(caller, args.setting("on", .bool(true)))) == true)
        }
        #expect(try state(await sync.1(context("k1", [.read]), args)) == true)
        for caller in [context("no-tasks"), context("other-key"), context("k1", [.read])] {
            #expect(!(await routinesTaskError { _ = try await sync.1(caller, args.setting("on", .bool(false))) }).isEmpty)
        }
        #expect(try await rig.store.byID("k1:sync-tool")?.value["crmSync"].bool == true)
    }

    @Test func v11ACreateAfterACancelReopensTheSameTaskAndNamesAreContextOnly() async throws {
        let (rig, api) = try await rig()
        #expect(try await api.call("create", keyID: "k1", input: create([("externalTaskId", .string("r-1")), ("assignee", .string("agent:builder")), ("createdByName", .string("Asad Iqbal"))])).ok)
        let cancel = routinesTaskObject([("eventId", .string("x1")), ("externalTaskId", .string("r-1")), ("requestedBy", .string(Self.owner)), ("changedByName", .string("Asad Iqbal"))])
        #expect(try await api.call("cancel", keyID: "k1", input: cancel).ok)
        let cancelled = try #require(try await rig.store.byID("k1:r-1"))
        #expect(cancelled.value["stopped"].bool == true && !cancelled.value["archivedAt"].isNullish)
        let again = try await api.call("create", keyID: "k1", input: create([("externalTaskId", .string("r-1")), ("assignee", .string("agent:builder")), ("instructions", .string("Do it after all."))]))
        #expect(again.ok && again.value["reopened"].bool == true)
        let reopened = try #require(try await rig.store.byID("k1:r-1"))
        #expect(reopened.value["stopped"].bool == false && reopened.value["archivedAt"].isNullish && reopened.value["projectId"].string == "crm")
        #expect(reopened.value["instructions"].string?.contains("Do it after all.") == true)
        let notes = (reopened.value["notes"].elements ?? []).compactMap { $0["text"].string }
        #expect(notes.contains("Asad Iqbal created it in the CRM.") && notes.contains("Asad Iqbal cancelled it in the CRM."))
        let reassigned = await rig.recorder.reassigned
        #expect(reassigned == ["k1:r-1"])
    }
}
