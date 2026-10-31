import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatRoutinesTests: XCTestCase {
    func testRoutineCopiesPromptOffAndRequiresExplicitTextForFilesWithoutChangingDraft() throws {
        var original = HootComposerDraft(); original.text = "Summarize daily changes"
        let prepared = try NativeChatRoutines.prepare(draft: original, explicitPrompt: nil, folder: "/scratch/project", projectID: "p")
        XCTAssertEqual(prepared.prompt, original.text)
        XCTAssertFalse(prepared.enabled)
        XCTAssertEqual(prepared.folder, "/scratch/project")
        XCTAssertEqual(prepared.agentID, "@hoot")
        original.add([URL(fileURLWithPath: "/scratch/a.txt")]); let saved = original
        XCTAssertThrowsError(try NativeChatRoutines.prepare(draft: original, explicitPrompt: nil, folder: "/scratch/project", projectID: "p"))
        let explicit = try NativeChatRoutines.prepare(draft: original, explicitPrompt: "Read a.txt daily", folder: "/scratch/project", projectID: "p")
        XCTAssertEqual(original, saved)
        XCTAssertEqual(explicit.prompt, "Read a.txt daily")
        XCTAssertEqual(NativeChatRoutines.wire(explicit)["persistentRoutineCreated"].bool, false)
        XCTAssertTrue(NativeChatRoutines.availability.contains("Mac awake"))
        XCTAssertThrowsError(try NativeChatRoutines.prepare(draft: original, explicitPrompt: String(repeating: "x", count: 8193), folder: "/scratch", projectID: "p"))
    }
}
