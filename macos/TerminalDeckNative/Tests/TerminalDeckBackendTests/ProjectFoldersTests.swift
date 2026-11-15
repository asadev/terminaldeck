import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Project folders (owner, 14 Nov 2026): a project in his Cloud that this Mac does not have a folder for gets one by
/// itself at `<Terminal Deck folder>/Projects/<name>`, and what the Cloud carries for it then lands. Two Macs exchange
/// records through the lean fixtures (as `CloudKindsTests` does). Every folder is a scratch folder under
/// ~/Deck Dev/notes/cloud-test-20261112: no real home folder, no real `~/Terminal Deck`, no real project.
@Suite("Project folders — a project from the Cloud gets its own folder on this Mac by itself")
struct ProjectFoldersTests {
    final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Double = 1_000
        var value: Double { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }
    struct Side {
        let mac: CloudLeanFixtureMac
        let registry: BackendPROJRegistry
        let folders: BackendProjectFolders?
        let owner: BackendCloudLeanProjects
        let adapter: CloudBrainRecordAdapter
        let tasks: BackendTaskStore
        let taskAdapter: CloudBrainRecordAdapter
        let home: URL
        let notices: CloudLeanFixture.Counter
        var adapters: [CloudBrainRecordAdapter] { [adapter, taskAdapter] }
        var projectsFolder: URL { home.appendingPathComponent("Terminal Deck/Projects", isDirectory: true) }
        func path(_ name: String) -> String { PROJProjects.normalize(projectsFolder.appendingPathComponent(name).path) }
        func project(_ id: String) async throws -> PROJProject? { try await registry.projects().first { $0.id == id } }
    }

