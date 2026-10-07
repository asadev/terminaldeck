import Foundation
import TerminalDeckNativeCore

public struct BackendMacAppHandoffCastWindow: Sendable {
    public let window: String
    /// nil means the existing drive's own slot, even when window has a real shell id.
    public let target: BackendBrowserCaptureTarget?
    public let url: String
    public let title: String
    public init(window: String, target: BackendBrowserCaptureTarget?, url: String, title: String) { self.window = window; self.target = target; self.url = url; self.title = title }
}
public struct BackendMacAppHandoffCastResult: Sendable, Equatable {
    public let ok: Bool
    public let reason: String?
    public init(ok: Bool, reason: String? = nil) { self.ok = ok; self.reason = reason }
}
public struct BackendMacAppHandoffHandoverState: Sendable, Equatable {
    public let asking: Bool
    public let prompt: String
    public let taker: String?
    public init(asking: Bool, prompt: String, taker: String?) { self.asking = asking; self.prompt = prompt; self.taker = taker }
    public static let none = Self(asking: false, prompt: "", taker: nil)
}
/// Only cast/input/baton operations, implemented by the Safari owner's existing watch service.
public protocol BackendMacAppHandoffCastDrive: Sendable {
    func start(target: BackendBrowserCaptureTarget?, watcherID: String, window: String, maxWidth: Int, quality: Int,
               everyNth: Int?, emit: @escaping @Sendable (NativeRPCValue) async throws -> Void) async throws -> BackendMacAppHandoffCastResult
    func stop(target: BackendBrowserCaptureTarget?, watcherID: String) async throws
    func ack(target: BackendBrowserCaptureTarget?, watcherID: String, sequence: Int) async throws
    func input(target: BackendBrowserCaptureTarget?, watcherID: String, frame: NativeRPCValue) async throws -> BackendMacAppHandoffCastResult
    func holding(target: BackendBrowserCaptureTarget?) async throws -> BackendMacAppHandoffHandoverState
    func take(target: BackendBrowserCaptureTarget?, watcherID: String) async throws -> BackendMacAppHandoffCastResult
    func handBack(target: BackendBrowserCaptureTarget?, watcherID: String, carryOn: Bool) async throws -> BackendMacAppHandoffCastResult
    func dropWatcher(_ watcherID: String) async throws
}
/// No browser is a source-defined refusal; it is not a pretend live engine.
public struct BackendMacAppHandoffNoBrowser: BackendMacAppHandoffCastDrive, Sendable {
    public init() {}
    public func start(target: BackendBrowserCaptureTarget?, watcherID: String, window: String, maxWidth: Int, quality: Int, everyNth: Int?, emit: @escaping @Sendable (NativeRPCValue) async throws -> Void) -> BackendMacAppHandoffCastResult { .init(ok: false, reason: "this app has no browser running") }
    public func stop(target: BackendBrowserCaptureTarget?, watcherID: String) {}
    public func ack(target: BackendBrowserCaptureTarget?, watcherID: String, sequence: Int) {}
    public func input(target: BackendBrowserCaptureTarget?, watcherID: String, frame: NativeRPCValue) -> BackendMacAppHandoffCastResult { .init(ok: false, reason: "this app has no browser running") }
    public func holding(target: BackendBrowserCaptureTarget?) -> BackendMacAppHandoffHandoverState { .none }
    public func take(target: BackendBrowserCaptureTarget?, watcherID: String) -> BackendMacAppHandoffCastResult { .init(ok: false, reason: "this app has no browser running") }
    public func handBack(target: BackendBrowserCaptureTarget?, watcherID: String, carryOn: Bool) -> BackendMacAppHandoffCastResult { .init(ok: false, reason: "this app has no browser running") }
    public func dropWatcher(_ watcherID: String) {}
}

