import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// U159: agent settings rules are kept once and read from there.
@MainActor
struct AgentSettingsOneRuleTests {
    // #517: the agent window refuses exactly the names the save check refuses.
    @Test func windowRefusesTheSharedEnvironmentNames() {
        for name in AGSCapabilities.reservedEnvironmentNames { #expect(!NativeAGSWords.validEnvironmentName(name)) }
        #expect(!NativeAGSWords.validEnvironmentName("GEMINI_CLI_SYSTEM_SETTINGS_PATH"))
        #expect(!NativeAGSWords.validEnvironmentName("CLAUDE_CODE_USE_BEDROCK"))
        #expect(NativeAGSWords.validEnvironmentName("MY_TOOL_FLAG"))
    }

    // #529: the task permission modes are Claude Code's from the one list.
    @Test func taskPermissionModesComeFromTheOneList() {
        #expect(BackendTAGAgentProfile.permissionModes == AGSCapabilities.permissionModes(provider: "claude"))
    }
}
