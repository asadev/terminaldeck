import Foundation
import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

@MainActor final class SkillVersionsMCPTests: XCTestCase {
    func testActualFactoryAndUIChannelsSaveCheckAdoptAndReadBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-version-mcp-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project/.agents/skills/topic-skill")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: topic-skill\ndescription: Fixture\n---\nRead files.".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let store = BackendSkillVersions(root: root.appendingPathComponent("private-history"), writable: true)
        let service = BackendROUTINESSkills(dependencies: .init(projects: { [] }, profiles: { [] }, catalogue: { .null }, install: { _, _ in .null }, remove: { _ in .null }), sharedRoots: [.init(folder: source.deletingLastPathComponent(), source: "Fixture")], home: root, writable: true, versions: store)
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, folder in folder }, session: { _, _ in .null }, runnableProject: { _, folder in folder }, rpc: { _ in throw NativeRPCError.invalidArguments("Unused") }, authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let tools = try ROUTINESSkillsMCP.definitions(access: access, service: service, currentGrant: { _, approved in .init(readRoots: [root.path], writeRoots: approved ? [root.path] : [], identity: "fixture") }, changed: {})
        let ids = ["skills.versions", "skills.version_save", "skills.version_adopt", "skills.version_check"]
        XCTAssertTrue(ids.allSatisfy { id in tools.contains { $0.spec.id == id && $0.spec.wireName == id.replacingOccurrences(of: ".", with: "_") } })
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: root.path, attended: true, allowedTools: Set(ids), allowedTiers: [.read, .alter], cancellation: .init())
        func call(_ id: String, _ extra: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
            let tool = try XCTUnwrap(tools.first { $0.spec.id == id })
            let reply = try await tool.handler(context, .object([.init("skill", .string(source.path))] + extra))
            XCTAssertFalse(reply.isError, String(describing: reply.content)); return try XCTUnwrap(reply.structuredContent)
        }
        let before = try await call("skills.versions"), digest = try before["currentDigest"].requireString("currentDigest")
        let saved = try await call("skills.version_save", [.init("label", .string("Named")), .init("expectedDigest", .string(digest))])
        let version = try saved["version"]["id"].requireString("version")
        let checked = try await call("skills.version_check", [.init("version", .string(version))]); XCTAssertEqual(checked["check"]["passed"], .bool(true))
        let adopted = try await call("skills.version_adopt", [.init("version", .string(version)), .init("expectedDigest", .string(digest))]); XCTAssertEqual(adopted["adoptedVersion"], .string(version))
        let model = ROUTINESSkillsStore(); model.fixture = true
        let registry = NativeChannelRegistry()
        try await BackendROUTINESSkills.register(registry: registry, ownerID: "fixture", service: service, policy: { _ in })
        let channels = await registry.channels(); XCTAssertTrue(ids.map { $0.replacingOccurrences(of: ".", with: ":") }.allSatisfy(channels.contains))
        model.versionInvoker = { channel, args in
            try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [args])
        }
        let ui = try await model.versionCall("skills:versions", args: ["skill": source.path])
        XCTAssertEqual(ui["adoptedVersion"], .string(version)); XCTAssertEqual(ui["checks"].elements?.count, 1)
        let body = ROUTINESSkillVersionsView(skill: source.path, model: model)
        _ = body.body // Construct the actual preview section without a window or app launch.
        try await renderIfRequested(body)
        let scoped = BackendROUTINESSkillsScope(roots: [])
        do { _ = try await service.call("skills:versions", .object([.init("skill", .string(source.path))]), scope: scoped); XCTFail("ungranted history") } catch {}
    }
    private func renderIfRequested(_ content: ROUTINESSkillVersionsView) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TD_INTEGRATOR_RENDER_DIR"] else { return }
        let root = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let themes: [(String, NSAppearance.Name, ColorScheme)] = [("light", .aqua, .light), ("dark", .darkAqua, .dark)]
        for (name, appearance, scheme) in themes {
            let frame = NSRect(x: 0, y: 0, width: 760, height: 620)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: content.environment(\.colorScheme, scheme)
                .frame(width: 720, alignment: .topLeading).padding(20)
                .frame(width: 760, height: 620, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = frame
            host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            host.layoutSubtreeIfNeeded()
            for (suffix, rect) in [("", host.bounds), ("-controls", NSRect(x: 0, y: 120, width: 760, height: 400))] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
                host.cacheDisplay(in: rect, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: root.appendingPathComponent("skills-\(name)\(suffix).png"))
            }
            window.close()
        }
    }

}
