import Foundation
import Testing
@testable import TerminalDeckNativeCore

struct FIXESIslandDisplayTests {
    let main = FIXESIslandDisplay(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), builtIn: true)
    let left = FIXESIslandDisplay(id: "left", name: "Studio", frame: CGRect(x: -1920, y: 240, width: 1920, height: 1080), builtIn: false)
    let upper = FIXESIslandDisplay(id: "upper", name: "Studio", frame: CGRect(x: 0, y: 982, width: 1920, height: 1080), builtIn: false)
    @Test func mainIgnoresPointerAndScreenNames() {
        #expect(FIXESIslandDisplayPolicy.select(.main, screens: [main, left], pointer: CGPoint(x: -500, y: 500)) == main)
    }
    @Test func pointerUsesBothCoordinatesOnStackedAndNegativeScreens() {
        let screens = [main, left, upper]
        #expect(FIXESIslandDisplayPolicy.select(.pointer, screens: screens, pointer: CGPoint(x: -500, y: 500)) == left)
        #expect(FIXESIslandDisplayPolicy.select(.pointer, screens: screens, pointer: CGPoint(x: 500, y: 1500)) == upper)
        #expect(FIXESIslandDisplayPolicy.select(.pointer, screens: screens, pointer: CGPoint(x: 500, y: 500)) == main)
    }
    @Test func disconnectedScreenReturnsWhenReconnectedAndDuplicateNamesAreSafe() {
        let choice = FIXESIslandScreenChoice(mode: .named, screenID: "upper", screenName: "Studio")
        #expect(FIXESIslandDisplayPolicy.select(choice, screens: [main, left], pointer: .zero) == main)
        #expect(FIXESIslandDisplayPolicy.select(choice, screens: [main, left, upper], pointer: .zero) == upper)
    }
    @Test func pointerOutsideScreensAndEmptyInventoryFallBackSafely() {
        #expect(FIXESIslandDisplayPolicy.select(.pointer, screens: [main], pointer: CGPoint(x: 99999, y: 99999)) == main)
        #expect(FIXESIslandDisplayPolicy.select(.main, screens: [], pointer: .zero) == nil)
    }
    @Test func savedChoiceRoundTripsWithoutChangingModeOrStableIdentity() throws {
        for choice in [FIXESIslandScreenChoice.main, .init(mode: .builtIn), .pointer, .init(mode: .named, screenID: "upper", screenName: "Studio")] {
            let bytes = try JSONEncoder().encode(choice)
            #expect(try JSONDecoder().decode(FIXESIslandScreenChoice.self, from: bytes) == choice)
        }
    }
    @Test func builtInChoiceUsesBuiltInAcrossChangedArrayOrder() {
        #expect(FIXESIslandDisplayPolicy.select(.init(mode: .builtIn), screens: [left, main], pointer: .zero) == main)
        #expect(FIXESIslandDisplayPolicy.select(.init(mode: .builtIn), screens: [left], pointer: .zero) == left)
    }
    @Test func presetsAndQuietHaveTheSpecifiedSizes() {
        let screen = IslandScreen(frame: main.frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 958))
        for width in FIXESIslandOptions.Width.allCases {
            let options = FIXESIslandOptions(width: width)
            let active = FIXESIslandDisplayPolicy.layout(for: screen, options: options, quiet: false)
            #expect(active.pill.width == width.resting); #expect(active.panel.width == width.grown)
            #expect(active.collapsedFrame.width == active.pill.outerWidth)
            let quiet = FIXESIslandDisplayPolicy.layout(for: screen, options: options, quiet: true)
            #expect(quiet.pill.width == width.resting); #expect(quiet.pill.height == 26)
        }
    }
    @Test func smallNotchedIslandKeepsContentOutOfTheNotch() {
        let screen = IslandScreen(frame: main.frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32), auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32))
        let quiet = FIXESIslandDisplayPolicy.layout(for: screen, options: .init(), quiet: true)
        #expect(quiet.gap == 188); #expect(quiet.ear >= 60)
        #expect(quiet.pill.width >= quiet.gap + 2 * quiet.ear)
    }
    @Test func appThemeWinsExceptBuiltInNotch() {
        #expect(!FIXESIslandDisplayPolicy.dark(appearance: "light", builtIn: false, hasNotch: false))
        #expect(FIXESIslandDisplayPolicy.dark(appearance: "dark", builtIn: false, hasNotch: false))
        #expect(FIXESIslandDisplayPolicy.dark(appearance: "light", builtIn: true, hasNotch: true))
        #expect(!FIXESIslandDisplayPolicy.dark(appearance: "light", builtIn: false, hasNotch: true))
        #expect(!FIXESIslandDisplayPolicy.dark(appearance: "light", builtIn: true, hasNotch: false))
        #expect(FIXESIslandDisplayPolicy.dark(appearance: "light", builtIn: false, hasNotch: false, look: .dark))
    }
}
