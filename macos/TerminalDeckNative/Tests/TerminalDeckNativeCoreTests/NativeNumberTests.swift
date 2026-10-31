import Foundation
import Testing
import TerminalDeckNativeCore

/// U29: the one number reader. A huge number from a tool, request or saved file is
/// refused or clamped; `Int(Double)` would end the whole app.
@Suite("Huge numbers are refused or clamped, never trapped")
struct NativeNumberTests {
    @Test func integerAcceptsOnlyWholeNumbersInRange() {
        #expect(NativeNumber.integer(3, in: 0...10) == 3)
        for bad: Double? in [nil, 1e300, -1e300, 9.3e18, Double(Int.max), 2.5, 11, -1] {
            #expect(NativeNumber.integer(bad, in: 0...10) == nil)
        }
        #expect(NativeNumber.integer(Double(Int.max), in: 1...Int.max) == nil, "2^63 is not an Int")
        #expect(NativeNumber.integer(1e15, in: 1...Int.max) == 1_000_000_000_000_000)
    }

    @Test func clampedHoldsEveryNumberInRange() {
        #expect(NativeNumber.clamped(1e300, to: 1...50, fallback: 10) == 50)
        #expect(NativeNumber.clamped(-1e300, to: 1...50, fallback: 10) == 1)
        #expect(NativeNumber.clamped(7.9, to: 1...50, fallback: 10) == 7)
        #expect(NativeNumber.clamped(nil, to: 1...50, fallback: 10) == 10)
        #expect(NativeNumber.clamped(.nan, to: 1...50, fallback: 10) == 10)
        #expect(NativeNumber.clamped(.infinity, to: 1...50, fallback: 10) == 10)
        #expect(NativeNumber.clamped(1e300, to: 0...Int.max, fallback: 0) == Int.max, "the top of Int's range never traps")
        #expect(NativeNumber.clamped(-1e300, to: Int.min...0, fallback: 0) == Int.min)
    }
}
