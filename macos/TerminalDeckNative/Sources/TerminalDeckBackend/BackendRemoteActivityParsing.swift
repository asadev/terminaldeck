import Foundation
import TerminalDeckNativeCore

extension BackendRemoteProtocol {
    /// `activity.watch {top?}` / `activity.unwatch`: the phone's Activity page (BackendPhoneActivity). Shapes only.
    static func parseActivity(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        switch r.type {
        case "activity.watch":
            var message = r.base
            if let top = r["top"].bool { message = message.setting("top", .bool(top)) }
            return message
        case "activity.unwatch":
            return r.base
        default:
            return nil
        }
    }
}
