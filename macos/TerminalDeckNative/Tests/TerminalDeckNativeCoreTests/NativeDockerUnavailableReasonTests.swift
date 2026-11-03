import Testing
@testable import TerminalDeckNativeCore

@Suite("Cached server connection failure copy")
struct NativeDockerUnavailableReasonTests {
    @Test func knownMissingSignInHasCauseAndRealDestination() {
        let notice = NativeDockerUnavailableReason.connection(
            problem: "There is no sign-in stored for this server yet. Add the password or key and try again.",
            fallback: "Docker could not be checked", isLocal: false)
        #expect(notice.title == "This server has no saved sign-in")
        #expect(notice.message == "Open Server connection below to check the username and password or SSH key.")
    }

    @Test func refusedSignInPreservesSafeReasonAndNamesWhatToCheck() {
        let reason = "That sign-in was refused. Check the username, and the password or key."
        let notice = NativeDockerUnavailableReason.connection(problem: reason, fallback: "Unavailable", isLocal: false)
        #expect(notice.title == "This server refused the sign-in")
        #expect(notice.message.hasPrefix(reason))
        #expect(notice.message.contains("Open Server connection below"))
        #expect(notice.message.contains("username and password or SSH key"))
    }

    @Test func unreachableServerPreservesActualReasonWithoutInventingCredentialFailure() {
        let reason = "That address did not answer. The server may be off, or something in between may be blocking it."
        let notice = NativeDockerUnavailableReason.connection(problem: reason, fallback: "Unavailable", isLocal: false)
        #expect(notice.title == "Can’t reach this server")
        #expect(notice.message.hasPrefix(reason))
        #expect(notice.message.contains("check the connection"))
        #expect(!notice.message.contains("password") && !notice.message.contains("SSH key"))
    }

    @Test func unknownAndLocalProblemsKeepCallerFallbackWithoutInferringMissingSignIn() {
        let fallback = "Docker could not be checked because server control is unavailable in this connection."
        let unknown = NativeDockerUnavailableReason.connection(problem: nil, fallback: fallback, isLocal: false)
        #expect(unknown.title == "Could not check this server")
        #expect(unknown.message.hasPrefix(fallback))
        #expect(!unknown.message.contains("password") && !unknown.title.contains("sign-in"))
        let local = NativeDockerUnavailableReason.connection(
            problem: "There is no sign-in stored for this server yet. Add the password or key and try again.",
            fallback: fallback, isLocal: true)
        #expect(local.title == "Could not check this Mac")
        #expect(local.message.hasPrefix(fallback))
        #expect(!local.message.contains("Server connection below") && !local.title.contains("sign-in"))
    }
}
