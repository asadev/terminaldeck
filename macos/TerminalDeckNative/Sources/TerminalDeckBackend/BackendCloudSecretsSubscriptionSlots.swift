import Foundation
import TerminalDeckNativeCore

/// Classification uses the existing account owner's slot grammar. Reading a
/// subscription slot is deliberately not implemented or registered tonight.
public enum BackendCloudSecretsSubscriptionSlots {
    public static func classify(provider: String, slot: String) throws -> CloudSecretsDomain {
        guard ["claude", "codex", "gemini"].contains(provider), BackendAccountProfile.validSlot(slot) else { throw CloudFailure.invalidRequest }
        // Unknown future auth slots must not fall into a generic enabled secret pack.
        return .aiSubscription
    }
    public static func perform<T: Sendable>(provider: String, slot: String, stage: CloudSecretsStage,
                                           policy: CloudSecretsPolicy, ownerOperation: @Sendable () async throws -> T) async throws -> T {
        _ = try classify(provider: provider, slot: slot)
        return try await CloudSecretsSubscriptionFence(policy: policy).perform(stage, operation: ownerOperation)
    }
}
