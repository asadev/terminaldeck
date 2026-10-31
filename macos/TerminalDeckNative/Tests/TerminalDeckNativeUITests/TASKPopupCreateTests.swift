import AppKit
import Observation
import SwiftUI
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Asad, 12 Oct, with ClickUp's "Task" dialog: "when we create a task, we should have this kind of pop-up
/// instead of right there, a small drop-down ... the shape of creating a task should be a pop-up". Every place
/// that makes a task opens ONE centred card with only the fields the app already had; and the task thread's
/// comment box has one + (what was behind the separate ⋯ moved into it, once each).
@Suite("TASK create pop-up", .serialized)
@MainActor
struct TASKPopupCreateTests {
    private static let statuses = ["To-Do", "Working on it", "In Progress", "Stuck", "Done"]

    @Test func eachPlaceStartsTheCardWithWhatItsOldFormHad() throws {
        // The Tasks page's New task: nobody has it yet, the page's project, the first status.
        let page = TaskCreateEntry.newTaskButton.preset
        let pageDraft = page.draft(statuses: Self.statuses, scopeProject: "/scratch/iMatch")
        #expect(pageDraft.assignee == "none")
        #expect(pageDraft.status == "To-Do")
        #expect(pageDraft.project == "/scratch/iMatch")
        #expect(page.carriedChips(today: "2026-10-12").isEmpty)

        // "Add task" under a group: yours, with every value of the group, the form's own fields winning.
        let defaults = GroupDefaults(status: "Stuck", priority: .some("High"), dueDate: .some("2026-10-13"),
                                     board: .some("Ops"), project: "/scratch/CRM", projectID: "crm")
        let group = TaskCreateEntry.addTaskRow(defaults).preset
        var groupDraft = group.draft(statuses: Self.statuses, scopeProject: "/scratch/iMatch")
        #expect(groupDraft.assignee == "me")
        #expect(groupDraft.status == "Stuck")
        #expect(groupDraft.project == "/scratch/CRM")
        groupDraft.title = "  Call the client  "
        let sent = try group.input(groupDraft, agents: []).get()
        #expect(sent["title"] as? String == "Call the client")
        #expect(sent["assignee"] as? String == "me")
        #expect(sent["status"] as? String == "Stuck")
        #expect(sent["project"] as? String == "/scratch/CRM")
        #expect(sent["priority"] as? String == "High")
        #expect(sent["dueDate"] as? String == "2026-10-13")
        #expect(sent["board"] as? String == "Ops")
        #expect(sent["projectId"] as? String == "crm")
        #expect(group.carriedChips(today: "2026-10-12").map(\.text) == ["Tomorrow", "High", "Ops"])
        groupDraft.status = "To-Do"
        #expect(try group.input(groupDraft, agents: []).get()["status"] as? String == "To-Do", "a status changed in the card wins")

        // A group of tasks with no priority sends no priority (as the old row did), and shows no chip for it.
        let plain = TaskCreateEntry.addTaskRow(GroupDefaults(priority: .some(nil))).preset
        var plainDraft = plain.draft(statuses: Self.statuses, scopeProject: "")
        plainDraft.title = "Tidy up"
        #expect(try plain.input(plainDraft, agents: []).get()["priority"] is NSNull)
        #expect(plain.carriedChips(today: "2026-10-12").isEmpty)

        // "Add task" under a board column: that column's status, yours.
        let column = TaskCreateEntry.addTaskRow(GroupDefaults(status: "In Progress")).preset
        #expect(column.assignee == "me")
        #expect(column.draft(statuses: Self.statuses, scopeProject: "").status == "In Progress")

        // "+ Add" on a calendar day: due that day, yours.
        let day = TaskCreateEntry.calendarDay("2026-10-14").preset
        var dayDraft = day.draft(statuses: Self.statuses, scopeProject: "")
        #expect(dayDraft.assignee == "me")
        dayDraft.title = "Pay rent"
        #expect(try day.input(dayDraft, agents: []).get()["dueDate"] as? String == "2026-10-14")
        #expect(day.carriedChips(today: "2026-10-13").map(\.text) == ["Tomorrow"])

        // An agent's "Assign task": that agent, by name even before the task list has loaded, in its folder.
        let agent = TaskCreateEntry.agent(id: "builder", name: "Builder", project: "/scratch/iMatch").preset
        #expect(agent.assignee == "builder")
        #expect(agent.assigneeName == "Builder")
        #expect(agent.draft(statuses: Self.statuses, scopeProject: "/elsewhere").project == "/scratch/iMatch")
        // An agent with no folder: said in the card, never sent.
        var lost = TaskCreateEntry.agent(id: "builder", name: "Builder", project: "").preset.draft(statuses: Self.statuses, scopeProject: "")
        lost.title = "Fix it"
        guard case .failure(let problem) = TaskCreateEntry.agent(id: "builder", name: "Builder", project: "").preset.input(lost, agents: []) else {
            Issue.record("a task for an agent with no folder was sent")
            return
        }
        #expect(problem.message == "Choose the project folder the agent should work in.")
    }

