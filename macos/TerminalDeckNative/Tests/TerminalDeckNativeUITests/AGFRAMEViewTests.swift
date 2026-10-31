import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Only XCTest launches. No application, window, engine or AI is created.
final class AGFRAMEViewTests: XCTestCase {
    private func requireGate(_ stage: String) throws {
        guard ProcessInfo.processInfo.environment["AGFRAME_GATE_STAGE"] == stage else { throw XCTSkip("WIP AGFRAME: run the explicit \(stage) gate") }
    }
    @MainActor func testFolderCallbacksAndFixtureImport() async throws {
        try requireGate("models")
        let folder = AGFRAMEImportFolder(folder: "/fixture/agents", candidates: [
            .init(id: "/fixture/agents/a.md", name: "a"), .init(id: "/fixture/agents/b.md", name: "b")], projects: [])
        let model = AGFRAMEImportModel(folders: [folder], live: false, invoke: { _, _ in
            XCTFail("Fixture must never call the engine"); throw NSError(domain: "AGFRAME", code: 1)
        })
        model.assign(folder: folder.id, projectID: "independent")
        model.select(folder: folder.id, id: "/fixture/agents/b.md", selected: false)
        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.folders[0].projectID, "independent")
        await model.scan()
        let imported = await model.importSelected()
        XCTAssertTrue(imported)
        XCTAssertEqual(model.outcome, "Fixture import checked.")
    }

    @MainActor func testSelectedBatchWireSkipsAlreadyImported() async throws {
        try requireGate("models")
        let folder = AGFRAMEImportFolder(folder: "/fixture/agents", candidates: [
            .init(id: "/fixture/agents/a.md", name: "a"), .init(id: "/fixture/agents/b.md", name: "b"),
            .init(id: "/fixture/agents/old.md", name: "old", alreadyImported: true)], projects: [])
        var calls = 0
        let model = AGFRAMEImportModel(folders: [folder], live: true, invoke: { channel, args in
            calls += 1
            XCTAssertEqual(channel, "tasks:agents-import")
            let options = try XCTUnwrap(args.first as? [String: Any])
            let batches = try XCTUnwrap(options["batches"] as? [[String: Any]])
            XCTAssertEqual(batches.count, 1)
            XCTAssertEqual(batches[0]["folder"] as? String, "/fixture/agents")
            XCTAssertEqual(batches[0]["projectId"] as? String, "independent")
            XCTAssertEqual(batches[0]["selectedFiles"] as? [String], ["/fixture/agents/a.md"])
            return ["ok": true]
        })
        model.assign(folder: folder.id, projectID: "independent")
        model.select(folder: folder.id, id: "/fixture/agents/b.md", selected: false)
        let imported = await model.importSelected()
        XCTAssertTrue(imported)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.count, 1)
    }

    @MainActor func testHiddenLightDarkRendersAtBothSizes() async throws {
        try requireGate("renders")
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design-2026-10-10/built.noindex")
        let root = NSHomeDirectory() // Fake fixture strings only; no source files are read.
        let projects = [PROJProject(id: "fixture-imatch", name: "iMatch", folders: [root + "/ClaudeiMatch"], colour: "blue"),
                        PROJProject(id: "fixture-crm", name: "CRM", folders: [root + "/ClaudeCRM"], colour: "purple"),
                        PROJProject(id: "independent", name: "Independent", colour: "graphite")]
        let store = AGTAgentsStore.shared
        let savedState = store.fixture
        let savedProjects = NativePROJLabels.shared.projects
        let savedLive = store.live
        let savedLoaded = store.liveLoaded
        let savedClock = AGTTime.fixedNow
        let savedProfile = store.openProfile
        let savedLayout = store.layout
        defer {
            store.openProfile = savedProfile; store.layout = savedLayout
            store.fixture = savedState; store.live = savedLive; store.liveLoaded = savedLoaded
            NativePROJLabels.shared.projects = savedProjects; AGTTime.fixedNow = savedClock
        }
        NativePROJLabels.shared.projects = [projects[1], projects[0], projects[2]]
        let imatch = ["panel-engineer", "ios-engineer", "accounts-keeper", "matchmaker", "db-surgeon", "locations-keeper", "critic", "whatsapp-officer", "analyst", "android-engineer", "brain-keeper", "design-keeper", "api-engineer", "ops-watcher", "photo-keeper", "listing-keeper", "data-engineer", "ios-reviewer", "web-reviewer", "test-engineer", "search-keeper", "billing-keeper", "scribe", "docs-keeper"]
        let roles: [String: String] = ["panel-engineer": "Builds the iMatch admin panel", "ios-engineer": "Builds and ships the iPhone app", "accounts-keeper": "Sign-up, sign-in, accounts, plans", "matchmaker": "Keeps match quality high", "db-surgeon": "Owns the live database structure", "locations-keeper": "The place tree and its parents", "critic": "Attacks a finished change", "whatsapp-officer": "Runs the WhatsApp channel", "portal-mechanic": "Keeps the CRM portal working", "crm-db": "Owns the CRM database and its tables", "diff-verifier": "Checks every change before it ships"]
        let symbols: [String: String] = ["panel-engineer": "square.grid.2x2", "ios-engineer": "iphone", "accounts-keeper": "key", "matchmaker": "star", "db-surgeon": "externaldrive", "locations-keeper": "mappin.circle", "critic": "ladybug", "whatsapp-officer": "message", "portal-mechanic": "wrench", "crm-db": "externaldrive", "diff-verifier": "checkmark.shield"]
        let names = [imatch, ["portal-mechanic", "crm-db", "diff-verifier"], ["release-captain", "researcher"]]
        let folders = [root + "/ClaudeiMatch/.claude/agents", root + "/ClaudeCRM/.claude/agents", root + "/agents/shared"]
        store.fixture = TasksState(agents: names.enumerated().flatMap { index, group in group.map { name in
            AgentProfile(id: name, name: name, role: roles[name] ?? "Keeps the project working", provider: "claude", model: name == "diff-verifier" ? "Sonnet 5.5" : "Opus 5.5",
                         status: name == "critic" ? .paused : .active,
                         defaultProject: folders[index], sourceFile: folders[index] + "/" + name + ".md", sourceDirectory: folders[index],
                         icon: "sf:" + (symbols[name] ?? "hammer"), projectID: projects[index].id)
        }})
        let working = Set(["portal-mechanic", "panel-engineer", "accounts-keeper", "db-surgeon", "api-engineer", "ops-watcher", "photo-keeper"])
        let waiting = Set(["ios-engineer", "listing-keeper"])
        let activeNames = working.union(waiting)
        store.live = names.enumerated().flatMap { index, group in group.compactMap { name -> AWWatchAgent? in
            guard activeNames.contains(name) else { return nil }
            let state = waiting.contains(name) ? "waiting" : "working"
            let action = name == "ios-engineer" ? "OK to upload build 4…" : name == "portal-mechanic" ? "Fixing the sign-in button" : name == "panel-engineer" ? "Admin tables fill the width" : "Checking the latest change"
            return AWWatchAgent.decode(.object([.init("id", .string("fixture-" + name)), .init("sourceID", .string(name)),
                .init("kind", .string("session")), .init("name", .string(name)), .init("provider", .string("claude")),
                .init("project", .string(folders[index])), .init("projectId", .string(projects[index].id)),
                .init("taskID", .string("task-" + name)), .init("state", .string(state)), .init("action", .string(action)),
                .init("updatedAt", .number(1_791_500_000_000 - 240_000))]))
        }}
        store.fixture?.tasks = activeNames.sorted().map { name in
            TaskRow(id: "task-" + name, title: "Fixture task", agent: name, process: .running, assignee: name)
        }
        store.liveLoaded = true; store.openProfile = nil; store.layout = .cards
        AGTTime.fixedNow = Date(timeIntervalSince1970: 1_791_500_000)
        var batches = names.enumerated().map { index, group in AGFRAMEImportFolder(folder: folders[index],
            candidates: group.sorted().map { AGFRAMEImportCandidate(id: folders[index] + "/" + $0 + ".md", name: $0) },
            projectID: projects[index].id, projects: projects) }
        batches[0].setSelected(false, id: folders[0] + "/critic.md")
        for dark in [false, true] {
            for size in [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 700)] {
                let suffix = "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
                try bitmap(AGFRAMERenderFrame { AGFRAMEAgentsPage(mode: .all, live: false) }, dark: dark, size: size,
                           output: output.appendingPathComponent("AGFRAME-all-\(suffix).png"))
                let model = AGFRAMEImportModel(folders: batches, live: false, invoke: { _, _ in
                    XCTFail("Render must never call the engine"); throw NSError(domain: "AGFRAME", code: 1)
                })
                try bitmap(AGFRAMERenderFrame {
                    ZStack {
                        AGFRAMEAgentsPage(mode: .all, live: false)
                        Color.black.opacity(0.2)
                        AGFRAMEImportSheet(model: model).frame(maxWidth: 600, maxHeight: size.height - 80)
                            .clipShape(RoundedRectangle(cornerRadius: 16)).shadow(radius: 20)
                    }
                }, dark: dark, size: size, output: output.appendingPathComponent("AGFRAME-import-\(suffix).png"))
            }
        }
    }

    @MainActor private func bitmap<V: View>(_ view: V, dark: Bool, size: CGSize, output: URL) throws {
        XCTAssertTrue(output.deletingLastPathComponent().lastPathComponent.hasSuffix(".noindex"))
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
        XCTAssertGreaterThan(png.count, 1000)
        print("AGFRAME rendered \(output.lastPathComponent); no window; \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
/// Inert framing fixture only. Product page/controls below are the actual native views.
struct AGFRAMERenderFrame<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: () -> Content
    private var frame: Color { scheme == .dark ? Color(red: 0.086, green: 0.086, blue: 0.094) : Color(red: 0.914, green: 0.914, blue: 0.933) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                HStack(spacing: 8) { ForEach([Color.red, Color.orange, Color.green], id: \.self) { $0.frame(width: 12, height: 12).clipShape(Circle()) } }
                    .frame(width: 224, alignment: .leading)
                Text("Hoot").foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Text("● Commander").foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Text("● CRM session").foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Text("localhost:3000").foregroundStyle(.secondary)
                Spacer()
            }.font(.system(size: 13)).padding(.horizontal, 20).frame(height: 44)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    row("Hoot", "sparkles")
                    row("Agents", "person.2", selected: true)
                    row("Tasks", "checklist")
                    row("Artifacts", "doc")
                    Text("Projects").font(.caption).foregroundStyle(.secondary).padding(.top, 16)
                    row("iMatch", "circle.fill")
                    row("CRM", "circle.fill")
                    Text("Machines").font(.caption).foregroundStyle(.secondary).padding(.top, 16)
                    row("Servers", "server.rack")
                    row("Devices", "iphone")
                    row("Simulators", "iphone.gen3.radiowaves.left.and.right")
                    Text("Integrations").font(.caption).foregroundStyle(.secondary).padding(.top, 16)
                    row("Receiver", "tray")
                    row("MCP servers", "server.rack")
                    row("Store", "bag")
                    Spacer()
                    Divider()
                    row("Settings", "gearshape")
                }.padding(12).frame(width: 264)
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(frame)
    }
    private func row(_ name: String, _ symbol: String, selected: Bool = false) -> some View {
        Label(name, systemImage: symbol).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).frame(height: 28)
            .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
