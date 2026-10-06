import Foundation
import JavaScriptCore
import Testing
@testable import TerminalDeckNativeCore

@Suite("Page dialogs drawn natively")
struct NativeDialogsTests {
    func body(_ json: String) -> Any { try! JSONSerialization.jsonObject(with: Data(json.utf8)) }

    @Test func dialogMessages() throws {
        guard case .dialog(let open) = PageMessage.parse(body(#"{"type":"dialog","name":"close-confirm","open":true,"seq":3,"data":{"title":"zsh","status":"working"}}"#)) else {
            Issue.record("expected .dialog"); return
        }
        #expect(open.name == "close-confirm" && open.open && open.seq == 3)
        let ask = try #require(open.decode(CloseConfirmRequest.self))
        #expect(ask.title == "zsh" && ask.status == "working" && ask.count == 1 && ask.subject == .project)
        guard case .dialog(let closed) = PageMessage.parse(body(#"{"type":"dialog","name":"close-confirm","open":false,"seq":4}"#)) else {
            Issue.record("expected .dialog"); return
        }
        #expect(!closed.open && closed.seq == 4)
        #expect(PageMessage.parse(body(#"{"type":"dialog","open":true}"#)) == nil, "no name")
        #expect(PageMessage.parse(body(#"{"type":"dialog","name":"x"}"#)) == nil, "no open/closed")
    }

    @Test func answersReachThePageIntact() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var window = { tdDialog: { run: function (n, a, arg) { window.got = { n: n, a: a, arg: arg, count: arguments.length } } } };")
        context.evaluateScript(DialogCommand("close-confirm", "confirm", argument: ["suppress": true]).script)
        #expect(context.evaluateScript("window.got.n").toString() == "close-confirm")
        #expect(context.evaluateScript("window.got.a").toString() == "confirm")
        #expect(context.evaluateScript("window.got.arg.suppress").toBool())
        context.evaluateScript(DialogCommand("close-confirm", "cancel").script)
        #expect(context.evaluateScript("window.got.count").toInt32() == 2)
        context.evaluateScript(DialogCommand("x", "say", text: "it's \"quoted\"\n\u{2028}").script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("window.got.arg").toString() == "it's \"quoted\"\n\u{2028}")
        context.evaluateScript("var window = {}")
        context.evaluateScript(DialogCommand("x", "y").script)
        #expect(context.exception == nil, "no tdDialog on the page is harmless")
    }

    // closeWarning — mirrors CloseSessionConfirm.test.ts
    @Test func closeWarnings() {
        #expect(CloseConfirmRequest.closeWarning(status: "input").headline.contains("asked you"))
        #expect(CloseConfirmRequest.closeWarning(status: "working").headline.contains("still working"))
        for status in ["idle", "working", "waiting", "input", "completed", "exited"] {
            #expect(CloseConfirmRequest.closeWarning(status: status).detail.count > 20)
        }
        let gone = CloseConfirmRequest.closeWarning(status: "exited")
        #expect(gone.headline.contains("already ended") && !gone.detail.contains("agent stops"))
        for status in ["idle", "waiting", "completed"] {
            #expect(CloseConfirmRequest.closeWarning(status: status).headline == "Deleting this session ends it.")
        }
        let four = CloseConfirmRequest.closeWarning(status: "working", count: 4)
        #expect(four.headline.contains("4 sessions") && four.headline.contains("project"))
        #expect(CloseConfirmRequest.closeWarning(status: "input", count: 1) == CloseConfirmRequest.closeWarning(status: "input"))
        let server = CloseConfirmRequest.closeWarning(status: "idle", count: 1, subject: .server)
        #expect(server.detail.contains("Nothing else on the server is touched"))
        #expect(server.detail.contains("open another terminal whenever you like"))
        #expect(CloseConfirmRequest.closeWarning(status: "working", count: 3, subject: .server).headline == "This deletes 3 terminals on that server.")
        #expect(CloseConfirmRequest.closeWarning(status: "idle", count: 2, subject: .machine).headline == "This deletes 2 sessions on that machine.")
    }

    @Test func headingsButtonsAndExtras() {
        let one = CloseConfirmRequest(title: "zsh", status: "idle")
        #expect(one.heading == "Delete this session?" && one.confirmLabel == "Delete")
        let servers = CloseConfirmRequest(title: "box", status: "idle", count: 3, subject: .server)
        #expect(servers.heading == "Delete these terminals?" && servers.confirmLabel == "Delete terminals")
        let resumable = CloseConfirmRequest(title: "claude", status: "idle", canResume: true)
        #expect(resumable.warning.detail.hasSuffix("The conversation itself is kept — a new session in this folder can continue it."))
        #expect(CloseConfirmRequest(title: "", status: "idle", attachedWindows: [1]).attachedLine == "B1 stays open, detached.")
        #expect(CloseConfirmRequest(title: "", status: "idle", attachedWindows: [1, 2, 3]).attachedLine == "B1, B2 and B3 stay open, detached.")
        #expect(CloseConfirmRequest(title: "", status: "idle").attachedLine == nil)
    }

    // SwitchAccountConfirm.tsx's states
    @Test func switchAccountStates() throws {
        let working = SwitchAccountRequest(toName: "work", busy: true)
        #expect(working.heading == "Switch to work?" && working.pendingLine == "Working out what this would do…")
        #expect(!working.offersSwitch && working.dismissLabel == "Close")
        #expect(SwitchAccountRequest(toName: "work").pendingLine == "Nothing could be worked out about this switch.")
        let ready = SwitchAccountRequest(fromName: "home", toName: "work", planned: true, canDefer: true)
        #expect(ready.offersSwitch && ready.dismissLabel == "Cancel" && ready.confirmLabel == "Switch now" && ready.pendingLine == nil)
        #expect(SwitchAccountRequest(toName: "w", planned: true, busy: true).confirmLabel == "Switching…")
        let refused = SwitchAccountRequest(toName: "w", planned: true, refusal: "Not signed in.")
        #expect(!refused.canSwitch && !refused.offersSwitch && refused.dismissLabel == "Close")
        let failed = SwitchAccountRequest(toName: "w", planned: true, problem: "The CLI refused.")
        #expect(failed.canSwitch && !failed.offersSwitch && failed.pendingLine == nil)
        let decoded = try #require(DialogRequest(name: "switch-account", open: true, seq: 1,
            data: Data(#"{"toName":"work","planned":true,"refusal":null,"tag":"New chat","note":"n","busy":false,"problem":null,"canDefer":true}"#.utf8))
            .decode(SwitchAccountRequest.self))
        #expect(decoded.tag == "New chat" && decoded.refusal == nil && decoded.canDefer)
    }
}
