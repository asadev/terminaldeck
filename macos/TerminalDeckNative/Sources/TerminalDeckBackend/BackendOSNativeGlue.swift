import Foundation
import TerminalDeckNativeCore

public enum BackendOSNativeMode {
    public static let directRefusal = "This app reaches phones and other computers through the relay. A direct address and its port stay with the normal Terminal Deck app."
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
