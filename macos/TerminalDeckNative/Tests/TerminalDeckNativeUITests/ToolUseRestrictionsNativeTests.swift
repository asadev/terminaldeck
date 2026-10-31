import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ToolUseRestrictionsNativeTests: XCTestCase {
    func testExistingDraftKeepsRawRulesAndEditorAcceptsSavedPolicy() throws {
        let raw = try NativeRPCValue.parseJSON(Data(#"{"version":1,"tools":[{"service":"tasks","tool":"tasks.comment","cases":[{"arguments":{"task":"local:fixture","text":"Progress"}}]}]}"#.utf8))
        let profile = AgentProfile(id: "worker", name: "Worker", provider: "claude", toolUseRestrictions: raw)
        var draft = AgentDraft(profile); draft.role = "Reviewer"
        let submitted = try AgentForm.payload(draft, agents: [profile]).get()
        XCTAssertEqual(submitted.toolUseRestrictions, raw)
        let view = NativeToolUseRestrictionsEditor(value: .constant(draft.toolUseRestrictions), agentName: draft.name, busy: false)
        _ = view // initializer only; do not evaluate TextEditor/AppKit body
        let malformed = NativeRPCValue.object([.init("version", .number(9))])
        let broken = NativeToolUseRestrictionsEditor(value: .constant(malformed), agentName: "Worker", busy: false)
        _ = broken; XCTAssertNotNil(ToolUseRestrictions.problem(malformed))
    }
}
