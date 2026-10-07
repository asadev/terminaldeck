import Foundation
import TerminalDeckNativeCore

/// The one effect gate every deck-tools production adapter uses (INT, 7 Oct).
///
/// deck-core's `Control.call` has already checked the caller's grant, the
/// base tier, budgets and consent for the tool before the handler runs. A
/// handler that learns its effective tier/sentence only after its own checks
/// calls `authorize` once; that enters the SAME running call through
/// `prepareEffect` (one consent, one budget, one action-log row). A second
/// `authorize` in the same call must stay inside what was already accepted.
/// `noteResult` hands the source summary to that same row; it never writes
/// a second row and never fails the operation after its effect happened.
public struct BackendCompositionDeckToolsGate: Sendable {
    public typealias Authorize = @Sendable (_ native: BackendMCPCallContext, _ tier: BackendMCPTier,
                                            _ sentence: String, _ ownerMustAnswer: Bool) async throws -> Void
    public typealias NoteResult = @Sendable (_ native: BackendMCPCallContext, _ summary: NativeRPCValue) async -> Void
    /// Credential-resolved caller, folder/session grants and RPC projection.
    public let authority: BackendCompositionAuthority
    public let authorize: Authorize
    public let noteResult: NoteResult
    public init(authority: BackendCompositionAuthority, authorize: @escaping Authorize, noteResult: @escaping NoteResult) {
        self.authority = authority; self.authorize = authorize; self.noteResult = noteResult
    }
}
