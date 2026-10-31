import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AgentCapabilitiesTests: XCTestCase {
    func testFormAndBackendUseTheSameCapabilities() {
        for provider: String? in [nil, "claude", "codex", "gemini", "shell", "custom-ai"] {
            for setting in AgentSetting.allCases {
                let backend = BackendSharedAgentCapabilities.capabilityFor(provider, setting: setting)
                XCTAssertEqual(AgentCapabilities.support(provider, setting), backend.support)
                XCTAssertEqual(AgentCapabilities.how(provider, setting), backend.how)
            }
        }
    }
}
