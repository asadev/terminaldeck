import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class AGOPTModelTests: XCTestCase {
    func testExistingProfileWithoutEfficiencyStillDecodes() throws {
        let json = #"{"provider":"codex","model":"gpt-example","effort":"high","permissionMode":"workspace-write","deniedTools":[],"mcpServers":{"extra":false},"hooks":[],"environment":{},"workingFolder":"/Projects/example","keepOpen":false}"#
        let profile = try JSONDecoder().decode(AGSAgentSettings.self, from: Data(json.utf8))
        XCTAssertNil(profile.efficiency)
        XCTAssertEqual(profile.model, "gpt-example")
        XCTAssertEqual(profile.effort, "high")
        XCTAssertEqual(profile.mcpServers, ["extra": false])
    }

    func testExistingAppDefaultsWithoutEfficiencyStillDecode() throws {
        let json = #"{"providers":{"claude":{"provider":"claude","deniedTools":[],"mcpServers":{},"hooks":[],"environment":{},"keepOpen":true}},"hooks":[]}"#
        let defaults = try JSONDecoder().decode(AGSDefaults.self, from: Data(json.utf8))
        XCTAssertNil(defaults.providers["claude"]?.efficiency)
        XCTAssertEqual(defaults.providers["claude"]?.keepOpen, true)
    }

    func testSavedEfficiencyPreservesInheritedAndExplicitUnlimitedChoices() throws {
        let efficiency = AGOPTEfficiencySettings(reuseContext: true, completion: "park", addonsOff: true,
            agentTokenBudget: 0, taskTokenBudget: nil, warningPercent: 80, serializeHeavyJobs: true)
        let profile = AGSAgentSettings(provider: "claude", efficiency: efficiency)
        let saved = try JSONEncoder().encode(AGSDefaults(providers: ["claude": profile]))
        let restored = try JSONDecoder().decode(AGSDefaults.self, from: saved)
        XCTAssertEqual(restored.providers["claude"]?.efficiency, efficiency)
        XCTAssertEqual(restored.providers["claude"]?.efficiency?.agentTokenBudget, 0)
        XCTAssertNil(restored.providers["claude"]?.efficiency?.taskTokenBudget)
    }
}
