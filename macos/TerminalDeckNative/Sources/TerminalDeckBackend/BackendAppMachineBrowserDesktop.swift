import Foundation
import TerminalDeckNativeCore

/// Source desktop panes and their current page are different identities. The
/// access supplier reads the same native UI/Safari owner, never a second map.
public struct BackendAppDesktopBrowserPane: Sendable {
    public let id: String, viewID: String?, url: String, title: String
    public init(id: String, viewID: String?, url: String = "", title: String = "") { self.id = id; self.viewID = viewID; self.url = url; self.title = title }
}
public struct BackendAppDesktopBrowserPage: Sendable {
    public let url: String, loading: Bool, profile: String
    public init(url: String, loading: Bool = false, profile: String) { self.url = url; self.loading = loading; self.profile = profile }
}
public struct BackendAppDesktopBrowserTarget: Sendable {
    public let id: String, viewID: String, name: String
    public init(id: String, viewID: String, name: String) { self.id = id; self.viewID = viewID; self.name = name }
}

@MainActor public struct BackendAppDesktopBrowserRecorder {
    public struct State: Sendable {
        public let recording: Bool, steps: [BrowserRecordedStep]
        public init(recording: Bool, steps: [BrowserRecordedStep]) { self.recording = recording; self.steps = steps }
    }
    public let state: @MainActor (String, NativeRPCContext) async throws -> State
    public let set: @MainActor (String, Bool, NativeRPCContext) async throws -> Void
    public init(state: @escaping @MainActor (String, NativeRPCContext) async throws -> State,
                set: @escaping @MainActor (String, Bool, NativeRPCContext) async throws -> Void) { self.state = state; self.set = set }
}

/// The native app supplies these operations through its actual shared Safari
/// runtime and window owner. Required operations have no successful defaults.
@MainActor public struct BackendAppDesktopBrowserAccess {
    public typealias Pick = @MainActor (BackendAppDesktopBrowserTarget, Double, Double, Int, NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked
    public let panes: @MainActor (NativeRPCContext) async throws -> [BackendAppDesktopBrowserPane]
    public let page: @MainActor (String, NativeRPCContext) async throws -> BackendAppDesktopBrowserPage?
    public let openPane: @MainActor (String, NativeRPCContext) async throws -> String?
    public let closePane: @MainActor (BackendAppDesktopBrowserTarget, NativeRPCContext) async throws -> Bool
    public let go: @MainActor (String, String, NativeRPCContext) async throws -> Void
    public let history: @MainActor (String, String, NativeRPCContext) async throws -> Void
    public let capture: @MainActor (String, NativeRPCContext) async throws -> BackendRemoteServeBrowserCapture
    public let sessions: @MainActor (NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession]
    public let write: @MainActor (String, String, NativeRPCContext) async throws -> Void
    public let authorize: @MainActor (NativeRPCContext, String, String?) async throws -> Void
    public let pick: Pick?
    public let recorder: BackendAppDesktopBrowserRecorder?
    public let now: @MainActor () -> Double
    public let wait: @MainActor (Int) async throws -> Void
    public init(panes: @escaping @MainActor (NativeRPCContext) async throws -> [BackendAppDesktopBrowserPane],
                page: @escaping @MainActor (String, NativeRPCContext) async throws -> BackendAppDesktopBrowserPage?,
                openPane: @escaping @MainActor (String, NativeRPCContext) async throws -> String?,
                closePane: @escaping @MainActor (BackendAppDesktopBrowserTarget, NativeRPCContext) async throws -> Bool,
                go: @escaping @MainActor (String, String, NativeRPCContext) async throws -> Void,
                history: @escaping @MainActor (String, String, NativeRPCContext) async throws -> Void,
                capture: @escaping @MainActor (String, NativeRPCContext) async throws -> BackendRemoteServeBrowserCapture,
                sessions: @escaping @MainActor (NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession],
                write: @escaping @MainActor (String, String, NativeRPCContext) async throws -> Void,
                authorize: @escaping @MainActor (NativeRPCContext, String, String?) async throws -> Void,
                pick: Pick? = nil, recorder: BackendAppDesktopBrowserRecorder? = nil,
                now: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 },
                wait: @escaping @MainActor (Int) async throws -> Void) {
        self.panes = panes; self.page = page; self.openPane = openPane; self.closePane = closePane; self.go = go; self.history = history
        self.capture = capture; self.sessions = sessions; self.write = write; self.authorize = authorize; self.pick = pick; self.recorder = recorder
        self.now = now; self.wait = wait
    }
}

