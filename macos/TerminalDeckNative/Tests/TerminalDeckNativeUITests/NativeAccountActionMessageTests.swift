import Testing
@testable import TerminalDeckNative

@MainActor
struct NativeAccountActionMessageTests {
    @Test func olderHelperMessagesGiveAnActionAvailableNow() {
        let assignments = NativeAccountLevelsModel.olderHelperLine
        #expect(assignments.contains("New session"))
        #expect(assignments.contains("Login"))
        #expect(!assignments.contains("ended"))
        let signIn = NativeAccountLevelsModel.olderHelperSignIn
        #expect(signIn.contains("Add account"))
        #expect(signIn.contains("press Sign in"))
        #expect(!signIn.contains("Try again after"))
    }
}
