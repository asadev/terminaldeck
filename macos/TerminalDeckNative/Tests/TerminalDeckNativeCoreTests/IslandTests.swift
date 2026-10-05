import Foundation
import CoreGraphics
import Testing
@testable import TerminalDeckNativeCore

// MARK: Geometry

/// A 14" MacBook Pro at its default scale: 1512 × 982, a 188-point notch, a 32-point menu bar.
private func macBook(originX: CGFloat = 0, originY: CGFloat = 0) -> IslandScreen {
    let frame = CGRect(x: originX, y: originY, width: 1512, height: 982)
    return IslandScreen(
        frame: frame,
        visibleFrame: CGRect(x: originX, y: originY, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: originX, y: originY + 950, width: 662, height: 32),
        auxiliaryTopRight: CGRect(x: originX + 850, y: originY + 950, width: 662, height: 32))
}

/// A plain 1920 × 1080 display with a 24-point menu bar.
private func plainDisplay(originX: CGFloat = 0, originY: CGFloat = 0) -> IslandScreen {
    IslandScreen(frame: CGRect(x: originX, y: originY, width: 1920, height: 1080),
                 visibleFrame: CGRect(x: originX, y: originY, width: 1920, height: 1056))
}

@Suite("Island geometry")
struct IslandGeometryTests {
    @Test func notchIsFoundFromTheTwoStrips() throws {
        let notch = try #require(IslandGeometry.notch(of: macBook()))
        #expect(notch.minX == 662)
        #expect(notch.width == 188)
        #expect(notch.height == 32)
        #expect(notch.midX == 756)
    }

    @Test func notchedScreenCentresOnTheNotchInsideTheMenuBar() {
        let layout = IslandGeometry.layout(for: macBook())
        #expect(layout.centreX == 756)
        #expect(layout.row == 32)
        // The pill is the notch plus an ear each side, hanging from the very top.
        #expect(layout.pill.width == 188 + IslandMetrics.ear * 2)
        #expect(layout.collapsedFrame.maxY == 982)
        #expect(layout.collapsedFrame.height == 32)
        #expect(layout.collapsedFrame.midX == 756)
        #expect(layout.collapsedFrame.width == layout.pill.outerWidth)
        #expect(layout.ear == IslandMetrics.ear)
        #expect(layout.gap == 188)
    }

    @Test func notchOnASecondScreenUsesThatScreensPosition() {
        let layout = IslandGeometry.layout(for: macBook(originX: -1512, originY: 200))
        #expect(layout.centreX == -756)
        #expect(layout.collapsedFrame.midX == -756)
        #expect(layout.collapsedFrame.maxY == 1182)
        #expect(layout.expandedFrame.maxY == 1182)
    }

    @Test func noNotchIsACompactPillAtTheMenuBarCentre() {
        let layout = IslandGeometry.layout(for: plainDisplay())
        #expect(layout.notch == nil)
        #expect(!layout.notched)
        #expect(layout.centreX == 960)
        #expect(layout.row == 24)
        #expect(layout.pill.width == 64)
        #expect(layout.pill.radius == 12)
        // No notch-shaped block: no ears, no empty gap standing in for a housing.
        #expect(layout.ear == 0)
        #expect(layout.gap == 0)
        #expect(layout.collapsedFrame == CGRect(x: 922, y: 1056, width: 76, height: 24))
        // Grown, the same as on any screen: down from the same centre line.
        #expect(layout.expandedFrame.midX == 960)
        #expect(layout.expandedFrame.maxY == 1080)
    }

    @Test func notchedPillKeepsItsEarsAndNotch() {
        let layout = IslandGeometry.layout(for: macBook())
        #expect(layout.notched)
        #expect(layout.ear == IslandMetrics.ear)
        #expect(layout.gap == 188)
        #expect(layout.pill.width == 268)
        #expect(layout.collapsedFrame == CGRect(x: 616, y: 950, width: 280, height: 32))
    }