/// machine-browser-desktop.ts. Reuses the existing remote controller, protocol
/// models, binding store and Safari primitives. No Chrome/Electron operation.
@MainActor public final class BackendAppMachineBrowserDesktop: BackendRemoteServeBrowserOperations {
    public static let noIsolatedOpen = "This computer opens browser windows in its own window, which cannot mint an isolated partition from here — open it, then use Isolate at the keyboard."
    public static let noProfileOpen = "This computer opens browser windows in the profile it is switched to; choosing another one is done at its keyboard."
    public static let noPage = "that window has no page in it yet"
    public let bindings: BackendBrowserBindings
    public let machineID: String
    public var canRecord: Bool { access.recorder != nil }
    public var canPick: Bool { access.pick != nil }
    // The source compatibility endpoint does not promise remote partitioning
    // or viewport sizing. Native Safari's separate supplied operations may.
    public var canRepartition: Bool { false }
    public var canResize: Bool { false }
    private let access: BackendAppDesktopBrowserAccess
    private let mine: @Sendable (String) async -> Bool
    private var refusal: String?
    public init(access: BackendAppDesktopBrowserAccess, bindings: BackendBrowserBindings, machineID: String = "", isMine: @escaping @Sendable (String) async -> Bool) {
        self.access = access; self.bindings = bindings; self.machineID = machineID; mine = isMine
    }
    public func controller() -> BackendRemoteServeBrowserControl { .init(operations: self) }
    public func isMine(_ deviceID: String) async -> Bool {
        guard !deviceID.isEmpty else { return false }; return await mine(deviceID)
    }
    private func pane(_ id: String, context: NativeRPCContext) async throws -> BackendAppDesktopBrowserPane? {
        try await access.panes(context).first { $0.id == id }
    }
    private func view(_ id: String, context: NativeRPCContext) async throws -> String {
        guard let pane = try await pane(id, context: context), let view = pane.viewID else { throw NativeRPCError(code: "unavailable", message: Self.noPage) }; return view
    }
    private func page(_ id: String, context: NativeRPCContext) async throws -> (String, BackendAppDesktopBrowserPage) {
        let view = try await view(id, context: context)
        guard let page = try await access.page(view, context) else { throw NativeRPCError(code: "unavailable", message: Self.noPage) }; return (view, page)
    }
    public func list(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserWindow] {
        try await access.authorize(context, "browser.windows", nil)
        var rows: [BackendRemoteServeBrowserWindow] = []
        for pane in try await access.panes(context) {
            let page: BackendAppDesktopBrowserPage?
            if let view = pane.viewID { page = try await access.page(view, context) }
            else { page = nil }
            var recording = false
            if page != nil, let id = pane.viewID, let recorder = access.recorder { recording = (try? await recorder.state(id, context).recording) ?? false }
            let url = page?.url.isEmpty == false ? page!.url : pane.url
            rows.append(.init(id: pane.id, title: pane.title, url: url, viewID: pane.viewID,
                profile: page?.profile ?? "", isolated: page?.profile.isEmpty == true, recording: recording, loading: page?.loading == true))
            bindings.observe(.init(tabID: pane.id, viewID: pane.viewID ?? "", url: url, title: pane.title))
        }
        return rows
    }
    public func sessions(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession] {
        try await access.authorize(context, "sessions.list", nil); return try await access.sessions(context)
    }
    public func open(url: String, profile: String, isolated: Bool, context: NativeRPCContext) async throws -> String? {
        refusal = nil
        try await access.authorize(context, "browser.window.open", nil)
        if isolated { refusal = Self.noIsolatedOpen; return nil }
        if !profile.isEmpty { refusal = Self.noProfileOpen; return nil }
        let id = try await access.openPane(url, context)
        if id == nil { refusal = "No window of this app answered, so there was nowhere to put the page — its browser may be switched off in Features." }
        return id
    }
    public func whyNotOpen() -> String? { refusal }
    public func go(id: String, url: String, context: NativeRPCContext) async throws {
        try await access.authorize(context, "browser.window.go", id)
        let (view, _) = try await page(id, context: context)
        try await access.go(view, Self.normalizedURL(url), context)
    }
    public func history(id: String, move: String, context: NativeRPCContext) async throws {
        try await access.authorize(context, "browser.window.act", id)
        let (view, _) = try await page(id, context: context)
        try await access.history(view, move == "back" || move == "forward" ? move : "reload", context)
    }
    public func close(id: String, context: NativeRPCContext) async throws {
        try await access.authorize(context, "browser.window.act", id)
        guard let pane = try await pane(id, context: context) else { throw NativeRPCError(code: "unavailable", message: "that window is not open here") }
        guard try await access.closePane(.init(id: pane.id, viewID: pane.viewID ?? "", name: pane.title.isEmpty ? pane.url : pane.title), context) else {
            throw NativeRPCError(code: "unavailable", message: "the window that holds it did not answer")
        }
    }
    public func attach(id: String, sessionID: String, context: NativeRPCContext) async throws -> BrowserBoundWindow {
        try await access.authorize(context, "browser.window.bind", id)
        guard let pane = try await pane(id, context: context) else { throw NativeRPCError(code: "unavailable", message: "that window is not open here") }
        let page: BackendAppDesktopBrowserPage?
        if let view = pane.viewID { page = try await access.page(view, context) } else { page = nil }
        let url = page?.url.isEmpty == false ? page!.url : pane.url
        bindings.observe(.init(tabID: pane.id, viewID: pane.viewID ?? "", url: url, title: pane.title))
        return try bindings.attach(pane.id, to: .init(sessionId: sessionID, machineId: machineID))
    }
    public func detach(id: String, context: NativeRPCContext) async throws { try await access.authorize(context, "browser.window.bind", id); bindings.detach(id) }
    public func setRecording(id: String, on: Bool, context: NativeRPCContext) async throws {
        try await access.authorize(context, "browser.window.act", id)
        guard let recorder = access.recorder else { throw NativeRPCError(code: "unavailable", message: "This machine's browser cannot record a click flow.") }
        try await recorder.set(view(id, context: context), on, context)
    }
    public func recordedSteps(id: String, context: NativeRPCContext) async throws -> [BrowserRecordedStep] {
        try await access.authorize(context, "browser.window.steps", id)
        guard let recorder = access.recorder else { throw NativeRPCError(code: "unavailable", message: "This machine's browser cannot record a click flow.") }
        return try await recorder.state(view(id, context: context), context).steps
    }
    public func capture(id: String, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserCapture {
        try await access.authorize(context, "browser.window.shot", id); return try await access.capture(view(id, context: context), context)
    }
    public func pick(id: String, x: Double, y: Double, up: Int, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked {
        try await access.authorize(context, "browser.window.pick", id)
        guard let pick = access.pick else { throw NativeRPCError(code: "unavailable", message: "This machine's browser cannot point at one thing on a page.") }
        let pane = try await pane(id, context: context), view = try await view(id, context: context)
        let name = pane?.title.isEmpty == false ? pane!.title : pane?.url.isEmpty == false ? pane!.url : "That window"
        return try await pick(.init(id: id, viewID: view, name: name), x, y, up, context)
    }
    public func write(sessionID: String, data: String, context: NativeRPCContext) async throws {
        try await access.authorize(context, "session.send", sessionID); try await access.write(sessionID, data, context)
    }
    public func now() -> Double { access.now() }
    public func wait(milliseconds: Int) async throws { try await access.wait(milliseconds) }
    /// The source desktop preprocessor is needed before Core's existing strict
    /// http(s) validator; omnibox search behavior is not appropriate here.
    public static func normalizedURL(_ input: String) throws -> String {
        let trimmed = BackendSharedText.trim(input)
        func refuse(_ message: String) throws -> Never { throw NativeRPCError(code: "browser-url", message: message) }
        if trimmed.isEmpty { try refuse("Enter a URL to open.") }
        if trimmed.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) { try refuse("That URL contains characters a URL cannot contain.") }
        var candidate = trimmed
        if BackendSharedText.matches(trimmed, #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#) {
            let scheme = String(trimmed.prefix { $0 != ":" }).lowercased()
            if scheme != "http" && scheme != "https" {
                guard BackendSharedText.matches(trimmed, #"^(?:[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*|\[[0-9a-fA-F:]+\]):[0-9]{1,5}(?:[/?#].*)?$"#) else { try refuse("Only http and https can be opened here, not \(scheme):.") }
                candidate = "http://" + trimmed
            }
        } else { candidate = trimmed.hasPrefix("//") ? "http:" + trimmed : "http://" + trimmed }
        guard var parts = URLComponents(string: candidate), let host = parts.host, !host.isEmpty else { try refuse("That is not a URL this can open.") }
        if let port = parts.port, !(0...65535).contains(port) { try refuse("That is not a URL this can open.") }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host.lowercased()
        if parts.path.isEmpty { parts.path = "/" }
        if parts.scheme == "http" && parts.port == 80 || parts.scheme == "https" && parts.port == 443 { parts.port = nil }
        guard let value = parts.url?.absoluteString else { try refuse("That is not a URL this can open.") }
        _ = try BrowserStepRules.openableURL(value); return value
    }
}
