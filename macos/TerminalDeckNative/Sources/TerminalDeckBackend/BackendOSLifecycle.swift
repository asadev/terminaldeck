import Foundation
import AppKit
import TerminalDeckNativeCore

/// idle.ts. Attachment events, never polling, drive the registered parts.
@MainActor
public protocol BackendOSIdleable: AnyObject {
    var name: String { get }
    var heldWhenIdle: Bool { get }
    func sleep()
    func wake()
}
public extension BackendOSIdleable { var heldWhenIdle: Bool { false } }

@MainActor
public final class BackendOSIdleController {
    private var parts: [any BackendOSIdleable] = []
    private var count: Int
    public init(attached: Int = 0) { count = max(0, attached) }
    public var mode: String { count == 0 ? "idle" : "awake" }
    public func register(_ part: any BackendOSIdleable) {
        parts.append(part)
        if !part.heldWhenIdle && count == 0 { part.sleep() }
    }
    @discardableResult public func attached(_ next: Int) -> String {
        let before = mode; count = max(0, next)
        if before != mode { for part in parts where !part.heldWhenIdle { count == 0 ? part.sleep() : part.wake() } }
        return mode
    }
    public func report() -> NativeRPCValue {
        .object([.init("mode", .string(mode)), .init("attached", .number(Double(count))),
            .init("holding", .array(parts.filter { count > 0 || $0.heldWhenIdle }.map { .string($0.name) })),
            .init("stopped", .array(parts.filter { count == 0 && !$0.heldWhenIdle }.map { .string($0.name) }))])
    }
}

/// window-owner.ts. Device ownership wins even when a local browser is attached.
public actor BackendOSWindowOwners {
    public struct Holder: Equatable, Sendable { public enum Kind: String, Sendable { case device, machine }; public let kind: Kind; public let id: String; public init(kind: Kind, id: String) { self.kind = kind; self.id = id } }
    public enum Route: Equatable, Sendable { case here, peer(Holder), ambiguous([Holder]) }
    private var owners: [String: String] = [:]
    public init() {}
    public func note(sessionID: String, deviceID: String) { if !sessionID.isEmpty && !deviceID.isEmpty { owners[sessionID] = deviceID } }
    public func owner(of sessionID: String) -> String? { owners[sessionID] }
    public func forget(_ sessionID: String) { owners[sessionID] = nil }
    public func route(sessionID: String, attachedHere: Bool, deviceHolders: [String], machineHolders: [String] = []) -> Route {
        if sessionID.isEmpty { return .here }
        if let owner = owners[sessionID] { return .peer(.init(kind: .device, id: owner)) }
        if attachedHere { return .here }
        let holders = deviceHolders.map { Holder(kind: .device, id: $0) } + machineHolders.map { Holder(kind: .machine, id: $0) }
        if holders.isEmpty { return .here }
        return holders.count == 1 ? .peer(holders[0]) : .ambiguous(holders)
    }
}

/// web-contents-teardown.ts, keyed by native caller owner. UI owners call destroy
/// exactly once when closing. A late registration runs immediately.
@MainActor
public final class BackendOSTeardowns {
    private var callbacks: [String: [String: @MainActor () throws -> Void]] = [:]
    private var destroyed = Set<String>()
    private let report: @MainActor (Error) -> Void
    public init(report: @escaping @MainActor (Error) -> Void = { _ in }) { self.report = report }
    public func on(owner: String, key: String, callback: @escaping @MainActor () throws -> Void) {
        if destroyed.contains(owner) { run(callback); return }
        callbacks[owner, default: [:]][key] = callback
    }
    public func off(owner: String, key: String) { callbacks[owner]?[key] = nil }
    public func pending(owner: String) -> [String] { callbacks[owner].map { Array($0.keys).sorted() } ?? [] }
    public func destroy(owner: String) {
        guard destroyed.insert(owner).inserted else { return }
        let saved = callbacks.removeValue(forKey: owner)?.values.map { $0 } ?? []
        for callback in saved { run(callback) }
    }
    private func run(_ callback: @MainActor () throws -> Void) { do { try callback() } catch { report(error) } }
}

public enum BackendOSResidentRules {
    public static let quitButtons = ["Keep Them Running", "Stop Everything", "Cancel"]
    public static func plannedQuit(liveSessions: Int, behavior: String) -> String { liveSessions <= 0 ? "stop" : behavior }
    public static func quitAnswer(_ index: Int) -> String { index == 0 ? "keep" : index == 1 ? "stop" : "cancel" }
    public static func quitQuestion(count: Int) -> (message: String, detail: String) {
        (count == 1 ? "One session is still running." : "\(count) sessions are still running.",
         "Quitting has always ended them. It does not have to: Terminal Deck can keep them running on this machine with no window, and put them back — screens and all — the next time you open it.\n\nWhile they are running you will find Terminal Deck in the menu bar, which lists them and can stop any of them, or all of them, without opening a window.")
    }
}

/// resident.ts. Native AppKit already keeps an app with no windows alive; no
/// libuv timer is needed. The behaviour lives in BackendS3FillResidentPresence (status item
/// behind a factory so the icon count is testable).
public typealias BackendOSResidentPresence = BackendS3FillResidentPresence

public enum BackendOSLivePush {
    public static let prefsChanged = "prefs:changed"
    public static let settingsChanged = "settings:changed"
    public static let sessionRemoved = "session:removed"
    public static let sessionRenamed = "session:renamed"
}
