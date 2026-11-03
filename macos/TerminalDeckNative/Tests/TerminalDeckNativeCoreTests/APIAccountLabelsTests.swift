import XCTest
@testable import TerminalDeckNativeCore

final class APIAccountLabelsTests: XCTestCase {
    func testAPITypeFollowsAccountThroughSharedSessionAndHootPickerLabels() {
        let api = CodingAIAccount(id: "api-key-" + String(repeating: "a", count: 24), name: "Gateway", provider: "codex")
        XCTAssertTrue(api.isAPIKey, "Reserved API identity must survive an older/minimal account snapshot.")
        XCTAssertEqual(CodingAIAccountLabels.profileLoginLabel(api, nil), "Gateway · API key")
        XCTAssertEqual(CodingAIAccountLabels.profileLoginLabel(api, .init(state: .signedIn, account: "stale-subscription@example.test")), "Gateway · API key")
        let subscription = CodingAIAccount(id: "ordinary", name: "Work", provider: "claude")
        XCTAssertFalse(subscription.isAPIKey)
        XCTAssertEqual(CodingAIAccountLabels.profileLoginLabel(subscription, .init(state: .signedIn, account: "person@example.test")), "person@example.test")
        XCTAssertFalse(CodingAIAccount(id: "api-key-not-a-reserved-id", name: "Work").isAPIKey)
    }
    func testDistinctAPIKeysNeverFoldIntoEachOtherOrSubscriptionEmails() {
        let api = CodingAIAccount(id: "api-key-" + String(repeating: "a", count: 24), name: "me@example.test", provider: "claude", keptBy: .app, keptSignedIn: true)
        let second = CodingAIAccount(id: "api-key-" + String(repeating: "b", count: 24), name: api.name, provider: "claude", keptBy: .app, keptSignedIn: true)
        let subscription = CodingAIAccount(id: "system", name: "Claude", provider: "claude", system: true)
        let reports = [subscription.id: CodingAISignIn(state: .signedIn, account: api.name)]
        let accounts = [api, second, subscription]
        XCTAssertEqual(CodingAILogins.oneRowPerEmail(accounts, signIn: reports).count, 3)
        XCTAssertEqual(CodingAILogins.oneRowPerEmail(accounts, signIn: reports, prefer: api.id).count, 3)
        XCTAssertTrue(CodingAILogins.duplicates(accounts, signIn: reports).isEmpty)
        XCTAssertNil(CodingAILogins.holding([api, second], signIn: [:], provider: "claude", address: api.name))
        XCTAssertNil(CodingAILogins.awaiting([api], signIn: [:], provider: "claude", address: api.name))
        XCTAssertEqual(CodingAIAccountLabels.namedLogin(api, .init(state: .signedIn, account: "stale@example.test")), api.name)
    }
}