    @Test func externalMonitorBesideANotchedMacBookHasNoNotch() {
        // The MacBook at the origin, a plain 1920 × 1080 to its right, tops not aligned.
        let builtIn = IslandGeometry.layout(for: macBook())
        let external = IslandGeometry.layout(for: plainDisplay(originX: 1512, originY: -98))
        #expect(builtIn.notched)
        #expect(builtIn.centreX == 756)
        #expect(!external.notched)
        #expect(external.gap == 0)
        #expect(external.pill.width == IslandMetrics.plainWidth)
        #expect(external.centreX == 2472)
        #expect(external.row == 24)
        #expect(external.collapsedFrame == CGRect(x: 2434, y: 958, width: 76, height: 24))

        // And to its left, where AppKit's x is negative.
        let left = IslandGeometry.layout(for: plainDisplay(originX: -1920, originY: 0))
        #expect(!left.notched)
        #expect(left.collapsedFrame.midX == -960)
    }

    @Test func noNotchOnAnOffsetDisplay() {
        let layout = IslandGeometry.layout(for: plainDisplay(originX: 1512, originY: -300))
        #expect(layout.centreX == 2472)
        #expect(layout.collapsedFrame.maxY == 780)
        #expect(layout.collapsedFrame.midX == 2472)
    }

    @Test func halfANotchOrAHugeGapIsNoNotch() {
        var oneStrip = macBook()
        oneStrip.auxiliaryTopRight = .zero
        #expect(IslandGeometry.notch(of: oneStrip) == nil)

        var hugeGap = macBook()
        hugeGap.auxiliaryTopLeft.size.width = 100
        hugeGap.auxiliaryTopRight.size.width = 100
        #expect(IslandGeometry.notch(of: hugeGap) == nil)

        var sliver = macBook()
        sliver.auxiliaryTopLeft.size.width = 740
        sliver.auxiliaryTopRight.size.width = 740
        #expect(IslandGeometry.notch(of: sliver) == nil)
    }

    @Test func hiddenMenuBarFallsBackToTheUsualHeight() {
        let screen = IslandScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(IslandGeometry.layout(for: screen).row == IslandMetrics.fallbackBar)
    }

    @Test func expandedFrameGrowsDownFromTheSameCentreLine() {
        for screen in [macBook(), plainDisplay(), plainDisplay(originX: 1512, originY: -300)] {
            let layout = IslandGeometry.layout(for: screen)
            #expect(layout.expandedFrame.midX == layout.collapsedFrame.midX)
            #expect(layout.expandedFrame.maxY == screen.frame.maxY)
            #expect(layout.expandedFrame.width >= layout.panel.outerWidth + IslandMetrics.shadowSide * 2)
            #expect(layout.expandedFrame.height == layout.panel.height + IslandMetrics.shadowBottom)
            #expect(layout.expandedFrame.minX >= screen.frame.minX)
            #expect(layout.expandedFrame.maxX <= screen.frame.maxX)
            // Whole points, so the shape lands on the same pixels in both windows.
            #expect(layout.expandedFrame.minX == layout.expandedFrame.minX.rounded())
            #expect(layout.collapsedFrame.minX == layout.collapsedFrame.minX.rounded())
        }
    }

