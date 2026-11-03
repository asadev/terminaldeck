import XCTest
@testable import TerminalDeckNativeCore

final class NewSessionAPIAccountTests: XCTestCase {
    func testGeminiAPIChoiceIsExplicitlyEnabledWithoutChangingSubscriptionPolicy() {
        let rows = NewSessionProviders.rows(detected: .null, added: [])
        XCTAssertFalse(NewSessionStartProvider.from(rows).first { $0.id == "gemini" }!.supportsProfiles)
        XCTAssertTrue(NewSessionStartProvider.from(rows, apiProviders: ["gemini"]).first { $0.id == "gemini" }!.supportsProfiles)
        XCTAssertNotNil(NewSessionProviders.isolationNotice("gemini"))
        XCTAssertNil(NewSessionProviders.isolationNotice("gemini", apiAccountAvailable: true))
        XCTAssertNotNil(NewSessionProviders.isolationNotice("custom:x", apiAccountAvailable: true))
    }
    func testSelectedGeminiAPIAccountSurvivesResolutionAndOtherProvidersNeverBecomeItsFallback() throws {
        let api = "api-key-" + String(repeating: "a", count: 24)
        let profiles = [NewSessionStartProfile(id: "system", name: "Claude", system: true, provider: "claude"),
            NewSessionStartProfile(id: "system:gemini", name: "Gemini", system: true, provider: "gemini"),
            NewSessionStartProfile(id: api, name: "Gemini API", provider: "gemini")]
        let providers = [NewSessionStartProvider(id: "gemini", label: "Gemini", available: true, canResume: false, supportsProfiles: true)]
        let selected = NewSessionStart.resolve(providers: providers, profiles: profiles, memory: NewSessionMemory(), defaultProvider: "gemini",
            defaultProfileId: "system", projectPath: "/scratch/project", provider: "gemini", profileId: api)
        XCTAssertEqual(selected.request?.profileId, api)
        let fallback = NewSessionStart.resolve(providers: providers, profiles: profiles, memory: NewSessionMemory(), defaultProvider: "gemini",
            defaultProfileId: "system", projectPath: "/scratch/project", provider: "gemini", profileId: nil)
        XCTAssertEqual(fallback.request?.profileId, "system:gemini")
        let missing = "api-key-" + String(repeating: "b", count: 24)
        let unavailable = NewSessionStart.resolve(providers: providers, profiles: profiles, memory: NewSessionMemory(), defaultProvider: "gemini",
            defaultProfileId: "system:gemini", projectPath: "/scratch/project", provider: "gemini", profileId: missing)
        XCTAssertNil(unavailable.request, "A missing API account must never become the machine's subscription login.")
        let foreign = NewSessionStart.resolve(providers: providers, profiles: [NewSessionStartProfile(id: missing, name: "Codex API", provider: "codex")],
            memory: NewSessionMemory(), defaultProvider: "gemini", defaultProfileId: nil, projectPath: "/scratch/project", provider: "gemini", profileId: missing)
        XCTAssertNil(foreign.request)
    }
}
