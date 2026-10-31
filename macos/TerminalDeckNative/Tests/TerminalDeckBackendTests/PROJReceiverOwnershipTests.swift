import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Made-up registered projects. The Receiver matches folders against the list it is given and holds
/// none of its own, so nothing here may depend on a folder of a real Mac.
private let madeUpProjects: [PROJProject] = [
    .init(id: "atlas", name: "Atlas", folders: ["/srv/work/atlas"]),
    .init(id: "birch", name: "Birch", folders: ["/srv/work/birch", "/srv/shared/birch-docs"]),
    .init(id: PROJProjects.independentID, name: "Independent"),
]

private actor PROJReceiverThreadDispatch: BackendRCVDispatching {
    var created: [NativeRPCValue] = []
    var continued: [String] = []
    private func capture(_ value: NativeRPCValue) -> String {
        created.append(value); return "local:thread-\(created.count)"
    }
    func createTask(assignee: String, title: String, instructions: String, project: String) async throws -> String {
        try await createTask(assignee: assignee, title: title, instructions: instructions, project: project, projectId: nil)
    }
    func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?) async throws -> String {
        try await BackendRCVProductionDispatch.createTask(assignee: assignee, title: title, instructions: instructions,
            project: project, projectId: projectId, projects: madeUpProjects, defaultProject: { "" }, create: { await self.capture($0) })
    }
    func continueTask(_ taskID: String, text: String) async throws { continued.append(taskID) }
    func typeIntoSession(_ sessionID: String, text: String) async throws { throw NativeRPCError(code: "unexpected", message: "No session in this fixture.") }
    func taskOutcome(_ taskID: String) async -> String? { nil }
    func agents() async -> [RCVChoice] { [.init(id: "builder", name: "Builder")] }
    func sessions() async -> [RCVChoice] { [] }
    func githubComment(repository: String, number: Int, body: String) async throws { throw NativeRPCError(code: "unexpected", message: "No GitHub in this fixture.") }
    func send(_ request: URLRequest) async throws -> Int { throw NativeRPCError(code: "unexpected", message: "No sender in this fixture.") }
}

@Suite("PROJ received task ownership")
struct PROJReceiverOwnershipTests {
    private actor Capture {
        var payload: NativeRPCValue?
        func create(_ value: NativeRPCValue) -> String { payload = value; return "local:receiver-fixture" }
    }
    private func dispatch(eventProject: String, rule: RCVRule? = nil) async throws -> NativeRPCValue {
        var event = RCVEvent(sourceId: "fixture-source", receivedAt: 1, kind: "fixture", title: "Received work")
        event.projectId = eventProject
        let capture = Capture()
        let result = try await BackendRCVProductionDispatch.createTask(assignee: "hoot", title: event.title,
            instructions: "Fixture instructions", project: rule?.project ?? "",
            projectId: BackendRCVProductionDispatch.projectId(event: event, rule: rule, projects: madeUpProjects),
            projects: madeUpProjects, defaultProject: { "/srv/work/atlas" }, create: { await capture.create($0) })
        #expect(result == "local:receiver-fixture")
        return try #require(await capture.payload)
    }

    @Test(arguments: ["birch", "independent"])
    func eventOwnershipSurvivesHootDefaultFolder(_ projectId: String) async throws {
        let payload = try await dispatch(eventProject: projectId)
        #expect(payload["projectId"].string == projectId)
        #expect(payload["project"].string == "/srv/work/atlas")
        #expect(payload["assignee"].string == "hoot" && payload["instructions"].string == "Fixture instructions")
    }

    @Test func explicitRuleProjectOverridesCRMSource() async throws {
        var rule = RCVRule(name: "Owner override", project: "/srv/work/birch")
        rule.projectId = "atlas"
        let payload = try await dispatch(eventProject: "birch", rule: rule)
        #expect(payload["projectId"].string == "atlas")
        #expect(payload["project"].string == "/srv/work/birch")
    }

