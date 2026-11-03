import AppKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// ORG-PAN (Asad, 11 Oct): "this page is not moveable only zoom in zoom out but cant drag and move one whiteboard".
/// At 68% his lead's card was cut off at the top and the seat cards ran off the right edge.
@Suite("ORG pan and fit")
@MainActor
struct ORGPanTests {
    private let bars = AGTOrgChartView.barsHeight

    @Test func aSmallChartIsCentredAboveTheBarsAtActualSize() throws {
        let fit = try #require(AGTOrgViewport.fitAboveBars(canvasSize: CGSize(width: 400, height: 300), viewportSize: CGSize(width: 1000, height: 800), bottomInset: bars))
        #expect(fit.scale == 1)
        #expect(fit.offset.x == 300)                                   // (1000 - 400) / 2
        #expect(fit.offset.y == 24 + (800 - bars - 48 - 300) / 2)       // centred in the part above the bars
    }

    @Test func aWideTeamFitsWholeWithItsTopCardVisible() throws {
        // Decker + 16 seats: much wider than the window.
        let canvas = CGSize(width: 3200, height: 420), viewport = CGSize(width: 1200, height: 760)
        let fit = try #require(AGTOrgViewport.fitAboveBars(canvasSize: canvas, viewportSize: viewport, bottomInset: bars))
        let shown = CGRect(x: fit.offset.x, y: fit.offset.y, width: canvas.width * fit.scale, height: canvas.height * fit.scale)
        #expect(shown.minX >= 24 - 0.5 && shown.maxX <= viewport.width - 24 + 0.5)   // nothing runs off the right edge
        #expect(shown.minY >= 24 - 0.5)                                              // the top card is fully visible
        #expect(shown.maxY <= viewport.height - bars - 24 + 0.5)                     // nothing hides under the bars
    }

    @Test func aChartTooTallEvenAtTheSmallestZoomKeepsItsTopAtTheMargin() throws {
        let fit = try #require(AGTOrgViewport.fitAboveBars(canvasSize: CGSize(width: 300, height: 9000), viewportSize: CGSize(width: 900, height: 700), bottomInset: bars))
        #expect(fit.scale == 0.25)
        #expect(fit.offset.y == 24)
    }

    @Test func noFitBeforeTheViewportHasASize() {
        #expect(AGTOrgViewport.fitAboveBars(canvasSize: CGSize(width: 400, height: 300), viewportSize: .zero, bottomInset: bars) == nil)
        #expect(AGTOrgViewport.fitAboveBars(canvasSize: .zero, viewportSize: CGSize(width: 900, height: 700), bottomInset: bars) == nil)
    }

    /// The drop hit-test follows the board wherever it was moved: a card dropped on a moved manager still lands.
    @Test func dropsFollowThePannedBoard() {
        let frames = ["boss": CGRect(x: 100, y: 24, width: 172, height: 56)]
        let pan = CGSize(width: -350, height: 120), scale: CGFloat = 0.68
        let onBoss = CGPoint(x: 186 * scale + pan.width, y: 52 * scale + pan.height)
        #expect(AGTOrgDrop.resolve(point: onBoss, scale: scale, pan: pan, frames: frames, shelf: .zero) == .manager("boss"))
        #expect(AGTOrgDrop.resolve(point: CGPoint(x: onBoss.x + 400, y: onBoss.y), scale: scale, pan: pan, frames: frames, shelf: .zero) == .outside)
    }
    @Test func canvasKeysReachZoomAndReleaseSpace() throws {
        let input = ORGCanvasInput.InputView()
        var commands: [String] = [], spaces: [Bool] = []
        input.command = { commands.append($0) }
        input.space = { spaces.append($0) }
        func key(_ text: String, code: UInt16 = 0, down: Bool = true, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        for text in ["+", "-", "0", "1"] {
            #expect(input.handleKey(try key(text, modifiers: .command)))
        }
        #expect(commands == ["+", "-", "0", "1"])
        #expect(!input.handleKey(try key("a")))
        #expect(input.handleKey(try key(" ", code: 49)))
        #expect(input.handleKey(try key(" ", code: 49, down: false)))
        #expect(spaces == [true, false])
        #expect(input.handleKey(try key(" ", code: 49)))
        input.stop()
        #expect(spaces == [true, false, true, false])
    }

}
