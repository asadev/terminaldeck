import Foundation
import TerminalDeckNativeCore

public enum BackendHootChatChannels {
    public static let invokes = ["read", "say", "steer", "stop", "child-stop", "answer", "options", "new", "fork"].map { "hoot:chat:" + $0 }
    public static let event = "hoot:chat:changed"
    public static func integer(_ value: NativeRPCValue, maximum: Int) throws -> Int? {
        if value.isNullish { return nil }
        guard let number = value.number, number >= 0, number.rounded() == number, number < Double(Int.max), number <= Double(maximum) else {
            throw NativeRPCError.invalidArguments("Expected a bounded nonnegative integer.")
        }
        return Int(number)
    }
}
