import Foundation
import TerminalDeckNativeCore

/// Registration only for this lane's kept sources. Root supplies the shared
/// registry/services and current caller grant; no second dispatcher is created.
public enum BackendOSKeptChannels {
    public static let channels = BackendOSPowerControl.channels.union(BackendOSVoiceService.channels).union(BackendOSNotificationEvidence.channels).union(BackendOSAppLog.channels)
    public static func register(registry: NativeChannelRegistry, ownerID: String, power: BackendOSPowerControl,
                                voice: BackendOSVoiceService, notifications: BackendOSNotificationEvidence, log: BackendOSAppLog,
                                authorize: @escaping @Sendable (NativeRPCContext, String, [NativeRPCValue]) throws -> Void) async throws -> [String] {
        for channel in channels.sorted() {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                try authorize(context, channel, args); try Task.checkCancellation()
                if BackendOSPowerControl.channels.contains(channel) { return try await power.invoke(channel, args: args, context: context) }
                if BackendOSVoiceService.channels.contains(channel) { return try await voice.invoke(channel, args: args, context: context) }
                if BackendOSNotificationEvidence.channels.contains(channel) { return try await notifications.invoke(channel, args: args, context: context) }
                return try await log.invoke(channel, args: args, context: context)
            }
        }
        return channels.sorted()
    }
}
