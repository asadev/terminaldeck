import Foundation
import TerminalDeckNativeCore

public struct BackendRemotePanelRequest: Sendable {
    public let path: String
    public let scope: String?
    public let query: String?
}
public struct BackendRemotePanelActionRequest: Sendable {
    public let panel: BackendRemotePanelRequest
    public let action: String
    public let id: String?
    public let fields: [String: String]
}
public struct BackendRemotePanelProvider: Sendable {
    public let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> NativeRPCValue
    public let act: (@Sendable (BackendRemotePanelActionRequest, NativeRPCContext) async throws -> NativeRPCValue)?
    public init(read: @escaping @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> NativeRPCValue,
                act: (@Sendable (BackendRemotePanelActionRequest, NativeRPCContext) async throws -> NativeRPCValue)? = nil) { self.read = read; self.act = act }
}

/// Artifact/Store/Readiness/MCP adapters share the actual panel contract. No
/// placeholder provider is installed for a domain that has not been supplied.
public actor BackendRemotePanelRegistry {
    public enum Domain: String, CaseIterable, Sendable { case artifacts, store, readiness, mcp }
    private var panels: [String: BackendRemotePanelProvider] = [:]
    public init() {}
    public func register(_ domain: Domain, provider: BackendRemotePanelProvider) throws {
        guard panels[domain.rawValue] == nil else { throw NativeRPCError(code: "panel-duplicate", message: "That native remote panel already has an owner") }
        panels[domain.rawValue] = provider
    }
    public func unregister(_ domain: Domain) { panels[domain.rawValue] = nil }
    public func suppliedDomains() -> [String] { panels.keys.sorted() }
    public func feature() throws -> BackendRemoteHostFeature {
        guard !panels.isEmpty else { throw NativeRPCError(code: "panel-unavailable", message: "No actual native panel providers are registered") }
        return .init(capability: "panels", messageTypes: ["panel.read", "panel.act"], policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "panel-closed", message: "The native panel registry stopped") }
            return [try await self.handle(message, context: context)]
        }
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> BackendRemoteServerMessage {
        try await handle(message, context: context, rpcContext: context.rpcContext)
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext, rpcContext: NativeRPCContext) async throws -> BackendRemoteServerMessage {
        let name = message["panel"].string!
        guard let provider = panels[name] else { throw NativeRPCError(code: "panel-unavailable", message: "The \(name) panel has no native service registered on this host") }
        let path = message["path"].string ?? context.reach.folders.first ?? ""
        guard !path.isEmpty, context.reach.unrestricted || context.reach.folders.contains(where: { BackendRemoteTrustStore.within($0, path) }) else { throw NativeRPCError(code: "panel-denied", message: "This device was not granted that project folder") }
        let request = BackendRemotePanelRequest(path: path, scope: message["scope"].string, query: message["query"].string)
        let before = try await provider.read(request, rpcContext)
        try validatePayload(before, expectedPath: path)
        let result: NativeRPCValue
        if message.type == "panel.act" {
            guard let act = provider.act else { throw NativeRPCError(code: "panel-read-only", message: "This panel has no editable native actions") }
            let action = message["action"].string!, id = message["id"].string
            let offered: [NativeRPCValue]
            if let id {
                guard let row = before["rows"].elements?.first(where: { $0["id"].string == id || name == "artifacts" && $0["id"].string?.split(separator: " ").first.map(String.init) == id }) else { throw NativeRPCError(code: "panel-row", message: "That row is no longer in the panel") }
                if name == "artifacts" && action == "preview" { offered = [.object([.init("id", .string("preview"))])] }
                else { offered = row["actions"].elements ?? [] }
            } else { offered = before["actions"].elements ?? [] }
            guard let chosen = offered.first(where: { $0["id"].string == action || $0["action"].string == action }), chosen["disabled"].bool != true else {
                throw NativeRPCError(code: "panel-action", message: "That action was not offered by this panel")
            }
            let fields = Dictionary(uniqueKeysWithValues: (message["fields"].fields ?? []).map { ($0.key, $0.value.string!) })
            result = try await act(.init(panel: request, action: action, id: id, fields: fields), rpcContext)
            try validatePayload(result, expectedPath: path)
        } else { result = before }
        // An action's real redraw is its confirmation. Outcomes never invent a
        // row or report success separately from the actual panel contents.
        let additions = result.fields?.filter { $0.key != "panel" } ?? []
        return try .init(.panelRows, fields: [.init("panel", .string(name))] + additions)
    }
    private func validatePayload(_ value: NativeRPCValue, expectedPath: String) throws {
        guard value.fields != nil, value["path"].string == expectedPath, let rows = value["rows"].elements, rows.count <= 200 else { throw NativeRPCError.malformed("The native panel service returned a malformed path or row list") }
        for row in rows {
            guard row.fields != nil, row["title"].string != nil, row["id"] == .missing || row["id"].string != nil else { throw NativeRPCError.malformed("The native panel service returned a malformed row") }
        }
    }
}

/// A supplied native domain registry can be adapted without Node IPC. The
/// integration worker must pass actual installed channels and exact result
/// projection; this factory refuses missing channels before registering a panel.
public enum BackendRemotePanelChannels {
    public static func provider(registry: NativeChannelRegistry, readChannel: String,
                                readArguments: @escaping @Sendable (BackendRemotePanelRequest) -> [NativeRPCValue],
                                projectRead: @escaping @Sendable (NativeRPCValue, BackendRemotePanelRequest) throws -> NativeRPCValue,
                                actions: [String: String] = [:],
                                actionArguments: @escaping @Sendable (BackendRemotePanelActionRequest) -> [NativeRPCValue] = { _ in [] }) async throws -> BackendRemotePanelProvider {
        guard await registry.has(readChannel) else { throw NativeRPCError(code: "panel-dependency", message: "The actual native \(readChannel) service is not registered") }
        for channel in actions.values { guard await registry.has(channel) else { throw NativeRPCError(code: "panel-dependency", message: "The native panel action \(channel) is not registered") } }
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> NativeRPCValue = { request, context in
            try projectRead(await registry.invoke(readChannel, context: context, arguments: readArguments(request)), request)
        }
        guard !actions.isEmpty else { return .init(read: read) }
        return .init(read: read, act: { action, context in
            guard let channel = actions[action.action] else { throw NativeRPCError(code: "panel-action", message: "That native action has no registered implementation") }
            _ = try await registry.invoke(channel, context: context, arguments: actionArguments(action))
            return try await read(action.panel, context)
        })
    }
}
