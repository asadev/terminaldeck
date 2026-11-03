import Foundation

/// Layout preferences only. An attachment token is never persisted here.
public struct UIGSessionSimulatorState: Codable, Equatable, Sendable {
    public static let defaultWidth = 420.0
    public var isOpen: Bool
    public private(set) var width: Double
    public init(isOpen: Bool = false, width: Double = defaultWidth) {
        self.isOpen = isOpen
        self.width = Self.clamped(width)
    }
    private static func clamped(_ width: Double) -> Double {
        width.isFinite ? min(800, max(280, width)) : defaultWidth
    }
    public mutating func resize(to width: Double) { self.width = Self.clamped(width) }
    public func fittedWidth(in available: Double) -> Double {
        guard available.isFinite, available > 0 else { return 0 }
        return min(width, max(0, available - min(160, available / 2)))
    }
    public static func storageKey(sessionID: String, slot: Int = 0) -> String {
        "session-simulator.layout.v1." + Data(sessionID.utf8).base64EncodedString() + (slot == 0 ? "" : ".\(slot)")
    }
    /// The device last shown in this place, so it comes back after a restart (not a token: never trusted).
    public static func deviceKey(sessionID: String, slot: Int) -> String {
        "session-simulator.device.v1." + Data(sessionID.utf8).base64EncodedString() + ".\(slot)"
    }
    public static func restored(from data: Data?) -> Self {
        guard let data, let state = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return .init(isOpen: state.isOpen, width: state.width)
    }
}

public struct UIGSessionSimulatorTicket: Equatable, Sendable {
    public let sessionID: String
    public let token: String
    public let deviceID: String?
    /// A session shows up to two devices: 0 the first, 1 the second.
    public let slot: Int
    public init?(value: Any, for sessionID: String) {
        guard let value = value as? [String: Any], value["sessionId"] as? String == sessionID,
              let token = value["attachmentToken"] as? String, UUID(uuidString: token) != nil else { return nil }
        self.sessionID = sessionID; self.token = token; self.deviceID = value["deviceId"] as? String
        self.slot = (value["slot"] as? NSNumber)?.intValue ?? 0
    }
    public var arguments: [String: Any] {
        ["sessionId": sessionID, "slot": slot, "attachmentToken": token, "deviceId": deviceID as Any? ?? NSNull()]
    }
    public func acceptsFrame(ticket: Self?, deviceID: String) -> Bool {
        self == ticket && self.deviceID == deviceID
    }
}
