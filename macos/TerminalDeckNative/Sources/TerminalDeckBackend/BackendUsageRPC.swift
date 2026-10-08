import Foundation
import TerminalDeckNativeCore

/// Typed channel factory over the same native services. Authorization derives
/// session/account/folder scope from the authenticated context on every call.
public struct BackendUsageRPC: Sendable {
    public static let invokeChannels = BackendUsageService.channels.union(BackendCostService.channels).union(BackendInsightsService.channels).union(BackendSessionSearchService.channels).union(BackendAlertsService.channels).union(BackendReadinessService.channels)
    public static let sendChannels = BackendUsageService.sendChannels
    public typealias Authorization = @Sendable (NativeRPCContext, String, [NativeRPCValue]) async throws -> Void
    private let usage: BackendUsageService, cost: BackendCostService, search: BackendSessionSearchService, alerts: BackendAlertsService
    private let insights: BackendInsightsService, readiness: BackendReadinessService
    private let authorize: Authorization
    public init(usage: BackendUsageService, cost: BackendCostService, insights: BackendInsightsService, search: BackendSessionSearchService,
                alerts: BackendAlertsService, readiness: BackendReadinessService, authorize: @escaping Authorization) {
        self.usage = usage; self.cost = cost; self.insights = insights; self.search = search; self.alerts = alerts; self.readiness = readiness; self.authorize = authorize
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.invokeChannels.contains(channel) else { throw BackendSessionFailure.unsupported("The native metrics channel is not registered.") }
        guard channel != "readiness:fix" else {
            throw NativeRPCError(code: "approval-required", message: "Re-check AI readiness, preview the exact file changes, and approve that preview before applying a fix. Machine CLI upgrades need the manual instructions shown in Coding AI.")
        }
        try await authorize(context, channel, args); try Task.checkCancellation()
        let first = args.first ?? .missing
        if BackendCostService.channels.contains(channel) { return try await cost.invoke(channel, args: args, ownerID: context.ownerID, context: context) }
        if BackendInsightsService.channels.contains(channel) { return try await insights.invoke(channel, args: args, context: context) }
        if BackendSessionSearchService.channels.contains(channel) { return try await search.invoke(channel, args: args, ownerID: context.ownerID, context: context) }
        if BackendAlertsService.channels.contains(channel) { return try await alerts.invoke(channel, args: args, context: context) }
        if BackendReadinessService.channels.contains(channel) { return try await readiness.invoke(channel, args: args, context: context) }
        switch channel {
        case "usage:read": return try await usage.read(sessionID: first.string).wireValue
        case "usage:watch": return try await usage.watch(sessionID: first.requireString("session id", nonempty: true), ownerID: context.ownerID)
        case "plan:watch": return try await usage.watch(sessionID: first.requireString("session id", nonempty: true), ownerID: context.ownerID, planOnly: true)
        case "usage:refresh": return try await usage.refresh(sessionID: first.requireString("session id", nonempty: true), force: args.count > 1 && args[1].bool == true).wireValue
        case "usage:context": return try await usage.contextWindow(sessionID: first.requireString("session id", nonempty: true), context: context)
        default: throw BackendSessionFailure.unsupported("The native usage operation is unsupported.")
        }
    }
    public func send(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws {
        guard Self.sendChannels.contains(channel) else { throw BackendSessionFailure.unsupported("The native metrics send channel is not registered.") }
        try await authorize(context, channel, args)
        let id = try (args.first ?? .missing).requireString("session id", nonempty: true)
        await usage.unwatch(sessionID: id, ownerID: context.ownerID, planOnly: channel == "plan:unwatch")
    }
    public func start() async { await usage.start(); await alerts.start() }
    /// Existing lifecycle event callback fans out here. This observes facts
    /// from the same owner; it neither parses a terminal nor starts a session.
    public func noteLifecycleEvent(_ event: BackendSessionLifecycleEvent) async {
        switch event {
        case .created: await cost.refreshWatchers()
        case .accountChanged(let session, _): await usage.accountChanged(sessionID: session.id)
        case .status(let id, let status, _): await alerts.noteStatusReceipt(sessionID: id, status: status, at: BackendUsageIO.now()); await usage.noteStatusReceipt()
        default: break
        }
    }
    public func disconnect(ownerID: String) async { await usage.disconnect(ownerID: ownerID); await cost.disconnect(ownerID: ownerID); await search.cancel(ownerID: ownerID) }
    public func stop() async { await usage.stop(); await cost.stop(); await search.stop(); await alerts.stop() }
}