    /// One Mac: its project list, its project folders (unless `folders` is false: a Mac on the record rule alone), its
    /// task list, and a scratch home folder.
    static func side(_ device: String, clock: CloudLeanFixture.Clock, folders: Bool = true, now: Now = Now()) async throws -> Side {
        let mac = try CloudLeanFixture.mac(device, clock: clock)
        let notices = CloudLeanFixture.Counter()
        let registry = BackendPROJRegistry(fileURL: mac.root.appendingPathComponent("projects.registry.json"), changed: { _ in notices.bump() })
        let home = mac.root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let placer = folders ? BackendProjectFolders(file: mac.root.appendingPathComponent("data/" + BackendProjectFolders.fileName),
                                                    registry: registry, home: home.path, protected: [mac.root.appendingPathComponent("data").path],
                                                    now: { now.value }) : nil
        let owner = BackendCloudLeanProjects(registry: registry, folders: placer)
        let tasks = BackendTaskStore(persistence: try .init(directory: mac.root.appendingPathComponent("remote"), ownership: .exclusive))
        try await tasks.start()
        let taskOwner = BackendCloudKindsTasks(store: tasks, projects: {
            guard let all = try? await registry.projects() else { return nil }
            return all.map { BackendCloudKindsProject(id: $0.id, folders: $0.folders) }
        })
        return Side(mac: mac, registry: registry, folders: placer, owner: owner,
                    adapter: try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins),
                    tasks: tasks, taskAdapter: try taskOwner.adapter(store: mac.store, account: mac.account, origins: mac.origins),
                    home: home, notices: notices)
    }
    static func cleanup(_ sides: Side...) { for side in sides { try? FileManager.default.removeItem(at: side.mac.root) } }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func listing(_ path: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() }

    // MARK: the normal path

    /// Mac A (his main Mac) has the project in a folder of its own; Mac B has none. B gets `…/Projects/Deck`, the
    /// project, its waiting task; A is untouched and nothing is sent back because of B's new folder.
    @Test func aProjectFromTheCloudGetsItsFolderAndWhatWaitedForItLands() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        let custom = "/Users/person-a/Work/deck-custom"
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", folders: [custom], icon: "terminal", colour: "teal"))
        _ = try await a.tasks.put(CloudKindsTests.task("p", title: "In deck", project: custom + "/app"), now: true)

        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        // A has its project in its own folder: nothing is made there, and the Terminal Deck folder is not touched.
        #expect(try await a.project("deck")?.folders == [custom])
        #expect(!Self.exists(a.home.appendingPathComponent("Terminal Deck")), "A Mac that has the project makes nothing")
        let travelled = CloudLeanFixture.text(startedA.sent)
        #expect(!travelled.contains("person-a") && !travelled.contains("Terminal Deck"), "No folder path travels")

        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        // The task comes first and waits: its project is not on B yet.
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.taskAdapter)
        #expect(try await b.tasks.byID("local:p") == nil)
        #expect(try await b.taskAdapter.listing().waiting.contains { $0.reason == BackendCloudKindsTasks.waitsForProject })

        // The project arrives: its folder is made by itself, with the project's own name, and the project points at it.
        let noticesBefore = b.notices.count
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let arrived = try #require(try await b.project("deck"))
        #expect(arrived.name == "Deck")
        #expect(arrived.folders == [b.path("Deck")])
        #expect(Self.listing(b.path("Deck")).isEmpty, "Only what the Cloud carries goes in: no code, nothing fetched")
        #expect(b.notices.count > noticesBefore, "The folder is saved through the ordinary change point (side panel, boot files, memory hear of it)")
        #expect(try await b.owner.needingFolder().isEmpty)
        // Memory for the project is placed under the same id.
        #expect(b.owner.memoryResolver()("deck", "store") == "deck")
        let rows = try await b.folders!.rows()
        #expect(rows == [.init(projectID: "deck", name: "Deck", folder: b.path("Deck"), onThisMac: true, madeByApp: true)])

        // The waiting task arrives, in the new folder; nothing travels back, from either Mac.
        let fromB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(fromB.isEmpty, "A folder made here is not a changed project and sends nothing")
        let placed = try #require(try await b.tasks.byID("local:p")?.value)
        #expect(placed["project"].string == b.path("Deck"))
        #expect(try await b.taskAdapter.listing().waiting.isEmpty)
        #expect(try await CloudLeanFixture.sync(startedA.activation, on: a.mac).isEmpty)
        #expect(try await a.project("deck")?.folders == [custom], "A is untouched")
        // A second look makes nothing more.
        #expect(await b.folders!.placeMissing().isEmpty)
        #expect(Self.listing(b.projectsFolder.path) == ["Deck"])
    }

    /// A Mac that already has the project, in whatever folder: nothing moves, nothing is made.
    @Test func aMacThatAlreadyHasTheProjectKeepsItsFolderAndMakesNothing() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", folders: ["/Users/person-a/deck"]))
        _ = try await b.registry.save(PROJProject(id: "deck", name: "Deck", folders: ["/Users/person-b/elsewhere/deck"]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        #expect(try await b.project("deck")?.folders == ["/Users/person-b/elsewhere/deck"])
        #expect(!Self.exists(b.home.appendingPathComponent("Terminal Deck")))
    }

    /// The instruction files the Cloud carries land in the new folder (lane F places them in a project's one folder).
    @Test func instructionFilesLandInTheNewFolderAndNothingElseIsInIt() async throws {
        let f = try CloudBootFilesFixture(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.write("a/app/.claude/commands/ship.md", "Ship.\n")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p-app", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [])
        try await CloudBootFilesFixture.apply(b, try await CloudBootFilesFixture.snapshot(a).operations, device: f.deviceA)
        #expect(try await b.items().count == 2, "They wait for the project's folder")

        // The project arrives on B (the record alone) and its folder is made.
        let registry = BackendPROJRegistry(fileURL: f.url("b/data/projects.registry.json"))
        try await registry.cloudLeanWrite(PROJProject(id: "p-app", name: "App"))
        let home = try f.folder("b/home")
        let folders = BackendProjectFolders(file: f.url("b/data/" + BackendProjectFolders.fileName), registry: registry, home: home.path)
        let placed = await folders.placeMissing()
        let folder = try #require(placed.first?.folder)
        // As the app hands places to lane F: a project's only folder is its chosen one (NativeCloudBootPlaces.decide).
        try await b.setPlaces([BackendCloudBootFilesPlace(kind: .project, identity: "p-app", root: URL(fileURLWithPath: folder, isDirectory: true), chosen: true)])
        #expect((try? String(contentsOfFile: folder + "/CLAUDE.md", encoding: .utf8)) == "rules\n")
        #expect((try? String(contentsOfFile: folder + "/.claude/commands/ship.md", encoding: .utf8)) == "Ship.\n")
        #expect(Self.listing(folder) == [".claude", "CLAUDE.md"], "Only what the Cloud carries")
        #expect(try await b.items().isEmpty)
    }

    // MARK: names

    @Test func folderNamesAreTheProjectNameMadeSafe() {
        #expect(BackendProjectFolders.safeName("Deck") == "Deck")
        #expect(BackendProjectFolders.safeName("  Client / Site: v2  ") == "Client - Site- v2")
        #expect(BackendProjectFolders.safeName(".hidden") == "hidden")
        #expect(BackendProjectFolders.safeName("../up") == "-up")
        #expect(BackendProjectFolders.safeName("two\nlines") == "two lines")
        #expect(BackendProjectFolders.safeName("...") == "Project")
        #expect(BackendProjectFolders.safeName("   ") == "Project")
        #expect(BackendProjectFolders.safeName(String(repeating: "x", count: 300)).utf8.count == BackendProjectFolders.maximumNameBytes)
        // Limited in BYTES: 80 emoji are about 320 bytes, more than a disk takes in one name.
        let emoji = BackendProjectFolders.safeName(String(repeating: "🚀", count: 80))
        #expect(emoji.utf8.count <= BackendProjectFolders.maximumNameBytes && !emoji.isEmpty && emoji.allSatisfy { $0 == "🚀" })
        // Characters other disk formats (exFAT) refuse.
        #expect(BackendProjectFolders.safeName(#"a?b*c"d<e>f|g"#) == "a-b-c-d-e-f-g")
        #expect(BackendProjectFolders.safeName("Notes.") == "Notes")
        #expect(Array(BackendProjectFolders.candidates("Deck").prefix(3)) == ["Deck", "Deck 2", "Deck 3"])
    }

    /// Two projects with the same name get plain, stable names; a folder of his that is already there is never taken
    /// over or written into; a rename later never moves a folder.
    @Test func sameNamesGetPlainSecondNamesAndHisOwnFolderIsNeverTaken() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock, folders: false), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        // His own "Deck" folder made by hand before signing in (not this project: same name, different project).
        let his = b.projectsFolder.appendingPathComponent("Deck", isDirectory: true)
        try FileManager.default.createDirectory(at: his, withIntermediateDirectories: true)
        try Data("mine\n".utf8).write(to: his.appendingPathComponent("notes.txt"))
        // A file (not a folder) called "Deck 3" is not taken either.
        try Data("x".utf8).write(to: b.projectsFolder.appendingPathComponent("Deck 3"))
        _ = try await a.registry.save(PROJProject(id: "deck-one", name: "Deck"))
        _ = try await a.registry.save(PROJProject(id: "deck-two", name: "Deck"))
        _ = try await a.registry.save(PROJProject(id: "site", name: "Client/Site"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        #expect(try await b.project("deck-one")?.folders == [b.path("Deck 2")])
        #expect(try await b.project("deck-two")?.folders == [b.path("Deck 4")])
        #expect(try await b.project("site")?.folders == [b.path("Client-Site")])
        #expect(Self.listing(his.path) == ["notes.txt"], "His folder is never written into")
        #expect((try? String(contentsOf: his.appendingPathComponent("notes.txt"), encoding: .utf8)) == "mine\n")
        #expect((try? Data(contentsOf: b.projectsFolder.appendingPathComponent("Deck 3"))) == Data("x".utf8))
        // Neither project is matched to his folder by name: he points one at it with "Use another folder".
        #expect(try await b.registry.projects().allSatisfy { !$0.folders.contains(PROJProjects.normalize(his.path)) })

        // A rename on A arrives; B's folder keeps its name and place.
        _ = try await a.registry.save(PROJProject(id: "deck-one", name: "Deck Mobile"))
        let rename = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(rename, from: a.mac.device, to: b.adapter)
        #expect(try await b.project("deck-one")?.name == "Deck Mobile")
        #expect(try await b.project("deck-one")?.folders == [b.path("Deck 2")])
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty)
    }

    // MARK: later

    /// A folder he moved or deleted is not made again; the project shows it is not on this Mac, and "Use another
    /// folder" points it at a folder of his (nothing made, moved or deleted; nothing sent).
    @Test func aMissingFolderIsNotMadeAgainAndUseAnotherFolderPointsAtHis() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock, folders: false), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let made = b.path("Deck")
        try FileManager.default.removeItem(atPath: made)

        #expect(await b.folders!.placeMissing().isEmpty)
        _ = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(!FileManager.default.fileExists(atPath: made), "A missing folder is never made again")
        #expect(try await b.folders!.rows() == [.init(projectID: "deck", name: "Deck", folder: made, onThisMac: false, madeByApp: true)])
        #expect(try await b.project("deck") != nil, "The project stays; nothing is removed because a folder is missing")

        // "Use another folder": only a folder that exists; none is made.
        let nowhere = b.home.appendingPathComponent("not-there").path
        await #expect(throws: NativeRPCError.self) { _ = try await b.folders!.use(projectID: "deck", folder: nowhere) }
        #expect(!FileManager.default.fileExists(atPath: nowhere))
        let mine = b.home.appendingPathComponent("Code/deck", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let row = try await b.folders!.use(projectID: "deck", folder: mine.path)
        #expect(row.folder == PROJProjects.normalize(mine.path) && row.onThisMac && !row.madeByApp)
        #expect(try await b.project("deck")?.folders == [PROJProjects.normalize(mine.path)])
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty, "The folder never travels")
        #expect(await b.folders!.placeMissing().isEmpty)
    }

    /// A project removed on another Mac (its Remove / tool = everywhere, Decker 15 Nov) leaves this Mac's list too, but
    /// its folder and his files stay exactly as they were.
    @Test func aProjectRemovedElsewhereKeepsItsFolderAndFiles() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock, folders: false), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.registry.save(PROJProject(id: "notes", name: "Notes"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let folder = b.path("Notes")
        try Data("draft\n".utf8).write(to: URL(fileURLWithPath: folder + "/draft.md"))

        _ = try await a.registry.removeEmpty("notes")
        let removal = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        #expect(removal.count == 1)
        try await CloudLeanFixture.deliver(removal, from: a.mac.device, to: b.adapter)
        #expect(try await b.project("notes") == nil)
        #expect(Self.exists(URL(fileURLWithPath: folder)))
        #expect((try? String(contentsOfFile: folder + "/draft.md", encoding: .utf8)) == "draft\n")
    }

    /// A Mac that cannot write: one calm line, no folder, tried again a few minutes later by itself.
    @Test func aMacThatCannotWriteSaysSoOnceAndTriesAgainLater() async throws {
        let clock = CloudLeanFixture.Clock(), now = Now()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock, folders: false)
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock, now: now)
        let locked = b.home.appendingPathComponent("Terminal Deck", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            Self.cleanup(a, b)
        }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        #expect(try await b.project("deck")?.folders == [], "The project is there; its folder waits")
        let line = try #require(await b.folders!.problem())
        #expect(line == "The folder for Deck could not be made on this Mac (this Mac does not allow writing there). Tried again in a few minutes.")
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty, "Nothing is sent because of it")

        // Not again at once (no flood of tries or lines).
        now.value += 10
        #expect(await b.folders!.placeMissing().isEmpty)
        // The place can be written again; a few minutes later it is made by itself.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        now.value += BackendProjectFolders.retrySeconds
        let placed = await b.folders!.placeMissing()
        #expect(placed.map(\.folder) == [b.path("Deck")])
        #expect(await b.folders!.problem() == nil)
    }

    /// The Terminal Deck folder chosen in Settings: new project folders are made there; ones made before stay.
    @Test func aNewTerminalDeckFolderTakesNewProjectsAndExistingOnesStay() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock, folders: false), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.registry.save(PROJProject(id: "first", name: "First"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        #expect(try await b.project("first")?.folders == [b.path("First")])

        await #expect(throws: NativeRPCError.self) { _ = try await b.folders!.setBase(b.home.appendingPathComponent("missing").path) }
        let other = b.home.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(try await b.folders!.setBase(other.path) == PROJProjects.normalize(other.path))
        #expect(b.folders!.configuredBase == PROJProjects.normalize(other.path))

        _ = try await a.registry.save(PROJProject(id: "second", name: "Second"))
        let more = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(more, from: a.mac.device, to: b.adapter)
        #expect(try await b.project("second")?.folders == [PROJProjects.normalize(other.appendingPathComponent("Projects/Second").path)])
        #expect(try await b.project("first")?.folders == [b.path("First")], "A folder made before stays where it is")
    }

    // MARK: the Code page

    /// A folder the app made for an arrived project shows "Code not on this Mac yet" on the Code page (code comes only
    /// by his own "Get the code"); once a repository is there, the ordinary states follow.
    @Test func theCodePageSaysTheCodeIsNotOnThisMacYet() {
        var row = BackendCodeBackupProject(id: "deck", name: "Deck")
        row.hasFolder = true; row.folderName = "Deck"; row.waitingForCode = true
        #expect(row.state == .codeNotHere)
        #expect(BackendCodeBackupWords.summary(row, now: Date()) == "Code not on this Mac yet")
        #expect(!row.needsAttention)
        row.isRepository = true
        #expect(row.state == .noHome)
        var own = BackendCodeBackupProject(id: "site", name: "Site")
        own.hasFolder = true; own.folderName = "site"
        #expect(own.state == .noHome, "A folder he made himself keeps its ordinary state")
    }

    // MARK: tools

    /// An AI sees where each folder is (read, free) and can use another folder (alter, asked under the usual rules).
    /// No tool makes a folder.
    @Test func theToolsReadFreelyAskBeforeAChangeAndNeverMakeAFolder() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        try await b.registry.cloudLeanWrite(PROJProject(id: "deck", name: "Deck"))
        await b.folders!.placeMissing()
        final class Tiers: @unchecked Sendable {
            private let lock = NSLock(); private var rows: [BackendMCPTier] = []
            func add(_ tier: BackendMCPTier) { lock.withLock { rows.append(tier) } }
            var all: [BackendMCPTier] { lock.withLock { rows } }
        }
        let tiers = Tiers()
        let tools = try BackendProjectFoldersTools.contribution(folders: b.folders!, authorize: { _, _, _, tier in tiers.add(tier) })
        #expect(tools.map { $0.0.id } == BackendProjectFoldersTools.ids)
        #expect(tools.map { $0.0.wireName } == ["project_folders_list", "project_folders_use", "project_folders_set_base"])
        func tool(_ id: String) throws -> BackendNativeMCPServer.Handler { try #require(tools.first { $0.0.id == id }?.1) }
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(BackendProjectFoldersTools.ids), allowedTiers: [.read, .alter], cancellation: .init())

        let listed = try await tool("project_folders.list")(caller, .object([]))
        let row = try #require(listed.structuredContent?["projects"].elements?.first)
        #expect(row["name"].string == "Deck" && row["folder"].string == b.path("Deck") && row["onThisMac"].bool == true && row["madeByApp"].bool == true)
        #expect(listed.structuredContent?["terminalDeckFolder"].string == b.home.appendingPathComponent("Terminal Deck").path)

        let nowhere = b.home.appendingPathComponent("made-by-a-tool").path
        await #expect(throws: NativeRPCError.self) {
            _ = try await tool("project_folders.use")(caller, .object([.init("projectId", .string("deck")), .init("folder", .string(nowhere))]))
        }
        await #expect(throws: NativeRPCError.self) {
            _ = try await tool("project_folders.set_base")(caller, .object([.init("folder", .string(nowhere))]))
        }
        #expect(!FileManager.default.fileExists(atPath: nowhere), "No tool makes a folder")
        let his = b.home.appendingPathComponent("Code/deck", isDirectory: true)
        try FileManager.default.createDirectory(at: his, withIntermediateDirectories: true)
        _ = try await tool("project_folders.use")(caller, .object([.init("projectId", .string("deck")), .init("folder", .string(his.path))]))
        #expect(try await b.project("deck")?.folders == [PROJProjects.normalize(his.path)])
        #expect(tiers.all == [.read, .alter, .alter, .alter], "Reads run freely; every change goes through the approval rules")

        let readOnly = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(BackendProjectFoldersTools.ids), allowedTiers: [.read], cancellation: .init())
        await #expect(throws: NativeRPCError.self) {
            _ = try await tool("project_folders.use")(readOnly, .object([.init("projectId", .string("deck")), .init("folder", .string(his.path))]))
        }
    }

    // MARK: review 14 Nov (PROJECT-FOLDERS-2)

    /// One project whose folder cannot be made (here: every plain name for it is taken) never holds up the others; it
    /// waits and is tried again later, not 99 folder creates on every pass.
    @Test func oneProjectThatCannotGetAFolderDoesNotBlockTheOthers() async throws {
        let clock = CloudLeanFixture.Clock(), now = Now()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock, now: now)
        defer { Self.cleanup(b) }
        try FileManager.default.createDirectory(at: b.projectsFolder, withIntermediateDirectories: true)
        for name in BackendProjectFolders.candidates("Busy") {
            try FileManager.default.createDirectory(at: b.projectsFolder.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try await b.registry.cloudLeanWrite(PROJProject(id: "busy", name: "Busy"))
        try await b.registry.cloudLeanWrite(PROJProject(id: "zed", name: "Zed"))
        // 60 emoji = 240 bytes: inside what any project list holds (256), over a folder name's 200, so it is cut.
        // (A name over 256 bytes cannot exist on any Mac, so it cannot arrive; an arriving name that is not one plain
        // line arrives under its plain form: CloudLeanProjectsTests.)
        try await b.registry.cloudLeanWrite(PROJProject(id: "rocket", name: String(repeating: "🚀", count: 60)))
        let placed = await b.folders!.placeMissing()
        #expect(Set(placed.map(\.projectID)) == ["zed", "rocket"], "The projects after the one that could not get a folder still get theirs")
        #expect(try await b.project("zed")?.folders == [b.path("Zed")])
        #expect(try await b.project("busy")?.folders == [])
        #expect(await b.folders!.problem()?.contains("Busy") == true)
        let before = Self.listing(b.projectsFolder.path).count
        now.value += 10
        #expect(await b.folders!.placeMissing().isEmpty, "It waits; no new tries at once")
        #expect(Self.listing(b.projectsFolder.path).count == before)
    }

    /// A link at `Projects/Deck` (to his own folder) is never followed or written into; "Deck" and "deck" are two folders.
    @Test func aLinkIsNeverFollowedAndNamesDifferingOnlyInCaseGetTwoFolders() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        let his = b.home.appendingPathComponent("Code/deck", isDirectory: true)
        try FileManager.default.createDirectory(at: his, withIntermediateDirectories: true)
        try Data("mine\n".utf8).write(to: his.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: b.projectsFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: b.projectsFolder.appendingPathComponent("Deck"), withDestinationURL: his)
        try await b.registry.cloudLeanWrite(PROJProject(id: "deck-upper", name: "Deck"))
        try await b.registry.cloudLeanWrite(PROJProject(id: "deck-lower", name: "deck"))
        await b.folders!.placeMissing()
        let upper = try #require(try await b.project("deck-upper")?.folders.first)
        let lower = try #require(try await b.project("deck-lower")?.folders.first)
        #expect(upper != lower && upper.lowercased() != lower.lowercased(), "Two projects, two folders")
        #expect(upper != b.path("Deck") && lower != b.path("Deck"), "The link is never taken")
        #expect(Self.listing(his.path) == ["notes.txt"], "His folder behind the link is untouched")
    }

    /// "Use another folder" and the Terminal Deck folder refuse, with one plain line, folders that are not his own:
    /// the home folder and above, ~/Library, hidden home folders, system places, the app's data, another project's
    /// folder, and a link that points into any of them.
    @Test func foldersThatAreNotHisAreRefusedEvenThroughALink() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        try await b.registry.cloudLeanWrite(PROJProject(id: "deck", name: "Deck"))
        try await b.registry.cloudLeanWrite(PROJProject(id: "site", name: "Site"))
        await b.folders!.placeMissing()
        let library = b.home.appendingPathComponent("Library/Application Support/thing", isDirectory: true)
        let ssh = b.home.appendingPathComponent(".ssh", isDirectory: true)
        let data = b.mac.root.appendingPathComponent("data", isDirectory: true)
        for folder in [library, ssh, data] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let link = b.home.appendingPathComponent("Work")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library)
        let refused = [b.home.path, b.home.deletingLastPathComponent().path, "/", "/System", "/usr", "/Applications", "/private/tmp",
                       library.path, ssh.path, data.path, link.path, try #require(try await b.project("site")?.folders.first)]
        for folder in refused {
            await #expect(throws: NativeRPCError.self, "use: \(folder)") { _ = try await b.folders!.use(projectID: "deck", folder: folder) }
        }
        for folder in refused.dropLast() {
            await #expect(throws: NativeRPCError.self, "base: \(folder)") { _ = try await b.folders!.setBase(folder) }
        }
        #expect(try await b.project("deck")?.folders == [b.path("Deck")], "Nothing changed")
        #expect(b.folders!.configuredBase == nil)
        // The registry itself never lets two projects share a folder.
        await #expect(throws: NativeRPCError.self) { _ = try await b.registry.useFolder(projectID: "deck", folder: b.path("Site")) }
        // A folder of his own is fine, and it is the one shown (the only one).
        let mine = b.home.appendingPathComponent("Code/deck", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        _ = try await b.folders!.use(projectID: "deck", folder: mine.path)
        #expect(try await b.project("deck")?.folders == [PROJProjects.normalize(mine.path)])
        #expect(BackendProjectFolders.shortPath("/Users/someone/Library/Application Support/terminaldeck", home: "/Users/someone")
                == "~/Library/Application Support/terminaldeck")
    }

    /// Choosing `…/Terminal Deck/Projects` is taken as the Projects folder itself; a chosen Terminal Deck folder whose
    /// drive is gone gives one line, makes nothing, and new sessions fall back to the default place.
    @Test func aProjectsFolderChosenAsTheBaseAndADriveThatIsGone() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        try FileManager.default.createDirectory(at: b.projectsFolder, withIntermediateDirectories: true)
        #expect(try await b.folders!.setBase(b.projectsFolder.path) == b.home.appendingPathComponent("Terminal Deck").path)
        #expect(b.folders!.configuredBase == nil, "That is the default place")

        let drive = b.home.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        _ = try await b.folders!.setBase(drive.path)
        try FileManager.default.removeItem(at: drive)
        #expect(b.folders!.configuredBase == nil, "New sessions start in ~/Terminal Deck/Independent meanwhile")
        try await b.registry.cloudLeanWrite(PROJProject(id: "deck", name: "Deck"))
        #expect(await b.folders!.placeMissing().isEmpty)
        #expect(!Self.exists(drive), "A Terminal Deck folder that is not there is never made")
        #expect(await b.folders!.problem() == "Your Terminal Deck folder is not on this Mac any more. Choose it again in Settings › General.")
    }

    /// The project list is reset (or rebuilt): the project comes back without a folder, and is pointed at the folder
    /// made for it before (still there) instead of staying hidden or getting a twin.
    @Test func aResetProjectListGetsTheSameFolderBack() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        try await b.registry.cloudLeanWrite(PROJProject(id: "deck", name: "Deck"))
        await b.folders!.placeMissing()
        let fresh = BackendPROJRegistry(fileURL: b.mac.root.appendingPathComponent("reset.registry.json"))
        try await fresh.cloudLeanWrite(PROJProject(id: "deck", name: "Deck"))
        let again = BackendProjectFolders(file: b.mac.root.appendingPathComponent("data/" + BackendProjectFolders.fileName), registry: fresh, home: b.home.path)
        let placed = await again.placeMissing()
        #expect(placed.map(\.folder) == [b.path("Deck")])
        #expect(Self.listing(b.projectsFolder.path) == ["Deck"], "No twin folder")
    }

    /// Code page: "Code not on this Mac yet" only while the folder holds nothing but what the Cloud put there.
    @Test func codeNotHereIsJudgedByWhatIsInTheFolder() throws {
        let root = try CloudLeanFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(BackendProjectFolders.holdsOnlyCloudFiles(root.path))
        try Data("rules\n".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/commands"), withIntermediateDirectories: true)
        #expect(BackendProjectFolders.holdsOnlyCloudFiles(root.path))
        try Data("print(1)\n".utf8).write(to: root.appendingPathComponent("main.swift"))
        #expect(!BackendProjectFolders.holdsOnlyCloudFiles(root.path), "Work written there is his work, not 'code not here yet'")
    }

    /// "Use another folder" on a checkout that has its own CLAUDE.md: the newer one from the Cloud is used, his is kept
    /// (30 days) and listed, as the one rule says.
    @Test func useAnotherFolderOnACheckoutWithItsOwnInstructionFile() async throws {
        let f = try CloudBootFilesFixture(); defer { f.close() }
        let t = CloudBootFilesFixture.past
        try f.write("b/home/Code/deck/CLAUDE.md", "his own\n", at: t)
        try f.write("a/app/CLAUDE.md", "from the cloud\n", at: t + 5_000)
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p-app", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [])
        try await CloudBootFilesFixture.apply(b, try await CloudBootFilesFixture.local(a).operations, device: f.deviceA)

        let registry = BackendPROJRegistry(fileURL: f.url("b/data/projects.registry.json"))
        try await registry.cloudLeanWrite(PROJProject(id: "p-app", name: "App"))
        let folders = BackendProjectFolders(file: f.url("b/data/" + BackendProjectFolders.fileName), registry: registry, home: f.url("b/home").path)
        await folders.placeMissing()
        let row = try await folders.use(projectID: "p-app", folder: f.url("b/home/Code/deck").path)
        let folder = try #require(row.folder)
        try await b.setPlaces([BackendCloudBootFilesPlace(kind: .project, identity: "p-app", root: URL(fileURLWithPath: folder, isDirectory: true), chosen: true)])
        #expect(f.text("b/home/Code/deck/CLAUDE.md") == "from the cloud\n")
        let hash = BackendCloudBrainMemoryHash.bytes(Data("his own\n".utf8))
        let kept = try await b.keptVersions(place: .project, identity: "p-app", relative: "CLAUDE.md")
        #expect(kept.contains { $0.hash == hash }, "His own file is kept")
        #expect(try await b.changedFromOtherDevices().contains { $0.identity == "p-app" }, "and listed")
    }

    // MARK: PROJECT-FOLDERS-3

    /// The folder judged is the folder saved: a link accepted today and re-pointed afterwards moves nothing. His cloud
    /// folders inside ~/Library (iCloud Drive, Dropbox and the like) are allowed; the two places themselves and
    /// /Volumes are not.
    @Test func theFolderSavedIsTheOneJudgedAndHisCloudFoldersAreAllowed() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        try await b.registry.cloudLeanWrite(PROJProject(id: "deck", name: "Deck"))
        await b.folders!.placeMissing()
        let fm = FileManager.default
        let target = b.home.appendingPathComponent("Code/deck", isDirectory: true), secret = b.home.appendingPathComponent("Library/Secret", isDirectory: true)
        for folder in [target, secret] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let link = b.home.appendingPathComponent("Shortcut")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let row = try await b.folders!.use(projectID: "deck", folder: link.path)
        let real = BackendProjectFolders.resolved(target.path)
        #expect(row.folder == real)
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(try await b.project("deck")?.folders == [real], "Re-pointing the link afterwards changes nothing")

        let baseTarget = b.home.appendingPathComponent("Bases/TD", isDirectory: true)
        try fm.createDirectory(at: baseTarget, withIntermediateDirectories: true)
        let baseLink = b.home.appendingPathComponent("BaseLink")
        try fm.createSymbolicLink(at: baseLink, withDestinationURL: baseTarget)
        #expect(try await b.folders!.setBase(baseLink.path) == BackendProjectFolders.resolved(baseTarget.path))
        try fm.removeItem(at: baseLink)
        try fm.createSymbolicLink(at: baseLink, withDestinationURL: secret)
        #expect(b.folders!.configuredBase == BackendProjectFolders.resolved(baseTarget.path))

        let icloud = b.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Work", isDirectory: true)
        let dropbox = b.home.appendingPathComponent("Library/CloudStorage/Dropbox", isDirectory: true)
        for folder in [icloud, dropbox] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        _ = try await b.folders!.use(projectID: "deck", folder: icloud.path)
        #expect(try await b.project("deck")?.folders == [BackendProjectFolders.resolved(icloud.path)])
        _ = try await b.folders!.setBase(dropbox.path)
        #expect(b.folders!.refusal(b.home.appendingPathComponent("Library/Mobile Documents").path) != nil)
        #expect(b.folders!.refusal(b.home.appendingPathComponent("Library/CloudStorage").path) != nil)
        #expect(BackendProjectFolders.refusal("/Volumes") != nil)
        #expect(BackendProjectFolders.refusal("/Volumes/Drive/Work") == nil, "A drive's own folders stay allowed")
    }

    /// The older project_registry_save tool goes through the same door: a folder that is not his is refused before
    /// anyone is asked, and an allowed link is saved resolved.
    @Test func theProjectSaveToolUsesTheSameRefusal() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock, folders: false)
        defer { Self.cleanup(b) }
        final class Asked: @unchecked Sendable { private let lock = NSLock(); private var n = 0
            func add() { lock.withLock { n += 1 } }; var count: Int { lock.withLock { n } } }
        let asked = Asked()
        let tools = try BackendPROJMCP.contribution(registry: b.registry, authorize: { _, _, _, _ in asked.add() })
        let save = try #require(tools.first { $0.0.id == "project_registry.save" }?.1)
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["project_registry.save"], allowedTiers: [.read, .alter], cancellation: .init())
        func args(_ folder: String) -> NativeRPCValue {
            .object([.init("id", .string("deck")), .init("name", .string("Deck")), .init("folders", .array([.string(folder)]))])
        }
        for folder in [NSHomeDirectory() + "/Library/Application Support/terminaldeck", NSHomeDirectory() + "/.ssh", "/System", NSHomeDirectory()] {
            await #expect(throws: NativeRPCError.self, "\(folder)") { _ = try await save(caller, args(folder)) }
        }
        #expect(asked.count == 0, "Refused before anyone is asked")
        #expect(try await b.project("deck") == nil)
        let target = b.home.appendingPathComponent("Code/deck", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = b.home.appendingPathComponent("Shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try await save(caller, args(link.path))
        #expect(try await b.project("deck")?.folders == [BackendProjectFolders.resolved(target.path)])
    }
}

