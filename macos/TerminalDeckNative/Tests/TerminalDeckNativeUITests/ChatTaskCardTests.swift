import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatTaskCardTests: XCTestCase {
    func testProgressCardFitsLongStepsInBothThemes() throws {
        let rows = ["done", "current", "next"].enumerated().map { index, state in
            NativeRPCValue.object([.init("id", .string(String(index))), .init("state", .string(state)),
                .init("text", .string(index == 1 ? "Inspect the task progress card with a deliberately long step that must wrap within its column" : "Check step \(index)")),
                .init("runningTasks", .number(index == 1 ? 2 : 0))])
        }
        for dark in [false, true] {
            let host = NSHostingView(rootView: NativeChatTaskCard(todos: rows).frame(width: 360)
                .environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 360, accuracy: 1)
            XCTAssertGreaterThan(host.fittingSize.height, 80)
            XCTAssertLessThan(host.fittingSize.height, 300)
        }
    }
}
