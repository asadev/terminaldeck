import AppKit
import SwiftUI
import XCTest
#if DRAG_SOURCE_SLICE
@testable import DRAGSource
#else
@testable import TerminalDeckNative
#endif

/// Production handlers and production SwiftUI modifiers; no app composition or event loop.
@objc(DRAGOffscreenTests)
final class DRAGOffscreenTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_WIP"] == "DRAG" else {
            throw XCTSkip("Run the isolated DRAG offscreen stage; do not render in a general app test run.")
        }
    }
    @MainActor func testPaneOutsideDispatchesOnceAndClears() {
        assertOutside(.pane(tabId: "DRAG-pane"))
    }
    @MainActor func testTabOutsideDispatchesOnceAndClears() {
        assertOutside(.tab(tabId: "DRAG-browser"))
    }
    @MainActor private func assertOutside(_ item: NativePaneItem) {
        var actions: [NativePaneItem] = []
        let space = NativePaneDragSpace(openWindow: { actions.append($0) })
        space.setZone("leaf:DRAG-other", token: UUID(), rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        space.update(item: item, title: "DRAG", pointer: CGPoint(x: 10, y: 10), outside: false)
        if case .pane = item { XCTAssertNotNil(space.target, "The outside release must clear the previous reorder target.") }
        space.finish(item: item, title: "DRAG", pointer: CGPoint(x: -10, y: 10), outside: true)
        XCTAssertEqual(actions, [item])
        assertCleared(space)
        space.finish()
        XCTAssertEqual(actions, [item], "A repeated finish without a new drag cannot open twice.")
    }
    @MainActor func testPaneReleaseInsideCancelsStaleOutside() {
        assertInside(.pane(tabId: "DRAG-pane"))
    }
    @MainActor func testTabReleaseInsideCancelsStaleOutside() {
        assertInside(.tab(tabId: "DRAG-browser"))
    }
    @MainActor private func assertInside(_ item: NativePaneItem) {
        var actions: [NativePaneItem] = []
        let space = NativePaneDragSpace(openWindow: { actions.append($0) })
        space.update(item: item, title: "DRAG", pointer: CGPoint(x: -10, y: 10), outside: true)
        space.finish(item: item, title: "DRAG", pointer: CGPoint(x: 10, y: 10), outside: false)
        XCTAssertTrue(actions.isEmpty)
        assertCleared(space)
    }
    @MainActor func testCancelClearsAndCannotDispatch() {
        var actions: [NativePaneItem] = []
        let space = NativePaneDragSpace(openWindow: { actions.append($0) })
        space.update(item: .tab(tabId: "DRAG-tab"), title: "DRAG", pointer: .zero, outside: true)
        space.cancel()
        assertCleared(space)
        space.finish()
        XCTAssertTrue(actions.isEmpty)
    }
    @MainActor private func assertCleared(_ space: NativePaneDragSpace, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(space.item, file: file, line: line)
        XCTAssertNil(space.target, file: file, line: line)
        XCTAssertFalse(space.outside, file: file, line: line)
        XCTAssertFalse(space.isDragging, file: file, line: line)
    }
    @MainActor func testReturnOutsideRejects() {
        var count = 0
        XCTAssertFalse(NativePopoutMerge.finish(pointer: CGPoint(x: 250, y: 50),
            targetFrame: CGRect(x: 0, y: 0, width: 200, height: 100), moveBack: { count += 1 }))
        XCTAssertEqual(count, 0)
    }
    @MainActor func testReturnMissingMainRejects() {
        var count = 0
        XCTAssertFalse(NativePopoutMerge.finish(pointer: CGPoint(x: 50, y: 50),
            targetFrame: nil, moveBack: { count += 1 }))
        XCTAssertEqual(count, 0)
    }
    @MainActor func testReturnInsideCallsOnce() {
        var count = 0
        XCTAssertTrue(NativePopoutMerge.finish(pointer: CGPoint(x: 50, y: 50),
            targetFrame: CGRect(x: 0, y: 0, width: 200, height: 100), moveBack: { count += 1 }))
        XCTAssertEqual(count, 1)
    }
    @MainActor func testPaneRoundTripPreservesRecordedIdentity() { roundTrip(.pane(tabId: "DRAG-pane")) }
    @MainActor func testTabRoundTripPreservesRecordedIdentity() { roundTrip(.tab(tabId: "DRAG-browser")) }

    @MainActor func testStripFinalOutsideReleaseOpensOnceAndResets() {
        var opened: [NativePaneItem] = []
        var saved: [[String]] = []
        let reorder = NativeTabReorder(popOut: { opened.append($0) }, setTabOrder: { saved.append($0) })
        reorder.step = 120; reorder.stripHeight = 40
        reorder.begin("DRAG-a", in: ["DRAG-a", "DRAG-b"])
        reorder.update(translation: 70, pointerY: 20, outsideWindow: false)
        XCTAssertFalse(reorder.popping)
        // This is the final onEnded update, after an inside last movement.
        reorder.update(translation: 70, pointerY: 20, outsideWindow: true)
        reorder.end()
        XCTAssertEqual(opened, [.tab(tabId: "DRAG-a")])
        XCTAssertTrue(saved.isEmpty)
        assertStripCleared(reorder)
        reorder.end()
        XCTAssertEqual(opened, [.tab(tabId: "DRAG-a")])
    }

    @MainActor func testStripFinalInsideReleaseCancelsStaleOutsideAndKeepsOrder() {
        var opened: [NativePaneItem] = []
        var saved: [[String]] = []
        let reorder = NativeTabReorder(popOut: { opened.append($0) }, setTabOrder: { saved.append($0) })
        reorder.step = 120; reorder.stripHeight = 40
        reorder.begin("DRAG-a", in: ["DRAG-a", "DRAG-b"])
        reorder.update(translation: 70, pointerY: 20, outsideWindow: true)
        XCTAssertTrue(reorder.popping)
        reorder.update(translation: 70, pointerY: 20, outsideWindow: false)
        reorder.end()
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(saved, [["DRAG-b", "DRAG-a"]])
        assertStripCleared(reorder)
        reorder.end()
        XCTAssertEqual(saved, [["DRAG-b", "DRAG-a"]])
    }

    @MainActor func testStripFinalReleaseBeyondVerticalBoundaryOpens() {
        var opened: [NativePaneItem] = []
        var saved: [[String]] = []
        let reorder = NativeTabReorder(popOut: { opened.append($0) }, setTabOrder: { saved.append($0) })
        reorder.stripHeight = 40
        reorder.begin("DRAG-a", in: ["DRAG-a", "DRAG-b"])
        reorder.update(translation: 0, pointerY: 20, outsideWindow: false)
        reorder.update(translation: 0, pointerY: 200, outsideWindow: false)
        reorder.end()
        XCTAssertEqual(opened, [.tab(tabId: "DRAG-a")])
        XCTAssertTrue(saved.isEmpty)
        assertStripCleared(reorder)
    }

    @MainActor func testStripFinalReleaseWithinVerticalBoundaryCancelsPopout() {
        var opened: [NativePaneItem] = []
        var saved: [[String]] = []
        let reorder = NativeTabReorder(popOut: { opened.append($0) }, setTabOrder: { saved.append($0) })
        reorder.stripHeight = 40
        reorder.begin("DRAG-a", in: ["DRAG-a", "DRAG-b"])
        reorder.update(translation: 0, pointerY: 200, outsideWindow: false)
        reorder.update(translation: 0, pointerY: 20, outsideWindow: false)
        reorder.end()
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(saved, [["DRAG-a", "DRAG-b"]])
        assertStripCleared(reorder)
    }

    @MainActor private func assertStripCleared(_ reorder: NativeTabReorder, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(reorder.dragID, file: file, line: line)
        XCTAssertEqual(reorder.translation, 0, file: file, line: line)
        XCTAssertFalse(reorder.popping, file: file, line: line)
        XCTAssertTrue(reorder.order.isEmpty, file: file, line: line)
    }

    @MainActor private func roundTrip(_ item: NativePaneItem) {
        // Fake window actions record identity only. This does not claim real window/terminal lifecycle proof.
        final class ContentToken {}
        let original = ContentToken()
        var main: ContentToken? = original
        var detached: ContentToken?
        var opened: [NativePaneItem] = []
        var closed = 0
        let space = NativePaneDragSpace(openWindow: { moving in
            opened.append(moving); detached = main; main = nil
        })
        space.finish(item: item, title: "DRAG", pointer: CGPoint(x: -20, y: 20), outside: true)
        XCTAssertEqual(opened, [item])
        XCTAssertNil(main)
        XCTAssertTrue(detached === original)
        let frame = CGRect(x: 10, y: 10, width: 200, height: 100)
        let returnAction: @MainActor () -> Void = { main = detached; detached = nil; closed += 1 }
        XCTAssertFalse(NativePopoutMerge.finish(pointer: CGPoint(x: -20, y: 20), targetFrame: frame, moveBack: returnAction))
        XCTAssertTrue(detached === original)
        XCTAssertTrue(NativePopoutMerge.finish(pointer: CGPoint(x: 30, y: 30), targetFrame: frame, moveBack: returnAction))
        XCTAssertTrue(main === original)
        XCTAssertNil(detached)
        XCTAssertEqual(closed, 1)
        assertCleared(space)
    }

    @MainActor func testRenderActualModifiersLight() throws { try render(dark: false) }
    @MainActor func testRenderActualModifiersDark() throws { try render(dark: true) }
    @MainActor private func render(dark: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["DRAG_RENDER_OUTPUT"] else {
            throw failure("DRAG_RENDER_OUTPUT is required.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var ancestor = output
        var safe = false
        while ancestor.path != "/" {
            if ancestor.lastPathComponent.hasSuffix(".noindex") { safe = true; break }
            ancestor.deleteLastPathComponent()
        }
        guard safe else { throw failure("Canonical output must have a .noindex ancestor.") }
        let space = NativePaneDragSpace(openWindow: { _ in XCTFail("Rendering must not dispatch.") })
        let fixture = VStack(alignment: .leading, spacing: 20) {
            Label("Session pane", systemImage: "terminal")
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .nativePaneDrag(.pane(tabId: "DRAG-pane"), title: "Session pane")
                .nativePaneDropZone("leaf:DRAG-pane")
            Label("Browser tab", systemImage: "globe")
                .padding(12)
                .nativePaneDrag(.tab(tabId: "DRAG-browser"), title: "Browser tab")
            Label("Detached header: drag back", systemImage: "arrow.uturn.backward")
                .padding(12)
                .nativePopoutDragBack(perform: { XCTFail("Rendering must not return.") })
            Spacer()
        }
        .padding(24)
        .environment(\.paneDragSpace, space)
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: 640, height: 360)
        .background(.background)
        let host = NSHostingView(rootView: fixture)
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        XCTAssertNil(host.window)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No bitmap.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertNil(host.window)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG encoding failed.") }
        let destination = output.appendingPathComponent("DRAG-modifiers-\(dark ? "dark" : "light").png")
        try png.write(to: destination)
        print("DRAG_RENDER \(destination.path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) standalone-host=true")
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "DRAGOffscreen", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
