import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

final class Skills19RenderTests: XCTestCase {
    @MainActor func testSkillsReadsAgentChangesFromTheSharedTaskState() {
        let original = TasksStore.shared.state ?? TasksState()
        defer { TasksStore.shared.adopt(.init(ok: true, message: nil, state: original)) }
        let model = ROUTINESSkillsStore()
        TasksStore.shared.adopt(.init(ok: true, message: nil, state: .init(agents: [.init(id: "worker", name: "Worker", skills: ["one"])])))
        XCTAssertEqual(model.profiles.first?["skills"], .array([.string("one")]))
        TasksStore.shared.adopt(.init(ok: true, message: nil, state: .init(agents: [.init(id: "worker", name: "Worker", skills: ["two"])])))
        XCTAssertEqual(model.profiles.first?["skills"], .array([.string("two")]))
    }

    @MainActor func testSkillClashCardsRenderWithoutStartingTheAppOrEngine() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = ROUTINESSkillsStore()
        model.fixture = true; model.loading = false; model.catalogueLoading = false
        model.installed = [
            .init(id: "/scratch/.claude/skills/status", name: "status", summary: "Find where the project stands and what is left.", projectID: "scratch", source: "This project · .claude/skills", folder: "/scratch/.claude/skills/status"),
            .init(id: "/scratch/.claude/skills/resume", name: "resume", summary: "Pick up work after a session is lost.", projectID: "scratch", source: "This project · .claude/skills", folder: "/scratch/.claude/skills/resume"),
            .init(id: "/scratch/.claude/skills/recover", name: "recover", summary: "A safe skill name with no command clash.", source: "Terminal Deck · built in", folder: "/scratch/.claude/skills/recover", builtIn: true)
        ]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("td-skills19-render.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [1000, 600] {
            let host = NSHostingView(rootView: ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Skills").font(.title)
                    AGTSkillsView(projectID: "scratch", model: model)
                }.padding(24)
            }.environment(\.colorScheme, .light))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("skills-\(width).png"))
            XCTAssertGreaterThan(data.count, 1000)
        }
    }
    @MainActor func testRenameIsExposedAsAnMCPTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills19-mcp-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".claude/skills/status")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nname: status\n---\nInstructions".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        let service = BackendROUTINESSkills(dependencies: .init(projects: { [.init(id: "p", name: "P", folders: [root.path])] }, profiles: { [] }, catalogue: { .null }, install: { _, _ in .null }, remove: { _ in .null }), sharedRoots: [], home: root, writable: true)
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, folder in folder }, session: { _, _ in .null }, runnableProject: { _, folder in folder }, rpc: { _ in throw NativeRPCError.invalidArguments("Unused") }, authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let tools = try ROUTINESSkillsMCP.definitions(access: access, service: service, currentGrant: { _, approved in
            .init(readRoots: [root.path], writeRoots: approved ? [root.path] : [], identity: "fixture")
        }, changed: {})
        let rename = try XCTUnwrap(tools.first { $0.spec.wireName == "skills_rename" })
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: root.path, attended: true, allowedTools: ["skills_rename"], allowedTiers: [.read, .alter], cancellation: .init())
        let reply = try await rename.handler(context, .object([.init("skill", .string(folder.path))]))
        XCTAssertFalse(reply.isError, String(describing: reply))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/skills/where-are-we/SKILL.md").path))
    }
}
