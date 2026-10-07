import Foundation
import TerminalDeckNativeCore

public enum BackendMacAppHandoffLinkRoute: String, Sendable { case tab, system, refused }
public enum BackendMacAppHandoffLinkRules {
    public static let tabChannel = "link:open-tab"
    public static let neverLeaves: Set<String> = ["javascript", "vbscript", "data", "blob", "about", "chrome", "chrome-extension", "devtools", "filesystem", "view-source"]
    public static func scheme(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = value.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) else { return nil }
        return String(value[range].dropLast()).lowercased()
    }
    /// browser-url.ts navigation gate, not the address bar's URL normalization.
    public static func navigationAllowed(_ value: NativeRPCValue) -> Bool {
        guard let text = value.string, !text.isEmpty else { return false }
        if text == "about:blank" { return true }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return false }
        return true
    }
    public static func canOpenOutside(_ value: NativeRPCValue) -> Bool {
        guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let scheme = scheme(text) else { return false }; return !neverLeaves.contains(scheme)
    }
    public static func app(_ value: NativeRPCValue) -> BackendMacAppHandoffLinkRoute {
        guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .refused }
        if navigationAllowed(value) { return .tab }
        guard let scheme = scheme(text), !neverLeaves.contains(scheme) else { return .refused }; return .system
    }
    public static func guest(_ value: NativeRPCValue) -> BackendMacAppHandoffLinkRoute {
        guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .refused }; return navigationAllowed(value) ? .tab : .refused
    }
}
public struct BackendMacAppHandoffLinkMenuItem: Sendable {
    public let label: String
    public let click: @Sendable () async throws -> Void
    public init(label: String, click: @escaping @Sendable () async throws -> Void) { self.label = label; self.click = click }
}
/// Actual app-owned window/menu/clipboard/Launch Services operations; no second browser.
public protocol BackendMacAppHandoffLinkDesktop: Sendable {
    func ownerAlive(_ ownerID: String) async -> Bool
    func hasWindow(_ ownerID: String) async -> Bool
    func push(_ ownerID: String, channel: String, value: NativeRPCValue) async throws
    func openSystem(_ url: String) async throws
    func copyLink(_ text: String) async throws
    func menu(_ ownerID: String, items: [BackendMacAppHandoffLinkMenuItem]) async throws
}
public struct BackendMacAppHandoffLinks: Sendable {
    public let desktop: (any BackendMacAppHandoffLinkDesktop)?
    public init(desktop: (any BackendMacAppHandoffLinkDesktop)?) { self.desktop = desktop }
    private func requireDesktop() throws -> any BackendMacAppHandoffLinkDesktop {
        guard let desktop else { throw NativeRPCError(code: "unavailable", message: "The native link window/menu/clipboard presenter is unavailable.") }; return desktop
    }
    @discardableResult public func openSystem(_ value: NativeRPCValue) async throws -> Bool {
        guard BackendMacAppHandoffLinkRules.canOpenOutside(value), let text = value.string else { return false }
        let desktop = try requireDesktop()
        do { try await desktop.openSystem(text) }
        catch let error as NativeRPCError where error.code == "unavailable" { throw error }
        catch { /* Handed to the actual OS opener; its rejected launch is source best effort. */ }
        return true
    }
    public func app(ownerID: String, url: NativeRPCValue, from: NativeRPCValue = .object([])) async throws -> BackendMacAppHandoffLinkRoute {
        let route = BackendMacAppHandoffLinkRules.app(url)
        if route == .tab { let desktop = try requireDesktop(); if await desktop.ownerAlive(ownerID) { try await desktop.push(ownerID, channel: BackendMacAppHandoffLinkRules.tabChannel, value: from.setting("url", url)) } }
        else if route == .system { _ = try await openSystem(url) }; return route
    }
    public func guest(ownerID: String, url: NativeRPCValue, from: NativeRPCValue = .object([])) async throws -> BackendMacAppHandoffLinkRoute {
        let route = BackendMacAppHandoffLinkRules.guest(url)
        if route == .tab { let desktop = try requireDesktop(); if await desktop.ownerAlive(ownerID) { try await desktop.push(ownerID, channel: BackendMacAppHandoffLinkRules.tabChannel, value: from.setting("url", url)) } }; return route
    }
    public func menu(ownerID: String?, url: NativeRPCValue) async throws -> Bool {
        guard let text = url.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let ownerID else { return false }
        let desktop = try requireDesktop()
        guard await desktop.ownerAlive(ownerID), await desktop.hasWindow(ownerID) else { return false }
        var items: [BackendMacAppHandoffLinkMenuItem] = []
        if BackendMacAppHandoffLinkRules.canOpenOutside(url) { items.append(.init(label: "Open in System Browser") { _ = try await self.openSystem(url) }) }
        items.append(.init(label: "Copy Link") { try await desktop.copyLink(text) })
        try await desktop.menu(ownerID, items: items); return true
    }
    public func register(registry: NativeChannelRegistry, ownerID: String = "mac-link-open") async throws {
        let policy: NativeChannelRegistry.Policy = { context in
            guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "Only the app may open system links or its native link menu.") }
        }
        try await registry.register("link:system", ownerID: ownerID, policy: policy) { _, args in .bool(try await self.openSystem(args.first ?? .missing)) }
        try await registry.register("link:menu", ownerID: ownerID, policy: policy) { context, args in .bool(try await self.menu(ownerID: context.ownerID, url: args.first ?? .missing)) }
    }
}
