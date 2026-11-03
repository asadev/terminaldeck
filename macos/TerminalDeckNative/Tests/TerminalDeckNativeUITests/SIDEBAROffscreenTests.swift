#if DEBUG
import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@Suite("SIDEBAR offscreen views", .serialized, .enabled(if: ProcessInfo.processInfo.environment["TD_WIP"] == "SIDEBAR" || ProcessInfo.processInfo.environment["SIDEBAR_RENDER_TESTS"] == "1"))
@MainActor struct SIDEBAROffscreenTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBAR_RENDER_TESTS"] == "1"))
    func lightAndDarkViews() async throws { try await Self.run() }

    @Test func sidebarHandlersKeepTheirExactDestinations() {
        var picked: [String] = [], created: [String] = [], closed: [String] = [], stopped: [String] = []
        let store = SIDEBARProjectStore()
        let panel = SIDEBARPanel(state: .init(groups: [], projects: [], selectedId: nil), selected: nil, store: store,
            choose: { if let id = $0 { picked.append(id) } }, openProject: {}, newSession: { created.append($0) },
            closeProject: { closed.append($0) }, openWindow: { _ in }, rename: { _ in }, close: { _ in }, stop: { stopped.append($0) }) {
                EmptyView()
            } hostFailure: { EmptyView() }
        for id in SIDEBARLayout.main + SIDEBARLayout.machines + SIDEBARLayout.integrations { panel.choose(id) }
        panel.choose("project:/scratch/project")
        panel.newSession("/scratch/project"); panel.closeProject("/scratch/project"); panel.stop("session-fixture")
        #expect(picked == SIDEBARLayout.main + SIDEBARLayout.machines + SIDEBARLayout.integrations + ["project:/scratch/project"])
        #expect(created == ["/scratch/project"]); #expect(closed == ["/scratch/project"]); #expect(stopped == ["session-fixture"])
    }
    @Test func ordinaryHostStatesAreSilentAndOnlyNewFailureShows() {
        #expect(!NativeHOSTNotice.shows(.checking, dismissed: nil))
        #expect(!NativeHOSTNotice.shows(.inApp, dismissed: nil))
        #expect(!NativeHOSTNotice.shows(.running, dismissed: nil))
        #expect(NativeHOSTNotice.shows(.fallback(reason: "new failure"), dismissed: "old failure"))
        #expect(!NativeHOSTNotice.shows(.fallback(reason: "same failure"), dismissed: "same failure"))
    }

    static func run() async throws {
        guard NSHomeDirectory().hasPrefix("/private/tmp/td-glitch-sidebar-"),
              ProcessInfo.processInfo.environment["TD_NATIVE_DATA_DIR"]?.hasPrefix("/private/tmp/td-glitch-sidebar-") == true,
              let destination = ProcessInfo.processInfo.environment["SIDEBAR_OUTPUT"],
              URL(fileURLWithPath: destination).lastPathComponent.hasSuffix(".noindex") else {
            throw SIDEBARRenderError.isolation
        }
        let root = try BackendCompositionRoot(dataRoot: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TD_NATIVE_DATA_DIR"]!),
                                              state: NativeStateStore(), environment: [:], home: NSHomeDirectory())
        // Only fixture routes exist. Every unknown invoke refuses; no native composition,
        // server transport, device runtime, session creation or AI is installed.
        for channel in ["session:list", "machines:list"] {
            try await root.registry.register(channel, ownerID: "sidebar-fixture") { _, _ in .array([]) }
        }
        for channel in ["tasks:local-detail", "tasks:workspace"] {
            try await root.registry.register(channel, ownerID: "sidebar-fixture") { _, _ in
                .object([.init("ok", .bool(false)), .init("message", .string("Scratch render"))])
            }
        }
        let taskPayload = try NativeRPCValue.parseJSON(Data(#"{"agents":[],"connections":[],"tasks":[{"id":"sidebar-render-task","title":"Review the side panel","project":"/scratch/iMatch","local":true,"crmStatus":"In Progress","process":"running","updatedAt":1791590400000}],"goals":[],"trash":[]}"#.utf8))
        try await root.registry.register("tasks:state", ownerID: "sidebar-fixture") { _, _ in taskPayload }
        try await root.registry.register("connected-tasks:state", ownerID: "sidebar-fixture") { _, _ in .object([.init("systems", .array([]))]) }
        try await EngineBridge.shared.configure(native: root)
        let resourceRoot = try #require(ProcessInfo.processInfo.environment["SIDEBAR_TEST_RESOURCES"])
        let assets = try NativeWebAssets.discover(resources: URL(fileURLWithPath: resourceRoot))
        try AppModel.prepareForUITests(configuration: EngineConfiguration(source: .nativeOnly(assets),
            dataRoot: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TD_NATIVE_DATA_DIR"]!)))
        let model = AppModel.shared
        #expect(model.isUITestFixture)
        let commander = SidebarItem(id: "sidebar-command", title: "Commander", kind: .session, status: "working")
        let crm = SidebarItem(id: "sidebar-crm", title: "CRM session", kind: .session, status: "input")
        let idle = SidebarItem(id: "sidebar-idle", title: "Session 1", kind: .session, status: "idle")
        let state = SidebarState(groups: [.init(id: "main", title: nil, items: [.init(id: "servers", title: "Servers", kind: .panel, unread: true)])], projects: [
            .init(id: "/scratch/iMatch", title: "iMatch", expanded: false, sessions: [commander, idle]),
            .init(id: "/scratch/CRM", title: "CRM", expanded: false, sessions: [crm]),
            .init(id: "/scratch/Daftar", title: "Daftar", expanded: false, sessions: [])
        ], selectedId: "project:/scratch/iMatch")
        let store = SIDEBARProjectStore()
        store.projects = [.init(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], colour: "blue"),
                          .init(id: "crm", name: "CRM", folders: ["/scratch/CRM"], colour: "purple"),
                          .init(id: "daftar", name: "Daftar", folders: ["/scratch/Daftar"], colour: "green")]
        store.liveIDs = [commander.id, crm.id, idle.id]
        store.started = [commander.id: 3, crm.id: 2, idle.id: 1]
        model.web.onMessage?(.sidebar(state))
        SIDEBARProjectStore.shared.projects = store.projects
        let tabs = TabsState(tabs: [.init(id: "hoot", title: "Hoot", kind: "hoot"),
                                   .init(id: commander.id, title: "Commander", kind: "session", closable: true),
                                   .init(id: crm.id, title: "CRM session", kind: "session", closable: true)], canNewTerminal: true, canNewBrowser: true)
        var fixtures = sidebarTaskRenderFixtures()
        if let fixture = TasksDecode.state(taskPayload.foundation) {
            TasksStore.shared.adopt(.init(ok: true, message: nil, state: fixture))
        }
        fixtures["tasks-layout"] = AnyView(NativeUIGTasksScreen().frame(width: 1100, height: 720))
        for (key, value) in try SIDEBARSourceRenderFixtures(appModel: model) { fixtures[key] = value }
        for (key, value) in try await sidebarSimRenderFixtures() { fixtures[key] = value }
        fixtures["side-panel"] = AnyView(SIDEBARPanel(state: state, selected: state.selectedId, store: store,
            choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in }, openWindow: { _ in },
            rename: { _ in }, close: { _ in }, stop: { _ in }) {
                HStack {
                    Label("Settings", systemImage: "gearshape"); Spacer(); Image(systemName: "laptopcomputer.and.iphone")
                }.font(.system(size: 13)).foregroundStyle(.secondary)
            } hostFailure: { EmptyView() }.frame(width: 264, height: 820))
        fixtures["tab-strip"] = AnyView(TabStrip(state: tabs, width: 920, anchor: StripAnchorBox(), select: { _ in }, close: { _ in },
            newTerminal: {}, newBrowser: {}, openInNewWindow: { _ in }).frame(width: 920, height: 36))
        fixtures["host-failure"] = AnyView(NativeHOSTNotice(state: .constant(.fallback(reason: "Scratch host unavailable")),
            retry: { .inApp }).padding(12).frame(width: 264, height: 60).background(SIDEBARChrome.frame))
        let out = URL(fileURLWithPath: destination)
        for (scheme, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (key, view) in fixtures.sorted(by: { $0.key < $1.key }) {
                let sizes: [String: CGSize] = ["side-panel": .init(width: 264, height: 820), "tab-strip": .init(width: 920, height: 36),
                    "host-failure": .init(width: 264, height: 60), "Receiver-Sources": .init(width: 920, height: 640),
                    "Command-Palette": .init(width: 1100, height: 720), "tasks-screen": .init(width: 1100, height: 720),
                    "tasks-layout": .init(width: 1100, height: 720), "SimulatorRailRows": .init(width: 296, height: 180),
                    "SimulatorInspectorOutline": .init(width: 520, height: 620), "SimulatorInspectorChecks": .init(width: 520, height: 620),
                    "SimulatorInspectorElement": .init(width: 520, height: 620), "SessionTitle": .init(width: 640, height: 64)]
                try await render(view, size: sizes[key] ?? .init(width: 900, height: 620), appearance: scheme,
                           output: out.appendingPathComponent("SIDEBAR-\(key)-\(name).png"))
            }
        }
        if let app = NSApp { #expect(!app.isActive); #expect(app.windows.allSatisfy { !$0.isVisible }) }
        print("PASS offscreen light+dark views \(fixtures.count * 2); no windows created or .app launched; scratch routes only")
        try await root.shutdown()
    }
    static func render(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name, output: URL) async throws {
        let hosted = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        hosted.sizingOptions = []
        hosted.appearance = NSAppearance(named: appearance)
        hosted.frame = NSRect(origin: .zero, size: size)
        hosted.setBoundsSize(size)
        hosted.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        hosted.layoutSubtreeIfNeeded()
        var png: Data?
        hosted.appearance?.performAsCurrentDrawingAppearance {
            if let rep = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) {
                hosted.cacheDisplay(in: hosted.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
                #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
            }
        }
        let data = try #require(png)
        try data.write(to: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}
enum SIDEBARRenderError: Error { case bitmap, isolation }

// Append to a scratch render executable importing the product module testably.
// Does not start NativeComposition or the engine. Caller must install a scratch
// invoke graph (or keep EngineBridge unready) before constructing these views.
import AppKit
import SwiftUI
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
func sidebarTaskRenderFixtures() -> [String: AnyView] {
    let task = TaskRow(id: "sidebar-render-task", externalTaskId: "DEMO-107",
        title: "Review the side panel", agent: "Commander", project: "/scratch/iMatch",
        crmStatus: "In Progress", process: .running, updatedAt: 1_791_590_400_000,
        local: true, priority: "High", startDate: "2026-10-10", dueDate: "2026-10-12")
    // Init schedules reads through tasks:local-detail. Caller intercepts all reads
    // with scratch responses; an unready bridge also refuses before invoke.
    let model = TaskDetailModel(row: task, agents: [])
    let people = TaskPeople(primary: nil)
    let subtasks = [SubtaskRow(id: "s1", title: "Check full row hit areas"),
                    SubtaskRow(id: "s2", title: "Compare light and dark frames", done: true)]
    let lists = [Checklist(id: "c1", title: "Review", sortOrder: 0, items: [
        ChecklistItem(id: "i1", title: "Whole row opens the task", done: true, sortOrder: 0, assigneeUserId: nil),
        ChecklistItem(id: "i2", title: "Right-click actions match", done: false, sortOrder: 1, assigneeUserId: nil)])]
    let system = ConnectedTaskSystem(.object([
        .init("id", .string("scratch-system")), .init("name", .string("Connected tasks")),
        .init("changes", .string("off")), .init("doneStatus", .string("Done"))]))!
    let connected = ConnectedTaskRow(id: "connected-demo", title: "Check the running section",
        status: "In Progress", priority: "High", dueDate: "2026-10-12", assigneeName: "Commander")

    func frame<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.system(size: 20, weight: .semibold))
            content()
            Spacer(minLength: 0)
        }.padding(28).frame(width: 900, height: 620, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
    }
    return [
        "task-dates-sections": frame("Review the side panel") {
            TaskDatesField(model: model)
            SubtasksTable(model: model, rows: subtasks, people: people, justAdded: false)
            ChecklistsBlock(model: model, lists: lists, people: people, justAdded: false)
        },
        "task-mirror": frame("Tasks") {
            CrmTasksBodyView(state: TasksState(tasks: [task]), now: 1_791_590_400_000,
                             detailed: true, onCloseSession: { _ in })
        },
        "connected-task-row": frame("Connected tasks") {
            Button {} label: {
                ConnectedTaskRowView(row: connected, system: system, handoff: nil, today: "2026-10-10")
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(SIDEBARRowStyle())
        }
    ]
}

import Foundation
import SwiftUI
import TerminalDeckNativeCore

/// Call only from the hidden scratch renderer. No engine connection or subscriptions.
@MainActor
func SIDEBARSourceRenderFixtures(appModel: AppModel) throws -> [String: AnyView] {
    let receiver = NativeRCVModel(sourceEvents: [], read: { _, _ in
        throw NSError(domain: "SIDEBARRenderFixture", code: 1)
    })
    receiver.loading = false
    receiver.projects = [
        PROJProject(id: "imatch", name: "iMatch", colour: "blue"),
        PROJProject(id: "crm", name: "CRM", colour: "purple"),
        PROJProject(id: "independent", name: "Independent", colour: "graphite")
    ]
    func source(_ id: String, _ name: String, _ preset: String, project: String,
                builtIn: Bool = false, enabled: Bool = true, count: Int = 0) -> RCVSourceView {
        RCVSourceView(source: RCVSource(id: id, name: name, preset: preset,
            origin: builtIn ? .terminalDeck : .relay, auth: RCVAuth(scheme: .token),
            mapping: RCVMapping(), enabled: enabled, createdAt: 0, projectID: project),
            address: builtIn ? nil : "https://receiver.example.invalid/s/" + id,
            active: enabled, hasReplyCredential: false, lastEventAt: nil,
            eventCount: count, rejectedCount: 0)
    }
    receiver.overview = RCVOverview(sources: [
        source("fixture-webhook", "CRM messages", "webhook", project: "crm", count: 12),
        source("fixture-github", "iMatch GitHub", "github", project: "imatch", count: 8),
        source("fixture-alerts", "Monitoring", "webhook", project: "imatch", enabled: false),
        source("terminaldeck.tasks", "Tasks", "terminaldeck", project: "independent", builtIn: true, count: 9),
        source("terminaldeck.sessions", "Sessions", "terminaldeck", project: "independent", builtIn: true, count: 6),
        source("terminaldeck.servers", "Servers", "terminaldeck", project: "independent", builtIn: true, count: 2)
    ], rules: [], events: [], unrouted: 0, held: 0, relayConnected: true,
       relayBase: nil, presets: [])
    let requestData = Data(#"{"mode":"commands","commands":[{"id":"view.tasks","title":"Tasks","group":"Go to","shortcut":"⌘3"},{"id":"view.artifacts","title":"Artifacts","group":"Go to","shortcut":"⌘4"},{"id":"project.open","title":"Open a project…","group":"Projects"},{"id":"view.mcp","title":"MCP servers","group":"Integrations"}]}"#.utf8)
    let request = try JSONDecoder().decode(PaletteRequest.self, from: requestData)
    return [
        "Receiver-Sources": AnyView(NativeRCVSourcesPage(model: receiver).padding(24).frame(width: 920, height: 640, alignment: .topLeading)),
        "Command-Palette": AnyView(NativeCommandPalette(request: request, opening: 1, model: appModel).frame(width: 1100, height: 720))
    ]
}

// Render-only draft: compile as a separate fixture source, never in shipping app.
// Root must first configure EngineBridge with a scratch-only registry returning
// these exact channels. Unknown channels MUST throw, never fall through to native.
// No NativeComposition, model.appear(), physical devices, sessions or AI calls.
import AppKit
import SwiftUI
import TerminalDeckNativeCore

@MainActor
func sidebarSimFixturePayloads() -> [String: Any] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 390, pixelsHigh: 844,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 390, height: 844)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let running: [String: Any] = ["id": "fixture-iphone", "platform": "ios", "kind": "simulator",
                                 "state": "ready", "available": true, "name": "iPhone 17", "runtime": "iOS 26.0"]
    let stopped: [String: Any] = ["id": "fixture-ipad", "platform": "ios", "kind": "simulator",
                                 "state": "shutdown", "available": false, "name": "iPad Pro", "runtime": "iOS 26.0", "canBoot": true]
    let tree: [String: Any] = ["source": "fixture", "root": [
        "ref": "fixture-root", "role": "window", "label": "Project settings",
        "frame": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0], "children": [
            ["ref": "fixture-title", "role": "staticText", "label": "Project settings",
             "frame": ["x": 0.12, "y": 0.2, "width": 0.7, "height": 0.06]],
            ["ref": "fixture-icon", "role": "button",
             "frame": ["x": 0.08, "y": 0.12, "width": 0.04, "height": 0.02]],
            ["ref": "fixture-save", "role": "button", "label": "Save changes",
             "frame": ["x": 0.68, "y": 0.82, "width": 0.22, "height": 0.05]]
        ]
    ]]
    return [
        "devices:list": ["available": true, "devices": [running, stopped]],
        "devices:open": ["id": "fixture-iphone", "name": "iPhone 17", "platform": "ios", "kind": "simulator",
                         "pointWidth": 390, "pointHeight": 844, "buttons": ["home", "lock"], "canRotate": true],
        "devices:watch": ["ok": true],
        "devices:freeze": ["image": "data:image/png;base64," + png.base64EncodedString(), "width": 390, "height": 844,
                           "tree": tree, "where": ["place": "Simulator", "name": "iPhone 17", "deviceId": "fixture-iphone"]],
        "session:list": [],
        "machines:list": []
    ]
}

enum SIDEBARSimFixtureError: Error { case unavailableChannel(String), readingTimedOut }

@MainActor
func sidebarSimRenderFixtures() async throws -> [String: AnyView] {
    let payloads = sidebarSimFixturePayloads()
    func model(_ section: NativeSimulatorModel.InspectorSection) async throws -> NativeSimulatorModel {
        let model = NativeSimulatorModel()
        // Existing scoped hook prevents persisted last-device defaults and all
        // device requests are served in memory even if a render invokes cleanup.
        model.scopedDeviceInvoke = { channel, _ in
            guard let payload = payloads[channel] else { throw SIDEBARSimFixtureError.unavailableChannel(channel) }
            return payload
        }
        await model.open("fixture-iphone")
        model.toggleInspect()
        for _ in 0..<200 {
            if model.latest != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.latest != nil else { throw SIDEBARSimFixtureError.readingTimedOut }
        model.focus("fixture-save", reveal: true)
        model.toggleMark("fixture-save")
        model.note = "Give the save control more room."
        model.section = section
        return model
    }
    let outline = try await model(.outline)
    let checks = try await model(.checks)
    let element = try await model(.element)
    let running = DeviceEntry(id: "fixture-iphone", name: "iPhone 17", runtime: "iOS 26.0", canShutDown: true)
    let stopped = DeviceEntry(id: "fixture-ipad", state: "shutdown", available: false,
                              name: "iPad Pro", runtime: "iOS 26.0", canBoot: true)
    return [
        "SimulatorRailRows": AnyView(VStack(spacing: 4) {
            NativeUIGSimulatorRailRow(entry: running, selected: true, working: "", openAction: {}, action: {})
            NativeUIGSimulatorRailRow(entry: stopped, selected: false, working: "", openAction: {}, action: {})
        }.frame(width: 264).padding(16)),
        "SimulatorInspectorOutline": AnyView(InspectPanel(model: outline).frame(width: 520, height: 620)),
        "SimulatorInspectorChecks": AnyView(InspectPanel(model: checks).frame(width: 520, height: 620)),
        "SimulatorInspectorElement": AnyView(InspectPanel(model: element).frame(width: 520, height: 620)),
        "SessionTitle": AnyView(HStack {
            NativeSessionTitle(title: "Review simulator layout", rename: { _ in }, pane: true)
            Spacer(minLength: 0)
        }.padding(16).frame(width: 640, height: 64))
    ]
}
// Coverage limit: SessionTitle is the actual changed title component. Full
// NativeSessionHeader is excluded because NativeTerminalSession starts settings.
// Render current rail rows directly: whole NativeUIGSimulatorScreen's lifecycle
// calls back/refresh and is outside this draft's changed-screen coverage.

#endif
