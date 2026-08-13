/**
 * What this phone tells the desktop it is.
 *
 * Display only, and the desktop treats it that way — `descriptor()` in
 * `protocol.ts` strips control characters and bidi overrides out of it before
 * anybody reads it, on the grounds that the approval screen is the one place a
 * human grants access by reading text a peer sent.
 *
 * `UIDevice.current.name` returns the model name ("iPhone") rather than the
 * user's chosen device name on iOS 16 and later, unless the app holds an
 * entitlement it has no business asking for. That is the right trade: the
 * approval list is more useful with a real name in it, but not at the price of
 * an entitlement request, and the desktop numbers duplicates itself.
 */

import UIKit

enum DeviceIdentity {
    @MainActor
    static func describe() -> DeviceDescriptor {
        let device = UIDevice.current
        return DeviceDescriptor(
            name: device.name,
            platform: "\(device.systemName) \(device.systemVersion)")
    }
}
