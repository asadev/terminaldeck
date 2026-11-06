import ColorSync
import CoreGraphics
import Foundation
import TerminalDeckNativeCore

/// Input and pointer reporting run many times per second. Re-read only when the display setup changes.
enum NativeMacDisplayInventory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var saved: [MacDisplaySelection.Display]?
    private static let observing: Bool = {
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            lock.withLock { saved = nil }
        }, nil) == .success
    }()

    static func read() throws -> [MacDisplaySelection.Display] {
        let canCache = observing
        return try lock.withLock {
            if canCache, let saved { return saved }
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw unavailable }
            guard count > 0 else { return [] }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw unavailable }
            let displays = ids.prefix(Int(count)).map(identity)
            if canCache { saved = displays }
            return displays
        }
    }

    static func identity(_ id: CGDirectDisplayID) -> MacDisplaySelection.Display {
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).flatMap {
            UUID(uuidString: CFUUIDCreateString(nil, $0.takeRetainedValue()) as String)
        }
        return .init(number: id, uuid: uuid, main: CGDisplayIsMain(id) != 0)
    }

    private static var unavailable: NativeRPCError {
        NativeRPCError(code: "unavailable", message: "macOS couldn't read the connected displays. Try again.")
    }
}
