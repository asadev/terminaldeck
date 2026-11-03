import Foundation
import Testing
@testable import TerminalDeckNativeCore

// The bind menu as data (browser:bind-menu-items), read natively. The engine half is
// browser-binding-menu.test.ts ("the same menu as data").

@Test func bindMenuReadsRowsAndWhatAPressSends() throws {
    let rows = try #require(BindMenuRow.list(CodingAIJSON.parse(#"""
    [{"type":"item","label":"Office PC","enabled":false,"checked":false,"act":null},
     {"type":"checkbox","label":"W1  Docs","enabled":true,"checked":false,"act":{"kind":"bind","tabId":"browser:1:1"}},
     {"type":"checkbox","label":"B1  Mail","enabled":true,"checked":true,"act":{"kind":"unbind","tabId":"browser:1:2"}},
     {"type":"separator","label":"","enabled":false,"checked":false,"act":null},
     {"type":"item","label":"New window, attached","enabled":true,"checked":false,"act":{"kind":"new-window"}},
     {"type":"martian"}, 3]
    """#)))
    #expect(rows.map(\.kind) == [.item, .checkbox, .checkbox, .separator, .item])
    #expect(rows[0].enabled == false && rows[0].act == nil)
    #expect(rows[2].checked && rows[2].act == .unbind(tabId: "browser:1:2"))
    #expect(BindMenuRow.list(.null) == nil)

    let bind = BindMenuRow.command(.bind(tabId: "browser:1:1"), sessionId: "s1", machineId: "")
    #expect(bind.channel == "browser:bind" && bind.arg["tabId"].string == "browser:1:1" && bind.arg["sessionId"].string == "s1")
    #expect(BindMenuRow.command(.unbind(tabId: "browser:1:2"), sessionId: "s1", machineId: "").arg == .string("browser:1:2"))
    #expect(BindMenuRow.command(.newWindow, sessionId: "s1", machineId: "pc").channel == "browser:bind-new-window")
}

@Test func bindMenuKeysARowTheWayBindKeyDoes() {
    #expect(BindMenuRow.key(tabId: "s1", server: nil)! == ("s1", ""))
    #expect(BindMenuRow.key(tabId: "machine pc r1", server: nil)! == ("r1", "pc"))
    let open = ServerTabInfo(serverId: "box", serverName: "Box", shellKey: "k", startIn: nil, run: nil, shellId: "sh-1")
    #expect(BindMenuRow.key(tabId: "server:box:k", server: open)! == ("sh-1", "box"))
    let closed = ServerTabInfo(serverId: "box", serverName: "Box", shellKey: "k", startIn: nil, run: nil, shellId: nil)
    #expect(BindMenuRow.key(tabId: "server:box:k", server: closed) == nil)
}
