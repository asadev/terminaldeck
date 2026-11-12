import Testing
@testable import TerminalDeckNativeCore

// 10 Nov (Asad: "the New session pop-up must show exactly the accounts in Settings"): the pop-up lists Settings' rows
// (one per login, nothing preferred) and shows a folded copy as the row Settings folds it under.
struct Restore1110PickerTests {
    private let own = CodingAIAccount(id: "system", name: "Default", provider: "claude", system: true)
    private let copy = CodingAIAccount(id: "copy", name: "me@example.com", provider: "claude")
    private let other = CodingAIAccount(id: "work", name: "work@example.com", provider: "claude")

    @Test func aFoldedCopyShowsAsTheRowSettingsListsAndUnknownIdsShowNothing() {
        let rows = [copy, own, other]
        let signIn = ["system": CodingAISignIn(state: .signedIn, account: "me@example.com"),
                      "copy": CodingAISignIn(state: .signedIn, account: "me@example.com"),
                      "work": CodingAISignIn(state: .signedIn, account: "work@example.com")]
        let settings = CodingAILogins.oneRowPerEmail(rows, signIn: signIn).map(\.id)
        #expect(!settings.contains("copy"))
        #expect(CodingAILogins.shownRow(for: "copy", accounts: rows, signIn: signIn) == "system")
        #expect(CodingAILogins.shownRow(for: "work", accounts: rows, signIn: signIn) == "work")
        #expect(CodingAILogins.shownRow(for: "deleted-account", accounts: rows, signIn: signIn) == nil)
        #expect(CodingAILogins.shownRow(for: nil, accounts: rows, signIn: signIn) == nil)
    }
}
