import Foundation
import TerminalDeckNativeCore

/// Ephemeral bindings mirror browser-binding.ts: names survive detaches while
/// siblings remain, and reset once a session has no windows. Never persisted.
@MainActor
public final class BackendBrowserBindings {
    public var changed: (@MainActor () -> Void)?
    public struct Window: Sendable {
        public let tabID: String
        public var viewID: String
        public var url: String
        public var title: String
        public var hostMachineID: String
        public var hostMachineName: String
        public var visible: Bool
        public var width: Double
        public init(tabID: String, viewID: String, url: String = "", title: String = "",
                    hostMachineID: String = "", hostMachineName: String = "", visible: Bool = false, width: Double = 0) {
            self.tabID = tabID; self.viewID = viewID; self.url = url; self.title = title
            self.hostMachineID = hostMachineID; self.hostMachineName = hostMachineName; self.visible = visible; self.width = width
        }
        public var value: NativeRPCValue { .object([
            .init("tabId", .string(tabID)), .init("browserTabId", .string(tabID)), .init("viewId", .string(viewID)),
            .init("url", .string(url)), .init("title", .string(title)), .init("machineId", .string(hostMachineID)),
            .init("hostMachineId", .string(hostMachineID)), .init("hostMachineName", .string(hostMachineName)),
            .init("visible", .bool(visible)), .init("w", .number(width))]) }
    }
    private struct Row { let session: BrowserDriverSession; var next = 0; var windows: [BrowserBoundWindow] = []; var ended = false; let colour: Int }
    private var rows: [String: Row] = [:]
    private var known: [String: Window] = [:]
    private var ownTabs: [String: String] = [:]
    private var windowNumbers: [String: Int] = [:]
    private var nextWindow = 0
    public init() {}
    public func observe(_ window: Window) {
        if windowNumbers[window.tabID] == nil { nextWindow += 1; windowNumbers[window.tabID] = nextWindow }
        known[window.tabID] = window
        changed?()
    }
    public func displayName(_ id: String) -> String? { windowNumbers[id].map { "W\($0)" } }
    public func named(_ name: String, session: BrowserDriverSession? = nil) -> Window? {
        if let session, let n = BrowserWindowName.number(name), let id = rows[BrowserBindings.key(session)]?.windows.first(where: { $0.n == n })?.tabID { return known[id] }
        return windowNumbers.first(where: { "W\($0.value)".lowercased() == name.trimmingCharacters(in: .whitespaces).lowercased() }).flatMap { known[$0.key] }
    }
    public func window(_ id: String) -> Window? { known[id] }
    public func windows() -> [Window] { known.values.sorted { $0.tabID < $1.tabID } }
    public func ownTab(_ owner: String) -> String? { ownTabs[owner] }
    public func setOwnTab(_ owner: String, _ id: String?) { ownTabs[owner] = id; changed?() }
    public func owner(of id: String) -> BrowserDriverSession? { rows.values.first { $0.windows.contains { $0.tabID == id } }?.session }
    public func attach(_ id: String, to session: BrowserDriverSession) throws -> BrowserBoundWindow {
        guard known[id] != nil, !session.sessionId.isEmpty else { throw NativeRPCError(code: "not-permitted", message: "That browser window is not available.") }
        let key = BrowserBindings.key(session)
        if let existing = rows[BrowserBindings.key(session)]?.windows.first(where: { $0.tabID == id }) { return existing }
        detach(id)
        // This map describes the relation, just like source attach(). Live
        // session authority belongs to the service resolver, not this ended flag.
        var row = rows[key] ?? Row(session: session, colour: nextColour())
        if row.windows.isEmpty { row.next = 0 }
        row.next += 1
        let window = BrowserBoundWindow(n: row.next, tabID: id)
        row.windows.append(window); rows[key] = row
        for owner in Array(ownTabs.keys) where ownTabs[owner] == id { ownTabs[owner] = nil }
        changed?()
        return window
    }
    public func detach(_ id: String) {
        for key in Array(rows.keys) { rows[key]?.windows.removeAll { $0.tabID == id } }
        changed?()
    }
    public func release(_ id: String) {
        detach(id)
        for owner in Array(ownTabs.keys) where ownTabs[owner] == id { ownTabs[owner] = nil }
    }
    public func closed(_ id: String) {
        detach(id); known[id] = nil; windowNumbers[id] = nil
        for owner in Array(ownTabs.keys) where ownTabs[owner] == id { ownTabs[owner] = nil }
    }
    public func sessionExited(_ session: BrowserDriverSession) {
        let key = BrowserBindings.key(session)
        guard var row = rows[key], !row.ended else { return }
        row.windows = []; row.ended = true; rows[key] = row; changed?()
    }
    public func sessionStarted(_ session: BrowserDriverSession) {
        let key = BrowserBindings.key(session)
        guard rows[key]?.ended == true else { return }
        rows[key]?.ended = false; changed?()
    }
    public func sessionRemoved(_ session: BrowserDriverSession) {
        guard rows.removeValue(forKey: BrowserBindings.key(session)) != nil else { return }
        changed?()
    }
    private func nextColour() -> Int {
        var used = Array(repeating: 0, count: 4)
        for row in rows.values { used[row.colour] += 1 }
        return used.indices.min { used[$0] < used[$1] } ?? 0
    }
    public func reset() { rows.removeAll(); known.removeAll(); ownTabs.removeAll(); windowNumbers.removeAll(); nextWindow = 0; changed?() }
    public func bindings(for principal: BackendBrowserPrincipal) -> BrowserBindings {
        let filtered = rows.filter { principal.managesWindows || $0.value.session == principal.session }
        return BrowserBindings(windows: filtered.mapValues(\.windows))
    }
    public func view(for principal: BackendBrowserPrincipal) -> NativeRPCValue {
        let entries = rows.values.filter { principal.managesWindows || $0.session == principal.session }.sorted { BrowserBindings.key($0.session) < BrowserBindings.key($1.session) }
        return .object([.init("sessions", .array(entries.map { row in
            .object([.init("sessionId", .string(row.session.sessionId)), .init("machineId", .string(row.session.machineId)),
                .init("colour", .number(Double(row.colour))), .init("ended", .bool(row.ended)),
                .init("windows", .array(row.windows.sorted { $0.n < $1.n }.compactMap { bound in
                    known[bound.tabID]?.value.setting("n", .number(Double(bound.n)))
                }))])
        }))])
    }
}