public actor BackendMacAppHandoffScreencast {
    public static let maximumSurfaces = 64
    private struct Cast: Sendable { let target: BackendBrowserCaptureTarget?; var watchers: Set<String> }
    private let drive: any BackendMacAppHandoffCastDrive
    private let windows: @Sendable () async throws -> [BackendMacAppHandoffCastWindow]
    private let report: @Sendable (any Error) -> Void
    private var casts: [String: Cast] = [:]
    public init(drive: any BackendMacAppHandoffCastDrive, windows: @escaping @Sendable () async throws -> [BackendMacAppHandoffCastWindow], report: @escaping @Sendable (any Error) -> Void = { _ in }) { self.drive = drive; self.windows = windows; self.report = report }
    private func list() async -> [BackendMacAppHandoffCastWindow] { do { return try await windows() } catch { report(error); return [] } }
    public func watch(watcherID: String, window: String, maxWidth: Int, quality: Int, everyNth: Int? = nil,
                      emit: @escaping @Sendable (NativeRPCValue) async throws -> Void) async throws -> BackendMacAppHandoffCastResult {
        guard let found = await list().first(where: { $0.window == window }) else { return .init(ok: false, reason: "that window is not open on this machine any more") }
        let result = try await drive.start(target: found.target, watcherID: watcherID, window: window, maxWidth: maxWidth, quality: quality, everyNth: everyNth) { frame in
            try await emit(frame.setting("t", .string("browser.frame")))
        }
        guard result.ok else { return result }
        if var cast = casts[window] { cast.watchers.insert(watcherID); casts[window] = cast }
        else { casts[window] = Cast(target: found.target, watchers: [watcherID]) }; return .init(ok: true)
    }
    public func unwatch(watcherID: String, window: String) async throws {
        guard var cast = casts[window] else { return }; cast.watchers.remove(watcherID)
        if cast.watchers.isEmpty { casts[window] = nil } else { casts[window] = cast }
        try await drive.stop(target: cast.target, watcherID: watcherID)
    }
    public func ack(watcherID: String, window: String, sequence: Int) async throws {
        guard let cast = casts[window], cast.watchers.contains(watcherID) else { return }; try await drive.ack(target: cast.target, watcherID: watcherID, sequence: sequence)
    }
    public func input(watcherID: String, window: String, frame: NativeRPCValue) async throws -> BackendMacAppHandoffCastResult {
        guard let cast = casts[window], cast.watchers.contains(watcherID) else { return .init(ok: false, reason: "that window is not being watched on this connection") }; return try await drive.input(target: cast.target, watcherID: watcherID, frame: frame)
    }
    public func handover(_ window: String) async throws -> BackendMacAppHandoffHandoverState { guard let cast = casts[window] else { return .none }; return try await drive.holding(target: cast.target) }
    public func take(watcherID: String, window: String) async throws -> BackendMacAppHandoffCastResult { guard let cast = casts[window], cast.watchers.contains(watcherID) else { return .init(ok: false, reason: "that window is not being watched on this connection") }; return try await drive.take(target: cast.target, watcherID: watcherID) }
    public func handBack(watcherID: String, window: String, carryOn: Bool) async throws -> BackendMacAppHandoffCastResult { guard let cast = casts[window], cast.watchers.contains(watcherID) else { return .init(ok: false, reason: "that window is not being watched on this connection") }; return try await drive.handBack(target: cast.target, watcherID: watcherID, carryOn: carryOn) }
    public func surfaces() async -> [NativeRPCValue] { await list().prefix(Self.maximumSurfaces).map { window in .object([.init("window", .string(window.window)), .init("url", .string(window.url)), .init("title", .string(window.title)), .init("live", .bool(!(casts[window.window]?.watchers.isEmpty ?? true)))]) } }
    public func dropWatcher(_ watcherID: String) async throws {
        try await drive.dropWatcher(watcherID)
        for window in Array(casts.keys) { casts[window]?.watchers.remove(watcherID); if casts[window]?.watchers.isEmpty == true { casts[window] = nil } }
    }
    /// frontTab is a live read, not a cache of the last open result.
    public static func frontTab(url: String?, title: String) -> BackendMacAppHandoffCastWindow? {
        guard let url else { return nil }
        let parsed = URL(string: url), scheme = parsed?.scheme?.lowercased() ?? ""
        let nonOpaque = ["http", "https", "ftp", "ws", "wss"].contains(scheme) && !(parsed?.host ?? "").isEmpty
        return .init(window: "", target: nil, url: nonOpaque ? url : "", title: title)
    }
}