    @Test func expandedPanelIsAThirdOfTheScreenWithinLimits() {
        let wide = IslandGeometry.layout(for: plainDisplay())
        #expect(wide.panel.width == 640)
        #expect(wide.panel.height == 24 + IslandMetrics.panelBody)
        #expect(wide.expandedFrame == CGRect(x: 590, y: 1080 - 312, width: 740, height: 312))

        let macBookLayout = IslandGeometry.layout(for: macBook())
        #expect(macBookLayout.panel.width == 620) // 1512 / 3 = 504, held at the minimum
        #expect(macBookLayout.panel.height == 32 + IslandMetrics.panelBody)

        let huge = IslandGeometry.layout(for: IslandScreen(
            frame: CGRect(x: 0, y: 0, width: 3008, height: 1692),
            visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1667)))
        #expect(huge.panel.width == IslandMetrics.panelMaxWidth)
    }

    @Test func narrowScreenKeepsThePanelOnScreen() {
        let narrow = IslandScreen(frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 640, height: 456))
        let layout = IslandGeometry.layout(for: narrow)
        #expect(layout.expandedFrame.minX >= 0)
        #expect(layout.expandedFrame.maxX <= 640)
        #expect(layout.expandedFrame.midX == 320)
        #expect(layout.panel.outerWidth <= 640)
        #expect(layout.panel.height <= 480 * 0.7)
    }

    @Test func contentSitsBelowTheTopRowInsideThePanel() {
        let layout = IslandGeometry.layout(for: macBook())
        #expect(layout.contentTop > layout.row)
        #expect(layout.contentSize.width == layout.panel.width - IslandMetrics.contentInset * 2)
        #expect(layout.contentTop + layout.contentSize.height + IslandMetrics.contentInset == layout.panel.height)
    }

    @Test func shapeBoxIsTopCentredInTheWindow() {
        let layout = IslandGeometry.layout(for: macBook())
        let rest = layout.shapeBox(expanded: false, inWindowOfSize: layout.collapsedFrame.size)
        #expect(rest == CGRect(origin: .zero, size: layout.collapsedFrame.size))

        let grown = layout.shapeBox(expanded: true, inWindowOfSize: layout.expandedFrame.size)
        #expect(grown.maxY == layout.expandedFrame.height)
        #expect(grown.midX == layout.expandedFrame.width / 2)
        #expect(grown.width == layout.panel.outerWidth)

        // Settling: the pill's box inside the still-big window.
        let settling = layout.shapeBox(expanded: false, inWindowOfSize: layout.expandedFrame.size)
        #expect(settling.maxY == layout.expandedFrame.height)
        #expect(settling.midX == layout.expandedFrame.width / 2)
        #expect(settling.size == layout.collapsedFrame.size)
    }
}

// MARK: State decoding

@Suite("Island state message")
struct IslandStateTests {
    private func message(_ state: Any?) -> [String: Any] {
        var body: [String: Any] = ["type": "island"]
        if let state { body["state"] = state }
        return body
    }

    @Test func decodesAFullMessage() {
        let state = IslandState.parse(message(["status": "needs-you", "badge": 3, "line": "Session 2 needs you"]))
        #expect(state == IslandState(status: .needsYou, badge: 3, line: "Session 2 needs you"))
    }

    @Test func everyStatusHasItsWireName() {
        for status in IslandStatus.allCases {
            #expect(IslandState.parse(message(["status": status.rawValue, "badge": 0, "line": ""]))?.status == status)
        }
        #expect(IslandStatus.needsYou.rawValue == "needs-you")
    }

    @Test func refusesUnknownOrMissingStatus() {
        #expect(IslandState.parse(message(["status": "busy", "badge": 1, "line": "x"])) == nil)
        #expect(IslandState.parse(message(["badge": 1, "line": "x"])) == nil)
        #expect(IslandState.parse(message(["status": 3])) == nil)
        #expect(IslandState.parse(message(nil)) == nil)
        #expect(IslandState.parse(message("idle")) == nil)
        #expect(IslandState.parse(["type": "title", "state": ["status": "idle"]]) == nil)
        #expect(IslandState.parse("island") == nil)
    }

