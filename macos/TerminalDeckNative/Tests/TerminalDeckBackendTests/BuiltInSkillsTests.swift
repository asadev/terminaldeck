import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// CONNECT-SKILLS (11 Oct): the starter skills shipped inside the app, how every screen and session finds them,
/// and the Codex label for Codex's own bundled skills.
final class BuiltInSkillsTests: XCTestCase {
    /// The folder the build scripts copy into the app: macos/built-in-skills.
    private var shipped: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("built-in-skills", isDirectory: true)
    }
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("built-in-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func skill(_ folder: URL, _ name: String, _ text: String? = nil) throws {
        let dir = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((text ?? "---\nname: \(name)\ndescription: \(name) skill\n---\n").utf8).write(to: dir.appendingPathComponent("SKILL.md"))
    }

    /// GUIDE-CONNECT (11 Oct): Hoot sets a project up by chat with the project-setup skill; every Claude and Codex
    /// session (Hoot included) is told the built-in skills and where to read them.
    func testProjectSetupSkillIsNamedToEverySessionAndFinishesWithTheScore() throws {
        XCTAssertTrue(BackendBuiltInSkills.sessionLine(folder: shipped).contains("project-setup"))
        let text = try String(contentsOf: shipped.appendingPathComponent("project-setup/SKILL.md"), encoding: .utf8)
        for tool in ["project_setup_guide", "project_setup_status", "project_registry_save", "projects_add", "project_registry_set_lead",
                     "tasks_agents", "skills_assign", "memory_card_save", "github_connect", "connected_tasks_connect"] {
            XCTAssertTrue(text.contains(tool), "project-setup names \(tool)")
        }
        XCTAssertTrue(text.contains("Only the name and the home folder are required"))
        XCTAssertTrue(text.contains("setup score"))
    }

    func testTheStarterSetShipsGenericForStrangers() throws {
        XCTAssertEqual(BackendBuiltInSkills.names(in: shipped), ["deep-research", "options-gallery", "overnight-run", "project-setup", "recover", "review-recording", "save-session", "start-an-agent"]) // R7: leads decide before starting agents.
        let shippedFolders = try FileManager.default.contentsOfDirectory(atPath: shipped.path).filter { FileManager.default.fileExists(atPath: shipped.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) }.sorted()
        XCTAssertEqual(shippedFolders, BackendBuiltInSkills.names(in: shipped), "Reserved skills must never be packaged silently")
        for name in BackendBuiltInSkills.names(in: shipped) {
            XCTAssertNoThrow(try SkillCommandNames.require(name))
            let text = try String(contentsOf: shipped.appendingPathComponent(name).appendingPathComponent("SKILL.md"), encoding: .utf8)
            XCTAssertEqual(try BackendAppAgentInventory.frontMatter(text, key: "name"), name)
            let description = try XCTUnwrap(try BackendAppAgentInventory.frontMatter(text, key: "description"))
            XCTAssertFalse(description.contains("\\\""), "\(name): the description shows clean on the Skills page")
            // Nothing about one person, his paths, accounts or servers.
            for personal in ["Asad", "imatch", "/Users/", "ClaudeAsad", "Deck Dev", "Hetzner", "Tailscale", "Spacefield", "AED"] {
                XCTAssertFalse(text.contains(personal), "\(name) mentions \(personal)")
            }
        }
        let save = try String(contentsOf: shipped.appendingPathComponent("save-session/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(save.contains("memory_note_add") && save.contains("memory_topic_update"), "saves into Deck Memory with the memory tools")
        let recording = try String(contentsOf: shipped.appendingPathComponent("review-recording/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(recording.contains("if neither is set, skip transcription cleanly"))
    }

    func testAgentPickersListBuiltInsAndAProjectsOwnCopyWins() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("built-in"), project = root.appendingPathComponent("project"), config = root.appendingPathComponent("claude")
        try skill(builtIn, "recover"); try skill(builtIn, "deep-research")
        try skill(project.appendingPathComponent(".claude/skills"), "recover", "---\nname: recover\ndescription: The project's own\n---\n")
        let reader = BackendAppAgentInventory(systemHome: root.path, loadServers: { _, _ in [] })
        let claude = reader.read(.init(provider: "claude", configDirectory: config.path, system: true, projects: [project.path], environment: [:], builtInSkills: builtIn.path))
        XCTAssertEqual(claude.skills.first { $0.value == "recover" }?.where, "project")
        XCTAssertEqual(claude.skills.first { $0.value == "deep-research" }?.where, "Terminal Deck · built in")
        let codex = reader.read(.init(provider: "codex", configDirectory: config.path, system: true, projects: [], environment: [:], home: root.path, builtInSkills: builtIn.path))
        XCTAssertEqual(Set(codex.skills.filter { $0.where == "Terminal Deck · built in" }.map(\.value)), ["recover", "deep-research"])
    }

    func testAgentBriefAndEverySessionKnowWhereTheyAre() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("built-in"), project = root.appendingPathComponent("project"), home = root.appendingPathComponent("home")
        try skill(builtIn, "recover"); try skill(builtIn, "overnight-run")
        let line = try XCTUnwrap(BackendBuiltInSkills.briefLine(["recover", "my-own"], projectFolder: project.path, folder: builtIn, home: home.path))
        XCTAssertTrue(line.contains(builtIn.appendingPathComponent("recover/SKILL.md").path)); XCTAssertFalse(line.contains("my-own"))
        // The project's own "recover" wins: the brief no longer points at the built-in one.
        try skill(project.appendingPathComponent(".claude/skills"), "recover")
        XCTAssertNil(BackendBuiltInSkills.briefLine(["recover"], projectFolder: project.path, folder: builtIn, home: home.path))
        let session = BackendBuiltInSkills.sessionLine(folder: builtIn)
        XCTAssertTrue(session.contains("overnight-run, recover") && session.contains(builtIn.path))
        // HOOT-FLOW: with no built-in skills, every session is still told how to report rules and skill steps.
        XCTAssertEqual(BackendBuiltInSkills.sessionLine(folder: nil), BackendBuiltInSkills.flowLine + SkillCommandNames.promptLine)
        XCTAssertTrue(session.hasSuffix(BackendBuiltInSkills.flowLine + SkillCommandNames.promptLine) && session.contains("flow_applied"))
    }

    func testTheSkillsPageShowsBuiltInsReadOnly() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("built-in"), codex = root.appendingPathComponent("codex/skills/.system")
        try skill(builtIn, "recover"); try skill(codex, "imagegen")
        let service = BackendROUTINESSkills(dependencies: .init(projects: { [] }, profiles: { [] }, catalogue: { .object([]) },
            install: { _, _ in .null }, remove: { _ in .null }),
            sharedRoots: [.init(folder: builtIn, source: BackendBuiltInSkills.source, builtIn: true),
                          .init(folder: codex, source: BackendBuiltInSkills.codexSource, builtIn: true)],
            home: root, writable: true)
        let rows = try await service.installed()
        XCTAssertEqual(rows.first { $0.name == "recover" }?.source, "Terminal Deck · built in")
        XCTAssertEqual(rows.first { $0.name == "imagegen" }?.source, "Codex · built in")
        XCTAssertTrue(rows.allSatisfy(\.builtIn))
        do { _ = try await service.remove("recover"); XCTFail("a built-in skill is never removed") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: builtIn.appendingPathComponent("recover/SKILL.md").path))
    }
}