    /// The opener every place reads from the screen opens the one card, centred over it, and only one.
    @Test func everyEntryPointOpensTheOneSharedCard() throws {
        let probe = TASKCreateProbe()
        let host = NSHostingView(rootView: TASKCreateHarness(probe: probe))
        // Never ordered in: nothing is shown.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); Self.spin(0.3)
        let opener = try #require(probe.opener, "the screen gives its places an opener")
        #expect(Self.nameFields(in: host).isEmpty, "no card before anything asks")
        let entries: [TaskCreateEntry] = [.newTaskButton, .addTaskRow(GroupDefaults(status: "Stuck")), .addTaskRow(GroupDefaults(status: "Done")),
                                          .calendarDay("2026-10-14"), .agent(id: "builder", name: "Builder", project: "/scratch/iMatch")]
        for entry in entries {
            opener.open(entry)
            host.layoutSubtreeIfNeeded(); Self.spin(0.3)
            #expect(probe.preset == entry.preset, "\(entry): the card opens with what that place knows")
            let fields = Self.nameFields(in: host)
            #expect(fields.count == 1, "\(entry): exactly one card")
            #expect(fields.first?.stringValue == "", "\(entry): a fresh card each time")
        }
        probe.preset = nil
        host.layoutSubtreeIfNeeded(); Self.spin(0.3)
        #expect(Self.nameFields(in: host).isEmpty, "closing takes the card away")
        withExtendedLifetime(window) {}
    }

    /// No place keeps its own small add field: the only code that makes a task from the screens is the card.
    @Test func noPlaceMakesATaskOutsideTheCard() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        let maker = /(TasksStore\.shared|store)\.create\((input|\[)/
        var makers: [String] = []
        for file in files where file != "NativeTaskCreateSave.swift" {
            if try Self.code(sources.appendingPathComponent(file)).contains(maker) { makers.append(file) }
        }
        #expect(makers.isEmpty, "these still make a task outside the one card: \(makers)")
        let page = try Self.code(sources.appendingPathComponent("NativeUIGTasksScreen.swift"))
        #expect(page.contains("TaskCreateEntry.newTaskButton") && page.contains(".taskCreatePopup("))
        #expect(!page.contains("LocalTaskForm("))
        let work = try Self.code(sources.appendingPathComponent("NativeTasksMyWork.swift"))
        #expect(work.contains(".open(.addTaskRow(") && work.contains(".open(.calendarDay("))
        #expect(try Self.code(sources.appendingPathComponent("AgentMenu.swift")).contains("NativeTaskCreatePopup("))
    }

    /// The task thread's comment box: one + (the separate ⋯ is gone), each former option once, in headed parts.
    @Test func theCommentBoxHasOnePlusWithEveryOptionOnce() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeTaskCommentBox.swift")
        let code = try Self.code(file)
        #expect(!code.contains("\"ellipsis\""), "no separate ⋯ under the comment box")
        #expect(code.contains("addPanel:"), "the box's own + opens the merged panel")
        for label in ["\"Add files\"", "\"Add photos\"", "\"Take a screenshot\"", "\"Emoji\"", "\"Mention someone\"",
                      "\"Assign this comment to someone\"", "\"ADD TO THE COMMENT\"", "\"SEND\""] {
            #expect(code.components(separatedBy: label).count - 1 == 1, "\(label) is in the + once")
        }
    }

    /// 12 Oct, his real app: opening a task held the main thread for seconds (CPU 70-137% for about 3 s in the dev
    /// copy with his 9 tasks and 44 agents). Every assignee menu row asked AGTAgentsStore.agents, a full rebuild of
    /// the agent list, for its picture: 9 rows x 47 choices. The list is now built once per run-loop turn.
    @Test func aTaskListLooksAgentsUpOncePerTurn() async throws {
        let store = AGTAgentsStore.shared, saved = store.fixture
        defer { store.fixture = saved }
        let agents = (0..<44).map { AgentProfile(id: "agent-\($0)", name: "Builder \($0)", role: "backend engineer") }
        store.fixture = TasksState(agents: agents, tasks: (0..<9).map { TaskRow(id: "t\($0)", title: "Task \($0)") })
        let ids = ["hoot"] + agents.map(\.id)
        var oldHits = 0, newHits = 0
        for _ in 0..<9 { for id in ids where store.agents.first(where: { $0.id == id || $0.profileID == id }) != nil { oldHits += 1 } }
        try await Task.sleep(for: .milliseconds(20))
        _ = DeckRowIcon.agentsThisTurn()
        // Changing the inputs mid-turn must not rebuild the snapshot for each picture.
        store.fixture = TasksState()
        for _ in 0..<9 { for id in ids where DeckRowIcon.agentsThisTurn()[id] != nil { newHits += 1 } }
        #expect(newHits == oldHits, "every lookup in this turn reuses the same agent snapshot")
        try await Task.sleep(for: .milliseconds(20))
        #expect(DeckRowIcon.agentsThisTurn()["agent-0"] == nil, "the next turn reads the changed directory")
        try await Task.sleep(for: .milliseconds(20))
    }

