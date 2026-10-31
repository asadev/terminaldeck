import Testing
@testable import TerminalDeckNativeCore

struct Install18AccountDuplicateTests {
    private let own = CodingAIAccount(id: "system", name: "Default", provider: "claude", system: true)
    private let copy = CodingAIAccount(id: "copy", name: " ME@Example.com ", provider: "claude", keptBy: .unavailable)
    private let report = CodingAISignIn(state: .signedIn, account: "me@example.com")

    @Test func lockedKeptCopyFoldsIntoVerifiedWorkingOwnLogin() {
        let rows = [copy, own]
        let reports = ["system": report, "copy": CodingAISignIn(state: .unknown)]
        #expect(CodingAILogins.oneRowPerEmail(rows, signIn: reports).map(\.id) == ["system"])
        #expect(CodingAILogins.copies(of: own, accounts: rows, signIn: reports).map(\.id) == ["copy"])
        #expect(CodingAILogins.duplicates(rows, signIn: reports)["copy"]?.id == "system")
        #expect(AccountChipRules.oneRowPerLogin(rows, signIn: reports, prefer: nil).map(\.id) == ["system"])
    }

    @Test func generatedOrRenamedOwnNameNeverClaimsAnEmailWithoutStatus() {
        var renamed = own; renamed.name = "me@example.com"
        #expect(CodingAILogins.oneRowPerEmail([copy, renamed], signIn: [:]).count == 2)
        #expect(CodingAILogins.email(renamed, signIn: nil) == nil)
    }

    @Test func freshStatusOverridesTheStoredCopyNameAndProviderScopesIdentity() {
        var otherAI = copy; otherAI.id = "codex-copy"; otherAI.provider = "codex"
        #expect(CodingAILogins.oneRowPerEmail([copy, own, otherAI], signIn: ["system": report]).count == 2)
        #expect(CodingAILogins.oneRowPerEmail([copy, own], signIn: ["system": report, "copy": .init(state: .signedOut)]).count == 2)
        #expect(CodingAILogins.oneRowPerEmail([copy, own], signIn: ["system": report, "copy": .init(state: .signedIn, account: "other@example.com")]).count == 2)
    }

    @Test func finishedSignInDetectsCollisionButNeverItself() {
        #expect(CodingAILogins.collision([copy, own], signIn: ["system": report], provider: "claude", address: " Me@Example.COM ", excludingID: "copy")?.id == "system")
        #expect(CodingAILogins.collision([own], signIn: ["system": report], provider: "claude", address: "me@example.com", excludingID: "system") == nil)
        #expect(CodingAILogins.collision([own], signIn: ["system": report], provider: "codex", address: "me@example.com", excludingID: "new") == nil)
        var newlyReady = copy; newlyReady.id = "new"; newlyReady.keptBy = .agent
        #expect(CodingAILogins.collision([newlyReady, copy], signIn: ["new": report], provider: "claude", address: "me@example.com", excludingID: "new")?.id == "copy")
    }

    @Test func savedLoginMessagesNameTheImmediateAction() {
        var adopting = copy; adopting.keptBy = .adopting
        #expect(CodingAIAccountText.keptLine(adopting)?.hasPrefix("Start a session") == true)
        #expect(CodingAIAccountText.keptLine(copy)?.contains("Allow login store") == true)
        #expect(CodingAIAccountText.keptLine(copy)?.contains("Always Allow") == true)
        #expect(CodingAIAccountText.keptLine(copy)?.contains("ended") == false)
    }

    @Test func remoteMachineAlsoShowsOneNormalizedEmail() {
        let rows = [CodingAIMachineAccount(id: "copy", name: "Second", provider: "claude", system: false, signIn: .init(state: .signedIn, account: "ME@example.com")),
                    CodingAIMachineAccount(id: "system", name: "Default", provider: "claude", system: true, signIn: report)]
        #expect(CodingAIMachineLogins.oneRowPerEmail(rows).map(\.id) == ["system"])
    }
}
