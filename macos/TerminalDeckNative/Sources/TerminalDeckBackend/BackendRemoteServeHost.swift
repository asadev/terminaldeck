import Foundation
import TerminalDeckNativeCore

/// GitHub authentication worker supplies the same account-shaped source state
/// as github-auth.ts, not a remote token or a folder's repository status.
public protocol BackendRemoteServeGitHubAuthenticator: Sendable {
    func status() async throws -> NativeRPCValue
    func connect() async throws
    func cancelConnect() async throws -> NativeRPCValue
    func disconnect() async throws -> NativeRPCValue
    func flowFailure() async -> String?
}
public actor BackendRemoteServeGitHub {
    private let authenticator: any BackendRemoteServeGitHubAuthenticator
    private var listeners: [UUID: @Sendable () async -> Void] = [:]
    public init(authenticator: any BackendRemoteServeGitHubAuthenticator) { self.authenticator = authenticator }
    public static func wire(_ state: NativeRPCValue, flowFailure: String?) -> NativeRPCValue {
        let connected = state["connected"].bool == true
        let identity = state["identity"], pending = state["pending"]
        let failure = connected ? nil : state["failure"]["message"].string ?? flowFailure
        return .object([.init("connected", .bool(connected)), .init("login", identity["login"].orNull),
            .init("name", identity["name"].orNull), .init("avatarUrl", identity["avatarUrl"].orNull),
            .init("source", state["source"].orNull), .init("appConfigured", state["appConfigured"].orNull),
            .init("installUrl", state["installUrl"].orNull), .init("pending", pending.fields == nil ? .null : .object([
                .init("userCode", pending["userCode"].orNull), .init("verificationUri", pending["verificationUri"].orNull),
                .init("expiresAt", pending["expiresAt"].orNull)])),
            .init("failure", failure.map(NativeRPCValue.string) ?? .null), .init("disconnect", state["disconnect"].orNull)])
    }
    public func read() async throws -> NativeRPCValue {
        let state = try await authenticator.status()
        return Self.wire(state, flowFailure: await authenticator.flowFailure())
    }
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "github", messageTypes: ["github.read", "github.connect", "github.cancel", "github.disconnect"], policy: .ownerOnly) { [self] message, context in
            guard context.kind == .mine else { return [try .error(code: "unauthorized", message: "Only this machine’s own devices manage its GitHub sign-in.")] }
            return [try await handle(message)]
        }
    }
    private func handle(_ message: BackendRemoteClientMessage) async throws -> BackendRemoteServerMessage {
        let state: NativeRPCValue
        switch message.type {
        case "github.connect": try await authenticator.connect(); state = try await read()
        case "github.cancel": state = Self.wire(try await authenticator.cancelConnect(), flowFailure: await authenticator.flowFailure())
        case "github.disconnect": state = Self.wire(try await authenticator.disconnect(), flowFailure: await authenticator.flowFailure())
        case "github.read": state = try await read()
        default: throw NativeRPCError.invalidArguments("Not a GitHub host message")
        }
        return try .init(.githubState, fields: [.init("rid", message["rid"]), .init("github", state)])
    }
    public func onChanged(_ listener: @escaping @Sendable () async -> Void) -> UUID { let id = UUID(); listeners[id] = listener; return id }
    public func unsubscribe(_ id: UUID) { listeners[id] = nil }
    public func emitChanged() async { for listener in Array(listeners.values) { await listener() } }
    /// Integration sends only to live mine connections claiming github.
    public func changedMessage() async throws -> BackendRemoteServerMessage { try .init(.githubChanged, fields: [.init("github", try await read())]) }
}

/// Desktop builds do not advertise host.control without an actual lifecycle
/// provider. Linux daemon implementation remains on the Linux source graph.
public protocol BackendRemoteServeHostLifecycle: Sendable {
    func status() async throws -> NativeRPCValue
    /// Schedule, then return; provider must allow reply to flush before exiting.
    func restart() async throws -> String
    func stop() async throws -> String
}
public enum BackendRemoteServeLifecycle {
    public static func wire(_ facts: NativeRPCValue, note: String?) -> NativeRPCValue {
        .object([.init("running", .bool(true))] + ["version", "address", "pid", "startedAt", "uptimeSeconds", "managed"].map {
            .init($0, facts[$0].orNull)
        } + [.init("note", note.map(NativeRPCValue.string) ?? .null)])
    }
    public static func feature(_ lifecycle: any BackendRemoteServeHostLifecycle) -> BackendRemoteHostFeature {
        .init(capability: "host.control", messageTypes: ["host.status", "host.restart", "host.stop"], policy: .ownerOnly) { message, context in
            guard context.kind == .mine else { return [try .error(code: "unauthorized", message: "Only this machine’s own devices manage its host.")] }
            let note: String?
            switch message.type { case "host.restart": note = try await lifecycle.restart(); case "host.stop": note = try await lifecycle.stop(); default: note = nil }
            return [try .init(.hostState, fields: [.init("rid", message["rid"]), .init("host", wire(try await lifecycle.status(), note: note))])]
        }
    }
}

