import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// A scripted scratch run of the production view. No host, provider, saved chat or visible app is started.
@MainActor final class ChatFollowProofTests: XCTestCase {
    private func event(_ sequence: Int, _ record: HootChatRecord, turn: String = "live") -> HootChatEvent {
        .init(conversationID: "follow-proof", turnID: turn, sequence: sequence, provider: .codex, record: record)
    }
    private func snapshot(_ events: [HootChatEvent], busy: Bool) -> NativeRPCValue {
        .object([.init("conversationId", .string("follow-proof")), .init("sequence", .number(Double(events.count))),
            .init("messageActions", .array(BackendChatMessageActions.rows(events, provider: .codex))),
            .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true)), .init("ready", .bool(true)),
            .init("busy", .bool(busy)), .init("unread", .object([.init("count", .number(99)), .init("seenSequence", .number(0))]))])
    }
    private func settle(_ host: NSView) {
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
    private func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, T.self) }
    }
    private var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHAT_FOLLOW_PROOF_OUTPUT"] ?? NSTemporaryDirectory() + "chat-follow-proof.noindex")
    }
    private func capture(_ host: NSView, _ name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
    /// Read actual ink in the final text region; container padding and action rows must not hide a larger gap.
    private func glyphGap(_ host: NSView, _ viewport: NativeChatFollowViewport) throws -> CGFloat {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let text = viewport.latestLine
        let left = max(0, Int((text.minX + 12) * scale))
        let right = min(bitmap.pixelsWide, Int(min(text.maxX - 12, text.minX + 250) * scale))
        let top = max(0, Int(text.minY * scale))
        let bottom = min(bitmap.pixelsHigh, Int(min(text.maxY, viewport.composer.minY) * scale))
        var last: Int?
        if left < right, top < bottom {
            for y in top..<bottom {
                for x in left..<right {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.8, max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.45 { last = y; break }
                }
            }
        }
        return viewport.composer.minY - CGFloat(try XCTUnwrap(last) + 1) / scale
    }
    func testScratchStreamToolsSixLineComposerAndReadingInAllMacChatSizes() throws {
        XCTAssertFalse(EngineBridge.shared.isReady)
        NSApplication.shared.setActivationPolicy(.prohibited)
        var measurements: [String] = []
        for (name, compact, source, size) in [
            ("session", false, HootChatSource.session("follow-proof", provider: "codex"), CGSize(width: 960, height: 760)),
            ("hoot", false, .hoot, CGSize(width: 800, height: 680)),
            ("island", true, .hoot, CGSize(width: 480, height: 580))
        ] {
            var events = (1...18).map { index in event(index, .text(index % 2 == 0 ? .message : .user, id: "old-\(index)", "Earlier message \(index). " + String(repeating: "History stays available. ", count: 3)), turn: "old-\(index)") }
            events.append(event(19, .text(.user, id: "ask", "Explain the result and check its files.")))
            let model = NativeHootChatModel(fixture: snapshot(events, busy: true), chatInvoke: { _, _ in [:] }, source: source)
            let sixLines = (1...6).map { "Draft line \($0)" }.joined(separator: "\n")
            model.composerDraft.text = sixLines
            let host = NSHostingView(rootView: NativeHootChat(model: model, compact: compact)
                .environment(\.agkitOffscreenSolid, true).environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(origin: .init(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            settle(host)
            let viewport = try XCTUnwrap(model.chatViewports.values.first)
            let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            XCTAssertEqual(scroll.verticalScrollElasticity, .none)
            func check(_ stage: String, gap: Bool = true) throws {
                settle(host)
                let state = try model.followTool("read")
                let receipt = state["views"].elements?.first ?? .null
                XCTAssertTrue(viewport.state.atBottom, "\(name) \(stage): at the real end")
                XCTAssertTrue(viewport.following, "\(name) \(stage): follows")
                if gap {
                    let distance = try XCTUnwrap(receipt["lineGap"].number)
                    XCTAssertGreaterThanOrEqual(distance, -0.5, "\(name) \(stage): last line is not behind the box")
                    XCTAssertLessThanOrEqual(distance, 18, "\(name) \(stage): at most one line of space")
                }
                measurements.append(name + " " + stage + " " + receipt.compact)
            }
            try check("start"); try capture(host, name + "-start")
            events.append(event(20, .init(.toolCall, id: "read-tool", value: .object([.init("name", .string("Read")), .init("input", .object([.init("file_path", .string("/scratch/report.txt"))]))]))))
            model.acceptFixtureUpdate(snapshot(events, busy: true)); settle(host)
            for line in 1...30 {
                var streamed = events
                streamed.append(event(21, .text(.textDelta, id: "reply", (1...line).map { "Streamed line \($0): the newest words stay just above the typing box." }.joined(separator: "\n\n"))))
                model.acceptFixtureUpdate(snapshot(streamed, busy: true)); settle(host)
                try check("stream-\(line)")
                if line == 15 { try capture(host, name + "-mid-stream") }
            }
            model.composerDraft.text = sixLines
            try check("six-line-box")
            let beforeReading = viewport.state.offset
            let document = try XCTUnwrap(scroll.documentView)
            let earlier = max(0, viewport.state.offset - viewport.state.viewport * 0.8)
            let y = document.isFlipped ? document.bounds.minY + earlier : document.bounds.maxY - scroll.contentView.bounds.height - earlier
            scroll.contentView.scroll(to: .init(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host)
            let reading = viewport.state.offset
            XCTAssertLessThan(reading, beforeReading)
            XCTAssertFalse(viewport.following)
            model.requestFocus += 1
            settle(host)
            XCTAssertFalse(viewport.following, "Preparing a draft never resumes following")
            XCTAssertEqual(viewport.state.offset, reading, accuracy: 1)
            var final = events
            final.append(event(21, .text(.message, id: "reply", (1...45).map { "Streamed line \($0): the newest words stay just above the typing box." }.joined(separator: "\n\n"))))
            model.acceptFixtureUpdate(snapshot(final, busy: true)); settle(host)
            XCTAssertEqual(viewport.state.offset, reading, accuracy: 1, "Streaming leaves the reader in place")
            try capture(host, name + "-reading")
            model.send(HootComposerDraft(text: "Scratch send while reading"))
            XCTAssertEqual(model.queuedMessages.count, 1, "A real send was accepted by the scratch chat")
            try check("send-resumes", gap: false)
            try capture(host, name + "-send")
            if let queued = model.queuedMessages.first { model.removeQueued(queued.id) }
            model.composerDraft.text = sixLines
            final.append(event(22, .init(.toolResult, id: "read-tool", value: .object([.init("output", .string("The checked file is ready."))]))))
            final.append(event(23, .init(.completed)))
            model.acceptFixtureUpdate(snapshot(final, busy: false)); try check("end")
            try capture(host, name + "-end")
            // A short completed answer leaves the real tool disclosure visible to the person and accessibility.
            var short = final
            if let index = short.firstIndex(where: { $0.sequence == 21 }) {
                short[index] = event(21, .text(.message, id: "reply", "The file check is ready."))
            }
            model.acceptFixtureUpdate(snapshot(short, busy: false)); try check("short-reply")
            let card = try XCTUnwrap(try model.toolCardsTool("read", request: nil)["cards"].elements?.last?["id"].string)
            let foldedHeight = viewport.state.content
            _ = try model.toolCardsTool("expand", request: card, viewID: viewport.id.uuidString)
            try check("tool-expanded")
            XCTAssertGreaterThan(viewport.state.content, foldedHeight, "The production tool card actually expanded")
            try capture(host, name + "-tool-expanded")
            _ = try model.toolCardsTool("collapse", request: card, viewID: viewport.id.uuidString)
            try check("tool-collapsed")
            XCTAssertEqual(viewport.state.content, foldedHeight, accuracy: 1)
            window.setContentSize(.init(width: size.width - 70, height: size.height - 80)); try check("resized")
            // A scroll beyond the end clamps at the content; no blank page can appear.
            scroll.contentView.scroll(to: .init(x: 0, y: 1_000_000)); scroll.reflectScrolledClipView(scroll.contentView); settle(host)
            try check("bottom-clamped")
            XCTAssertLessThanOrEqual(viewport.state.offset, viewport.state.maximumOffset + 0.5)
            // R2 (Asad, 6 Nov): Copy sits below every message, so the last reply's one action row is under its last
            // line on purpose. Beside that row, at most one line of space.
            let actions = HootMessageRow.actionsHeight
            let proseGap = try glyphGap(host, viewport)
            let proseLine = NSLayoutManager().defaultLineHeight(for: NativeChatMarkdown.bodyFont)
            XCTAssertGreaterThanOrEqual(proseGap, 0)
            XCTAssertLessThanOrEqual(proseGap - actions, proseLine)
            measurements.append("\(name) literal-prose gap=\(proseGap) line=\(proseLine)")
            var codeEvents = final
            codeEvents.append(event(24, .text(.user, id: "code-question", "Show the code."), turn: "code"))
            codeEvents.append(event(25, .text(.message, id: "code-answer", "```swift\nlet ready = true\n```"), turn: "code"))
            model.acceptFixtureUpdate(snapshot(codeEvents, busy: false))
            // Finding code uses the production renderer's existing expansion path.
            model.findVisible = true; model.findQuery = "ready"; model.updateFind()
            settle(host)
            _ = try model.followTool("latest")
            try check("completed-code")
            let codeGap = try glyphGap(host, viewport)
            let codeLine = NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: NativeChatMarkdown.bodyFont.pointSize * 0.92, weight: .regular))
            XCTAssertGreaterThanOrEqual(codeGap, 0)
            XCTAssertLessThanOrEqual(codeGap - actions, codeLine)
            measurements.append("\(name) literal-code gap=\(codeGap) line=\(codeLine)")
            try capture(host, name + "-completed-code")
            XCTAssertFalse(window.isVisible)
        }
        try measurements.joined(separator: "\n").write(to: folder.appendingPathComponent("measurements.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
