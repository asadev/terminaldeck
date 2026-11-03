import Testing
@testable import TerminalDeckNativeCore

struct Leftovers20AccountTests {
    @Test func systemAccountUsesItsKnownEmailAndCodexNamesItsChatGPTLogin() {
        let own = CodingAIAccount(id: "system:codex", name: "Default", provider: "codex", system: true)
        let report = CodingAISignIn(state: .signedIn, plan: "ChatGPT")
        #expect(CodingAIAccountLabels.profileLoginLabel(own, report) == "Codex · signed in with ChatGPT")
        #expect(AccountChipRules.identity((own.id, own.name, true), report).label == "Codex · signed in with ChatGPT")
        let named = CodingAISignIn(state: .signedIn, account: "person@example.test", plan: "ChatGPT")
        #expect(CodingAIAccountLabels.profileLoginLabel(own, named) == "person@example.test")
        #expect(AccountChipRules.identity(("system", "Default", true), named).label == "person@example.test")
        #expect(CodingAIAccountLabels.profileLoginLabel(own, .init(state: .signedOut)) != "Codex · signed in with ChatGPT")
        let kept = CodingAIAccount(id: "work", name: "Work", provider: "codex", system: false)
        #expect(CodingAIAccountLabels.profileLoginLabel(kept, report) == "Work")
    }
}
