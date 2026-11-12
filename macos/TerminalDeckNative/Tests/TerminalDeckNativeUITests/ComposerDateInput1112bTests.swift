import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TerminalDeckNative

@MainActor final class ComposerLeak1112bDateInputTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        override var isKeyWindow: Bool { keyboardActive }
    }

    @MainActor @Observable final class Dates {
        var selection = Date(timeIntervalSince1970: 1_900_003_600)
    }

    private struct Ranges: View {
        @Bindable var dates: Dates
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let end = Date(timeIntervalSince1970: 1_900_007_200)
        var body: some View {
            VStack {
                NativeSessionDatePicker("Future", selection: $dates.selection, in: start..., displayedComponents: .date)
                NativeSessionDatePicker("Past", selection: $dates.selection, in: ...end, displayedComponents: .hourAndMinute)
                NativeSessionDatePicker("Calendar", selection: $dates.selection, in: start...end, displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }.frame(width: 650, height: 600)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    func testDateRangesStylesAndHiddenExplicitModelUpdate() throws {
        let dates = Dates()
        let scope = NativeSessionInputScope()
        let host = NSHostingView(rootView: Ranges(dates: dates).environment(\.nativeSessionInputScope, scope))
        let window = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: 700, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let pickers = descendants(host).compactMap { $0 as? NativeSessionDateControl }
        XCTAssertEqual(pickers.count, 3)
        let future = try XCTUnwrap(pickers.first { $0.minDate != nil && $0.maxDate == nil })
        let past = try XCTUnwrap(pickers.first { $0.minDate == nil && $0.maxDate != nil })
        let calendar = try XCTUnwrap(pickers.first { $0.minDate != nil && $0.maxDate != nil })
        XCTAssertEqual(future.minDate, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(past.maxDate, Date(timeIntervalSince1970: 1_900_007_200))
        XCTAssertEqual(calendar.datePickerStyle, .clockAndCalendar)
        XCTAssertEqual(future.datePickerStyle, .textFieldAndStepper)
        XCTAssertTrue(window.makeFirstResponder(future))
        let before = future.dateValue
        future.dateValue = Date(timeIntervalSince1970: 1_899_999_000)
        XCTAssertEqual(future.dateValue, before, "The future-only picker rejects a UI edit below its lower bound")
        let oldClient = window.firstResponder
        scope.setActive(false)
        XCTAssertFalse(window.firstResponder === oldClient, "The private date client releases the keyboard synchronously on hide")
        for picker in pickers {
            let accepted = picker.dateValue
            picker.dateValue = accepted.addingTimeInterval(60)
            picker.setAccessibilityValue(accepted.addingTimeInterval(120))
            XCTAssertEqual(picker.dateValue, accepted)
        }
        settle(host)
        XCTAssertFalse(window.firstResponder === future)
        XCTAssertTrue(pickers.allSatisfy { !$0.isEnabled })
        dates.selection = Date(timeIntervalSince1970: 1_900_004_200)
        settle(host)
        XCTAssertTrue(pickers.allSatisfy { $0.dateValue == dates.selection }, "An explicitly changed model still renders while the scope is hidden")
        scope.setActive(true)
        settle(host)
        XCTAssertTrue(pickers.allSatisfy(\.isEnabled))
        XCTAssertTrue(window.makeFirstResponder(future))
        window.keyboardActive = false
        let restored = future.dateValue
        future.dateValue = restored.addingTimeInterval(60)
        XCTAssertEqual(future.dateValue, restored, "A background window cannot accept a retained date-input callback")
    }
}
