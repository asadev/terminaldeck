import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Asad, 12 Oct: "I can't rename sessions like before. If I edit and apply, it does not work."
@Suite("Session names: shown at once, kept in the saved launch")
struct SessionNamesTests {
    private let id = "7f1c2a9e-0c55-4c1e-9d4e-1f2a3b4c5d6e"

    private var rail: SidebarState {
        SidebarState(groups: [SidebarGroup(id: "main", title: nil, items: [SidebarItem(id: "tasks", title: "Tasks", kind: .panel)])],
                     projects: [SidebarProject(id: "/work/api", title: "api", expanded: true,
                                               sessions: [SidebarItem(id: id, title: "api", kind: .session, status: "working", subtitle: "Claude")])],
                     selectedId: id)
    }

    @Test func aNamedSessionsRowAndTabShowTheName() {
        let named = SessionNames.applied([id: "API work"], to: rail)
        let row = named.item(id: id)
        #expect(row?.title == "API work")
        #expect(row?.status == "working" && row?.subtitle == "Claude" && row?.kind == .session)
        #expect(named.item(id: "tasks")?.title == "Tasks")
        #expect(named.selectedId == id)
        // The session bar reads the rail's row first.
        #expect(TerminalHeader.make(info: nil, railTitle: row?.title, status: nil, ended: false).title == "API work")

        let strip = TabsState(tabs: [TabItem(id: id, title: "api", kind: "session", active: true),
                                     TabItem(id: "b1", title: "Docs", kind: "browser")], canNewTerminal: true, canNewBrowser: true)
        let tabs = SessionNames.applied([id: "API work", "b1": "x"], to: strip)
        #expect(tabs.tabs.map(\.title) == ["API work", "Docs"])
        #expect(tabs.tabs.first?.active == true)
    }

    @Test func noNameOrABlankOneLeavesThePagesOwn() {
        #expect(SessionNames.applied([:], to: rail) == rail)
        #expect(SessionNames.applied([id: "  "], to: rail).item(id: id)?.title == "api")
    }

    @Test func aNameOutlivesItsLaunchBeingNotedAgain() throws {
        let saved: [NativeRPCValue.Field] = [.init("cwd", .string("/work/api")), .init("provider", .string("claude")), .init("tabKey", .string("k1"))]
        // The previous run left the tab with its name.
        var ledger = try NativeOpenSessionLedger(saved: [.object(saved + [.init("title", .string("API work"))])])
        // Restored (or adopted from the helper) under a new id: the launch is written again without the name.
        try ledger.note("s-new", saved: .object(saved))
        #expect(ledger.get("s-new")?["title"].string == "API work")
        #expect(ledger.snapshot().count == 1)
        // Noted again at the next start: still named.
        try ledger.note("s-new", saved: .object(saved + [.init("cols", .number(90))]))
        #expect(ledger.get("s-new")?["title"].string == "API work")
        // A rename to blank forgets it, and a later note does not bring it back.
        try ledger.update("s-new", patch: .object([.init("title", .null)]))
        try ledger.note("s-new", saved: .object(saved))
        #expect(ledger.get("s-new")?["title"].string == nil)
    }

    @Test func savedLaunchesWithoutANameAreUnchanged() throws {
        let saved = NativeRPCValue.object([.init("cwd", .string("/w")), .init("provider", .string("shell")), .init("tabKey", .string("k2"))])
        var ledger = try NativeOpenSessionLedger(saved: [saved])
        try ledger.note("s1", saved: saved)
        #expect(ledger.get("s1") == saved)
    }
}
