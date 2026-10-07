import Foundation
import AppKit
import TerminalDeckNativeCore

/// native-shell/inherited-env.ts. Values never appear in the returned report.
public enum BackendOSInheritedEnvironment {
    public struct Scrubbed: Sendable { public let environment: [String: String]; public let removed: [String] }
    public static func scrub(_ source: [String: String], ownUserData: String, delimiter: String = ":",
                             isAppDataDirectory: (String) -> Bool = { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("state.json").path) }) -> Scrubbed {
        func marker(_ key: String) -> Bool {
            key.range(of: #"^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_AGENT_SDK_VERSION|CLAUDE_CODE_.*|CLAUDE_PREVIEW_.*)$"#, options: .regularExpression) != nil ||
            key.range(of: #"^TERMINALDECK_(SESSION_ID|ACCOUNT_VAULT|ACCOUNT_TICKET|ACCOUNT_HOME)$"#, options: .regularExpression) != nil
        }
        let parentRun = source.keys.contains(where: marker)
        var environment: [String: String] = [:], removed: [String] = []
        for key in source.keys.sorted() {
            if marker(key) || (key == "CLAUDE_CONFIG_DIR" && parentRun) { removed.append(key) }
            else { environment[key] = source[key] }
        }
        if let path = environment["PATH"] {
            let own = URL(fileURLWithPath: ownUserData).standardizedFileURL.path
            let kept = path.components(separatedBy: delimiter).filter { entry in
                if entry.isEmpty { return true }
                let url = URL(fileURLWithPath: entry).standardizedFileURL
                if !["shim", "account-vault-shim"].contains(url.lastPathComponent) { return true }
                let directory = url.deletingLastPathComponent().path
                return directory == own || !isAppDataDirectory(directory)
            }.joined(separator: delimiter)
            if kept != path { environment["PATH"] = kept; removed.append("PATH (another copy’s shims)") }
        }
        return Scrubbed(environment: environment, removed: removed)
    }
}

public enum BackendOSNativeMode {
    public static let flag = "--native-shell"
    public static func enabled(arguments: [String]) -> Bool { arguments.contains(flag) }
    public static func preview(arguments: [String], environment: [String: String]) -> Bool {
        enabled(arguments: arguments) && (environment["TD_NATIVE_NODE"] != "1" || environment["TD_NATIVE_PRIMARY"] != "1")
    }
    public static func machineName(_ name: String, preview: Bool) -> String { preview ? name + " (native)" : name }
    /// These refusals apply only while a caller asks for legacy Electron views.
    /// Native WebKit capability registration is owned by Safari.
    public static let refusedChannels: [String: String] = [
        "browser:create": "The built-in browser is not available in the native shell yet.",
        "browser-view:claim": "The built-in browser is not available in the native shell yet."]
    public static let hookRefusal = "The native shell does not change agents’ hook settings, so the copy of the app installed on this computer keeps them."
    public static let directRefusal = "This app reaches phones and other computers through the relay. A direct address and its port stay with the normal Terminal Deck app."
}

/// native-shell/hydration.ts. No re-announcement: every new page reads its own
/// session:list, while first attachment restores exactly once.
public actor BackendOSHydration {
    private var hydrated = false
    public init() {}
    public func firstClient(_ hydrate: @Sendable () async throws -> Void) async rethrows {
        guard !hydrated else { return }; hydrated = true; try await hydrate()
    }
}

/// A cancellable one-shot timer (the page bridge's keep-alive).
public struct BackendOSTimer: Sendable {
    private let cancelAction: @Sendable () -> Void
    public init(cancel: @escaping @Sendable () -> Void) { cancelAction = cancel }
    public func cancel() { cancelAction() }
}

/// Channels that only the app itself may call: never a page, a phone or an agent.
public enum BackendOSNativeCaller {
    public static func only(_ context: NativeRPCContext) throws {
        guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "Only the native app may use this channel.") }
    }
}

