import Foundation
import Testing
@testable import TerminalDeckNative

/// #87: the island types a menu number only for a real CLI permission menu, and only while that same menu still waits.
@MainActor @Test
func PermissionDeskReadsARealMenuButNotANumberedListInAnAnswer() {
    let menu = """
    ⏺ Bash(rm -rf build)
      Remove the build folder
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for rm commands in this folder
       3. No, and tell Claude what to do differently (esc)
    """
    let read = NativePermissionDesk.permissionMenu(in: menu)
    #expect(read?.options.map(\.id) == ["1", "2", "3"])
    #expect(read?.question.contains("Do you want to proceed?") == true)

    // Claude's idle notification while its answer ends in a numbered Yes/No list: no menu, nothing to type.
    let answer = """
    ⏺ Two ways forward:
      1. Yes, migrate the database now
      2. No, keep the old schema
    ╭──────────────────────────────╮
    │ >                            │
    ╰──────────────────────────────╯
      ? for shortcuts
    """
    #expect(NativePermissionDesk.permissionMenu(in: answer) == nil)
    // The same list with nothing below it still has no selection mark: not a menu either.
    #expect(NativePermissionDesk.permissionMenu(in: "  1. Yes, migrate\n  2. No, keep it\n") == nil)
}

@MainActor @Test
func PermissionDeskAnswersOnlyTheSameMenuStillWaiting() throws {
    let first = try #require(NativePermissionDesk.permissionMenu(in: " Run npm test?\n ❯ 1. Yes\n   2. No\n"))
    let item = NativePermissionDesk.Item(id: "session:s1", source: .session("s1"), asker: "s1", what: first.question, options: first.options, at: .now)
    #expect(NativePermissionDesk.sameMenu(first, as: item))
    // The CLI moved on to another question: the old card's key is not typed into it.
    let next = try #require(NativePermissionDesk.permissionMenu(in: " Delete the cache?\n ❯ 1. Yes\n   2. No\n"))
    #expect(!NativePermissionDesk.sameMenu(next, as: item))
}
