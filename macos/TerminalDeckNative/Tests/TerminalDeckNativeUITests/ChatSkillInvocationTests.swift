import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatSkillInvocationTests: XCTestCase {
    func testOnlyAdvertisedUniqueCommandsPrepareIntoEmptyDraft() throws {
        let skill = ROUTINESSkill(id: "one", name: "check-project", source: "project", folder: "/scratch/.codex/skills/check-project")
        let commands = [HootSlashCommand(name: "check-project")]
        XCTAssertEqual(try NativeChatSkillInvocation.command(skill, installed: [skill], commands: commands, current: ""), "/check-project ")
        XCTAssertThrowsError(try NativeChatSkillInvocation.command(skill, installed: [skill], commands: [], current: ""))
        XCTAssertThrowsError(try NativeChatSkillInvocation.command(skill, installed: [skill, skill], commands: commands, current: ""))
        XCTAssertThrowsError(try NativeChatSkillInvocation.command(skill, installed: [skill], commands: commands, current: "keep draft"))
    }
}
