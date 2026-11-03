import XCTest
@testable import TerminalDeckNativeCore

final class SkillCommandNamesTests: XCTestCase {
    func testListsAreSeparateAndIncludeAliasesAndHiddenCommands() {
        XCTAssertEqual(Set(SkillCommandNames.commands.keys), Set(SkillCommandNames.ais))
        XCTAssertEqual(SkillCommandNames.clashes("compress"), ["gemini"])
        XCTAssertEqual(SkillCommandNames.clashes("approve"), ["codex"])
        XCTAssertEqual(SkillCommandNames.clashes("continue"), ["claude"])
        for name in ["status", "resume", "review", "init", "model", "usage", "clear", "compact", "mcp", "skills"] {
            XCTAssertTrue(SkillCommandNames.commands["claude"]!.contains(name))
        }
        XCTAssertTrue(SkillCommandNames.commands["codex"]!.contains("debug-m-update"))
        XCTAssertTrue(SkillCommandNames.commands["gemini"]!.contains("bashes"))
        XCTAssertTrue(SkillCommandNames.note("todos", targets: ["claude"])!.contains("is reserved"))
        XCTAssertFalse(SkillCommandNames.note("todos", targets: ["claude"])!.contains("also a"))
    }
    func testOnlyExactNamesClashAndNormalizationCannotBypassGuard() {
        XCTAssertEqual(SkillCommandNames.clashes(" /STATUS "), ["claude", "codex"])
        XCTAssertTrue(SkillCommandNames.clashes("status-report").isEmpty)
        XCTAssertThrowsError(try SkillCommandNames.require("Resume"))
        XCTAssertNoThrow(try SkillCommandNames.require("recover"))
        XCTAssertNoThrow(try SkillCommandNames.require("review-recording"))
        XCTAssertNoThrow(try SkillCommandNames.require("approve", targets: ["claude"]))
    }
    func testActualHeadersAndNestedCommandPathsAreGuarded() {
        XCTAssertEqual(SkillCommandNames.headerName("---\nname: \"sta\\x74us\"\n---\n"), "status")
        XCTAssertThrowsError(try SkillCommandNames.requireFile(path: "safe/SKILL.md", text: "---\nname: \"status\"\n---\n", targets: ["claude"]))
        XCTAssertThrowsError(try SkillCommandNames.requireFile(path: "SKILL.md", text: "---\nname: safe\nname: status # comment\n---\n", targets: ["claude"]))
        XCTAssertThrowsError(try SkillCommandNames.requireFile(path: "resume/SKILL.md", text: "---\nname: safe\n---\n", targets: ["codex"]))
        XCTAssertThrowsError(try SkillCommandNames.requireFile(path: "commands/model.toml", text: "", targets: ["gemini"]))
        XCTAssertNoThrow(try SkillCommandNames.requireFile(path: "commands/team/status.md", text: "", targets: ["claude"]))
        XCTAssertNoThrow(try SkillCommandNames.requireFile(path: "SKILL.md", text: "# status\n", targets: ["claude"]))
    }
    func testDiscoveryWireAndPromptCarryTheSamePolicy() {
        let row = ROUTINESSkill(id: "/p/.claude/skills/status", name: "status", source: "Project", folder: "/p/.claude/skills/status")
        XCTAssertTrue(row.wire["clash"].string!.contains("so neither works. Rename it?"))
        XCTAssertEqual(row.wire["suggestedName"].string, "where-are-we")
        XCTAssertEqual(SkillCommandNames.suggestion("resume"), "recover")
        XCTAssertEqual(SkillCommandNames.suggestion("review"), "review-skill")
        XCTAssertTrue(SkillCommandNames.promptLine.contains("skills_rename"))
        XCTAssertTrue(SkillCommandNames.promptLine.contains("project setup, agent creation and playbook"))
    }
}
