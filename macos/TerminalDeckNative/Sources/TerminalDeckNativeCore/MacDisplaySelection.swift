import Foundation

/// A CoreGraphics number belongs to this login, while the UUID follows the display across restarts.
public enum MacDisplaySelection {
    public struct Display: Equatable, Sendable {
        public let number: UInt32
        public let uuid: UUID?
        public let main: Bool
        public init(number: UInt32, uuid: UUID?, main: Bool) {
            self.number = number; self.uuid = uuid; self.main = main
        }
        public var wireID: String { "mac:\(uuid?.uuidString ?? String(number))" }
    }

    public enum Failure: Error, Equatable { case invalidID, noDisplays }

    public static func isValidID(_ id: String) -> Bool {
        guard id.hasPrefix("mac:") else { return false }
        let key = String(id.dropFirst(4))
        return UUID(uuidString: key) != nil || UInt32(key) != nil || key == "main"
    }

    public static func resolve(_ id: String, displays: [Display]) throws -> Display {
        guard id.hasPrefix("mac:") else { throw Failure.invalidID }
        let key = String(id.dropFirst(4))
        let uuid = UUID(uuidString: key), number = UInt32(key)
        guard uuid != nil || number != nil || key == "main" else { throw Failure.invalidID }
        guard let main = displays.first(where: \.main) ?? displays.first else { throw Failure.noDisplays }
        // Never interpret a missing UUID as a number: a reused CG id must not select another monitor.
        if let uuid { return displays.first { $0.uuid == uuid } ?? main }
        if let number { return displays.first { $0.number == number } ?? main }
        return main
    }

    /// Empty capture inventories are not evidence that a physically connected monitor was unplugged.
    public static let captureUnavailable = "macOS isn't making any displays available for screen sharing. On your Mac, check System Settings → Privacy & Security → Screen Recording, then try again."
}
