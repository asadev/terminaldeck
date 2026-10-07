import Foundation
import TerminalDeckNativeCore

/// The source confine IPC registers on Mac too: grants are Windows-only,
/// while Mac state reports Seatbelt without making a permission change.
public struct BackendAppConfinementChannels: Sendable {
    public static let channels: Set<String> = ["confine:state", "confine:grant", "confine:withdraw"]
    public init() {}
    public var state: NativeRPCValue { .object([.init("platform", .string("darwin")), .init("confining", .bool(true)), .init("canGrant", .bool(false)), .init("folders", .array([])), .init("note", .string(""))]) }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) throws -> NativeRPCValue {
        switch channel {
        case "confine:state": state
        case "confine:grant": .object([.init("result", .null), .init("state", state)])
        case "confine:withdraw": .object([.init("ok", .bool(true)), .init("detail", .string("")), .init("state", state)])
        default: throw BackendAppSessionError("The native confinement facade does not handle this channel.")
        }
    }
}
