import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Asad, 11 Oct: the account dropdown on a session "should only show ready to use accounts only and add account
/// button only and rest should be handled in settings not here".
struct CONNECTAccountChipTests {
    private let accounts = [
        CodingAIAccount(id: "system", name: "Default", provider: "claude", system: true),
        CodingAIAccount(id: "p-work", name: "work@example.com", provider: "claude"),
        CodingAIAccount(id: "p-old", name: "old@example.com", provider: "claude"),
        CodingAIAccount(id: "system:codex", name: "Default (Codex CLI)", provider: "codex", system: true),
        CodingAIAccount(id: "system:gemini", name: "Default (Gemini CLI)", provider: "gemini", system: true),
    ]
    private let signIn: [String: CodingAISignIn] = [
        "system": .init(state: .signedIn, account: "me@example.com"),
        "p-work": .init(state: .signedIn, account: "work@example.com"),
        "p-old": .init(state: .signedOut),
        "system:codex": .init(state: .signedIn),
        "system:gemini": .init(state: .signedOut),
    ]

    @Test func aClaudeSessionListsOnlyItsReadyClaudeAccounts() {
        let shown = AccountChipRules.readyRows(accounts, signIn: signIn, currentId: "system", sessionAgent: "claude")
        // The current one (ticked) and the other signed-in Claude account. Not the signed-out one, not Codex or Gemini.
        #expect(shown.map(\.id) == ["system", "p-work"])
    }

    @Test func theCurrentAccountStaysEvenWhenItsLoginLapsed() {
        let shown = AccountChipRules.readyRows(accounts, signIn: signIn, currentId: "p-old", sessionAgent: "claude")
        #expect(shown.map(\.id) == ["system", "p-work", "p-old"])
    }

    @Test func aShellsOwnAgentListsEverySignedInAccount() {
        let shown = AccountChipRules.readyRows(accounts, signIn: signIn, currentId: nil, sessionAgent: nil)
        #expect(shown.map(\.id) == ["system", "p-work", "system:codex"])
    }

    @Test func itSaysWhenSignInsAreStillBeingRead() {
        var reading = signIn
        reading["p-work"] = .checking
        #expect(AccountChipRules.stillChecking(accounts, signIn: reading, sessionAgent: "claude"))
        reading["p-work"] = nil
        reading["system:gemini"] = nil
        #expect(AccountChipRules.stillChecking(accounts, signIn: reading, sessionAgent: "claude"))
        #expect(!AccountChipRules.stillChecking(accounts, signIn: signIn, sessionAgent: "claude"))
        // Another AI's unread account does not keep a Claude session's menu "checking".
        var other = signIn
        other["system:gemini"] = nil
        #expect(!AccountChipRules.stillChecking(accounts, signIn: other, sessionAgent: "claude"))
    }
}