    @Test func badgeIsAWholeNonNegativeCount() {
        func badge(_ value: Any?) -> Int? {
            var state: [String: Any] = ["status": "working"]
            if let value { state["badge"] = value }
            return IslandState.parse(message(state))?.badge
        }
        #expect(badge(nil) == 0)
        #expect(badge(-4) == 0)
        #expect(badge(2.9) == 2)
        #expect(badge(NSNumber(value: 7)) == 7)
        #expect(badge(Double.nan) == 0)
        #expect(badge(Double.infinity) == 0)
        #expect(badge(true) == 0)
        #expect(badge(NSNumber(value: true)) == 0)
        #expect(badge("5") == 0)
        #expect(badge(10_000_000) == IslandState.maxBadge)
    }

    @Test func lineIsOneTrimmedShortLine() {
        let long = String(repeating: "a", count: 500)
        #expect(IslandState.parse(message(["status": "idle", "line": "  two\nlines \r\n"]))?.line == "two lines")
        #expect(IslandState.parse(message(["status": "idle", "line": long]))?.line.count == IslandState.maxLine)
        #expect(IslandState.parse(message(["status": "idle"]))?.line == "")
        #expect(IslandState.parse(message(["status": "idle", "line": 42]))?.line == "")
    }

    @Test func anyIslandTypedBodyIsTheRelaysEvenWhenMalformed() {
        #expect(IslandState.isIslandMessage(message(["status": "nope"])))
        #expect(IslandState.isIslandMessage(message(nil)))
        #expect(!IslandState.isIslandMessage(["type": "sidebar"]))
        #expect(!IslandState.isIslandMessage("island"))
        // And the main window's own messages still ignore it.
        #expect(PageMessage.parse(message(["status": "idle"])) == nil)
    }

    @Test func expandedCommandIsABooleanCall() {
        #expect(IslandCommand.expanded(true) == "window.tdNative && window.tdNative.run('island-expanded', true)")
        #expect(IslandCommand.expanded(false) == "window.tdNative && window.tdNative.run('island-expanded', false)")
    }

    @Test func islandPageIsOnTheEngineOriginWithoutTheToken() throws {
        let engine = try #require(URL(string: "http://127.0.0.1:51234/?t=SECRET"))
        let url = try #require(IslandLocation.url(engineURL: engine))
        #expect(url.absoluteString == "http://127.0.0.1:51234/?island=1")
        #expect(!url.absoluteString.contains("SECRET"))
        #expect(EngineOrigin(url: engine)?.contains(url) == true)
        #expect(IslandLocation.url(engineURL: try #require(URL(string: "https://example.com/?t=x"))) == nil)
    }
}

// MARK: Hover / collapse

/// A clock that only moves when the test says so.
private struct FakeClock {
    var now: TimeInterval = 1_000
    mutating func tick(_ seconds: TimeInterval) { now += seconds }
}

@Suite("Island hover")
struct IslandHoverTests {
    private func ready() -> IslandHover {
        var hover = IslandHover(openDelay: 0.125, closeDelay: 0.25)
        hover.setAvailable(true)
        return hover
    }

