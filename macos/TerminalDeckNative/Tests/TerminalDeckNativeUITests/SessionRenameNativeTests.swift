import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Asad, 12 Oct (install 18): "I can't rename sessions like before. If I edit and apply, it does not work."
/// The side panel (its menu's alert and the double-click on a name) and the session bar's title both call
/// `NativeSessionNames.rename`, which goes straight to the engine (`session:rename`), never through the page.
@MainActor final class SessionRenameNativeTests: XCTestCase {
    private final class Engine {
        var calls: [(channel: String, args: [String])] = []
        var renameAnswer: Any = true
        var renameFails = false
        var sessions: [[String: Any]] = []
        var changes = 0
        func invoke(_ channel: String, _ args: [Any?]) throws -> Any {
            calls.append((channel, args.map { $0.map { "\($0)" } ?? "" }))
            switch channel {
            case "session:rename":
                if renameFails { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine is not answering."]) }
                return renameAnswer
            case "session:list": return sessions
            default: return true
            }
        }
    }

    private let id = "7f1c2a9e-0c55-4c1e-9d4e-1f2a3b4c5d6e"

    private func names(_ engine: Engine) -> NativeSessionNames {
        NativeSessionNames(invoke: { channel, args in try engine.invoke(channel, args) },
                           changed: { engine.changes += 1 }, pause: { _ in })
    }

    private func rail(_ names: NativeSessionNames) -> SidebarState {
        SessionNames.applied(names.names, to: SidebarState(groups: [], projects: [
            SidebarProject(id: "/work/api", title: "api", expanded: true, sessions: [SidebarItem(id: id, title: "api", kind: .session)])],
            selectedId: id))
    }

    func testSidePanelRenameCallsSessionRenameAndShowsTheNameAtOnce() async {
        let engine = Engine(), names = names(engine)
        let task = names.rename(tabId: id, typed: "  API   work ")
        // Before the engine answers: the row and the session bar already say it.
        XCTAssertEqual(rail(names).item(id: id)?.title, "API work")
        XCTAssertEqual(TerminalHeader.make(info: nil, railTitle: rail(names).item(id: id)?.title, status: nil, ended: false).title, "API work")
        XCTAssertEqual(engine.changes, 1)
        await task?.value
        XCTAssertEqual(engine.calls.map(\.channel), ["session:rename"])
        XCTAssertEqual(engine.calls.first?.args, [id, "API work"])
        XCTAssertNil(names.problem)
    }

    func testSessionBarRenameGoesTheSameWayAndReportsOnItsOwnLine() async {
        let engine = Engine(), names = names(engine)
        var lines: [String] = []
        await names.rename(tabId: id, typed: "Docs", report: { lines.append($0) })?.value
        XCTAssertEqual(engine.calls.first?.channel, "session:rename")
        XCTAssertEqual(engine.calls.first?.args, [id, "Docs"])
        XCTAssertEqual(rail(names).item(id: id)?.title, "Docs")
        XCTAssertTrue(lines.isEmpty)
    }

    func testABlankNameIsACancelAsBefore() {
        let engine = Engine(), names = names(engine)
        XCTAssertNil(names.rename(tabId: id, typed: "   "))
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertEqual(rail(names).item(id: id)?.title, "api")
    }

    func testANameIsCutToFortyCharacters() async {
        let engine = Engine(), names = names(engine)
        await names.rename(tabId: id, typed: String(repeating: "word ", count: 20))?.value
        let sent = engine.calls.first?.args.last ?? ""
        XCTAssertLessThanOrEqual(sent.count, SessionTitleRules.maxLength)
        XCTAssertEqual(names.names[id], sent)
    }

    func testAClosedSessionSaysSoAndKeepsItsOldName() async {
        let engine = Engine(), names = names(engine)
        engine.renameAnswer = false
        await names.rename(tabId: id, typed: "Gone")?.value
        XCTAssertEqual(engine.calls.map(\.channel), ["session:rename", "session:list"])
        XCTAssertEqual(rail(names).item(id: id)?.title, "api")
        XCTAssertEqual(names.problem, "That session has closed, so it cannot be renamed.")
    }

    func testAnEngineThatDoesNotAnswerIsAskedAgainThenSaysSoInOneLine() async {
        let engine = Engine(), names = names(engine)
        engine.renameFails = true
        await names.rename(tabId: id, typed: "Later")?.value
        XCTAssertEqual(engine.calls.filter { $0.channel == "session:rename" }.count, NativeSessionNames.tries.count)
        XCTAssertEqual(rail(names).item(id: id)?.title, "Later", "it keeps showing on this Mac")
        XCTAssertEqual(names.problem, "The new name could not be saved. It shows on this Mac for now, but may be lost when the app restarts.")
    }

    func testANewerNameWinsOverOneStillBeingSaved() async {
        let engine = Engine(), names = names(engine)
        engine.renameFails = true
        let first = names.rename(tabId: id, typed: "First")
        engine.renameFails = false
        await names.rename(tabId: id, typed: "Second")?.value
        await first?.value
        XCTAssertEqual(names.names[id], "Second")
        XCTAssertEqual(engine.calls.last?.args, [id, "Second"])
        XCTAssertNil(names.problem)
    }

    func testNamesGivenElsewhereFollowAndClosedSessionsAreForgotten() {
        let engine = Engine(), names = names(engine)
        names.heard(id, title: "From the phone")
        XCTAssertEqual(rail(names).item(id: id)?.title, "From the phone")
        names.heard(id, title: "")
        XCTAssertEqual(rail(names).item(id: id)?.title, "api")
    }

    func testASessionOnAnotherMacGoesToThatMac() async {
        let engine = Engine(), names = names(engine)
        await names.rename(tabId: "machine m1 s1", typed: " Build box ")?.value
        XCTAssertEqual(engine.calls.first?.channel, "machines:session:rename")
        XCTAssertEqual(engine.calls.first?.args, ["m1", "s1", "Build box"])
    }

    func testAServerTerminalSaysItCannotBeRenamed() {
        let engine = Engine(), names = names(engine)
        XCTAssertNil(names.rename(tabId: "server box key", typed: "x"))
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertEqual(names.problem, "A terminal on a server shows the server’s name; it cannot be renamed.")
    }
}
