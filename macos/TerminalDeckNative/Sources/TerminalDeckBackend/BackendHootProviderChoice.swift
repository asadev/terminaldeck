import Foundation
import TerminalDeckNativeCore

/// Only Hoot's window-authorized routes call select. General MCP settings writes
/// already refuse hoot.*. Composition calls selected before installing Hoot.
public actor BackendHootProviderChoice {
    private let settings: BackendAppSettingsStore
    public init(settings: BackendAppSettingsStore) { self.settings = settings }
    public func selected() async throws -> HootChatProvider { try HootProviderPreference.resolve(await settings.value(HootProviderPreference.key)) }
    public func read(current: HootChatProvider) async throws -> NativeRPCValue {
        let selected = try await selected()
        return .object([.init("provider", .string(selected.rawValue)), .init("current", .string(current.rawValue)),
            .init("restartRequired", .bool(selected != current))])
    }
    public func select(_ value: NativeRPCValue, current: HootChatProvider) async throws -> NativeRPCValue {
        let selected = try HootProviderPreference.resolve(value)
        _ = try await settings.patch(.object([.init(HootProviderPreference.key, .string(selected.rawValue))]))
        return try await read(current: current)
    }
}