/// Adapter retains private watch tokens and delegates every pixel/ACK/input to the existing WebKit owner.
/// Required hooks read the same real browser baton; they do not create another handover desk.
public actor BackendMacAppHandoffWebKitCastDrive: BackendMacAppHandoffCastDrive {
    public struct Hooks: Sendable {
        public let watch: @Sendable (BackendBrowserCaptureTarget?) async throws -> BackendWebKitProfileArmingWatch
        public let caller: @Sendable (String) async throws -> BackendBrowserScrapingCaller
        public let holding: @Sendable (BackendBrowserCaptureTarget?) async throws -> BackendMacAppHandoffHandoverState
        public let handBack: @Sendable (BackendBrowserCaptureTarget?, String, Bool) async throws -> BackendMacAppHandoffCastResult
        public init(watch: @escaping @Sendable (BackendBrowserCaptureTarget?) async throws -> BackendWebKitProfileArmingWatch,
                    caller: @escaping @Sendable (String) async throws -> BackendBrowserScrapingCaller,
                    holding: @escaping @Sendable (BackendBrowserCaptureTarget?) async throws -> BackendMacAppHandoffHandoverState,
                    handBack: @escaping @Sendable (BackendBrowserCaptureTarget?, String, Bool) async throws -> BackendMacAppHandoffCastResult) { self.watch = watch; self.caller = caller; self.holding = holding; self.handBack = handBack }
    }
    private struct Entry: Sendable { let watch: BackendWebKitProfileArmingWatch; let token: BackendWebKitProfileArmingWatch.Token; let caller: BackendBrowserScrapingCaller; let target: BackendBrowserCaptureTarget?; let watcher: String; let window: String; let width: Int; let quality: Int }
    private let hooks: Hooks
    private var held: [String: Entry] = [:]
    public init(hooks: Hooks) { self.hooks = hooks }
    private func key(_ target: BackendBrowserCaptureTarget?, _ watcher: String) -> String { (target?.tabID ?? "own") + "\u{0}" + watcher }
    public func start(target: BackendBrowserCaptureTarget?, watcherID: String, window: String, maxWidth: Int, quality: Int, everyNth: Int?, emit: @escaping @Sendable (NativeRPCValue) async throws -> Void) async throws -> BackendMacAppHandoffCastResult {
        if let everyNth, everyNth != 1 { return .init(ok: false, reason: "everyNth is unavailable for event-driven WebKit snapshots.") }
        let id = key(target, watcherID)
        if let entry = held[id] {
            if entry.width == maxWidth && entry.quality == quality && entry.window == window { return .init(ok: true) }
            return .init(ok: false, reason: "Changing a WebKit watch's geometry is unavailable until the shared watch owner supplies reconfiguration.")
        }
        let caller = try await hooks.caller(watcherID), watch = try await hooks.watch(target)
        let token = try await watch.watch(caller: caller, window: window, maxWidth: maxWidth, quality: quality, emit: emit)
        held[id] = Entry(watch: watch, token: token, caller: caller, target: target, watcher: watcherID, window: window, width: maxWidth, quality: quality)
        return .init(ok: true)
    }
    public func stop(target: BackendBrowserCaptureTarget?, watcherID: String) async throws { guard let entry = held[key(target, watcherID)] else { return }; try await entry.watch.unwatch(entry.token, caller: entry.caller); held[key(target, watcherID)] = nil }
    public func ack(target: BackendBrowserCaptureTarget?, watcherID: String, sequence: Int) async throws { guard let entry = held[key(target, watcherID)] else { return }; try await entry.watch.acknowledge(entry.token, caller: entry.caller, sequence: sequence) }
    public func input(target: BackendBrowserCaptureTarget?, watcherID: String, frame: NativeRPCValue) async throws -> BackendMacAppHandoffCastResult {
        guard let entry = held[key(target, watcherID)], let sequence = frame["seq"].number else { return .init(ok: false, reason: "that window is not being watched on this connection") }
        let value = frame.removing("t").removing("window").removing("seq")
        let answer = try await entry.watch.input(entry.token, caller: entry.caller, sequence: Int(sequence), value: value); return .init(ok: answer["ok"].bool ?? true, reason: answer["reason"].string ?? answer["message"].string)
    }
    public func holding(target: BackendBrowserCaptureTarget?) async throws -> BackendMacAppHandoffHandoverState { try await hooks.holding(target) }
    public func take(target: BackendBrowserCaptureTarget?, watcherID: String) async throws -> BackendMacAppHandoffCastResult { guard let entry = held[key(target, watcherID)] else { return .init(ok: false, reason: "that window is not being watched on this connection") }; try await entry.watch.take(entry.token, caller: entry.caller); return .init(ok: true) }
    public func handBack(target: BackendBrowserCaptureTarget?, watcherID: String, carryOn: Bool) async throws -> BackendMacAppHandoffCastResult {
        guard let entry = held[key(target, watcherID)] else { return .init(ok: false, reason: "that window is not being watched on this connection") }
        let answer = try await hooks.handBack(target, watcherID, carryOn)
        if answer.ok { try await entry.watch.untake(entry.token, caller: entry.caller); await entry.watch.uncurtain() }; return answer
    }
    public func dropWatcher(_ watcherID: String) async throws {
        for id in held.keys.filter({ held[$0]?.watcher == watcherID }) { guard let entry = held[id] else { continue }; try await entry.watch.unwatch(entry.token, caller: entry.caller); held[id] = nil }
    }
}
