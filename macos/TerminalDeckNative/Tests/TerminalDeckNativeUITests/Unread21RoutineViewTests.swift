import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class Unread21RoutineViewTests: XCTestCase {
    private func snapshot(seen: Int) -> CodingAIJSON {
        let rows: [NativeRPCValue] = [("old", "report", "The earlier report stays above."),
            ("question", "question", "How did the inbox work go?"),
            ("first", "answer", "The inbox changes are ready. This is the first reply you haven’t seen yet."),
            ("second", "report", "The daily check also finished. Scroll down to read the rest.")].map { id, kind, text in
            .object([.init("id", .string(id)), .init("kind", .string(kind)), .init("text", .string(text)),
                .init("status", .string("ok")), .init("at", .number(1_791_878_000_000))])
        }
        return CodingAIJSON(RoutineChatSnapshot.snapshot(rows, routineID: "daily").foundation)
    }
    func testReportsIgnoreLegacyUnreadMarkers() {
        let model = Routines21ReportsModel(routineID: "daily") { _, _ in CodingAIJSON.null }
        model.acceptReports(snapshot(seen: 1))
        XCTAssertEqual(model.entries.count, 4)
        model.acceptReports(snapshot(seen: 4))
        XCTAssertEqual(model.entries.count, 4)
    }
    func testRenderRoutineReportFollowLightAndDark() throws {
        guard let output = ProcessInfo.processInfo.environment["UNREAD21_RENDER_OUTPUT"] else { return XCTFail("Set the owned frame directory") }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previousAgents = AGTAgentsStore.shared.fixture
        AGTAgentsStore.shared.fixture = TasksState(agents: [])
        defer { AGTAgentsStore.shared.fixture = previousAgents }
        for dark in [false, true] {
            let model = Routines21ReportsModel(routineID: "daily") { _, _ in CodingAIJSON.null }
            model.fixture = true; model.loading = false; model.acceptReports(snapshot(seen: 1))
            let size = CGSize(width: 780, height: 480)
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
                Text("Daily check").font(.title2.weight(.semibold)).padding(.horizontal, 14)
                Routines21ReportsView(name: "Daily check", agentID: "fixture", model: model, live: false)
                Spacer(minLength: 0)
            }.padding(.top, 20).environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(origin: .init(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
            XCTAssertFalse(window.isVisible)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("unread21-routine-\(dark ? "dark" : "light").png"))
            window.contentView = nil; window.close()
        }
    }
}
