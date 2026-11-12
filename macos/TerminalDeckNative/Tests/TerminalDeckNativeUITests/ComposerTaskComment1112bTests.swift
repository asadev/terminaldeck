import AppKit
import SwiftUI
import TerminalDeckNativeCore
import XCTest
@testable import TerminalDeckNative

/// The production Composer → CommentAddPanel → SchedulePanel tree, using only an inert
/// task transport and an offscreen window. No app, popover, chooser, or backend is opened.
@MainActor final class ComposerLeak1112bTaskCommentTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @MainActor final class Calls {
        struct Write {
            let name: String
            let arguments: [NativeRPCValue]
        }
        var writes: [Write] = []
        var holdFirstWrite = false
        var pending: CheckedContinuation<NativeRPCValue, Never>?
        var readsAfterPost = 0

        static var ok: NativeRPCValue { .object([.init("ok", .bool(true))]) }

        func invoke(_ name: String, _ arguments: [NativeRPCValue]) async -> NativeRPCValue {
            if name == "addTaskComment" || name == "addTaskCommentWith" {
                writes.append(.init(name: name, arguments: arguments))
                if holdFirstWrite {
                    holdFirstWrite = false
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

    private func model(_ calls: Calls, id: String = "task-comment-fixture") -> TaskDetailModel {
        let row = TaskRow(id: id, keyId: "local", externalTaskId: id, title: "Fixture task",
                          project: "/scratch/comment-rule", local: true, assignee: "builder", instructions: "Fixture only")
        let transport = NativeFIXESTaskThreadTransport(invoke: { await calls.invoke($0, $1) }, observe: { _ in .init {} })
        return TaskDetailModel(row: row, agents: [], threadTransport: transport, loadOnOpen: false)
    }

    private func mount(_ model: TaskDetailModel, fixture: NativeTaskCommentFixture) -> (NSHostingView<AnyView>, ScratchWindow) {
        let commands = [SlashCommand(key: "fixture", group: "TASK ACTIONS", label: "Fixture command", icon: "checkmark", run: {})]
        let composer = Composer(model: model, commands: commands, onAttach: { _ in [] }, fixtureMode: true, fixture: fixture)
        let host = NSHostingView(rootView: AnyView(composer.frame(width: 680)))
        let window = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: 720, height: 950),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        return (host, window)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The inert comment callback did not complete")
    }

    func testRetainedActualTaskPanelRejectsHiddenSearchScheduleAndComposerSend() async throws {
        let calls = Calls()
        let task = model(calls)
        let fixture = NativeTaskCommentFixture(draft: .init(text: "This task's own comment"))
        let (host, window) = mount(task, fixture: fixture)
        defer { window.contentView = nil; window.close() }
        let scope = try XCTUnwrap(fixture.inputScope)
        let schedule = try XCTUnwrap(fixture.schedule)
        let send = try XCTUnwrap(fixture.send)
        let search = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionTextControl }
            .first { $0.placeholderString == "Search" }, "The actual supplied panel contains the guarded command search")
        XCTAssertTrue(window.makeFirstResponder(search))
        let oldClient = try XCTUnwrap(search.currentEditor() as? NativeSessionTextView)
        XCTAssertTrue(window.firstResponder === oldClient)
        let before = search.stringValue
        // No SwiftUI view is rerendered before these late callbacks: the presentation
        // retains its old environment, while its shared owner scope closes immediately.
        scope.setActive(false)
        oldClient.insertText("wrong task command", replacementRange: NSRange(location: NSNotFound, length: 0))
        oldClient.setMarkedText("wrong marked command", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        oldClient.setAccessibilityValue("wrong command accessibility")
        schedule(Date().addingTimeInterval(7200))
        send(.init(text: "Wrong hidden direct send"))
        settle(host)
        XCTAssertEqual(search.stringValue, before)
        XCTAssertEqual(oldClient.string, before)
        XCTAssertFalse(oldClient.hasMarkedText())
        XCTAssertFalse(window.firstResponder === oldClient)
        XCTAssertTrue(calls.writes.isEmpty, "Neither retained Schedule nor Composer.send may begin a hidden post")
        scope.setActive(true)
        settle(host)
        let restoredSchedule = try XCTUnwrap(fixture.schedule)
        restoredSchedule(Date().addingTimeInterval(7200))
        try await waitUntil { calls.writes.count == 1 && calls.readsAfterPost > 0 }
        XCTAssertEqual(calls.writes.first?.name, "addTaskCommentWith")
        XCTAssertEqual(calls.writes.first?.arguments.first?.string, task.taskId)
        XCTAssertEqual(calls.writes.first?.arguments.dropFirst().first?.string, "This task's own comment")
        XCTAssertNotNil(calls.writes.first?.arguments.dropFirst(2).first?["scheduledFor"].string)
    }

    func testAlreadyAcceptedScheduleFinishesAfterItsTaskHides() async throws {
        let calls = Calls()
        calls.holdFirstWrite = true
        let task = model(calls)
        let fixture = NativeTaskCommentFixture(draft: .init(text: "Accepted before switching"))
        let (host, window) = mount(task, fixture: fixture)
        defer { calls.finish(); window.contentView = nil; window.close() }
        let schedule = try XCTUnwrap(fixture.schedule)
        schedule(Date().addingTimeInterval(3600))
        try await waitUntil { calls.pending != nil }
        XCTAssertEqual(calls.writes.count, 1)
        try XCTUnwrap(fixture.inputScope).setActive(false)
        calls.finish()
        try await waitUntil { calls.readsAfterPost > 0 }
        XCTAssertEqual(calls.writes.count, 1, "Visibility does not cancel or duplicate an already-started model post")
        XCTAssertEqual(calls.writes.first?.arguments.dropFirst().first?.string, "Accepted before switching")
        XCTAssertNil(task.error)
    }

    func testExplicitModelPostRemainsAvailableWhileTaskComposerIsHidden() async throws {
        let calls = Calls()
        let task = model(calls)
        let fixture = NativeTaskCommentFixture(draft: .init(text: "UI draft stays separate"))
        let (host, window) = mount(task, fixture: fixture)
        defer { window.contentView = nil; window.close() }
        try XCTUnwrap(fixture.inputScope).setActive(false)
        let posted = await task.postCommentDraft(.init(text: "Explicit model operation"), attachmentIDs: [],
                                                assignee: nil, scheduledFor: nil)
        XCTAssertTrue(posted)
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.writes.first?.name, "addTaskComment")
        XCTAssertEqual(calls.writes.first?.arguments.dropFirst().first?.string, "Explicit model operation")
    }
    func testActualScheduleDateEditorReleasesKeyboardAndRejectsHiddenDateChanges() throws {
        let calls = Calls()
        let fixture = NativeTaskCommentFixture(draft: .init(text: "Date editor fixture"))
        let (host, window) = mount(model(calls), fixture: fixture)
        defer { window.contentView = nil; window.close() }
        let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSDatePicker }.first)
        XCTAssertTrue(picker is any NativeSessionInputProtected)
        XCTAssertTrue(window.makeFirstResponder(picker))
        let oldResponder = try XCTUnwrap(window.firstResponder)
        let before = picker.dateValue
        try XCTUnwrap(fixture.inputScope).setActive(false)
        settle(host)
        XCTAssertFalse(window.firstResponder === oldResponder)
        XCTAssertFalse(picker.isEnabled)
        picker.dateValue = before.addingTimeInterval(3600)
        picker.setAccessibilityValue(before.addingTimeInterval(7200))
        XCTAssertEqual(picker.dateValue, before)
        XCTAssertTrue(calls.writes.isEmpty)
        try XCTUnwrap(fixture.inputScope).setActive(true)
        settle(host)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(picker))
    }

}
