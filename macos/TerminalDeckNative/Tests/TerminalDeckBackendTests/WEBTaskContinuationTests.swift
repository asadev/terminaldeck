import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Web task redraw continuation")
struct WEBTaskContinuationTests {
    @Test func movingAnOpenTaskOutKeepsItsOriginalProjectAndFilterButReturnsTheList() {
        let original = BackendRemotePanelRequest(path: "/projects/first", scope: "task:one", query: "login")
        let redraw = BackendINT2PhonePanels.taskRedraw(original, action: "move", target: "/projects/second")
        #expect(redraw.path == original.path)
        #expect(redraw.query == "login")
        #expect(redraw.scope == nil)
        let empty = BackendINT2PhonePanels.payload(redraw, rows: [])
        #expect(empty["scope"] == .null)
        #expect(empty["path"].string == "/projects/first")
        #expect(empty["rows"].elements?.isEmpty == true)
    }

    @Test func deletingTheLastTaskHasAnExplicitListContinuationAndEmptyRows() {
        let original = BackendRemotePanelRequest(path: "/projects/first", scope: "task:last", query: nil)
        let redraw = BackendINT2PhoneTasks.answering(original, removed: true)
        let response = BackendINT2PhonePanels.payload(redraw, rows: [])
        #expect(redraw.scope == nil)
        #expect(response["scope"] == .null)
        #expect(response["rows"].elements?.isEmpty == true)
        #expect(BackendINT2PhoneTasks.answering(original, removed: false).scope == "task:last")
    }

    @Test func sameProjectActionsAndScopedProfilesKeepTheirRealContinuationScope() {
        let original = BackendRemotePanelRequest(path: "/projects/first", scope: "task:one", query: nil)
        for action in ["edit", "comment", "status", "move"] {
            let redraw = BackendINT2PhonePanels.taskRedraw(original, action: action, target: "/projects/first")
            #expect(redraw.scope == "task:one")
            #expect(BackendINT2PhonePanels.payload(redraw, rows: [row("one")])["scope"].string == "task:one")
        }
        let profile = BackendRemotePanelRequest(path: "", scope: "agent:reviewer", query: nil)
        #expect(BackendIOS2PhonePanels.payload(profile, rows: [row("reviewer")])["scope"].string == "agent:reviewer")
    }

    private func row(_ id: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("title", .string(id))])
    }
}
