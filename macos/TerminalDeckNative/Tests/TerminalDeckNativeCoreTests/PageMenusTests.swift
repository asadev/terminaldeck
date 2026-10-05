import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Page scripts")
struct PageScriptTests {
    @Test func valuesAreWrittenAsJavaScriptLiterals() {
        #expect(PageValue.number(3).literal == "3")
        #expect(PageValue.number(-2.5).literal == "-2.5")
        #expect(PageValue.number(.nan).literal == "null")
        #expect(PageValue.bool(true).literal == "true")
        #expect(PageValue.null.literal == "null")
        #expect(PageValue.string("a\"b</script>").literal == "\"a\\\"b\\u003C/script>\"")
        #expect(PageValue.object([("b", .number(1)), ("a", .array([.string("x"), .null]))]).literal
                == "{\"b\":1,\"a\":[\"x\",null]}")
    }

    @Test func runWithAndWithoutAnArgument() {
        #expect(PageScript.run("x") == "window.tdNative && window.tdNative.run('x')")
        #expect(PageScript.run("x", .bool(false)) == "window.tdNative && window.tdNative.run('x', false)")
    }
}

@Suite("Context menu message")
struct ContextMenuTests {
    private func menu(_ items: Any?, id: Any? = "m1", x: Any? = 40, y: Any? = 12.5) -> [String: Any] {
        var body: [String: Any] = ["type": "context-menu"]
        if let id { body["id"] = id }
        if let x { body["x"] = x }
        if let y { body["y"] = y }
        if let items { body["items"] = items }
        return body
    }

    private func shown(_ body: [String: Any]) -> ContextMenuRequest? {
        guard case .show(let request)? = ContextMenuRequest.parse(body) else { return nil }
        return request
    }

    @Test func decodesRowsSeparatorsChecksAndSubmenus() throws {
        let request = try #require(shown(menu([
            ["id": "copy", "label": "Copy", "enabled": true],
            ["id": "paste", "label": "Paste", "enabled": false],
            ["separator": true],
            ["id": "wrap", "label": "Wrap Lines", "enabled": true, "checked": true],
            ["id": "more", "label": "Move to", "enabled": true, "submenu": [
                ["id": "w1", "label": "Window 1", "enabled": true],
            ]],
        ])))
        #expect(request.id == "m1")
        #expect(request.x == 40)
        #expect(request.y == 12.5)
        #expect(request.items.count == 5)
        #expect(request.items[0] == ContextMenuItem(id: "copy", label: "Copy"))
        #expect(request.items[1].enabled == false)
        #expect(request.items[2].isSeparator)
        #expect(request.items[3].checked)
        #expect(request.items[4].submenu == [ContextMenuItem(id: "w1", label: "Window 1")])
        #expect(request.items[4].enabled)
    }

    @Test func separatorsNeverLeadTrailOrRepeat() throws {
        let request = try #require(shown(menu([
            ["separator": true],
            ["id": "a", "label": "A", "enabled": true],
            ["separator": true],
            ["separator": true],
            ["id": "b", "label": "B", "enabled": true],
            ["separator": true],
        ])))
        #expect(request.items.map(\.isSeparator) == [false, true, false])
    }

    @Test func aRequestWithNoIdIsNotAnswered() {
        #expect(ContextMenuRequest.parse(menu([["id": "a", "label": "A"]], id: nil)) == nil)
        #expect(ContextMenuRequest.parse(menu([["id": "a", "label": "A"]], id: "")) == nil)
        #expect(ContextMenuRequest.parse(menu([["id": "a", "label": "A"]], id: 7)) == nil)
        #expect(ContextMenuRequest.parse(["type": "open-link", "id": "m1"]) == nil)
        #expect(ContextMenuRequest.parse("context-menu") == nil)
    }

    @Test func nothingShowableIsAnsweredAsDismissed() {
        #expect(ContextMenuRequest.parse(menu([])) == .dismissOnly(id: "m1"))
        #expect(ContextMenuRequest.parse(menu(nil)) == .dismissOnly(id: "m1"))
        #expect(ContextMenuRequest.parse(menu([["separator": true]])) == .dismissOnly(id: "m1"))
        #expect(ContextMenuRequest.parse(menu([["id": "a", "label": "  "]])) == .dismissOnly(id: "m1"))
        #expect(ContextMenuRequest.parse(menu([["id": "a", "label": "A"]], x: "40")) == .dismissOnly(id: "m1"))
        #expect(ContextMenuRequest.parse(menu([["id": "a", "label": "A"]], y: Double.nan)) == .dismissOnly(id: "m1"))
    }

    @Test func flagsAreRealBooleans() throws {
        let request = try #require(shown(menu([
            ["id": "a", "label": "A", "enabled": 0, "checked": "yes"],
            ["id": "b", "label": "B", "enabled": false, "checked": 1],
        ])))
        #expect(request.items[0].enabled)      // 0 is not false: default (enabled)
        #expect(!request.items[0].checked)     // "yes" is not true
        #expect(!request.items[1].enabled)
        #expect(!request.items[1].checked)
    }

    @Test func aRowWithoutAnIdCannotBeChosen() throws {
        let request = try #require(shown(menu([["label": "Orphan"], ["id": "a", "label": "A"]])))
        #expect(request.items[0].label == "Orphan")
        #expect(!request.items[0].enabled)
    }

    @Test func labelsAreOneShortLine() throws {
        let request = try #require(shown(menu([
            ["id": "a", "label": "  Two\nlines  "],
            ["id": "b", "label": String(repeating: "x", count: 500)],
        ])))
        #expect(request.items[0].label == "Two lines")
        #expect(request.items[1].label.count == ContextMenuRequest.maxLabel)
    }

    @Test func nestingAndSizeAreBounded() throws {
        func nest(_ depth: Int) -> [String: Any] {
            depth == 0 ? ["id": "leaf", "label": "Leaf"] : ["id": "n\(depth)", "label": "Level \(depth)", "submenu": [nest(depth - 1)]]
        }
        let deep = try #require(shown(menu([nest(6)])))
        var level = deep.items[0]
        var depth = 1
        while let child = level.submenu?.first { level = child; depth += 1 }
        #expect(depth == ContextMenuRequest.maxDepth)
        #expect(level.submenu == [])
        #expect(!level.enabled)

        let many = (0..<1000).map { ["id": "i\($0)", "label": "Item \($0)"] }
        #expect(try #require(shown(menu(many))).items.count == ContextMenuRequest.maxItems)
    }

    @Test func resultCarriesTheChosenIdOrNull() {
        #expect(ContextMenuRequest.resultScript(id: "m1", itemId: "copy")
                == "window.tdNative && window.tdNative.run('context-menu-result', {\"id\":\"m1\",\"itemId\":\"copy\"})")
        #expect(ContextMenuRequest.resultScript(id: "m1", itemId: nil)
                == "window.tdNative && window.tdNative.run('context-menu-result', {\"id\":\"m1\",\"itemId\":null})")
        #expect(ContextMenuRequest.resultScript(id: "a'b\"c", itemId: nil).contains("\"a'b\\\"c\""))
    }

    @Test func theMainWindowsOwnMessagesIgnoreIt() {
        #expect(PageMessage.parse(menu([["id": "a", "label": "A"]])) == nil)
        #expect(ContextMenuRequest.isContextMenuMessage(menu(nil, id: nil)))
    }
}
