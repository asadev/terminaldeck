import AppKit
import SwiftUI
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// The main Tasks list drawn off screen with scratch tasks (13 Oct), for a side-by-side look.
/// Run only through one-build.sh with TASKS_RENDER_TESTS=1 and TASKS_RENDER_OUTPUT=<folder>.noindex.
/// No app is launched, no window is shown, no engine call is made: the store is never started and
/// every task here is made up in memory.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TASKS_RENDER_TESTS"] == "1"), .serialized)
@MainActor
struct TASKSAllListRenderTests {
    @Test func renderTheMainListWithScratchTasks() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        try #require(!application.isActive)
        let folder = try #require(ProcessInfo.processInfo.environment["TASKS_RENDER_OUTPUT"])
        let output = URL(fileURLWithPath: folder).standardizedFileURL
        try #require(output.lastPathComponent.hasSuffix(".noindex"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let suite = "tasks21-render-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = TASKSRenderFixture()
        var rendered = 0
        func save(_ name: String, scope: String?, size: CGSize, dark: Bool, _ adjust: (MyWorkModel) -> Void = { _ in }) async throws {
            defaults.removePersistentDomain(forName: suite)
            let projects = TKTasksProjectScope.renderFixture(projects: fixture.projects, selectedProjectID: scope)
            let model = MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: [])
            model.view = TasksViewState()
            adjust(model)
            let view = NativeUIGTasksWorkView(model: model, state: projects.scoped(fixture.state), now: fixture.now, projects: projects)
                .environment(\.openTaskCreate, TaskCreateOpener { _ in })
                .padding(24)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(.background)
            try await TASKSHiddenRender.render(view, size: size, dark: dark,
                to: output.appendingPathComponent("TASKS-\(name)-\(dark ? "dark" : "light").png"))
            rendered += 1
        }
        for dark in [false, true] {
            try await save("all-projects", scope: nil, size: .init(width: 1280, height: 860), dark: dark)
            try await save("one-project", scope: "td", size: .init(width: 1280, height: 860), dark: dark) {
                $0.view.subtasks = .expanded
            }
            try await save("narrow", scope: "td", size: .init(width: 860, height: 700), dark: dark)
            try await save("selected", scope: "td", size: .init(width: 1280, height: 600), dark: dark) {
                $0.selected = ["td-push", "td-release"]
            }
            try await save("saved-view", scope: "td", size: .init(width: 1280, height: 760), dark: dark) {
                $0.view.groupBy = .priority
                $0.view.sort = .dueDate
                $0.view.columns.reorder(["due", "priority", "assignee"])
                $0.view.columns.resize("due", to: 140)
                $0.saveView(named: "Release week")
            }
            try await save("columns", scope: "td", size: .init(width: 1280, height: 760), dark: dark) {
                $0.view.groupBy = .none
                $0.view.columns.reorder(["priority", "due", "status", "assignee"])
                $0.view.columns.resize("priority", to: 140)
            }
            try await save("by-assignee", scope: "td", size: .init(width: 1280, height: 760), dark: dark) {
                $0.view.groupBy = .assignee
                $0.view.showClosed = true
            }
        }
        #expect(rendered == 14)
        #expect(application.windows.allSatisfy { !$0.isVisible })
        print("TASKS: \(rendered) list frames in \(output.path); no app launched, no window shown, scratch tasks only")
    }
}

/// Scratch work for the list: real Terminal Deck items of 13 Oct, two projects, every status,
/// priorities, due dates around "today", tags, Hoot and an agent at work, a parent with two children.
@MainActor
struct TASKSRenderFixture {
    let projects = [PROJProject(id: "td", name: "Terminal Deck", folders: ["/scratch/Terminal Deck"]),
                    PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"])]
    let now: Double
    let state: TasksState

    init() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 13; parts.hour = 10
        now = (Calendar.current.date(from: parts) ?? Date()).timeIntervalSince1970 * 1000
        let td = "/scratch/Terminal Deck", im = "/scratch/iMatch"
        func task(_ id: String, _ title: String, _ status: String, project: String = td, assignee: String = "me",
                  priority: String? = nil, due: String? = nil, tags: [String] = [], details: String = "",
                  process: ProcessState = .queued, parent: String? = nil, created: Double = 0) -> TaskRow {
            TaskRow(id: id, title: title, project: project, crmStatus: status, process: process, local: true,
                    assignee: assignee, instructions: details, priority: priority, dueDate: due, labels: tags,
                    createdAt: created, parentTaskId: parent)
        }
        let tasks = [
            task("td-install", "Install 19 into the real app", "In Progress", priority: "Critical", due: "2026-10-13",
                 tags: ["release"], details: "Freeze, build, old-host proof, swap, checks."),
            task("td-install-proof", "Old-host proof", "Done", parent: "td-install", created: 1),
            task("td-install-swap", "Swap and checks", "In Progress", parent: "td-install", created: 2),
            task("td-switch", "Switch a session to another AI with the conversation carried over", "Working on it",
                 assignee: "commander", priority: "High", due: "2026-10-16", tags: ["sessions", "accounts"], process: .running),
            task("td-skills", "Skill names clash with built-in commands", "Stuck", priority: "High", due: "2026-10-12",
                 tags: ["accounts"]),
            task("td-buttons", "Move native buttons off the hidden web page", "To-Do", assignee: "hoot", priority: "High",
                 due: "2026-10-17", tags: ["sessions"], details: "Split view, servers, files, main navigation."),
            task("td-phone", "Phone panel: show running emulators and simulators", "To-Do", assignee: "none",
                 priority: "Medium", due: "2026-10-15", tags: ["devices"]),
            task("td-dot", "Dot memory round 2", "To-Do", assignee: "none", priority: "Low", due: "2026-10-20", tags: ["memory"]),
            task("td-release", "Public release 0.21 on \u{201C}push live\u{201D}", "To-Do", priority: "High", due: "2026-10-24",
                 tags: ["release"]),
            task("td-push", "Push lane/native-full to GitHub (289 commits ahead)", "To-Do", priority: "Critical", due: "2026-10-11",
                 tags: ["release"]),
            task("td-memory", "Memory accuracy check after a week of use", "To-Do", priority: "Medium", due: "2026-10-18",
                 tags: ["memory"]),
            task("td-store", "Re-sign the Store list and refresh the website", "To-Do", assignee: "none"),
            task("td-signin", "Asad's five sign-in tests", "Stuck", priority: "Critical", due: "2026-10-10", tags: ["accounts"]),
            task("td-rename", "Session rename goes through the native engine", "Done", priority: "Medium", tags: ["sessions"]),
            task("im-lead", "Commander as the iMatch lead", "In Progress", project: im, assignee: "commander",
                 priority: "Medium", due: "2026-10-14", process: .queued),
            task("im-emulators", "Keep emulator-5554 signed in for the 2.0.0 build", "To-Do", project: im, assignee: "none",
                 priority: "Low"),
        ]
        state = TasksState(agents: [AgentProfile(id: "commander", name: "Commander")], tasks: tasks)
    }
}

/// Draws a view into a PNG without a window (the same way the other render suites do).
@MainActor
enum TASKSHiddenRender {
    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) async throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosted = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosted.sizingOptions = []
        hosted.appearance = appearance
        hosted.frame = NSRect(origin: .zero, size: size)
        hosted.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        hosted.layoutSubtreeIfNeeded()
        var png: Data?
        appearance?.performAsCurrentDrawingAppearance {
            if let rep = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) {
                hosted.cacheDisplay(in: hosted.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }
        }
        try #require(png).write(to: url)
    }
}
