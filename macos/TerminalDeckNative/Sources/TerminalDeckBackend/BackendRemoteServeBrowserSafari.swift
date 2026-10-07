import Foundation
import TerminalDeckNativeCore

/// The remote phone toolbar uses Safari's native toolbar APIs. It does not
/// impersonate a nativeApp caller or relax the six agent tools' paired-device
/// refusal. The live resolver must explicitly grant a My-device browser picker.
@MainActor
public final class BackendRemoteServeBrowserSafari: BackendRemoteServeBrowserOperations {
    public typealias Mine = @Sendable (String) async -> Bool
    public typealias Sessions = @MainActor (NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession]
    public typealias Write = @MainActor (String, String, NativeRPCContext) async throws -> Void
    public typealias StartPage = @MainActor (NativeRPCContext) async throws -> String
    public let service: BackendBrowserService
    public var bindings: BackendBrowserBindings { service.bindings }
    public let machineID: String
    public var canRecord: Bool { true }
    public var canRepartition: Bool { true }
    public var canPick: Bool { documentPicker != nil }
    // A desktop does not accept a remote viewport resize. The protocol default
    // returns the source's explicit policy refusal for browser.window.size.
    private let mine: Mine
    private let readSessions: Sessions
    private let writeSession: Write
    private let startPage: StartPage
    private let authorize: BackendBrowserService.Authorize
    private let documentPicker: (any BackendRemoteServeBrowserDocumentPicking)?
    public init(service: BackendBrowserService, machineID: String = "", isMine: @escaping Mine,
                sessions: @escaping Sessions, write: @escaping Write, startPage: @escaping StartPage,
                authorize: @escaping BackendBrowserService.Authorize,
                documentPicker: (any BackendRemoteServeBrowserDocumentPicking)? = nil) {
        self.service = service; self.machineID = machineID; mine = isMine
        readSessions = sessions; writeSession = write; self.startPage = startPage
        self.authorize = authorize; self.documentPicker = documentPicker
    }
    public func isMine(_ deviceID: String) async -> Bool {
        guard !deviceID.isEmpty else { return false }
        return await mine(deviceID)
    }
    private func principal(_ context: NativeRPCContext) async throws -> BackendBrowserPrincipal {
        guard context.caller == .pairedDevice, await isMine(context.ownerID) else {
            throw NativeRPCError(code: "unavailable", message: "This machine does not let this phone drive its browser.")
        }
        let who = try await service.principal(context)
        guard who.managesWindows, who.sessionID == nil, who.ownerID == context.ownerID else {
            throw NativeRPCError(code: "not-permitted", message: "This device has no grant to manage this machine's browser.")
        }
        return who
    }
    public func list(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserWindow] {
        _ = try await principal(context)
        _ = try await service.bindingsView(context)
        var rows: [BackendRemoteServeBrowserWindow] = []
        for entry in bindings.windows() where entry.hostMachineID.isEmpty {
            guard service.runtime.tabExists(entry.tabID) else { continue }
            let state = try service.runtime.pageState(entry.tabID)
            // An active sign-in popup is a person's surface, never a remote
            // window target. Regular handover-held tabs still keep their row.
            if state["transientSignIn"].bool == true { continue }
            rows.append(.init(id: entry.tabID, title: state["title"].string ?? entry.title,
                url: state["url"].string.flatMap { $0.isEmpty ? nil : $0 } ?? entry.url, viewID: entry.viewID,  // machine-browser-desktop.ts:382 `page?.url || pane.url`
                // machine-browser-desktop.ts:386: an isolated page is nobody's profile, so only `isolated` rides the wire.
                profile: (state["isolated"].bool ?? false) ? "" : (state["profileId"].string ?? ""), isolated: state["isolated"].bool ?? false,
                recording: state["recording"].bool ?? false, loading: state["loading"].bool ?? false))
        }
        _ = try await principal(context)
        return rows
    }
    public func sessions(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession] {
        _ = try await principal(context)
        let rows = try await readSessions(context)
        _ = try await principal(context)
        return rows
    }
    public func open(url: String, profile: String, isolated: Bool, context: NativeRPCContext) async throws -> String? {
        _ = try await principal(context)
        let address: String
        if url.isEmpty { address = try await startPage(context) } else { address = url }
        var args = NativeRPCValue.object([.init("url", .string(address)), .init("isolated", .bool(isolated))])
        if !profile.isEmpty { args = args.setting("profileId", .string(profile)) }
        let state = try await service.nativeCreate(context, arguments: args)
        return try state["id"].requireString("browser window id", nonempty: true)
    }
    public func go(id: String, url: String, context: NativeRPCContext) async throws {
        _ = try await principal(context)
        _ = try await service.nativePage(context, id: id, operation: "navigate", arguments: .object([.init("url", .string(url))]))
    }
    public func history(id: String, move: String, context: NativeRPCContext) async throws {
        _ = try await principal(context)
        guard ["back", "forward", "reload"].contains(move) else { throw NativeRPCError.invalidArguments("Unknown history action.") }
        _ = try await service.nativePage(context, id: id, operation: move, arguments: .object([]))
    }
    public func close(id: String, context: NativeRPCContext) async throws {
        _ = try await principal(context)
        _ = try await service.nativePage(context, id: id, operation: "close", arguments: .object([]))
        bindings.closed(id)
    }
    public func attach(id: String, sessionID: String, context: NativeRPCContext) async throws -> BrowserBoundWindow {
        let who = try await principal(context)
        _ = try await service.bind(context, arguments: .object([.init("tabId", .string(id)),
            .init("sessionId", .string(sessionID)), .init("machineId", .string(machineID))]))
        let session = BrowserDriverSession(sessionId: sessionID, machineId: machineID)
        guard let bound = bindings.bindings(for: who).of(session).first(where: { $0.tabID == id }) else {
            throw NativeRPCError(code: "unavailable", message: "That browser window could not be attached to this session.")
        }
        return bound
    }
    public func detach(id: String, context: NativeRPCContext) async throws {
        _ = try await principal(context)
        _ = try await service.bind(context, arguments: .object([.init("tabId", .string(id))]), detach: true)
    }
    public func repartition(id: String, isolated: Bool, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserMove? {
        let who = try await principal(context)
        let state = try await service.nativePage(context, id: id, operation: "state", arguments: .object([]))
        try await authorize(.init(tool: "browser:repartition", principal: who, tabID: id,
            profileID: state["profileId"].string, origin: BackendBrowserOrigin.exact(service.runtime.pageURL(id)),
            tier: .act, arguments: .object([.init("isolated", .bool(isolated))])))
        _ = try await principal(context)
        guard service.runtime.tabExists(id), service.runtime.handoverPrompt(id) == nil else {
            throw NativeRPCError(code: "not-permitted", message: "The person has this page or it is no longer available.")
        }
        service.runtime.setIsolated(id, isolated)
        guard service.runtime.tabExists(id), service.runtime.isIsolated(id) == isolated else { return nil }
        let updated = try service.runtime.pageState(id)
        bindings.observe(.init(tabID: id, viewID: id, url: updated["url"].string ?? "", title: updated["title"].string ?? ""))
        return .init(viewID: id)
    }
    public func setRecording(id: String, on: Bool, context: NativeRPCContext) async throws {
        _ = try await principal(context)
        _ = try await service.nativePage(context, id: id, operation: "record", arguments: .object([.init("on", .bool(on))]))
    }
    public func recordedSteps(id: String, context: NativeRPCContext) async throws -> [BrowserRecordedStep] {
        _ = try await principal(context)
        let reading = try await service.nativePage(context, id: id, operation: "recording", arguments: .object([]))
        let rows = try reading["steps"].requireArray("recorded steps")
        return try rows.map { row in
            guard let rawKind = row["kind"].string, let kind = BrowserRecordedStep.Kind(rawValue: rawKind), let at = row["at"].number else {
                throw NativeRPCError(code: "unavailable", message: "The browser returned an unreadable recorded step.")
            }
            let redacted = row["redacted"].bool == true
            return .init(kind: kind, selector: row["selector"].string ?? "", label: row["label"].string ?? "",
                tag: row["tag"].string ?? "", value: redacted ? "" : row["value"].string ?? "", redacted: redacted,
                key: row["key"].string ?? "", checked: row["checked"].bool ?? false, url: row["url"].string ?? "", at: at)
        }
    }
    public func capture(id: String, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserCapture {
        _ = try await principal(context)
        let shot = try await service.nativePage(context, id: id, operation: "user-screenshot", arguments: .object([]))
        _ = try await principal(context)
        guard let width = shot["width"].number, let height = shot["height"].number,
              width >= 0, height >= 0, width <= 16_384, height <= 16_384 else {
            throw NativeRPCError(code: "unavailable", message: "The browser returned an unreadable screenshot size.")
        }
        let prefix = "data:image/png;base64,", encoded = shot["preview"].string ?? ""
        let preview = encoded.hasPrefix(prefix) ? Data(base64Encoded: String(encoded.dropFirst(prefix.count))) ?? Data() : Data()
        return .init(path: shot["path"].string ?? "", width: Int(width), height: Int(height), preview: preview)
    }
    public func pick(id: String, x: Double, y: Double, up: Int, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked {
        let who = try await principal(context)
        guard let documentPicker else { throw NativeRPCError(code: "unavailable", message: "This machine's browser cannot point at one thing on a page.") }
        let state = try await service.nativePage(context, id: id, operation: "state", arguments: .object([]))
        try await authorize(.init(tool: "browser:pick", principal: who, tabID: id,
            profileID: state["profileId"].string, origin: BackendBrowserOrigin.exact(service.runtime.pageURL(id)), tier: .read,
            arguments: .object([.init("x", .number(x)), .init("y", .number(y)), .init("up", .number(Double(up)))])))
        _ = try await principal(context)
        guard service.runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "The person has this page.") }
        let picked = try await documentPicker.pickDocumentPoint(tabID: id, x: x, y: y, up: up, context: context)
        _ = try await principal(context)
        guard service.runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "The person has this page.") }
        return picked
    }
    public func write(sessionID: String, data: String, context: NativeRPCContext) async throws {
        let who = try await principal(context)
        guard let target = try await readSessions(context).first(where: { $0.id == sessionID }), !target.ended else {
            throw NativeRPCError(code: "not-permitted", message: "That session is no longer available to this device.")
        }
        try await authorize(.init(tool: "session.send", principal: who, tier: .act,
            targetSession: .init(sessionId: sessionID, machineId: machineID)))
        _ = try await principal(context)
        try await writeSession(sessionID, data, context)
    }
}
