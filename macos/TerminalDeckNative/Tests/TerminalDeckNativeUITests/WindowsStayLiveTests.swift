import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U46: a question or form whose window goes away never leaves the sidebar and tab buttons dead
/// (review items in each test's name comment).
@MainActor
final class WindowsStayLiveTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + file), encoding: .utf8)
    }
    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let a = try XCTUnwrap(text.range(of: start), start)
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), end)
        return text[a.lowerBound..<b.lowerBound]
    }

    /// #105: the close question answers exactly once, and its window going away answers "no".
    func testCloseQuestionAnswersOnceAndWhenItsWindowGoes() async throws {
        let accepted = await withCheckedContinuation { done in
            let answer = CloseAnswer(done)
            answer.finish(false)
            XCTAssertTrue(answer.answered)
            answer.finish(true) // the late button press after the window went is ignored, not a second resume
        }
        XCTAssertFalse(accepted)
        let confirm = try slice(try source("TerminalDeckNative/NativeButtonPresentation.swift"),
                                from: "static func confirm(", to: "final class CloseAnswer")
        XCTAssertTrue(confirm.contains("NSWindow.willCloseNotification, object: parent"))
        XCTAssertTrue(confirm.contains("answer.finish(false)"))
        XCTAssertFalse(confirm.contains("done.resume("), "only CloseAnswer resumes the question")
    }

    /// #106: the New session form is forgotten when the window under it closes.
    func testNewSessionFormIsForgottenWithItsWindow() throws {
        let text = try source("TerminalDeckNative/NativeNewSessionDialog.swift")
        let present = try slice(text, from: "static func present(", to: "static var isOpen")
        XCTAssertTrue(present.contains("NSWindow.willCloseNotification, object: parent"))
        XCTAssertTrue(present.contains("if sheet === window { close() }"))
        let open = try slice(text, from: "static func open(", to: "static func startFolder(")
        XCTAssertTrue(open.contains("if sheet?.sheetParent == nil { close() }"), "a stale form never blocks a new one")
        XCTAssertFalse(try source("TerminalDeckNative/NativeButtonPresentation.swift").contains("if NativeNewSession.isOpen { return }"))
    }


    /// #620: one New session door, on the main window, with one starting-folder rule.
    func testNewSessionHasOneDoorAndOneStartingFolderRule() throws {
        let project = PROJProject(id: "p1", name: "One", folders: ["/work/one", "/work/one-b"])
        let independent = PROJProject(id: PROJProjects.independentID, name: "Independent", folders: [])
        XCTAssertEqual(NativeNewSession.startFolder("/asked", project: project, current: "/open", last: "/last"), "/asked")
        XCTAssertEqual(NativeNewSession.startFolder(nil, project: project, current: "/open", last: "/last"), "/work/one")
        XCTAssertNil(NativeNewSession.startFolder(nil, project: independent, current: "/open", last: "/last"))
        XCTAssertEqual(NativeNewSession.startFolder(nil, project: nil, current: "/open", last: "/last"), "/open")
        XCTAssertEqual(NativeNewSession.startFolder(nil, project: nil, current: nil, last: " /last \n"), "/last")
        XCTAssertNil(NativeNewSession.startFolder(nil, project: nil, current: nil, last: "relative"))

        let presentation = try source("TerminalDeckNative/NativeButtonPresentation.swift")
        XCTAssertTrue(try slice(presentation, from: "static func session(folder:", to: "static func confirm(").contains("NativeNewSession.open(folder: folder)"))
        XCTAssertTrue(try slice(presentation, from: "static var sessionParent", to: "static func session(folder:")
            .contains("mainWindow(in: NSApp?.windows ?? []) ?? NSApp?.mainWindow ?? NSApp?.keyWindow"), "the main window first")
        let dialog = try source("TerminalDeckNative/NativeNewSessionDialog.swift")
        XCTAssertTrue(try slice(dialog, from: "static func show(project:", to: "static func open(").contains("try? open(project: project)"))
        XCTAssertTrue(try slice(dialog, from: "static func open(", to: "static func startFolder(").contains("NativeButtonPresentation.sessionParent"))
    }
}
