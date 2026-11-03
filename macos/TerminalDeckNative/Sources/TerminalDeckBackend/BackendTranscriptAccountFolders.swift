import Foundation
import TerminalDeckNativeCore

/// HELPER DOWN (11 Oct, test rows 10 and 11): reading what agents wrote is reading files on this
/// Mac. Only the LIST of account folders to look in comes from the session helper. When the
/// helper's line was down (killed, being replaced) that list threw, and every reader of the
/// transcripts failed with it: Artifacts showed "Could not read this project's history" for every
/// project and stayed that way until the app was restarted, because the app keeps one handle to
/// the helper for its whole life and a retry went through the same dead handle.
/// The last list the helper gave is kept here and used while the helper cannot be reached, so
/// these pages keep reading. Nothing is widened: it is the same folders the helper named a
/// moment ago, or none (then only the Mac's own Claude folder is read).
public final class BackendTranscriptAccountFolders: @unchecked Sendable {
    public static let shared = BackendTranscriptAccountFolders()
    private let lock = NSLock()
    private var folders: [String]?
    public init() {}

    public func remember(_ list: [String]) { lock.withLock { folders = list } }
    public func lastKnown() -> [String]? { lock.withLock { folders } }

    /// The folders to use after the account list could not be read. Only a helper line that is
    /// down counts (DeckRetryRules.isTransient); any other failure is still the caller's failure.
    public func whileHelperIsAway(_ error: Error) throws -> [String] {
        guard !(error is CancellationError), DeckRetryRules.isTransient(error.localizedDescription) else { throw error }
        return lastKnown() ?? []
    }
}