    @Test func restingOnThePillGrowsItAfterTheIntentDelay() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        #expect(!hover.expanded)
        #expect(hover.deadline == clock.now + 0.125)
        clock.tick(0.0625)
        hover.advance(to: clock.now)
        #expect(!hover.expanded)
        clock.tick(0.0625)
        hover.advance(to: clock.now)
        #expect(hover.expanded)
        #expect(hover.deadline == nil)
    }

    @Test func passingOverDoesNotGrowIt() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        clock.tick(0.0625)
        hover.pointerExited(at: clock.now)
        #expect(hover.deadline == nil)
        clock.tick(1)
        hover.advance(to: clock.now)
        #expect(!hover.expanded)
    }

    @Test func leavingSettlesItAfterTheGraceDelay() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        clock.tick(0.125); hover.advance(to: clock.now)
        #expect(hover.expanded)

        hover.pointerExited(at: clock.now)
        #expect(hover.expanded)
        clock.tick(0.1875); hover.advance(to: clock.now)
        #expect(hover.expanded)
        clock.tick(0.0625); hover.advance(to: clock.now)
        #expect(!hover.expanded)
    }

    @Test func comingBackWithinTheGraceKeepsItOpen() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        clock.tick(0.125); hover.advance(to: clock.now)
        hover.pointerExited(at: clock.now)
        clock.tick(0.125)
        hover.pointerEntered(at: clock.now)
        #expect(hover.deadline == nil)
        clock.tick(5); hover.advance(to: clock.now)
        #expect(hover.expanded)
    }

    @Test func nothingToShowMeansItNeverGrows() {
        var clock = FakeClock()
        var hover = IslandHover()
        hover.pointerEntered(at: clock.now)
        #expect(hover.deadline == nil)
        clock.tick(1); hover.advance(to: clock.now)
        #expect(!hover.expanded)
        hover.pressed(at: clock.now)
        #expect(!hover.expanded)

        // And losing the page while grown settles it at once.
        hover.setAvailable(true)
        hover.pressed(at: clock.now)
        #expect(hover.expanded)
        hover.setAvailable(false)
        #expect(!hover.expanded)
        #expect(hover.deadline == nil)
    }

    @Test func aClickGrowsItAtOnceAndTheKeyboardHoldsIt() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        hover.pressed(at: clock.now)
        #expect(hover.expanded)
        hover.keyboardChanged(true, at: clock.now)

        // Typing, then the pointer wanders off: it stays.
        hover.pointerExited(at: clock.now)
        #expect(hover.deadline == nil)
        clock.tick(5); hover.advance(to: clock.now)
        #expect(hover.expanded)

        // A click elsewhere takes the keyboard: it settles now.
        hover.keyboardChanged(false, at: clock.now)
        #expect(!hover.expanded)
    }

    @Test func losingTheKeyboardWithThePointerStillOnItWaitsForThePointer() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        hover.pressed(at: clock.now)
        hover.keyboardChanged(true, at: clock.now)
        hover.keyboardChanged(false, at: clock.now)
        #expect(hover.expanded)
        hover.pointerExited(at: clock.now)
        clock.tick(0.25); hover.advance(to: clock.now)
        #expect(!hover.expanded)
    }

    @Test func escapeSettlesItAndItWaitsForThePointerToComeBack() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        clock.tick(0.125); hover.advance(to: clock.now)
        hover.dismiss()
        #expect(!hover.expanded)
        #expect(hover.quiet)

        // Still resting on it: no regrowth.
        hover.pointerEntered(at: clock.now)
        clock.tick(1); hover.advance(to: clock.now)
        #expect(!hover.expanded)

        // Off and back on: grows again after the delay.
        hover.pointerExited(at: clock.now)
        hover.pointerEntered(at: clock.now)
        clock.tick(0.125); hover.advance(to: clock.now)
        #expect(hover.expanded)
    }

    @Test func escapeCancelsAPendingGrow() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        hover.dismiss()
        #expect(hover.deadline == nil)
        clock.tick(1); hover.advance(to: clock.now)
        #expect(!hover.expanded)
    }

    @Test func deadlineIsTheEarliestPendingTimer() {
        var clock = FakeClock()
        var hover = ready()
        #expect(hover.deadline == nil)
        hover.pointerEntered(at: clock.now)
        #expect(hover.deadline == clock.now + 0.125)
        clock.tick(0.125); hover.advance(to: clock.now)
        hover.pointerExited(at: clock.now)
        #expect(hover.deadline == clock.now + 0.25)
    }

    @Test func aLateTimerDoesNotUndoANewerState() {
        var clock = FakeClock()
        var hover = ready()
        hover.pointerEntered(at: clock.now)
        clock.tick(0.125); hover.advance(to: clock.now)
        hover.pointerExited(at: clock.now)
        hover.pressed(at: clock.now) // a click lands during the grace
        hover.keyboardChanged(true, at: clock.now)
        clock.tick(1); hover.advance(to: clock.now)
        #expect(hover.expanded)
    }
}