    /// SETTINGS-TRUTH rows 43/45: a project's "Task source" was only saved. Its Tasks page now opens on that system;
    /// a system picked on the page still wins, and with none chosen the first one shows as before.
    @Test func aProjectsTaskSourceIsTheSystemItsTasksPageOpensOn() throws {
        func system(_ id: String) throws -> ConnectedTaskSystem {
            try #require(ConnectedTaskSystem(.object([.init("id", .string(id)), .init("name", .string(id.uppercased()))])))
        }
        let systems = [try system("iloop"), try system("clickup")]
        #expect(ConnectedTasksSource.pick(chosen: nil, projectSource: "clickup", systems: systems)?.id == "clickup")
        #expect(ConnectedTasksSource.pick(chosen: "iloop", projectSource: "clickup", systems: systems)?.id == "iloop")
        #expect(ConnectedTasksSource.pick(chosen: nil, projectSource: nil, systems: systems)?.id == "iloop")
        #expect(ConnectedTasksSource.pick(chosen: nil, projectSource: "gone", systems: systems)?.id == "iloop")
        #expect(ConnectedTasksSource.pick(chosen: nil, projectSource: "clickup", systems: []) == nil)
    }

    /// Pictures of the card and of the comment box's + panel, light and dark (offscreen, cacheDisplay only).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_RENDER_OUT"] != nil))
    func drawTheCardAndTheCommentPanel() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TASK_RENDER_OUT"] ?? "")
        let preset = TaskCreateEntry.addTaskRow(GroupDefaults(status: "Stuck", priority: .some("High"), dueDate: .some("2026-10-13"))).preset
        let commands = [SlashCommand(key: "assign-me", group: "TASK ACTIONS", label: "Assign to me", icon: "person", run: {}),
                        SlashCommand(key: "status", group: "TASK ACTIONS", label: "Status", icon: "circle.dashed",
                                     options: [.init(key: "Done", label: "Done", run: {})]),
                        SlashCommand(key: "close", group: "TASK ACTIONS", label: "Close task", icon: "checkmark.circle", run: {})]
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let scheme: ColorScheme = look == .darkAqua ? .dark : .light
            try Self.draw(AnyView(NativeTaskCreatePopup(preset: preset, context: Self.fixtureContext, onClose: {}).frame(width: 660).environment(\.colorScheme, scheme)),
                          look: look, to: out.appendingPathComponent("TASK-create-card-\(name).png"))
            let panel = CommentAddPanel(panel: HootComposerAddPanel(close: {}, mention: {}), commands: commands, team: [], rich: true,
                                        fixtureMode: false, recording: false, canSchedule: true, assignee: .constant(nil),
                                        onFiles: {}, onPhotos: {}, onScreenshot: {}, onRecord: {}, onEmoji: { _ in }, onSchedule: { _ in })
            try Self.draw(AnyView(panel.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)),
                          look: look, to: out.appendingPathComponent("TASK-comment-plus-\(name).png"))
        }
    }

    static func draw(_ view: AnyView, look: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: look)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); spin(0.4)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        withExtendedLifetime(window) {}
    }

    // MARK: Helpers

    /// The card without the app's model: one project, no lead seats, no engine.
    static var fixtureContext: TaskCreateContext {
        TaskCreateContext(scopeProject: { "/scratch/iMatch" }, projects: { [TaskProject(path: "/scratch/iMatch", title: "iMatch")] },
                          withLeadSeats: { $0 }, startStore: {})
    }

    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func nameFields(in view: NSView) -> [NSTextField] {
        let named = (view as? NSTextField).flatMap { field in
            [field.placeholderString, field.placeholderAttributedString?.string].contains("Task name") ? [field] : nil
        }
        return (named ?? []) + view.subviews.flatMap(nameFields)
    }

    /// A source file without its comment lines (a comment naming a call is not the call).
    static func code(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }
}

@MainActor
@Observable
final class TASKCreateProbe {
    var preset: TaskCreatePreset?
    @ObservationIgnored var opener: TaskCreateOpener?
}

/// A screen that hosts the card, and one place inside it that reads the opener (as AddTaskRow does).
private struct TASKCreateHarness: View {
    @Bindable var probe: TASKCreateProbe

    var body: some View {
        TASKOpenerReader(probe: probe)
            .frame(width: 1000, height: 700)
            .taskCreatePopup($probe.preset, context: TASKPopupCreateTests.fixtureContext)
    }
}

private struct TASKOpenerReader: View {
    let probe: TASKCreateProbe
    @Environment(\.openTaskCreate) private var opener

    var body: some View {
        Color.clear.onAppear { probe.opener = opener }
    }
}
