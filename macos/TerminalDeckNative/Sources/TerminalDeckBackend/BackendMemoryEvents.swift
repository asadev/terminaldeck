import Foundation
import TerminalDeckNativeCore

/// The memory and Hoot stores share the app's event registry. Composition supplies
/// the registry before opening the stores; only the app translates events for views.
public final class BackendMemoryEvents: @unchecked Sendable {
    public static let shared = BackendMemoryEvents()
    private let lock = NSLock()
    private var registry: NativeChannelRegistry?
    public init() {}
    public func connect(_ registry: NativeChannelRegistry?) { lock.withLock { self.registry = registry } }
    public func publish(_ channel: String, arguments: [NativeRPCValue] = []) async {
        let registry = lock.withLock { self.registry }
        try? await registry?.publish(channel, arguments: arguments)
    }
}