/// sender.ts. Identity and delivery belong to one connected native owner.
/// A web page cannot mint a native-app context by presenting this numeric id.
public struct BackendOSNativeSender: Sendable {
    public static let legacyID = 1_000_000_000
    public let ownerID: String
    private let dispatcher: BackendOSTraceDispatcher
    private let deliver: @Sendable (String, [NativeRPCValue]) async -> Bool
    public init(ownerID: String, dispatcher: BackendOSTraceDispatcher, deliver: @escaping @Sendable (String, [NativeRPCValue]) async -> Bool) {
        self.ownerID = ownerID; self.dispatcher = dispatcher; self.deliver = deliver
    }
    public func invoke(_ channel: String, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        try await dispatcher.invoke(channel: channel, arguments: arguments, context: .init(caller: .nativeApp, ownerID: ownerID))
    }
    public func send(_ channel: String, arguments: [NativeRPCValue]) async throws -> Bool {
        try await dispatcher.send(channel: channel, arguments: arguments, context: .init(caller: .nativeApp, ownerID: ownerID))
    }
    public func push(_ channel: String, arguments: [NativeRPCValue]) async -> Bool { await deliver(channel, arguments) }
}

/// notifications.ts: policy is retained here; native_os_bridge supplies actual
/// banner presentation, including its system authorization and delegate.
@MainActor public protocol BackendOSBanner: AnyObject {
    func show() throws
    func close()
    func clicked(_ callback: @escaping @MainActor () -> Void)
    func closed(_ callback: @escaping @MainActor () -> Void)
}
@MainActor public protocol BackendOSBannerFactory: AnyObject {
    var supported: Bool { get }
    func make(title: String, body: String, silent: Bool) throws -> any BackendOSBanner
}
@MainActor
public final class BackendOSNativeNotifier {
    public static let notifyChannel = "native-shell:notify", closeChannel = "native-shell:notify-close", clickChannel = "native-shell:notification-click"
    private let factory: any BackendOSBannerFactory
    private let push: @MainActor (String, [NativeRPCValue]) -> Void
    private var live: [String: any BackendOSBanner] = [:]
    private var order: [String] = []
    public init(factory: any BackendOSBannerFactory, push: @escaping @MainActor (String, [NativeRPCValue]) -> Void) { self.factory = factory; self.push = push }
    public func notify(_ request: NativeRPCValue) throws -> NativeRPCValue {
        let id = BackendOSTrace.prefix(request["id"].string ?? "", limit: 200)
        let title = BackendOSTrace.prefix(request["title"].string ?? "", limit: 500)
        let body = BackendOSTrace.prefix(request["body"].string ?? "", limit: 2000)
        guard !id.isEmpty, !title.isEmpty, factory.supported else { return .object([.init("shown", .bool(false))]) }
        live[id]?.close()
        let banner = try factory.make(title: title, body: body, silent: true)
        if live[id] == nil { order.append(id) }; live[id] = banner
        banner.clicked { [weak self] in self?.push(Self.clickChannel, [.string(id)]); self?.live[id] = nil; self?.order.removeAll { $0 == id } }
        banner.closed { [weak self, weak banner] in
            if let current = self?.live[id], let banner, current === banner { self?.live[id] = nil; self?.order.removeAll { $0 == id } }
        }
        while order.count > 50 { live[order.removeFirst()] = nil }
        try banner.show(); return .object([.init("shown", .bool(true))])
    }
    public func close(_ id: NativeRPCValue) { guard let id = id.string else { return }; live[id]?.close(); live[id] = nil; order.removeAll { $0 == id } }
    public func register(registry: NativeChannelRegistry, ownerID: String) async throws {
        try await registry.register(Self.notifyChannel, ownerID: ownerID, policy: BackendOSNativeCaller.only) { [weak self] _, args in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native notification presenter is unavailable.") }
            return try await self.notify(args.first ?? .missing)
        }
        try await registry.register(Self.closeChannel, ownerID: ownerID, policy: BackendOSNativeCaller.only) { [weak self] _, args in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native notification presenter is unavailable.") }
            await self.close(args.first ?? .missing); return .missing
        }
    }
}

/// dialogs.ts: one wrapper across actual app-owned dialog operations. Bringing
/// the app forward is best effort and precedes the supplied panel operation.
@MainActor
public enum BackendOSFrontedDialogs {
    public static let methods = ["showOpenDialog", "showSaveDialog", "showMessageBox", "showCertificateTrustDialog"]
    public static func call(_ name: String, arguments: [NativeRPCValue], front: @MainActor () throws -> Void = { NSApplication.shared.activate(ignoringOtherApps: true) },
                            operation: @MainActor ([NativeRPCValue]) async throws -> NativeRPCValue) async throws -> NativeRPCValue {
        guard methods.contains(name) else { throw NativeRPCError(code: "unavailable", message: "That is not a native dialog operation.") }
        try? front()
        let clean = arguments.count >= 2 && arguments[0].isNullish ? Array(arguments.dropFirst()) : arguments
        return try await operation(clean)
    }
}
