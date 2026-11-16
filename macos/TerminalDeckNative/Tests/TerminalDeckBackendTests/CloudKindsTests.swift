import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane L3 first slice (14 Nov): tasks (I12) and his settings (I21) in the Cloud, on the record rule. Scratch stores
/// only (under ~/Deck Dev/notes/cloud-test-20261112/a2), fixture clocks only: no test waits on real time.
@Suite("Cloud kinds — tasks and settings travel; what is about this Mac stays")
struct CloudKindsTests {
    /// One Mac: its task list, settings file, app state and the two owners, on the lean fixture's bookkeeping.
    struct Side {
        let mac: CloudLeanFixtureMac
        let tasks: BackendTaskStore
        let settings: BackendAppSettingsStore
        let state: NativeStateStore
        let taskOwner: BackendCloudKindsTasks
        let settingsOwner: BackendCloudKindsSettings
        let taskAdapter: CloudBrainRecordAdapter
        let settingsAdapter: CloudBrainRecordAdapter
        let kept: BackendCloudKindsKept
        var adapters: [CloudBrainRecordAdapter] { [taskAdapter, settingsAdapter] }
    }
    final class Time: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        var now: Double { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }
    /// What a listener of the app's events heard.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [(String, NativeRPCValue)] = []
        func add(_ channel: String, _ payload: NativeRPCValue) { lock.withLock { rows.append((channel, payload)) } }
        var all: [(String, NativeRPCValue)] { lock.withLock { rows } }
    }

    static func side(_ device: String, clock: CloudLeanFixture.Clock, projects: CloudLeanFixture.Box<[BackendCloudKindsProject]> = .init([]),
                     fullAccess: Bool = true, time: Time? = nil, heard: Heard? = nil) async throws -> Side {
        let mac = try CloudLeanFixture.mac(device, clock: clock)
        let tasks = BackendTaskStore(persistence: try .init(directory: mac.root.appendingPathComponent("remote"), ownership: .exclusive))
        try await tasks.start()
        let settings = BackendAppSettingsStore(userData: mac.root.appendingPathComponent("data"), writable: true)
        let state = NativeStateStore()
        let kept = try BackendCloudKindsKept(file: mac.root.appendingPathComponent("kept/replaced-values.json"), now: { 1_000 })
        let quiet: Double = time == nil ? 0 : BackendCloudKinds.quiet
        let now: @Sendable () -> Double = { time?.now ?? 0 }
        let taskOwner = BackendCloudKindsTasks(store: tasks, projects: { projects.value }, kept: kept, settle: .init(quiet: quiet, now: now))
        let settingsOwner = BackendCloudKindsSettings(appSettings: settings, state: state,
            display: { app, preferences in
                await BackendCloudKindsSettings.announce(app: app, preferences: preferences, settings: settings, state: state,
                    publish: { channel, payload in heard?.add(channel, payload) })
            }, fullAccess: { fullAccess }, kept: kept,
            settle: .init(quiet: quiet, now: now), records: mac.store, chosenFile: mac.root.appendingPathComponent("settings-chosen.json"))
        return .init(mac: mac, tasks: tasks, settings: settings, state: state, taskOwner: taskOwner, settingsOwner: settingsOwner,
            taskAdapter: try taskOwner.adapter(store: mac.store, account: mac.account, origins: mac.origins),
            settingsAdapter: try settingsOwner.adapter(store: mac.store, account: mac.account, origins: mac.origins), kept: kept)
    }
    static func task(_ id: String, title: String, project: String = "", notes: [NativeRPCValue] = [], local: Bool = true, key: String = "local") -> NativeRPCValue {
        .object([.init("id", .string(key + ":" + id)), .init("keyId", .string(key)), .init("externalTaskId", .string(id)),
            .init("local", .bool(local)), .init("title", .string(title)), .init("crmStatus", .string("To-Do")), .init("project", .string(project)),
            .init("process", .string("queued")), .init("sessionId", .string("session-" + id)),
            .init("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("worker"))])), .init("notes", .array(notes))])
    }
    static func note(_ id: String, at: Double, by: String, text: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("at", .number(at)), .init("by", .string(by)), .init("kind", .string("comment")), .init("text", .string(text))])
    }
    /// Delivers both ways until neither Mac has anything more to send.
    static func settle(_ a: Side, _ aActivation: CloudBrainRecordActivation, _ b: Side, _ bActivation: CloudBrainRecordActivation,
                       first: (a: [CloudOperation], b: [CloudOperation])) async throws {
        var fromA = first.a, fromB = first.b
        for _ in 0..<4 {
            for adapter in b.adapters { try await CloudLeanFixture.deliver(fromA, from: a.mac.device, to: adapter) }
            for adapter in a.adapters { try await CloudLeanFixture.deliver(fromB, from: b.mac.device, to: adapter) }
            fromA = try await CloudLeanFixture.sync(aActivation, on: a.mac)
            fromB = try await CloudLeanFixture.sync(bActivation, on: b.mac)
            if fromA.isEmpty && fromB.isEmpty { return }
        }
        Issue.record("The two Macs never settled")
    }
    static func cleanup(_ sides: Side...) { for side in sides { try? FileManager.default.removeItem(at: side.mac.root) } }

    // MARK: the list

    /// The travels / stays list as a table. Same everywhere (15 Nov): a setting of the settings file, the preferences or a
    /// project travels unless it names something of one device only; a screen's choice travels only when listed.
    @Test func theTravelsAndStaysListIsATableAndOnlyMachineBoundItemsStay() {
        let travels: [(CloudBrainSettings.Source, String)] = [
            (.preference, "theme"), (.app, "appearance.terminalScheme"), (.app, "appearance.terminalScheme.custom.mine"),
            (.app, "appearance.terminalFontSize"), (.app, "appearance.terminalFontFamily"), (.preference, "restoreSessions"),
            (.preference, "newSessionMode"), (.app, "general.confirmCloseWorking"), (.app, "general.copyOnSelect"),
            (.app, "general.autoNameSessions"), (.preference, "notifyOnComplete"), (.app, "notifications.onNeedsInput"),
            (.app, "notifications.soundName"), (.app, "notifications.onlyWhenUnfocused"), (.app, "browser.startUrl"),
            (.app, "copilot.islandLook"), (.app, "copilot.islandQuiet"), (.app, "copilot.islandWidthPreset"), (.app, "copilot.menuBar"),
            (.preference, "defaultProvider"),
            // 15 Nov: everything else about him travels too.
            (.app, "general.whenOpens"), (.app, "browser.persistSession"), (.app, "advanced.debugMode"), (.app, "hoot.effort.claude"),
            (.app, "hoot.provider"), (.app, "something.new"), (.preference, "openTabs"), (.app, "theme"),
            (.choice, "sidebar.pagePins.v1"), (.choice, "sidebar.pinnedTabs.v2"), (.choice, "chat.sessionPanel.open"),
            (.choice, "td.tasks.viewState.v1"), (.choice, "AGFRAME.view"), (.choice, "agt.declaredLead.notNow.p1.lead"),
            (.project, "project-1/githubRepo"), (.project, "project-1/setup.hootLeads"),
            // Lead's decision (15 Nov): permission settings and the routines' limit travel too.
            (.app, "hoot.permission.claude"), (.app, "hoot.interactive"), (.app, "copilot.interactive"),
            (.app, "hoot.policy.runSessions"), (.app, "routines.maxRunsPerHour"),
        ]
        for (source, key) in travels {
            #expect(CloudBrainSettings.rule(source, key) != nil, "\(key) travels")
            #expect(CloudBrainSettings.stayReason(source, key) == nil)
        }
        let stays: [(CloudBrainSettings.Source, String)] = [
            (.app, "IslandShowOn"), (.app, "copilot.islandWidth"), (.app, "copilot.islandHeight"), (.app, "remote.enabled"),
            (.app, "remote.macScreenAllowed"), (.app, "hoot.policy.folders"), (.preference, "accountLimits"), (.preference, "windowBounds"),
            (.app, "appearance.windowBounds"), (.app, "agents.mcpServers"), (.app, "hoot.home"), (.app, "accounts.default"),
            (.app, "features.install.linux"), (.app, "hoot.migratedAt"),
            // Screens' choices about this device only, and any defaults key nobody listed.
            (.choice, "session-start.lastFolder.v1"), (.choice, "openScreenWindows"), (.choice, "settingsWindow.size.v2"),
            (.choice, "paneArrangement.v1"), (.choice, "nativeBrowser.tabs.v1"), (.choice, "AppleLanguages"), (.choice, "NSWindow Frame main"),
            (.project, "project-1/localFolder"), (.project, "/Users/someone/work/notes"),
        ]
        for (source, key) in stays {
            #expect(CloudBrainSettings.rule(source, key) == nil, "\(key) stays")
            #expect(!(CloudBrainSettings.stayReason(source, key) ?? "").isEmpty, "\(key) has a reason")
        }
        #expect(CloudBrainSettings.stays.allSatisfy { !$0.reason.isEmpty })
        #expect(CloudBrainSettings.travels.allSatisfy { !CloudBrainSettings.looksMachineOrSecret($0.key) })
        // Only the first settings travel on every build; everything added on 15 Nov waits for the gate.
        #expect(CloudBrainSettings.rule(.app, "something.new")?.newer == true)
        #expect(CloudBrainSettings.rule(.app, "appearance.terminalFontSize")?.newer == false)
    }

    // MARK: settings

    @Test func aSettingAboutHimTravelsAndOneAboutThisMacStaysAndNothingEchoes() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await Self.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))

        _ = try await a.settings.patch(.object([.init("appearance.terminalFontSize", .number(16)), .init("remote.enabled", .bool(false)),
            .init("IslandShowOn", .string("\"main\"")), .init("hoot.permission.claude", .string("bypass"))]))
        let sent = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        let text = CloudLeanFixture.text(sent)
        #expect(sent.count == 1 && text.contains("appearance.terminalFontSize"))
        #expect(!text.contains("remote.enabled") && !text.contains("IslandShowOn") && !text.contains("hoot.permission"))

        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.settingsAdapter)
        #expect(await b.settings.value("appearance.terminalFontSize") == .number(16))
        #expect(await b.settings.value("remote.enabled") == .missing)
        // Echo guard: what B just applied is never sent back as B's own change.
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty)
        #expect(try await CloudLeanFixture.sync(startedA.activation, on: a.mac).isEmpty)
    }

    @Test func theDefaultAIWaitsUnderAskMeAndAValueThisMacCannotUseIsNotApplied() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock, fullAccess: false)
        defer { Self.cleanup(a, b) }
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await Self.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))
        _ = try await a.state.setPreferences(.object([.init("defaultProvider", .string("codex"))]))
        _ = try await a.settings.patch(.object([.init("notifications.soundName", .string("not-a-sound"))]))
        let sent = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.settingsAdapter)
        #expect(await b.state.getPreferences()["defaultProvider"].string == "claude")
        #expect(await b.settings.value("notifications.soundName") == .missing)
        let waiting = try await b.settingsAdapter.listing().waiting
        #expect(waiting.contains { $0.record == "preference:defaultProvider" && $0.reason == BackendCloudKindsSettings.wideningHeld })
        #expect(waiting.contains { $0.record == "setting:notifications.soundName" && $0.reason == BackendCloudKindsSettings.notUsable })
    }

    /// Cost: a slider dragged for a while sends ONE record, the settled value, once it has been still for 2 s.
    @Test func aFlickeringSettingSendsOneRecord() async throws {
        let clock = CloudLeanFixture.Clock(), time = Time()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock, time: time)
        defer { Self.cleanup(a) }
        _ = try await a.settings.patch(.object([.init("appearance.terminalFontSize", .number(9))]))
        let started = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        var sent: [CloudOperation] = []
        for size in 10...20 {
            time.now += 300
            _ = try await a.settings.patch(.object([.init("appearance.terminalFontSize", .number(Double(size)))]))
            sent += try await CloudLeanFixture.sync(started.activation, on: a.mac)
        }
        #expect(sent.isEmpty, "Nothing is sent while the value keeps moving")
        time.now += 1_000
        sent += try await CloudLeanFixture.sync(started.activation, on: a.mac)
        #expect(sent.isEmpty, "Still within the quiet period")
        time.now += 1_500
        sent += try await CloudLeanFixture.sync(started.activation, on: a.mac)
        time.now += 5_000
        sent += try await CloudLeanFixture.sync(started.activation, on: a.mac)
        #expect(sent.count == 1)
        #expect(sent.first?.payload.raw["fields"]["value"] == .number(20), "The settled value, not one on the way")
    }

    /// First sync on his two Macs (CLOUD-KINDS-2, the owner's decision): tasks are all kept (union, matched only by
    /// their own id). A setting he chose beats a default: a Mac where it still has its default takes his value. Two
    /// values he chose differently both STAY, in either install order, and nothing is listed for it. His next real
    /// change anywhere travels, and the value it replaces is kept for 30 days.
    @Test(arguments: [true, false])
    func firstSyncKeepsEveryTaskAndNeverFlipsAChosenSetting(aFirst: Bool) async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.tasks.put(Self.task("a1", title: "Fix the login page"), now: true)
        _ = try await b.tasks.put(Self.task("b1", title: "Fix the login page"), now: true)  // same title, another task
        _ = try await a.settings.patch(.object([.init("appearance.terminalFontSize", .number(14))]))      // chosen on A
        _ = try await b.settings.patch(.object([.init("appearance.terminalFontSize", .number(18)),        // chosen on B
            .init("general.copyOnSelect", .bool(true))]))                                                 // chosen on B only
        _ = try await b.state.setPreferences(.object([.init("theme", .string("light"))]))                 // A keeps the default
        _ = try await a.state.setPreferences(.object([.init("defaultProvider", .string("codex"))]))       // B keeps the default

        let first = aFirst ? a : b, second = aFirst ? b : a
        let startedFirst = try await CloudLeanFixture.start(first.adapters, on: first.mac)
        let startedSecond = try await CloudLeanFixture.start(second.adapters, on: second.mac)
        // Never-chosen defaults are not sent as first copies.
        #expect(!CloudLeanFixture.text(startedA(aFirst, startedFirst, startedSecond).sent).contains("preference:theme"))
        #expect(!CloudLeanFixture.text(startedB(aFirst, startedFirst, startedSecond).sent).contains("preference:defaultProvider"))
        try await Self.settle(first, startedFirst.activation, second, startedSecond.activation, first: (startedFirst.sent, startedSecond.sent))

        for side in [a, b] {
            let ids = try await side.tasks.all().map { $0.id }.sorted()
            #expect(ids == ["local:a1", "local:b1"], "Both tasks on both Macs; the same title never merges two tasks")
            #expect(await side.settings.value("general.copyOnSelect") == .bool(true), "Chosen on B, default on A: A takes it")
            #expect(await side.state.getPreferences()["theme"].string == "light", "Chosen on B, default on A: A takes it")
            #expect(await side.state.getPreferences()["defaultProvider"].string == "codex", "Chosen on A, default on B: B takes it")
        }
        #expect(await a.settings.value("appearance.terminalFontSize") == .number(14), "Two chosen values: A keeps its own")
        #expect(await b.settings.value("appearance.terminalFontSize") == .number(18), "Two chosen values: B keeps its own")
        #expect(a.kept.entries().isEmpty && b.kept.entries().isEmpty, "Nothing he chose was replaced")
        #expect(try await a.settingsAdapter.listing().waiting.isEmpty, "Nothing is listed")
        #expect(try await b.settingsAdapter.listing().waiting.isEmpty, "Nothing is listed")
        // A task that arrived is inert on the other Mac: stopped, unassigned, no session.
        let arrived = try await a.tasks.byID("local:b1")?.value
        #expect(arrived?["assignee"]["kind"].string == "none" && arrived?["process"].string == "stopped" && arrived?["sessionId"] == .null)

        // Then the one rule: a real change on B travels to A, and A's value is kept for 30 days.
        let startedOfA = aFirst ? startedFirst : startedSecond, startedOfB = aFirst ? startedSecond : startedFirst
        _ = try await b.settings.patch(.object([.init("appearance.terminalFontSize", .number(20))]))
        let change = try await CloudLeanFixture.sync(startedOfB.activation, on: b.mac)
        #expect(change.count == 1)
        try await Self.settle(a, startedOfA.activation, b, startedOfB.activation, first: ([], change))
        #expect(await a.settings.value("appearance.terminalFontSize") == .number(20))
        #expect(await b.settings.value("appearance.terminalFontSize") == .number(20))
        let keptA = a.kept.entries()
        #expect(keptA.count == 1 && keptA.first?.record == "setting:appearance.terminalFontSize" && keptA.first?.value.contains("14") == true)
        #expect(keptA.allSatisfy { $0.keptUntil - $0.replacedAt == 30 * 86_400_000 })
        // And the other way: a real change on A arrives on B.
        _ = try await a.settings.patch(.object([.init("appearance.terminalFontSize", .number(12))]))
        let back = try await CloudLeanFixture.sync(startedOfA.activation, on: a.mac)
        try await Self.settle(a, startedOfA.activation, b, startedOfB.activation, first: (back, []))
        #expect(await b.settings.value("appearance.terminalFontSize") == .number(12))
    }
    private func startedA(_ aFirst: Bool, _ first: (activation: CloudBrainRecordActivation, sent: [CloudOperation]),
                          _ second: (activation: CloudBrainRecordActivation, sent: [CloudOperation])) -> (activation: CloudBrainRecordActivation, sent: [CloudOperation]) {
        aFirst ? first : second
    }
    private func startedB(_ aFirst: Bool, _ first: (activation: CloudBrainRecordActivation, sent: [CloudOperation]),
                          _ second: (activation: CloudBrainRecordActivation, sent: [CloudOperation])) -> (activation: CloudBrainRecordActivation, sent: [CloudOperation]) {
        aFirst ? second : first
    }

    // MARK: tasks

    /// Comments are a list: two Macs adding comments to the same task both keep theirs; a title edit travels.
    @Test func commentsFromTwoMacsAreBothKeptAndTheNewestTitleWins() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.tasks.put(Self.task("t", title: "Draft", notes: [Self.note("n0", at: 1, by: "Asad", text: "first")]), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await Self.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))

        // Offline on both: A comments and renames; B comments.
        let onA = try #require(try await a.tasks.byID("local:t")?.value)
        _ = try await a.tasks.put(onA.setting("title", .string("Final")).setting("notes", .array((onA["notes"].elements ?? []) + [Self.note("na", at: 5, by: "Mac A", text: "from A")])), now: true)
        let onB = try #require(try await b.tasks.byID("local:t")?.value)
        _ = try await b.tasks.put(onB.setting("notes", .array((onB["notes"].elements ?? []) + [Self.note("nb", at: 6, by: "Mac B", text: "from B")])), now: true)
        let fromA = try await CloudLeanFixture.sync(startedA.activation, on: a.mac), fromB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        try await Self.settle(a, startedA.activation, b, startedB.activation, first: (fromA, fromB))

        for side in [a, b] {
            let row = try #require(try await side.tasks.byID("local:t")?.value)
            #expect((row["notes"].elements ?? []).compactMap { $0["id"].string }.sorted() == ["n0", "na", "nb"])
            #expect(row["title"].string == "Final")
        }
        // B kept its own copy of the task, with assignee and session, as it was (this Mac's fields never travel).
        let onBAfter = try #require(try await b.tasks.byID("local:t")?.value)
        #expect(onBAfter["sessionId"] == .null && onBAfter["assignee"]["kind"].string == "none")
    }

    /// Tasks of a connected task system (iLoop) are that system's: never sent, and one arriving is not applied.
    @Test func aConnectedSystemsTaskIsNeverCopied() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.tasks.put(Self.task("crm-7", title: "From iLoop", local: false, key: "iloop-key"), now: true)
        _ = try await a.tasks.put(Self.task("mine", title: "Mine"), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let text = CloudLeanFixture.text(startedA.sent)
        #expect(text.contains("local:mine") && !text.contains("crm-7") && !text.contains("From iLoop"))

        // A record shaped like a connected system's task (another key, or the right id with another key) that reaches
        // B is not applied there: it waits with the plain reason, and nothing is written.
        let shared = BackendCloudKindsTasks.shared(Self.task("crm-7", title: "From iLoop", local: false, key: "iloop-key"), place: "tasks", projects: [])
        let foreign = try await b.taskOwner.cloudPlan(entity: "task:iloop-key:crm-7", cloud: shared)
        #expect(foreign.waiting == BackendCloudKindsTasks.connectedSystem && foreign.store == nil)
        let mine = BackendCloudKindsTasks.shared(Self.task("mine", title: "Mine"), place: "tasks", projects: [])
        let disguised = try await b.taskOwner.cloudPlan(entity: "task:local:mine", cloud: mine.setting("keyId", .string("iloop-key")))
        #expect(disguised.waiting == BackendCloudKindsTasks.connectedSystem)
        #expect(try await b.tasks.byID("iloop-key:crm-7") == nil)
    }

    /// A task whose project is not on the other Mac yet waits quietly, and is placed once the project is there.
    @Test func aTaskWaitsForItsProjectThenArrives() async throws {
        let clock = CloudLeanFixture.Clock()
        let projectsA = CloudLeanFixture.Box([BackendCloudKindsProject(id: "deck", folders: ["/Users/a/deck"])])
        let projectsB = CloudLeanFixture.Box([BackendCloudKindsProject]())
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock, projects: projectsA)
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock, projects: projectsB)
        defer { Self.cleanup(a, b) }
        _ = try await a.tasks.put(Self.task("p", title: "In deck", project: "/Users/a/deck/app"), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        #expect(!CloudLeanFixture.text(startedA.sent).contains("/Users/a"), "A folder path never travels")
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.taskAdapter)
        #expect(try await b.tasks.byID("local:p") == nil)
        #expect(try await b.taskAdapter.listing().waiting.contains { $0.reason == BackendCloudKindsTasks.waitsForProject })

        projectsB.value = [BackendCloudKindsProject(id: "deck", folders: ["/Users/b/code/deck"])]
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty, "Placing it sends nothing back")
        let placed = try #require(try await b.tasks.byID("local:p")?.value)
        #expect(placed["project"].string == "/Users/b/code/deck", "It takes the project's folder on this Mac")
        #expect(try await b.taskAdapter.listing().waiting.isEmpty)
    }

    /// Moving a task to the Trash travels; a larger spending limit and turning approval off never arrive.
    @Test func trashTravelsAndStricterLimitsAreKept() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        _ = try await a.tasks.put(Self.task("x", title: "Budgeted").setting("tokenBudget", .number(1_000)), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await Self.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))
        #expect(try await b.tasks.byID("local:x")?.value["tokenBudget"] == .number(1_000))

        let onA = try #require(try await a.tasks.byID("local:x")?.value)
        _ = try await a.tasks.put(onA.setting("tokenBudget", .number(50_000)), now: true)
        try await a.tasks.moveToTrash("local:x")
        let sent = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.taskAdapter)
        let inTrash = try await b.tasks.inTrash().map(\.id)
        #expect(inTrash == ["local:x"])
        #expect(try await b.tasks.byID("local:x", includeTrash: true)?.value["tokenBudget"] == .number(1_000), "The smaller limit stays")
    }

    // MARK: CLOUD-KINDS-3

    /// A theme and a font size applied from the Cloud reach the screens through the two existing events, with the
    /// same payloads a change made here sends.
    @Test func arrivingSettingsSendTheExistingEvents() async throws {
        let clock = CloudLeanFixture.Clock(), heard = Heard()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock, heard: heard)
        defer { Self.cleanup(a, b) }
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await Self.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))
        _ = try await a.settings.patch(.object([.init("appearance.terminalFontSize", .number(17))]))
        _ = try await a.state.setPreferences(.object([.init("theme", .string("light"))]))
        let sent = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.settingsAdapter)
        let settings = heard.all.filter { $0.0 == "settings:changed" }.last?.1
        let prefs = heard.all.filter { $0.0 == "prefs:changed" }.last?.1
        let storedSettings = await b.settings.get(), savedPreferences = await b.state.getPreferences()
        #expect(settings == storedSettings && settings?["values"]["appearance.terminalFontSize"] == .number(17))
        #expect(prefs == savedPreferences && prefs?["theme"].string == "light")
        #expect(Set(heard.all.map { $0.0 }) == ["settings:changed", "prefs:changed"], "No new event")
    }

    /// Approval: "needs approval" travels and the task can be put under approval there; "no approval" never lifts it.
    @Test func approvalArrivesAndIsNeverLiftedByAnotherMacsCopy() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(a, b) }
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await a.tasks.cloudKindsWrite(Self.task("ok", title: "Needs approval").setting("decisionRequired", .bool(true)), trash: false)
        let sent = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await Self.settle(a, startedA.activation, b, startedB.activation, first: (sent, []))
        let arrived = try #require(try await b.tasks.byID("local:ok")?.value)
        #expect(arrived["decisionRequired"].bool == true)
        #expect(arrived["decisionEligible"].bool == true, "Treated like a newly created task")
        // What the decision service needs to bind and approve it here: required, unassigned, stopped, no session.
        #expect(PCDecisions.requires(arrived) && arrived["assignee"]["kind"].string == "none" && arrived["sessionId"] == .null && arrived["process"].string == "stopped")

        // A's copy now says "no approval needed": B keeps approval on, and says so in plain words.
        let onA = try #require(try await a.tasks.byID("local:ok")?.value)
        try await a.tasks.cloudKindsWrite(onA.setting("decisionRequired", .bool(false)).setting("title", .string("Renamed")), trash: false)
        let lifted = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(lifted, from: a.mac.device, to: b.taskAdapter)
        let onB = try #require(try await b.tasks.byID("local:ok")?.value)
        #expect(onB["decisionRequired"].bool == true && onB["title"].string == "Renamed")
    }

    /// Hostile records handed straight to the receiving Mac: nothing is written.
    @Test func hostileRecordsWriteNothing() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        let before = await b.settings.get()
        for (entity, key, value) in [("setting:remote.enabled", "remote.enabled", NativeRPCValue.bool(true)),
                                     ("setting:appearance.terminalScheme.custom.mcp-dark", "appearance.terminalScheme.custom.mcp-dark", .string("{}"))] {
            let record = NativeRPCValue.object([.init("key", .string(key)), .init("value", value)])
            let plan = try await b.settingsOwner.cloudPlan(entity: entity, cloud: record)
            #expect(plan.store == nil && plan.waiting != nil, "\(key) waits")
            await #expect(throws: (any Error).self) { try await b.settingsOwner.cloudWrite(entity: entity, value: record, expecting: nil) }
        }
        #expect(await b.settings.get() == before)

        // A task B has under approval with a limit; a copy arrives queued, assigned, approval off, a larger limit.
        try await b.tasks.cloudKindsWrite(Self.task("h", title: "Guarded").setting("decisionRequired", .bool(true)).setting("tokenBudget", .number(1_000))
            .setting("process", .string("stopped")).setting("sessionId", .null).setting("assignee", .object([.init("kind", .string("none"))])), trash: false)
        let hostile = Self.task("h", title: "Guarded").setting("decisionRequired", .bool(false)).setting("tokenBudget", .number(90_000))
            .setting("process", .string("queued")).setting("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("worker"))]))
            .setting("place", .string("tasks"))
        let plan = try await b.taskOwner.cloudPlan(entity: "task:local:h", cloud: hostile)
        if let store = plan.store {
            let mine = BackendCloudKindsTasks.shared(try #require(try await b.tasks.byID("local:h")?.value), place: "tasks", projects: [])
            try await b.taskOwner.cloudWrite(entity: "task:local:h", value: store, expecting: mine)
        }
        let row = try #require(try await b.tasks.byID("local:h")?.value)
        #expect(row["decisionRequired"].bool == true && row["tokenBudget"] == .number(1_000))
        #expect(row["process"].string == "stopped" && row["assignee"]["kind"].string == "none" && row["sessionId"] == .null)
    }

    /// Another device can add at most 50 colour schemes here.
    @Test func colourSchemesFromAnotherDeviceAreCapped() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { Self.cleanup(b) }
        var patch: [NativeRPCValue.Field] = []
        for n in 0..<CloudBrainSettings.maximumCustomSchemes { patch.append(.init("appearance.terminalScheme.custom.s\(n)", .string("{}"))) }
        _ = try await b.settings.patch(.object(patch))
        let key = "appearance.terminalScheme.custom.one-more"
        let plan = try await b.settingsOwner.cloudPlan(entity: "setting:" + key, cloud: .object([.init("key", .string(key)), .init("value", .string("{}"))]))
        #expect(plan.store == nil && plan.waiting == BackendCloudKindsSettings.tooManySchemes)
    }
}
