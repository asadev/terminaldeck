#if DEBUG
import AppKit
import SwiftUI
import WebKit
import TerminalDeckNativeCore

/// A deterministic assistant reply in the actual chat view, in the dev window
/// only. It makes the one visual check independent of an AI's word choices.
@MainActor enum DevRichChatPreview {
    private static var original: NSView?
    static func show() throws -> Any {
        guard ProcessInfo.processInfo.environment["TD_NATIVE_DATA_DIR"]?.contains("Terminal Deck Dev-0213") == true,
              let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else {
            throw NativeRPCError.invalidArguments("Use the isolated Dev-0213 window for this preview.")
        }
        let text = """
        ### Rich chat
        | Feature | Mac | Phone | Readable detail | Source | Status |
        | --- | --- | --- | --- | --- | --- |
        | Wide Markdown table columns | Native layout in the Mac chat | Identical source sent to the phone | Columns keep space and scroll inside this message. | Original Markdown kept for agents | Ready for review in the dev copy |

        1. Native text and **bold** labels
           - Nested list
           - [x] Checked item

        ```visual
        <style>.bars{display:flex;align-items:end;gap:18px;height:100px}.bar{width:100px;background:var(--accent);border-radius:8px 8px 0 0;display:flex;align-items:center;justify-content:center;color:var(--background)}p{margin:6px}</style>
        <strong>Weekly activity</strong><div class="bars"><div class="bar" style="height:40%">Mon 4</div><div class="bar" style="height:70%">Tue 7</div><div class="bar" style="height:95%">Wed 9</div></div>
        ```

        ```mermaid
        flowchart LR
          A[Message] --> B[Mac renderer]
          B --> C[Phone feed]
        ```
        """
        let records: [HootChatRecord] = [.text(.user, id: "render-mac-user", "Show a wide table, a nested list, a visual chart and a diagram."),
            .text(.message, id: "render-mac-answer", text), .init(.completed)]
        let events = records.enumerated().map { HootChatEvent(conversationID: "render-mac-preview", turnID: "render-mac-turn", sequence: $0.offset + 1, provider: .codex, record: $0.element) }
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("render-mac-preview")), .init("provider", .string("codex")),
            .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true)), .init("busy", .bool(false))]), source: .session("render-mac-preview", provider: "codex"))
        if original == nil { original = window.contentView }
        window.contentView = NSHostingView(rootView: NativeHootChat(model: model).frame(minWidth: 1050, minHeight: 1000).background(Color(nsColor: .windowBackgroundColor)))
        window.setContentSize(NSSize(width: 1180, height: 1120))
        window.orderBack(nil)
        return ["scratchMessages": 2, "assistantMessages": 1, "seededAssistantReply": true,
            "blocks": ChatMarkdown.renderedBlocks(text).foundation ?? [], "behindOtherWindows": true] as [String: Any]
    }
    static func status() async throws -> Any {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), let root = window.contentView else { throw NativeRPCError.invalidArguments("No dev preview is open.") }
        func pages(_ view: NSView) -> [WKWebView] {
            if let page = view as? WKWebView { return [page] }
            return view.subviews.flatMap(pages)
        }
        var results: [[String: Any]] = []
        for page in pages(root) {
            let status = try? await page.evaluateJavaScript("window.__tdChatStatus || null")
            results.append(["status": status ?? NSNull(), "width": page.bounds.width, "height": page.bounds.height])
        }
        return ["pages": results, "pageCount": results.count]
    }
    static func restore() -> Any {
        if let original, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) { window.contentView = original }
        original = nil
        return ["restored": true]
    }
}
#endif
