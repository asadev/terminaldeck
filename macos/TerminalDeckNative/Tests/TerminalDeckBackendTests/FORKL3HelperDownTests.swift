import Foundation
import Testing
@testable import TerminalDeckBackend

/// HELPER DOWN (11 Oct, test rows 10 and 11): while the session helper cannot be reached, the
/// readers of what agents wrote use the last list of account folders it gave. No helper, no app
/// and no real account is involved: the failures are the helper client's own error values.
@Suite struct FORKL3HelperDownTests {
    @Test func aDeadHelperLineFallsBackToTheLastKnownFolders() throws {
        let folders = BackendTranscriptAccountFolders()
        folders.remember(["/scratch/accounts/a", "/scratch/accounts/b"])
        for failure in [BackendHOSTFailure.unavailable, .io(61), .io(60), .authentication, .occupiedHost] {
            #expect(try folders.whileHelperIsAway(failure) == ["/scratch/accounts/a", "/scratch/accounts/b"])
        }
    }
    @Test func withNoListYetOnlyTheMacsOwnFolderIsRead() throws {
        #expect(try BackendTranscriptAccountFolders().whileHelperIsAway(BackendHOSTFailure.unavailable) == [])
    }
    @Test func anyOtherFailureIsStillTheCallersFailure() {
        let folders = BackendTranscriptAccountFolders()
        folders.remember(["/scratch/accounts/a"])
        #expect(throws: (any Error).self) { try folders.whileHelperIsAway(BackendHOSTFailure.remote("The profile read was refused.")) }
        #expect(throws: (any Error).self) { try folders.whileHelperIsAway(BackendHOSTFailure.incompatible(1)) }
        #expect(throws: (any Error).self) { try folders.whileHelperIsAway(CancellationError()) }
    }
    @Test func aNewListReplacesTheOldOne() throws {
        let folders = BackendTranscriptAccountFolders()
        folders.remember(["/scratch/accounts/a"]); folders.remember([])
        #expect(try folders.whileHelperIsAway(BackendHOSTFailure.unavailable) == [])
    }
}
