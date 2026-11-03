import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class LaunchPermissionRulesTests: XCTestCase {
    func testClaudePermissionModesHaveOneSource() throws {
        let expected = ["default", "acceptEdits", "plan", "bypassPermissions"]
        XCTAssertEqual(AGSCapabilities.permissionModes(provider: "claude"), expected)
        XCTAssertEqual(BackendTAGAgentProfile.permissionModes, expected)
        var draft = AgentDraft(nil)
        draft.name = "Fixture"; draft.provider = "claude"
        for mode in expected {
            draft.permissionMode = mode
            XCTAssertEqual(try AgentForm.payload(draft, agents: []).get().permissionMode, mode)
        }
        draft.permissionMode = "not-a-mode"
        XCTAssertThrowsError(try AgentForm.payload(draft, agents: []).get())
    }

    func testEveryLaunchCleanupUsesTheSamePermissionFlags() {
        let shared = ["--permission-mode", "plan", "--sandbox=read-only", "--ask-for-approval", "on-request", "--approval-mode=plan", "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox", "--yolo", "-y", "--full-auto"]
        let retained = ["--resume", "session-id", "--mcp-config", "/private/mcp.json", "--append-system-prompt-file", "/private/owned.md"]
        for provider in ["claude", "codex", "gemini"] {
            XCTAssertEqual(BackendTAGLaunchArguments.removingPermissionOverride(shared + retained, provider: provider), retained)
            XCTAssertEqual(BackendAGSLaunchBinding.removingScalarOverrides(shared + retained, provider: provider), retained)
        }
    }

    func testCodexAliasesAndConfigurationOverridesPreserveOtherConfiguration() {
        let overrides = ["-s", "read-only", "-a=on-request", "-c", "approval_policy=untrusted", "--config", "sandbox_mode=read-only", "--config=approval_policy=never", "-csandbox_mode=workspace-write"]
        let retained = ["-c", "developer_instructions=Keep this", "--config=model=chosen", "--mcp-config=/private/mcp.json"]
        XCTAssertEqual(BackendTAGLaunchArguments.removingPermissionOverride(overrides + retained, provider: "codex"), retained)
        XCTAssertEqual(BackendAGSLaunchBinding.removingScalarOverrides(overrides + retained, provider: "codex"), ["-c", "developer_instructions=Keep this", "--mcp-config=/private/mcp.json"])
    }

    func testGeminiBooleanSandboxDoesNotConsumeFollowingArgument() {
        let input = ["--sandbox", "prompt", "-s", "--resume", "session-id", "--approval-mode", "plan"]
        let expected = ["prompt", "--resume", "session-id"]
        XCTAssertEqual(BackendTAGLaunchArguments.removingPermissionOverride(input, provider: "gemini"), expected)
        XCTAssertEqual(BackendAGSLaunchBinding.removingScalarOverrides(input, provider: "gemini"), expected)
        XCTAssertEqual(BackendTAGLaunchArguments.removingPermissionOverride(["-s", "settings.json"], provider: "claude"), ["-s", "settings.json"])
    }

    func testScalarCleanupKeepsPermissionOnlyCleanupNarrow() {
        let scalars = ["--model", "old", "--effort=high", "--tools", "Read", "--allowed-tools=Write", "--disallowedTools", "Bash", "-c", "model_reasoning_effort=high"]
        XCTAssertEqual(BackendTAGLaunchArguments.removingPermissionOverride(scalars, provider: "codex"), scalars)
        XCTAssertEqual(BackendAGSLaunchBinding.removingScalarOverrides(scalars, provider: "codex"), [])
    }

    func testFreshStartsAlwaysBypassWhateverWasAskedAndRestoresKeepTheirMode() {
        for provider in ["claude", "codex", "gemini"] {
            // R73 (Reviewer M1): a task/agent/start form asking for Ask ("default") still launches a fresh session in bypass.
            XCTAssertEqual(BackendSessionLauncher.initialPermission(requested: "default", provider: provider, fresh: true), BackendTAGLaunchArguments.newSessionPermission(provider: provider))
            XCTAssertEqual(BackendSessionLauncher.initialPermission(requested: "plan", provider: provider, fresh: true), BackendTAGLaunchArguments.newSessionPermission(provider: provider))
            XCTAssertEqual(BackendSessionLauncher.initialPermission(requested: nil, provider: provider, fresh: true), BackendTAGLaunchArguments.newSessionPermission(provider: provider))
            XCTAssertNil(BackendSessionLauncher.initialPermission(requested: nil, provider: provider, fresh: false))
            XCTAssertEqual(BackendSessionLauncher.initialPermission(requested: "plan", provider: provider, fresh: false), "plan")
        }
    }

    func testFreshSessionBypassDefaultsStayExactlyR73() {
        let flags = ["--permission-mode", "plan", "--sandbox=read-only", "--approval-mode", "plan", "--full-auto"]
        let suffixes = ["claude": ["--permission-mode", "bypassPermissions"], "codex": ["--sandbox", "danger-full-access", "--ask-for-approval", "never"], "gemini": ["--yolo"]]
        let modes = ["claude": "bypassPermissions", "codex": "danger-full-access", "gemini": "yolo"]
        for provider in ["claude", "codex", "gemini"] {
            XCTAssertEqual(BackendTAGLaunchArguments.bypassing(flags + ["--resume", "session-id"], provider: provider), ["--resume", "session-id"] + suffixes[provider]!)
            XCTAssertEqual(BackendTAGLaunchArguments.newSessionPermission(provider: provider), modes[provider])
        }
        XCTAssertEqual(BackendTAGLaunchArguments.bypassing(flags, provider: "custom"), flags)
    }
}
