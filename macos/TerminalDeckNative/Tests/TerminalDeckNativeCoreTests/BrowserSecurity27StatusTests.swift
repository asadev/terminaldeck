import Testing
@testable import TerminalDeckNativeCore

struct BrowserSecurity27StatusTests {
    @Test func mockStatusesCannotTrapTheNativeNumberConversion() {
        func refusal(_ status: NativeRPCValue) -> String? {
            BrowserAutomationPolicy.refusal(operation: "route", arguments: .object([.init("mock", .array([
                .object([.init("url", .string("**/fixture")), .init("status", status)])
            ]))]), isolated: true)
        }
        for raw in [Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan, -1, 0, 100, 200.5, 600] {
            #expect(refusal(.number(raw))?.contains("whole number") == true)
        }
        #expect(refusal(.string("200")) != nil)
        for raw in [200.0, 204, 404, 599] { #expect(refusal(.number(raw)) == nil) }
    }
}
