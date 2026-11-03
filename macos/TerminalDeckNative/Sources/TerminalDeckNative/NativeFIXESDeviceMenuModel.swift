import Foundation
import TerminalDeckNativeCore

// #108 (L6-SIMMENU, from Codex FIXES drafts): the Simulators row menu's pure model.

public enum FIXESDeviceContextAction: String, CaseIterable, Hashable, Sendable {
    case start, startAndOpen, coldStart, shutDown, restart, newTab, newWindow, beside, sendToHoot, finder, copyID, rename, reset, delete
    public var title: String {
        switch self {
        case .start: "Start"
        case .startAndOpen: "Start and open in a new tab"
        case .coldStart: "Cold start"
        case .shutDown: "Shut down"
        case .restart: "Restart"
        case .newTab: "Open in a new tab"
        case .newWindow: "Open in a new window"
        case .beside: "Show beside a session"
        case .sendToHoot: "Send the screen to Hoot"
        case .finder: "Show in Finder"
        case .copyID: "Copy device ID"
        case .rename: "Rename…"
        case .reset: "Erase all content and settings…"
        case .delete: "Delete…"
        }
    }
    public var destructive: Bool { self == .reset || self == .delete }
    public var symbol: String {
        switch self {
        case .start, .startAndOpen: "play"
        case .coldStart: "snowflake"
        case .shutDown: "power"
        case .restart, .reset: "arrow.counterclockwise"
        case .newTab: "rectangle.topthird.inset.filled"
        case .newWindow: "arrow.up.forward.square"
        case .beside: "sidebar.right"
        case .sendToHoot: "bird"
        case .finder: "folder"
        case .copyID: "doc.on.doc"
        case .rename: "pencil"
        case .delete: "trash"
        }
    }
    public func title(for entry: DeviceEntry) -> String { self == .reset && entry.platform == "android" ? "Wipe data…" : title }
    public static func sections(for entry: DeviceEntry) -> [[Self]] {
        let opens: [Self] = [.newTab, .newWindow, .beside, .sendToHoot]
        if entry.kind == "physical" { return [opens, [.copyID]] }
        let management: [[Self]] = [[.finder, .copyID, .rename], [.reset, .delete]]
        if entry.platform == "android" { return [[.start, .coldStart, .shutDown], opens] + management }
        if entry.canShutDown { return [[.shutDown, .restart], opens] + management }
        return [[.start, .startAndOpen], opens] + management
    }
    /// The phone panel's device list: Start is its own button, so the ⋯ menu holds the rest.
    /// Everything the retired Simulators page offered for a device, only what applies to this one.
    public static func pickerSections(for entry: DeviceEntry) -> [[Self]] {
        let all: [[Self]] = entry.kind == "physical"
            ? [[.newWindow, .sendToHoot], [.copyID]]
            : [[.start, .coldStart, .restart, .shutDown], [.newWindow, .sendToHoot], [.finder, .copyID, .rename], [.reset, .delete]]
        return all.map { $0.filter { $0.available(for: entry) } }.filter { !$0.isEmpty }
    }
    public func available(for entry: DeviceEntry, working: Bool = false) -> Bool {
        if self == .copyID { return true }
        guard !working else { return false }
        switch self {
        case .start, .startAndOpen: return entry.canBoot
        case .coldStart: return entry.kind != "physical" && (entry.canBoot || entry.canShutDown)
        case .shutDown: return entry.canShutDown
        case .restart: return entry.canShutDown
        case .newTab, .newWindow, .beside: return entry.available || entry.canBoot
        case .sendToHoot: return entry.available
        case .finder, .rename, .reset, .delete: return entry.kind != "physical"
        case .copyID: return true
        }
    }
}


/// Human-facing copy is the platform identifier. Wire tools retain the full
/// ios:/android:/avd: id so the backend can distinguish the three namespaces.
public enum FIXESDeviceIdentity {
    public static func copiedID(_ id: String) -> String {
        for prefix in ["ios:", "android:", "avd:"] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
    }
}


/// The actual row menu's confirmation state, also driven directly in tests.
/// Opening/cancelling an alert never emits a device command.
public struct FIXESDeviceMenuInteraction: Sendable {
    public struct Command: Equatable, Sendable {
        public let action: FIXESDeviceContextAction
        public let deviceID: String
        public let name: String?
        public let confirmed: Bool
    }
    public private(set) var pending: FIXESDeviceContextAction?
    public private(set) var deviceID: String?
    public private(set) var deviceName = ""
    public var name = ""
    public init() {}
    public mutating func choose(_ action: FIXESDeviceContextAction, entry: DeviceEntry) -> Command? {
        guard action.available(for: entry) else { return nil }
        if action == .rename || action.destructive {
            pending = action; deviceID = entry.id; deviceName = entry.name
            name = action == .rename ? entry.name : ""
            return nil
        }
        return .init(action: action, deviceID: entry.id, name: nil, confirmed: false)
    }
    public mutating func confirm() -> Command? {
        guard let action = pending, let id = deviceID else { return nil }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .rename && typed.isEmpty { return nil }
        let result = Command(action: action, deviceID: id, name: action == .rename ? typed : nil, confirmed: action.destructive)
        pending = nil; deviceID = nil
        return result
    }
    public mutating func cancel() { pending = nil; deviceID = nil; deviceName = ""; name = "" }
}


/// Read-only attachment projection. Two slots of one session can name two
/// different devices; a detach/invalidated event clears only that slot.
public struct FIXESDeviceSessionUsage: Sendable {
    private var slots: [String: [Int: String]] = [:]
    public init() {}
    @discardableResult public mutating func accept(_ value: NativeRPCValue) -> Bool {
        guard let id = value["sessionId"].string, !id.isEmpty,
              let number = value["slot"].number, number == 0 || number == 1 else { return false }
        let slot = Int(number), before = slots[id]?[slot]
        let next = value["invalidated"].bool == true ? nil : value["deviceId"].string
        slots[id, default: [:]][slot] = next
        if slots[id]?.isEmpty == true { slots[id] = nil }
        return before != next
    }
    public mutating func retain(sessions: Set<String>) { slots = slots.filter { sessions.contains($0.key) } }
    /// Sessions that still need their first read: new since the last rows, plus any whose read was cut short.
    /// The attachment push keeps every other session current, so a rename or another session's end reads nothing (#466).
    public static func unread(before: Set<String>, after: Set<String>, pending: Set<String>) -> Set<String> {
        pending.union(after.subtracting(before)).intersection(after)
    }
    public mutating func forget(_ sessionID: String) { slots[sessionID] = nil }
    public func sessionIDs(for deviceID: String) -> [String] {
        slots.keys.filter { slots[$0]?.values.contains(deviceID) == true }.sorted()
    }
}

