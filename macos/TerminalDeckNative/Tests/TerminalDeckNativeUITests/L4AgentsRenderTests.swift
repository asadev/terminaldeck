import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// L4 offscreen renders of the Agents page through its one frame: All agents, Import,
/// Org chart and At work, light and dark, 1440x900 and 1000x700. Fixture data only:
/// no engine, no AI, no app activation. The host sits in a borderless window that is
/// never ordered on screen, so native tables materialise their rows.
final class L4AgentsRenderTests: XCTestCase {
    private func requireGate() throws {
        guard ProcessInfo.processInfo.environment["L4_RENDER"] == "1" else { throw XCTSkip("L4 renders run on request") }
    }

    @MainActor func testAgentsPageRenders() throws {
        try requireGate()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["L4_RENDER_OUTPUT"] ??
            "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex")
        XCTAssertTrue(output.lastPathComponent.hasSuffix(".noindex"))
        let store = AGTAgentsStore.shared
        let saved = (store.fixture, store.live, store.liveLoaded, store.openProfile, store.layout, NativePROJLabels.shared.projects, AGTTime.fixedNow)
        defer {
            store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2; store.openProfile = saved.3
            store.layout = saved.4; NativePROJLabels.shared.projects = saved.5; AGTTime.fixedNow = saved.6
        }
        NativePROJLabels.shared.projects = PROJProjects.defaults
        let home = NSHomeDirectory()
        let folders = ["imatch": home + "/ClaudeiMatch/.claude/agents", "crm": home + "/ClaudeCRM/.claude/agents"]
        store.fixture = TasksState(agents: ORGRenderTests.fixture.map { profile in
            var row = profile
            if let folder = folders[profile.projectID] { row.sourceDirectory = folder; row.sourceFile = folder + "/" + profile.id + ".md" }
            row.model = "Opus 5.5"
            return row
        })
        store.live = ORGRenderTests.liveFixture
        store.liveLoaded = true; store.openProfile = nil; store.search = ""; store.message = nil
        AGTTime.fixedNow = Date()
        for dark in [false, true] {
            for size in [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 700)] {
                let suffix = "\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
                store.layout = .cards
                try render(AGFRAMEAgentsPage(mode: .all, live: false), dark: dark, size: size, name: "L4-all-\(suffix)")
                try render(AGFRAMEAgentsPage(mode: .org, live: false), dark: dark, size: size, name: "L4-org-\(suffix)")
                try render(AGFRAMEAgentsPage(mode: .work, live: false, workModel: try Self.workFixture()), dark: dark, size: size,
                           name: "L4-work-\(suffix)", minimumTableRows: 9)
                let batches = [
                    AGFRAMEImportFolder(folder: folders["crm"]!, candidates: ["crm-db", "diff-verifier", "portal-mechanic"].map {
                        AGFRAMEImportCandidate(id: folders["crm"]! + "/\($0).md", name: $0) }, projectID: "crm", projects: PROJProjects.defaults),
                    AGFRAMEImportFolder(folder: folders["imatch"]!, candidates: (["accounts-keeper", "analyst", "android-engineer", "db-surgeon",
                        "ios-engineer", "matchmaker", "whatsapp-officer"] + (1...17).map { "helper-\($0)" }).map {
                        AGFRAMEImportCandidate(id: folders["imatch"]! + "/\($0).md", name: $0, alreadyImported: $0 == "analyst") },
                        projectID: "imatch", projects: PROJProjects.defaults),
                ]
                let model = AGFRAMEImportModel(folders: batches, live: false, invoke: { _, _ in
                    XCTFail("Render must never call the engine"); throw NSError(domain: "L4", code: 1)
                })
                try render(ZStack {
                    AGFRAMEAgentsPage(mode: .all, live: false)
                    Color.black.opacity(0.25)
                    AGFRAMEImportSheet(model: model).frame(maxWidth: 600, maxHeight: size.height - 80)
                        .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 24)
                }, dark: dark, size: size, name: "L4-import-\(suffix)")
            }
        }
    }

    /// Deck Memory (spec 3a, 3b): seats and hands on the Agents page. Hoot → leads → agents, a lead
    /// that is not running, a vacant seat that still holds memory, a seat with three hands, the hire
    /// page with the role picker, and the Add a hand sheet. Fixture data only.
    @MainActor func testMemorySeatsAndHandsRender() throws {
        guard ProcessInfo.processInfo.environment["L4_MEMORY_RENDER"] == "1" else { throw XCTSkip("runs on request") }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = AGTAgentsStore.shared, seats = AGTSeatsStore.shared, hands = AGTHandsStore.shared
        let saved = (store.fixture, store.live, store.liveLoaded, store.openProfile, NativePROJLabels.shared.projects)
        defer {
            store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2; store.openProfile = saved.3
            NativePROJLabels.shared.projects = saved.4; seats.fixture = nil; hands.fixture = nil; hands.fixtureResults = [:]; AGTLeads.pendingHire = nil
        }
        NativePROJLabels.shared.projects = [
            PROJProject(id: "imatch", name: "iMatch", folders: ["/work/imatch"], colour: "blue", lead: "session:gone", leadName: "Commander"),
            PROJProject(id: "crm", name: "CRM", folders: ["/work/crm"], colour: "purple", lead: "agent:portal-mechanic", leadName: "portal-mechanic"),
            PROJProject(id: PROJProjects.independentID, name: "Independent", icon: "square.grid.2x2", colour: "graphite"),
        ]
        store.fixture = TasksState(agents: ORGRenderTests.fixture.map { profile in
            var row = profile; row.reportsTo = nil; row.model = "Opus 5.5"; return row
        })
        store.live = ORGRenderTests.liveFixture
        store.liveLoaded = true; store.openProfile = nil; store.search = ""; store.message = nil; store.layout = .cards
        let fixer = DeckMemoryOwner.role(project: "imatch", role: "db-surgeon")
        seats.fixture = [
            .init(owner: .role(project: "imatch", role: "release-captain"), name: "Release captain", folder: "projects/imatch/roles/release-captain", hasCard: true, notes: 12, topics: 2),
            .init(owner: fixer, name: "Database fixer", folder: "projects/imatch/roles/db-surgeon", hasCard: true, notes: 31, topics: 3),
            .init(owner: .lead("imatch"), name: "Lead of iMatch", folder: "projects/imatch/lead", hasCard: true, notes: 40, topics: 4),
        ]
        hands.fixture = [
            .init(seat: fixer, number: 1, sessionID: "h1", job: "Fix the March import", taskID: "t1", startedAt: Date()),
            .init(seat: fixer, number: 2, sessionID: "h2", job: "Rebuild the listings index", taskID: "t2", startedAt: Date()),
            .init(seat: fixer, number: 3, sessionID: "h3", job: "Check the backup restores", taskID: "t3", startedAt: Date()),
        ]
        hands.fixtureResults = ["h1": .reported, "h2": .attempted, "h3": .verified]
        let size = CGSize(width: 1440, height: 900)
        for dark in [false, true] {
            try render(AGFRAMEAgentsPage(mode: .org, live: false), dark: dark, size: size, name: "L4-seats-org-\(dark ? "dark" : "light")")
        }
        try render(AGFRAMEAgentsPage(mode: .all, live: false), dark: false, size: size, name: "L4-seats-all-light")
        AGTLeads.pendingHire = .role(projectID: "imatch", role: "release-captain")
        store.openProfile = "new"
        try render(AGFRAMEAgentsPage(mode: .all, live: false), dark: false, size: size, name: "L4-seats-hire-light")
        store.openProfile = nil
        if let agent = store.agents.first(where: { $0.id == "db-surgeon" }) {
            try render(ZStack { DeckTokens.page; AGTAddHandSheet(agent: agent).background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 14)) },
                       dark: false, size: CGSize(width: 900, height: 620), name: "L4-seats-addhand-light")
            try render(ZStack { DeckTokens.page; AGTSeatHeader(agent: agent).padding(24) }, dark: false, size: CGSize(width: 1200, height: 200), name: "L4-seats-header-light")
        }
    }

    /// 13 Oct: a session opened in a project led by a saved agent shows as that lead; a project with no lead is
    /// offered the name its own CLAUDE.md gives its AI. Pictures on request (L4_MEMORY_RENDER=1).
    @MainActor func testWorksAsLeadRender() throws {
        guard ProcessInfo.processInfo.environment["L4_MEMORY_RENDER"] == "1" else { throw XCTSkip("runs on request") }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = AGTAgentsStore.shared, hands = AGTHandsStore.shared, declared = AGTDeclaredLeads.shared
        let saved = (store.fixture, store.live, store.liveLoaded, store.openProfile, NativePROJLabels.shared.projects, store.layout)
        defer {
            store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2; store.openProfile = saved.3
            NativePROJLabels.shared.projects = saved.4; store.layout = saved.5; hands.fixture = nil; declared.fixture = nil
        }
        NativePROJLabels.shared.projects = [
            PROJProject(id: "imatch", name: "iMatch", folders: ["/work/ClaudeiMatch"], colour: "blue", lead: "agent:commander", leadName: "Commander"),
            PROJProject(id: "daftar", name: "Daftar", folders: ["/work/daftar"], colour: "green"),
            PROJProject(id: PROJProjects.independentID, name: "Independent", icon: "square.grid.2x2", colour: "graphite"),
        ]
        store.fixture = TasksState(agents: [
            AgentProfile(id: "commander", name: "Commander", role: "Lead of iMatch", provider: "claude", model: "Opus 5.5", status: .active, icon: "sf:scope", projectID: "imatch"),
            AgentProfile(id: "matchmaker", name: "matchmaker", provider: "claude", model: "Opus 5.5", status: .active, icon: "sf:star", projectID: "imatch"),
            AgentProfile(id: "db-surgeon", name: "db-surgeon", provider: "claude", model: "Opus 5.5", status: .active, icon: "sf:cylinder.split.1x2", projectID: "imatch"),
        ])
        store.live = [AGTWorksAsLeadUITests.session("a", title: "ClaudeiMatch", folder: "/work/ClaudeiMatch", session: "s1"),
                      AGTWorksAsLeadUITests.session("b", title: "daftar", folder: "/work/daftar", session: "s2")]
        store.liveLoaded = true; store.openProfile = nil; store.search = ""; store.message = nil; store.layout = .cards
        hands.fixture = [.init(seat: .lead("imatch"), number: 1, sessionID: "s1", job: "", taskID: nil, startedAt: Date())]
        declared.fixture = ["daftar": .init(name: "Munshi", file: "CLAUDE.md", path: "/work/daftar/CLAUDE.md", provider: "claude")]
        let size = CGSize(width: 1440, height: 900)
        for dark in [false, true] {
            try render(AGFRAMEAgentsPage(mode: .all, live: false), dark: dark, size: size, name: "L4-lead-all-\(dark ? "dark" : "light")")
        }
        try render(AGFRAMEAgentsPage(mode: .org, live: false), dark: false, size: size, name: "L4-lead-org-light")
        if let plain = store.agents.first(where: { $0.sessionID == "s2" }) {
            try render(ZStack { DeckTokens.page; AGTSeatHeader(agent: plain).padding(24) }, dark: false, size: CGSize(width: 1200, height: 200), name: "L4-lead-offer-header-light")
        }
    }

    /// Glass only draws in a real window. One borderless window, ordered below every other
    /// window and never activated, captured with `screencapture -l`, then closed.
    @MainActor func testRealWindowOrgAndAtWork() throws {
        guard ProcessInfo.processInfo.environment["L4_REAL_WINDOW"] == "1" else { throw XCTSkip("real-window check runs on request") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex")
        let store = AGTAgentsStore.shared
        let saved = (store.fixture, store.live, store.liveLoaded, store.openProfile, NativePROJLabels.shared.projects)
        defer { store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2; store.openProfile = saved.3; NativePROJLabels.shared.projects = saved.4 }
        NativePROJLabels.shared.projects = PROJProjects.defaults
        store.fixture = TasksState(agents: ORGRenderTests.fixture)
        store.live = ORGRenderTests.liveFixture
        store.liveLoaded = true; store.openProfile = nil
        let size = CGSize(width: 1200, height: 800)
        for dark in [false, true] {
            for (name, view) in [("org", AnyView(AGFRAMEAgentsPage(mode: .org, live: false))),
                                 ("work", AnyView(AGFRAMEAgentsPage(mode: .work, live: false, workModel: try Self.workFixture())))] {
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                    .background(DeckTokens.page).environment(\.colorScheme, dark ? .dark : .light))
                window.order(.below, relativeTo: 0)
                window.orderBack(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(1.2))
                XCTAssertFalse(NSApp.isActive)
                let file = output.appendingPathComponent("L4-real-\(name)-\(dark ? "dark" : "light").png")
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
                try shot.run(); shot.waitUntilExit()
                window.orderOut(nil); window.contentView = nil; window.close()
                XCTAssertEqual(shot.terminationStatus, 0)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
                print("L4 real window \(file.lastPathComponent)")
            }
        }
    }

    @MainActor private func render<V: View>(_ view: V, dark: Bool, size: CGSize, name: String, minimumTableRows: Int = 0) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["L4_RENDER_OUTPUT"] ??
            "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex")
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        // The real window keeps a 264 pt side panel; the page gets the rest.
        let host = NSHostingView(rootView: AnyView(HStack(spacing: 0) {
            Color(nsColor: .underPageBackgroundColor).frame(width: 264)
            view.frame(width: size.width - 264, height: size.height).background(DeckTokens.page)
        }.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light)))
        host.appearance = appearance
        // Never ordered front, so it is never visible and the app never activates.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var rows = 0
        appearance.performAsCurrentDrawingAppearance {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func materialize(_ view: NSView) -> Int {
                var count = 0
                if let table = view as? NSTableView { table.layoutSubtreeIfNeeded(); count += table.numberOfRows }
                for child in view.subviews { count += materialize(child) }
                return count
            }
            rows = materialize(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertFalse(window.isVisible); XCTAssertFalse(NSApp.isActive)
        XCTAssertGreaterThanOrEqual(rows, minimumTableRows, "\(name): native table rows")
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
        let data = try XCTUnwrap(png)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent(name + ".png"))
        print("L4 rendered \(name).png rows=\(rows) visible=false active=false")
    }

    /// The At work mockup's nine rows (same values as the ATWORK chat's render fixture).
    @MainActor static func workFixture() throws -> AWAgentsWatchModel {
        let now = Date().timeIntervalSince1970 * 1000
        let json = #"""
        [
          {"id":"panel","sourceID":"panel","kind":"session","name":"panel-engineer","provider":"claude","projectId":"imatch","project":"/fixture/imatch","state":"working","action":"Running the admin panel tests","cpuPercent":38.2,"memoryBytes":1503238554,"tokensToday":612000,"runtime":2472},
          {"id":"accounts","sourceID":"accounts","kind":"session","name":"accounts-keeper","provider":"claude","projectId":"imatch","project":"/fixture/imatch","state":"working","action":"Reading the sign-in callback","cpuPercent":12.6,"memoryBytes":509607936,"tokensToday":188000,"runtime":723},
          {"id":"portal","sourceID":"portal","kind":"session","name":"portal-mechanic","provider":"claude","projectId":"crm","project":"/fixture/crm","state":"working","action":"Fixing the sign-in button","cpuPercent":9.8,"memoryBytes":421527552,"tokensToday":96000,"runtime":400},
          {"id":"db","sourceID":"db","kind":"session","name":"db-surgeon","provider":"claude","projectId":"imatch","project":"/fixture/imatch","state":"working","action":"Reviewing an index change","cpuPercent":4.1,"memoryBytes":372244480,"tokensToday":240000,"runtime":1371},
          {"id":"hoot","sourceID":"hoot","kind":"hoot","name":"Hoot","provider":"claude","projectId":"all","project":"","state":"working","action":"Reading CRM session's last turn","cpuPercent":2.3,"memoryBytes":312475648,"tokensToday":1100000,"runtime":10930},
          {"id":"ios","sourceID":"ios","kind":"session","name":"ios-engineer","provider":"claude","projectId":"imatch","project":"/fixture/imatch","state":"waiting","action":"OK to upload build 412?","cpuPercent":0,"memoryBytes":325058560,"tokensToday":402000,"runtime":3944},
          {"id":"device:terminal","sourceID":"terminal","kind":"device","name":"Claude Code","provider":"claude","projectId":"crm","project":"/fixture/crm","state":"working","action":"~/ClaudeCRM · update the lead export","cpuPercent":6.4,"memoryBytes":545259520,"sourceApp":"Terminal","runtime":1100},
          {"id":"device:codex","sourceID":"codex","kind":"device","name":"Codex","provider":"codex","projectId":"independent","project":"/fixture/td-native-shell","state":"working","action":"~/td-native-shell · building the Mac app","cpuPercent":61,"memoryBytes":2254857830,"sourceApp":"Codex app","runtime":3249},
          {"id":"device:vscode","sourceID":"vscode","kind":"device","name":"Claude Code","provider":"claude","projectId":"independent","project":"/fixture/engineerings-pk","state":"idle","action":"~/engineerings-pk · at a prompt","cpuPercent":0.1,"memoryBytes":224395264,"sourceApp":"VS Code","runtime":8040}
        ]
        """#
        let values = try NativeRPCValue.parseJSON(Data(json.utf8)).elements ?? []
        let rows = values.enumerated().compactMap { index, raw in
            AWWatchAgent.decode(raw.setting("since", .number(now - (raw["runtime"].number ?? 0) * 1000))
                .setting("pid", .number(Double(42000 + index))).setting("threads", .number(4))
                .setting("processCount", .number(4)).setting("metricsSampledAt", .number(now)))
        }
        let icons: [String: String] = ["panel": "square.grid.2x2", "accounts": "key", "portal": "wrench", "db": "externaldrive", "ios": "iphone"]
        let model = AWAgentsWatchModel(sourceEvents: [], iconProvider: { row in icons[row.id].map { .symbol($0) } }, read: { _, _ in
            throw NSError(domain: "L4", code: 2, userInfo: [NSLocalizedDescriptionKey: "Render attempted a live read."])
        })
        model.agents = rows; model.loading = false; model.deviceLoaded = true
        model.selectedID = "accounts"
        model.updatedAt = now
        for i in 0..<150 {
            let angle = Double(i) / 8
            model.acceptMetrics(.object([.init("load", .object([
                .init("at", .number(now - Double(149 - i) * 2000)),
                .init("agentCPU", .number(max(0, 18 + 13 * sin(angle) + 6 * sin(angle * 0.4)))),
                .init("otherCPU", .number(max(0, 10 + 4 * sin(angle + 1)))),
                .init("agentMemoryBytes", .number(6.2 * 1073741824)), .init("freeMemoryBytes", .number(9.8 * 1073741824)),
                .init("processes", .number(41)), .init("memoryPressure", .number(34)),
                .init("tokensPerMinute", .number(2000 + 700 * sin(angle))),
            ])), .init("heavyJob", .object([.init("busy", .bool(true))]))]))
        }
        return model
    }
}