public actor BackendRemoteServeRoster {
    private let trust: BackendRemoteTrustStore
    private let connected: @Sendable () async -> Set<String>
    private let drop: @Sendable (String) async -> Void
    private let forget: @Sendable (String) async throws -> Void
    private let announce: @Sendable () async -> Void
    public init(trust: BackendRemoteTrustStore, connected: @escaping @Sendable () async -> Set<String>,
                drop: @escaping @Sendable (String) async -> Void, forget: @escaping @Sendable (String) async throws -> Void,
                announce: @escaping @Sendable () async -> Void) {
        self.trust = trust; self.connected = connected; self.drop = drop; self.forget = forget; self.announce = announce
    }
    public func list() async -> [NativeRPCValue] {
        let online = await connected()
        var rows: [NativeRPCValue] = []
        let devices = await trust.listDevices()
        for device in devices.enumerated().sorted(by: { a, b in a.element.addedAt == b.element.addedAt ? a.offset < b.offset : a.element.addedAt > b.element.addedAt }).map(\.element) where !device.revoked {
            let kind = await trust.kindOf(device.id)
            rows.append(.object([.init("id", .string(device.id)), .init("name", .string(device.name)), .init("kind", .string(kind.rawValue)),
                .init("status", .string(device.approved ? "approved" : "pending")), .init("addedAt", .number(device.addedAt)),
                .init("lastSeenAt", device.lastSeenAt.map(NativeRPCValue.number) ?? .null), .init("connected", .bool(online.contains(device.id))),
                .init("fingerprint", device.fingerprint.map(NativeRPCValue.string) ?? .null)]))
        }
        return rows
    }
    public func revoke(_ deviceID: String) async throws -> Bool {
        guard try await trust.revoke(deviceID) else { return false }
        await drop(deviceID)
        do { try await forget(deviceID) } catch { await announce(); throw error }
        await announce(); return true
    }
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "devices", messageTypes: ["devices.list", "devices.revoke"], policy: .ownerOnly) { [self] message, context in
            guard context.kind == .mine else { return [try .error(code: "unauthorized", message: "Only your own devices can manage the devices signed in here.")] }
            if message.type == "devices.list" { return [try .init(.deviceRows, fields: [.init("rid", message["rid"]), .init("devices", .array(await list()))])] }
            let removed = try await revoke(message["device"].string!)
            if removed && message["device"].string == context.deviceID { return [] } // self-revoke reply is the socket close
            return [try .init(.deviceRevoked, fields: [.init("rid", message["rid"]), .init("ok", .bool(removed)),
                .init("message", .string(removed ? "That device was removed." : "That device is not signed in here.")), .init("devices", .array(await list()))])]
        }
    }
    public func changedMessage() async throws -> BackendRemoteServerMessage { try .init(.devicesChanged, fields: [.init("devices", .array(await list()))]) }
}

private extension NativeRPCValue { var orNull: NativeRPCValue { self == .missing ? .null : self } }

/// Integration uses these before generic feature denials, preserving the source
/// sentences even when the optional feature is absent on this native host.
public enum BackendRemoteServeHostRefusals {
    public static func missing(_ tag: String) throws -> BackendRemoteServerMessage? {
        if tag.hasPrefix("credential.") { return try .error(code: "unauthorized", message: "Nothing here asked this device for a login.") }
        if tag.hasPrefix("github.") { return try .error(code: "unavailable", message: "This Mac does not manage its GitHub sign-in from here.") }
        if tag.hasPrefix("host.") { return try .error(code: "unavailable", message: "This Mac does not manage its host from here.") }
        if tag.hasPrefix("devices.") { return try .error(code: "unauthorized", message: "Only your own devices can manage the devices signed in here.") }
        if tag.hasPrefix("browser.window.") || tag == "browser.windows" { return try .error(code: "unavailable", message: "This machine does not let this phone drive its browser.") }
        if tag.hasPrefix("account.") { return try .error(code: "unavailable", message: "This Mac cannot change a session’s account from here.") }
        if tag.hasPrefix("logins.") { return try .error(code: "unavailable", message: "This Mac does not manage its logins from here.") }
        if tag == "usage.read" { return try .error(code: "unavailable", message: "This Mac cannot report a session’s usage.") }
        // server.ts settingsServe: not served by this build.
        if tag.hasPrefix("settings.") { return try .error(code: "unavailable", message: "This Mac does not manage its settings from here.") }
        return nil
    }
    public static func guest(_ tag: String) throws -> BackendRemoteServerMessage? {
        if tag.hasPrefix("github.") { return try .error(code: "unauthorized", message: "Only this machine’s own devices manage its GitHub sign-in.") }
        if tag.hasPrefix("host.") { return try .error(code: "unauthorized", message: "Only this machine’s own devices manage its host.") }
        if tag.hasPrefix("settings.") { return try .error(code: "unauthorized", message: "Only this machine’s own devices manage its settings.") }
        if tag.hasPrefix("devices.") || tag.hasPrefix("browser.window.") || tag == "browser.windows" || tag.hasPrefix("logins.") { return try missing(tag) }
        return nil
    }
}
