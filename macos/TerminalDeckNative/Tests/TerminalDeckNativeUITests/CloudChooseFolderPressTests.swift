import AppKit
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Proof 3 (13 Nov), defect 2: "Choose folder…" on the Cloud page did nothing on five presses while the Settings window
/// was not the main window. The press passed the remote-input guard; the picker was decided later, in a task, and
/// opened as a free panel that never came forward. It is now taken at the press and opens as a sheet on the window
/// that was clicked. No panel is shown here.
@Suite("Cloud page — Choose folder… opens on the window that was clicked")
@MainActor
struct CloudChooseFolderPressTests {
    @Test func thePickerBelongsToTheClickedWindowNotTheMainOne() {
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let main = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(NativeCompositionFolderPicker.pressWindow(event: settings, key: main) === settings)
        #expect(NativeCompositionFolderPicker.pressWindow(event: nil, key: settings) === settings)
        #expect(NativeCompositionFolderPicker.pressWindow(event: nil, key: nil) == nil)
        // A window that already shows a sheet (or is not on screen) gets the free panel instead.
        #expect(NativeCompositionFolderPicker.canHostSheet(visible: true, hasSheet: false))
        #expect(!NativeCompositionFolderPicker.canHostSheet(visible: true, hasSheet: true))
        #expect(!NativeCompositionFolderPicker.canHostSheet(visible: false, hasSheet: false))
    }
    @Test func theWindowAndThePersonAreTakenAtThePressAndTheGuardStays() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let records = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudRecords.swift"), encoding: .utf8)
        let body = try #require(records.range(of: "private func chooseFolder(").map { String(records[$0.lowerBound...].prefix(1200)) })
        let task = try #require(body.range(of: "Task {"))
        let window = try #require(body.range(of: "NSApp.currentEvent?.window"))
        let acting = try #require(body.range(of: "NativeFront.personActing"))
        #expect(window.lowerBound < task.lowerBound && acting.lowerBound < task.lowerBound)
        #expect(body.contains("pick(nil, on: window, acting: acting)"))
        // The remote-input guard is unchanged: the button still goes through the page press.
        let overview = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudOverview.swift"), encoding: .utf8)
        #expect(overview.contains("pagePress(model: model) { choose(projectId) }"))
    }
}
