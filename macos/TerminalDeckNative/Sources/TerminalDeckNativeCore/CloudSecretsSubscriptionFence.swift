import Foundation

/// No real provider token implementation is installed tonight. Future provider
/// adapters must enter this fence even when called for launch materialization.
public struct CloudSecretsSubscriptionFence: Sendable {
    private let policy: CloudSecretsPolicy
    public init(policy: CloudSecretsPolicy) { self.policy = policy }
    public func perform<T: Sendable>(_ stage: CloudSecretsStage, operation: @Sendable () async throws -> T) async throws -> T {
        try await policy.require(.aiSubscription, stage: stage)
        return try await operation()
    }
}
