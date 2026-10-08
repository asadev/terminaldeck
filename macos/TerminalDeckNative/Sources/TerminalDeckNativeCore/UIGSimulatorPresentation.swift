import Foundation

/// Presentation rules for the Device Hub layout. Starting a device is always an
/// explicit action; selecting an available simulator only opens its live screen.
public enum UIGSimulatorPresentation {
    public enum Action: String, Sendable, Equatable {
        case start = "Start"
        case open = "Open"
        case viewScreen = "View Screen"
    }

    public static func kind(_ entry: DeviceEntry) -> String {
        if entry.kind == "physical" { return entry.platform == "ios" ? "iPhone" : "Android phone" }
        return entry.platform == "ios" ? "Simulator" : "Emulator"
    }

    public static func version(_ entry: DeviceEntry) -> String {
        let runtime = entry.runtime.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["iOS ", "Android "] where runtime.hasPrefix(prefix) {
            return String(runtime.dropFirst(prefix.count))
        }
        return runtime
    }

    public static func description(_ entry: DeviceEntry) -> String {
        let runtime = entry.runtime.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.kind == "physical" { return runtime.isEmpty ? kind(entry) : runtime }
        if entry.platform == "ios" { return runtime.isEmpty ? "iOS Simulator" : "\(runtime) Simulator" }
        return runtime.isEmpty ? "Android emulator" : "\(runtime) Emulator"
    }

    public static func action(_ entry: DeviceEntry) -> Action? {
        if entry.kind == "physical" { return .viewScreen }
        if entry.available { return .open }
        return entry.canBoot ? .start : nil
    }

    public static func canPerformAction(_ entry: DeviceEntry) -> Bool {
        if entry.kind == "physical" { return entry.available }
        return entry.available || entry.canBoot
    }

    public static func opensOnSelection(_ entry: DeviceEntry) -> Bool {
        entry.available && entry.kind != "physical"
    }

    /// A live device can outlast one incomplete inventory read. Keep its row until
    /// the existing model receives its closed event, without inventing a device.
    public static func entries(_ list: DeviceList?, open: DeviceDetails?) -> [DeviceEntry] {
        var entries = list?.devices ?? []
        if let open, !entries.contains(where: { $0.id == open.id }) {
            entries.append(DeviceEntry(id: open.id, platform: open.platform, kind: open.kind,
                                       name: open.name, canShutDown: !open.isPhysical))
        }
        return entries
    }

    public static func selectedID(in entries: [DeviceEntry], selected: String?, open: String?, remembered: String?) -> String? {
        // Opening the page must never attach to a remembered or another tool's
        // running device. Only a still-present, explicit selection is retained.
        guard let selected, entries.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }
}

/// A reply may update the screen only while it belongs to the latest requested
/// device. Used by NativeSimulatorModel's open/start wiring; cancellation also
/// invalidates the ticket because a bridge call can finish after cancellation.
public struct UIGSimulatorRequestFence: Sendable {
    public struct Ticket: Sendable, Equatable {
        public let deviceID: String
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var active: Ticket?

    public init() {}

    public var currentTicket: Ticket? { active }

    public mutating func begin(_ id: String) -> Ticket {
        generation &+= 1
        let ticket = Ticket(deviceID: id, generation: generation)
        active = ticket
        return ticket
    }

    public mutating func invalidate() {
        generation &+= 1
        active = nil
    }

    public func accepts(_ ticket: Ticket) -> Bool { active == ticket }
}
