import Foundation
import XCTest
@testable import TerminalDeckBackend

@MainActor final class BackendGitHubParityApp: XCTestCase {
    func testShippingVerifiedClientSlugAndConfiguredState() {
        let shipping = BackendGitHubAppRegistration.shipping
        XCTAssertEqual(shipping.clientID, "Iv23limkNV4N6mChRl60")
        XCTAssertNotNil(shipping.clientID!.range(of: "^Iv[0-9]{2}li[A-Za-z0-9]+$", options: .regularExpression))
        XCTAssertEqual(shipping.slug, "terminal-deck")
        XCTAssertEqual(shipping.installURL(), "https://github.com/apps/terminal-deck/installations/new")
        XCTAssertNotNil(BackendGitHubAppRegistration.resolve(environment: [:]).clientID)
        XCTAssertNil(BackendGitHubAppRegistration.resolve(environment: [:], built: .absent).clientID)
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [:], built: .absent), .absent)
    }
    func testUnconfiguredReasonAndExactEnvironmentNames() {
        XCTAssertEqual(BackendGitHubAppRegistration.clientIDEnvironment, "TERMINALDECK_GITHUB_APP_CLIENT_ID")
        XCTAssertEqual(BackendGitHubAppRegistration.slugEnvironment, "TERMINALDECK_GITHUB_APP_SLUG")
        XCTAssertTrue(BackendGitHubAppRegistration.unconfiguredReason.contains("gh auth login"))
        XCTAssertTrue(BackendGitHubAppRegistration.unconfiguredReason.contains(BackendGitHubAppRegistration.clientIDEnvironment))
    }
    func testEnvironmentOverridesTrimAndBlankFallbackWithoutOrphanSlug() {
        let client = BackendGitHubAppRegistration.clientIDEnvironment, slug = BackendGitHubAppRegistration.slugEnvironment
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [client: "Iv23liEXAMPLE", slug: "terminal-deck"], built: .absent), .init(clientID: "Iv23liEXAMPLE", slug: "terminal-deck"))
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [client: "Iv23liOTHER", slug: "other-deck"]), .init(clientID: "Iv23liOTHER", slug: "other-deck"))
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [client: "  Iv23li7  "], built: .absent).clientID, "Iv23li7")
        XCTAssertNil(BackendGitHubAppRegistration.resolve(environment: [client: "   "], built: .absent).clientID)
        XCTAssertNil(BackendGitHubAppRegistration.resolve(environment: [client: "Iv23li7", slug: "  "], built: .absent).slug)
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [client: "   "]), .shipping)
        XCTAssertNotNil(BackendGitHubAppRegistration.resolve(environment: [client: ""]).clientID)
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [slug: "terminal-deck"], built: .absent), .absent)
    }
    func testInstallURLHostAndEveryMalformedSlug() {
        XCTAssertEqual(BackendGitHubAppRegistration(clientID: "id", slug: "terminal-deck").installURL(), "https://github.com/apps/terminal-deck/installations/new")
        XCTAssertEqual(BackendGitHubAppRegistration(clientID: "id", slug: "terminal-deck").installURL(host: "git.acme.co"), "https://git.acme.co/apps/terminal-deck/installations/new")
        for slug in [nil, "", "../../evil", "https://evil.example/apps/x", "has spaces", "ſlug", "K-deck"] as [String?] { XCTAssertNil(BackendGitHubAppRegistration(clientID: "id", slug: slug).installURL()) }
    }
}