    @Test func legacyNonemptyRuleFolderOverridesSourceProject() async throws {
        let payload = try await dispatch(eventProject: "birch", rule: RCVRule(name: "Legacy rule", project: "/srv/work/atlas"))
        #expect(payload["projectId"].string == "atlas")
        // An old rule's folder that no registered project holds files the task under Independent.
        let outside = try await dispatch(eventProject: "birch", rule: RCVRule(name: "Legacy rule", project: "/somewhere/else"))
        #expect(outside["projectId"].string == "independent")
    }

    /// SUITE-0600 note C3 (L4, 11 Oct): the Receiver sorted an event by a list built into the app that held
    /// two folders of the builder's own Mac, so on anyone else's Mac matching by folder found nothing.
    /// It is given the person's registered projects now and matches against those only.
    @Test func anEventThatNamesNoProjectIsSortedByItsFolderAmongTheRegisteredProjects() async throws {
        let store = BackendRCVStore(persistence: nil, cipher: nil)
        let dispatch = PROJReceiverThreadDispatch()
        let service = BackendRCVService(store: store, dispatch: dispatch, relayBase: { nil }, now: { 1_000 }, projects: { madeUpProjects })
        try await service.start()
        let sourceID = "terminaldeck.folder-fixture"
        try await store.seed { state in
            state.sources.append(RCVSource(id: sourceID, name: "Folder fixture", preset: "terminaldeck", origin: .terminalDeck,
                auth: .init(scheme: .none), mapping: RCVPresets.terminalDeck.mapping, projectScope: .all))
        }
        // (the folder the event came from, the project it must land in)
        let cases: [(folder: String, project: String)] = [
            ("/srv/work/atlas", "atlas"),                      // the project's own folder
            ("/srv/work/birch/api/src", "birch"),              // somewhere inside it
            ("/srv/shared/birch-docs", "birch"),               // a project's second folder
            ("/srv/work/atlas-old", "independent"),            // only looks alike: a whole folder name has to match
            ("/somewhere/else", "independent"),                // in no registered project
            ("/work/imatch", "independent"),     // nothing is built in: a folder the app once knew by itself
            ("/work/crm", "independent"),
        ]
        for (index, row) in cases.enumerated() {
            await service.post(internal: sourceID, .init(kind: "fixture", title: "Event \(index)", fields: ["project": row.folder], id: "folder-\(index)"))
        }
        let events = try await store.read().events
        #expect(events.count == cases.count)
        for (event, row) in zip(events, cases) { #expect(event.projectId == row.project, "\(row.folder)") }
        // A project the sender names outright always wins over the folder.
        await service.post(internal: sourceID, .init(kind: "fixture", title: "Named", fields: ["projectId": "atlas", "project": "/srv/work/birch"], id: "named"))
        let named = try #require(try await store.read().events.last)
        #expect(named.projectId == "atlas")
        await service.stop()
    }

    @Test func withNoRegisteredProjectsAFolderMatchesNothingAndANamedProjectStillWins() async throws {
        let store = BackendRCVStore(persistence: nil, cipher: nil)
        let service = BackendRCVService(store: store, dispatch: PROJReceiverThreadDispatch(), relayBase: { nil }, now: { 1_000 })
        try await service.start()
        let sourceID = "terminaldeck.empty-fixture"
        try await store.seed { state in
            state.sources.append(RCVSource(id: sourceID, name: "Empty fixture", preset: "terminaldeck", origin: .terminalDeck,
                auth: .init(scheme: .none), mapping: RCVPresets.terminalDeck.mapping, projectScope: .all))
        }
        await service.post(internal: sourceID, .init(kind: "fixture", title: "By folder", fields: ["project": "/work/imatch"], id: "a"))
        await service.post(internal: sourceID, .init(kind: "fixture", title: "By name", fields: ["projectId": "atlas", "project": "/srv/work/atlas"], id: "b"))
        let events = try await store.read().events
        #expect(events.map(\.projectId) == ["independent", "atlas"])
        await service.stop()
    }

    @Test func anOldRulesFolderIsMatchedAgainstTheGivenProjectsOnly() {
        let old = RCVRule(name: "Old rule", project: "/srv/work/birch/api")
        #expect(old.projectID(in: madeUpProjects) == "birch")
        #expect(old.projectID(in: []) == "independent")
        #expect(old.projectID == "independent", "without a list a folder names no project")
        var named = old; named.projectId = "atlas"
        #expect(named.projectID(in: madeUpProjects) == "atlas" && named.projectID == "atlas")
    }


    @Test func everyProjectSourceKeepsSameConversationTasksInTheirOwnProjects() async throws {
        let store = BackendRCVStore(persistence: nil, cipher: nil)
        let dispatch = PROJReceiverThreadDispatch()
        let service = BackendRCVService(store: store, dispatch: dispatch, relayBase: { nil }, now: { 1_000 }, projects: { madeUpProjects })
        try await service.start()
        let sourceID = "terminaldeck.project-fixture"
        let source = RCVSource(id: sourceID, name: "Every project fixture", preset: "terminaldeck", origin: .terminalDeck,
            auth: .init(scheme: .none), mapping: RCVPresets.terminalDeck.mapping, projectScope: .all)
        try await store.seed { state in state.sources.append(source) }
        _ = try await service.saveRule(RCVRule(name: "Same conversation", sourceIds: [sourceID],
            target: .init(kind: .agent, id: "builder", threadKey: "same-conversation")), byOwner: true)
        await service.post(internal: sourceID, .init(kind: "fixture", title: "Birch first", fields: ["projectId": "birch"], id: "birch-1"))
        await service.post(internal: sourceID, .init(kind: "fixture", title: "Independent first", fields: ["projectId": "independent", "project": "/srv/work/atlas"], id: "independent-1"))
        await service.post(internal: sourceID, .init(kind: "fixture", title: "Birch second", fields: ["projectId": "birch"], id: "birch-2"))
        let created = await dispatch.created
        let continued = await dispatch.continued
        #expect(created.count == 2)
        #expect(created.map { $0["projectId"].string } == ["birch", "independent"])
        #expect(continued == ["local:thread-1"])
        let events = try await service.events()
        #expect(events.count == 3 && events.allSatisfy { $0.status == .delivered })
        await service.stop()
    }

    @Test func oldStoredBuiltinMappingKeepsProducerOwnershipWithoutBeingRewritten() async throws {
        let store = BackendRCVStore(persistence: nil, cipher: nil)
        let dispatch = PROJReceiverThreadDispatch()
        let service = BackendRCVService(store: store, dispatch: dispatch, relayBase: { nil }, now: { 1_000 }, projects: { madeUpProjects })
        try await service.start()
        let sourceID = "terminaldeck.tasks"
        var oldMapping = RCVPresets.terminalDeck.mapping
        oldMapping.fields.removeAll { $0.name == "projectId" }
        oldMapping.fields.append(.init("ownerNote", "{{text}}"))
        let ownerMapping = oldMapping
        try await store.seed { state in
            guard let index = state.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            state.sources[index].mapping = ownerMapping
            state.sources[index].projectScope = .all
            state.sources[index].projectId = nil
        }
        _ = try await service.saveRule(RCVRule(name: "Old built-in work", sourceIds: [sourceID],
            target: .init(kind: .newTask, id: "builder")), byOwner: true)
        await service.post(internal: sourceID, .init(kind: "fixture", title: "Independent old source", text: "Owner mapping retained",
            fields: ["projectId": "independent", "project": "/srv/work/atlas"], id: "old-independent"))
        let state = try await store.read()
        let event = try #require(state.events.last)
        let created = await dispatch.created
        #expect(event.status == .delivered && event.projectId == "independent")
        #expect(event.fields["projectId"] == "independent")
        #expect(created.count == 1 && created.first?["projectId"].string == "independent")
        let retained = try #require(state.sources.first { $0.id == sourceID })
        #expect(retained.mapping == ownerMapping)
        #expect(!retained.mapping.fields.contains { $0.name == "projectId" })
        #expect(event.fields["ownerNote"] == "Owner mapping retained")
        await service.stop()
    }

    @Test func explicitIndependentRuleWinsOverLegacyFolder() async throws {
        var rule = RCVRule(name: "Independent", project: "/srv/work/atlas")
        rule.projectId = "independent"
        let payload = try await dispatch(eventProject: "birch", rule: rule)
        #expect(payload["projectId"].string == "independent")
    }
}
