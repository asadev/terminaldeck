import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

enum NativeChatApprovalAuthority {
    /// The grant to answer a child job once does not include saving provider rules.
    /// Recheck the exact request after the owner's asynchronous confirmation.
    static func authorize(requestID: String, allowed: Bool, answers: NativeRPCValue, ownerMustAnswer: Bool,
                          caller: BackendMCPCallContext, read: @Sendable () async throws -> NativeRPCValue,
                          authorize: BackendCompositionDeckToolsGate.Authorize) async throws -> NativeRPCValue {
        let snapshot = try await read()
        guard let request = snapshot["pending"].elements?.first(where: { $0["requestId"].string == requestID }) else {
            throw NativeRPCError(code: "stale-approval", message: "This request is no longer waiting for an answer.")
        }
        let remembered = BackendChatApproval.requiresRememberedConsent(request, allowed: allowed, answers: answers)
        guard !remembered || request["approvalNonce"].string?.isEmpty == false else {
            throw NativeRPCError(code: "helper-upgrade-required", message: "Update the session helper before saving approval rules.")
        }
        let bound = BackendChatApproval.isApproval(request) && !request["approvalNonce"].isNullish && !answers.has("approvalNonce")
            ? answers.setting("approvalNonce", request["approvalNonce"]) : answers
        try BackendChatApproval.validate(request, allowed: allowed, answers: bound)
        let operation = BackendChatApproval.details(request)
        let operationText = operation["command"].string ?? request["name"].string ?? "tool operation"
        try await authorize(caller, remembered ? .alter : .act,
            remembered ? "Remember offered permissions for: " + String(operationText.prefix(1000)) : "Answer this chat request", remembered || ownerMustAnswer)
        let current = try await read()
        guard current["pending"].elements?.first(where: { $0["requestId"].string == requestID }) == request else {
            throw NativeRPCError(code: "stale-approval", message: "The operation changed while waiting for approval. Review its current details.")
        }
        return bound
    }
}
