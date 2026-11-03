import Testing
@testable import TerminalDeckBackend

struct AGOPTBillingTests {
    @Test func anotherAccountCannotMakeThisAgentAnAPIUser() {
        let another = BackendUsageAccount(provider: "claude", id: "other", name: nil, configDirectory: "/stub/other")
        #expect(BackendAGOPTBilling.kind(provider: "claude", accountID: "selected", configDirectory: "/stub/selected",
            observedAccount: another, sessionBilling: "api", cachedBilling: nil) == nil)
        #expect(BackendAGOPTBilling.kind(provider: "claude", accountID: "selected", configDirectory: "/stub/selected",
            observedAccount: another, sessionBilling: "api", cachedBilling: "subscription") == "subscription")
    }
    @Test func currentExactSessionSupersedesOldBilling() {
        let exact = BackendUsageAccount(provider: "claude", id: "selected", name: nil, configDirectory: "/stub/selected")
        #expect(BackendAGOPTBilling.kind(provider: "claude", accountID: "selected", configDirectory: "/stub/selected",
            observedAccount: exact, sessionBilling: "subscription", cachedBilling: "api") == "subscription")
        #expect(BackendAGOPTBilling.kind(provider: "claude", accountID: "selected", configDirectory: "/stub/selected",
            observedAccount: exact, sessionBilling: "api", cachedBilling: nil) == "api")
    }
    @Test func missingOrUnknownBillingStaysUnknown() {
        #expect(BackendAGOPTBilling.kind(provider: "codex", accountID: "selected", configDirectory: "/stub/selected",
            observedAccount: nil, sessionBilling: "api", cachedBilling: "no-limits") == nil)
        #expect(BackendAGOPTBilling.kind(provider: "claude", accountID: "", configDirectory: "/stub/selected",
            observedAccount: nil, sessionBilling: nil, cachedBilling: "api") == nil)
    }
}
