import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckNative
@testable import TerminalDeckNativeCore

/// Actual feed cards, ReplyBox and native button targets, with an inert task transport.
/// No app singleton, provider, session, clipboard, popover or stored data is used.
@MainActor final class ComposerLeak1112bTaskFeedTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @MainActor final class Calls {
        struct Write { let name: String; let arguments: [NativeRPCValue] }
        var writes: [Write] = []
        var readsAfterPost = 0
        var holdPost = false
        var pending: CheckedContinuation<NativeRPCValue, Never>?
        static var ok: NativeRPCValue { .object([.init("ok", .bool(true))]) }

        func invoke(_ name: String, _ arguments: [NativeRPCValue]) async -> NativeRPCValue {
            if ["addTaskComment", "addTaskCommentWith", "sendScheduledNow"].contains(name) {
                writes.append(.init(name: name, arguments: arguments))
                if holdPost {
                    holdPost = false
                    return await withCheckedContinuation { pending = $0 }
                }
            } else if !writes.isEmpty { readsAfterPost += 1 }
            return Self.ok
        }

        func finish() {
            let continuation = pending
            pending = nil
            continuation?.resume(returning: Self.ok)
        }
    }

    private func model(_ calls: Calls) -> TaskDetailModel {
        let row = TaskRow(id: "feed-submit-fixture", keyId: "local", externalTaskId: "feed-submit-fixture",
                          title: "Fixture task", project: "/scratch/feed-submit-rule", local: true,
                          instructions: "Fixture only")
        let transport = NativeFIXESTaskThreadTransport(invoke: { await calls.invoke($0, $1) }, observe: { _ in .init {} })
        return TaskDetailModel(row: row, agents: [], threadTransport: transport, loadOnOpen: false)
    }

    private struct FeedCard: View {
        let model: TaskDetailModel
        let comment: TaskComment
        @State var replyingTo: String?
        var body: some View {
            CommentCard(model: model, comment: comment, replies: [], replyingTo: $replyingTo)
                .frame(width: 650)
        }
    }

    private func mount(_ model: TaskDetailModel, reply: Bool, scheduled: Bool = false)
        -> (NSHostingView<AnyView>, ScratchWindow, NativeSessionInputScope) {
        let comment = TaskComment(id: "parent-comment", taskId: model.taskId, authorUserId: model.me,
                                  authorName: "You", authorInitials: "YO", authorColor: "blue",
                                  body: "The parent comment", createdAt: "2026-11-12T06:00:00Z")
        model.commentExtras = CommentExtras(meta: scheduled ? [comment.id: CommentMeta(
            scheduledFor: "2099-01-01T12:00:00Z", deliveredAt: .some(nil))] : [:], reactions: [:])
        let scope = NativeSessionInputScope()
        let view = FeedCard(model: model, comment: comment, replyingTo: reply ? comment.id : nil)
            .environment(\.nativeSessionInputScope, scope)
        let host = NSHostingView(rootView: AnyView(view))
        let window = ScratchWindow(contentRect: .init(x: -32000, y: -32000, width: 700, height: 950),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        return (host, window, scope)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func property(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(implementation, to: Getter.self)(object, selector)
    }

    /// SwiftUI publishes its accessibility elements only after an assistive client has asked
    /// the app for them. A test process has none (no VoiceOver, no UI automation), so the walk
    /// found no buttons at all. Ask on its behalf, the way an assistive client does.
    private func enableAccessibilityTree() {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }
    /// Keep the native target/selector, not a test-created callback or a SwiftUI view value.
    /// Calling the target also covers late activation after native enabled state changes.
    private func retainAction(_ identifier: String, in root: NSView) throws -> () -> Void {
        enableAccessibilityTree()
        settle(root)
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = (property(object, "accessibilityChildren") as? [NSObject] ?? [])
                + ((object as? NSView)?.subviews ?? [])
            return [object] + children.flatMap(walk)
        }
        let nodes = walk(root)
        let node = try XCTUnwrap(nodes.first {
            property($0, "accessibilityIdentifier") as? String == identifier
                && ($0 is NSButton || $0.responds(to: NSSelectorFromString("accessibilityPerformPress")))
        }, "The actual feed must expose its native submit action: \(identifier)")
        if let button = node as? NSButton, let target = button.target as? NSObject,
           let selector = button.action, let implementation = target.method(for: selector) {
            typealias Action = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let invoke = unsafeBitCast(implementation, to: Action.self)
            return { invoke(target, selector, button) }
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(node.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let invoke = unsafeBitCast(implementation, to: Press.self)
        return { _ = invoke(node, selector) }
    }

    private func fillReply(_ body: String, in host: NSView, window: NSWindow) throws {
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? TaskRichText.RichTextView }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText(body, replacementRange: .init(location: 0, length: editor.string.utf16.count))
        settle(host)
        XCTAssertEqual(editor.string, body)
    }

    private func drain() async { for _ in 0..<20 { await Task.yield() } }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ComposerTaskFeedFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The inert task operation did not finish"])
    }

    func testRetainedActualReplySubmitRejectsHiddenPostThenVisibleAndExplicitHiddenPostsWork() async throws {
        let calls = Calls()
        let task = model(calls)
        let (host, window, scope) = mount(task, reply: true)
        defer { window.contentView = nil; window.close() }
        try fillReply("This task's reply", in: host, window: window)
        let submit = try retainAction("task-reply-submit", in: host)
        scope.setActive(false)
        submit()
        await drain()
        XCTAssertTrue(calls.writes.isEmpty, "A retained native Reply action cannot start a hidden task post")

        scope.setActive(true)
        settle(host)
        let visibleSubmit = try retainAction("task-reply-submit", in: host)
        visibleSubmit()
        try await waitFor { calls.writes.count == 1 && calls.readsAfterPost > 0 }
        XCTAssertEqual(calls.writes.first?.name, "addTaskCommentWith")
        XCTAssertEqual(calls.writes.first?.arguments.first?.string, task.taskId)
        XCTAssertEqual(calls.writes.first?.arguments.dropFirst().first?.string, "This task's reply")
        XCTAssertEqual(calls.writes.first?.arguments.dropFirst(2).first?["parentId"].string, "parent-comment")

        scope.setActive(false)
        let explicitPost = await task.postComment("Explicit hidden model reply", parentId: "parent-comment")
        XCTAssertTrue(explicitPost)
        XCTAssertEqual(calls.writes.count, 2)
        XCTAssertEqual(calls.writes.last?.arguments.dropFirst().first?.string, "Explicit hidden model reply")
    }

    func testRetainedActualSendNowRejectsHiddenActivationButExplicitHiddenSendStillWorks() async throws {
        let calls = Calls()
        let task = model(calls)
        let (host, window, scope) = mount(task, reply: false, scheduled: true)
        defer { window.contentView = nil; window.close() }
        let sendNow = try retainAction("task-comment-send-now", in: host)
        scope.setActive(false)
        sendNow()
        await drain()
        XCTAssertTrue(calls.writes.isEmpty, "A late native action cannot publish a hidden scheduled comment early")

        scope.setActive(true)
        settle(host)
        let visibleSendNow = try retainAction("task-comment-send-now", in: host)
        visibleSendNow()
        try await waitFor { calls.writes.count == 1 && calls.readsAfterPost > 0 }
        XCTAssertEqual(calls.writes.first?.name, "sendScheduledNow")
        XCTAssertEqual(calls.writes.first?.arguments.map(\.string), [task.taskId, "parent-comment"])
        scope.setActive(false)
        task.sendNow("parent-comment")
        try await waitFor { calls.writes.count == 2 }
        XCTAssertEqual(calls.writes.last?.name, "sendScheduledNow")
    }

    func testReplyAcceptedBeforeHideFinishesForItsCapturedTask() async throws {
        let calls = Calls()
        calls.holdPost = true
        let task = model(calls)
        let (host, window, scope) = mount(task, reply: true)
        defer { calls.finish(); window.contentView = nil; window.close() }
        try fillReply("Accepted before switching", in: host, window: window)
        let submit = try retainAction("task-reply-submit", in: host)
        submit()
        try await waitFor { calls.pending != nil }
        scope.setActive(false)
        calls.finish()
        try await waitFor { calls.readsAfterPost > 0 }
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.writes.first?.arguments.first?.string, task.taskId)
        XCTAssertEqual(calls.writes.first?.arguments.dropFirst().first?.string, "Accepted before switching")
    }
}
