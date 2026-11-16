import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review of e425bca2e, blocker 1 (launch side): the New session page's explicit "Before it changes files" pick
/// (`chosenStartPermission`) is R73's one exception. A fresh start runs in exactly that mode, passed by name ("default"
/// included), whatever an agent, a profile or the AI's saved default in Settings asked (Bypass in these tests); every
/// launch without it keeps R73 exactly (LaunchPermissionRulesTests, unchanged).
final class LandingExplicitStartPermissionTests: XCTestCase {
    static let bypass = ["claude": "bypassPermissions", "codex": "danger-full-access", "gemini": "yolo"]

    func testThePagesPickReplacesBypassOnAFreshStartOnly() throws {
        for provider in ["claude", "codex", "gemini"] {
            for mode in AGSCapabilities.permissionModes(provider: provider) {
                let chosen = try BackendTAGLaunchArguments.chosenStart(mode, provider: provider)
                XCTAssertEqual(chosen, mode)
                // The agent's / Settings' own mode is Bypass: his pick still wins.
                XCTAssertEqual(BackendSessionLauncher.initialPermission(requested: Self.bypass[provider], provider: provider, fresh: true, chosen: chosen), mode)
                // A restore keeps what it carries.
                XCTAssertEqual(BackendSessionLauncher.initialPermission(requested: "plan", provider: provider, fresh: false, chosen: nil), "plan")
            }
            // No pick: R73 as before.
            XCTAssertNil(try BackendTAGLaunchArguments.chosenStart(nil, provider: provider))
            XCTAssertEqual(BackendSessionLauncher.initialPermission(requested: "default", provider: provider, fresh: true), Self.bypass[provider])
        }
    }

    func testAModeThisAIDoesNotHaveRefusesTheStart() {
        XCTAssertThrowsError(try BackendTAGLaunchArguments.chosenStart("plan", provider: "codex"))
        XCTAssertThrowsError(try BackendTAGLaunchArguments.chosenStart("bypassPermissions", provider: "gemini"))
        XCTAssertThrowsError(try BackendTAGLaunchArguments.chosenStart("default", provider: "shell"), "never Bypass in its place")
    }

    func testClaudeAskFirstIsPassedByName() {
        let inherited = ["--dangerously-skip-permissions", "--permission-mode", "bypassPermissions", "--model", "opus"]
        XCTAssertEqual(BackendTAGLaunchArguments.explicitStart(inherited, provider: "claude", mode: "default"),
                       ["--model", "opus", "--permission-mode", "default"])
        XCTAssertEqual(BackendTAGLaunchArguments.explicitStart(["--yolo"], provider: "gemini", mode: "default"), ["--approval-mode", "default"])
        XCTAssertEqual(BackendTAGLaunchArguments.explicitStart(["--sandbox", "danger-full-access", "--ask-for-approval", "never"], provider: "codex", mode: "default"),
                       ["--ask-for-approval", "on-request"])
        XCTAssertEqual(BackendTAGLaunchArguments.explicitStart([], provider: "codex", mode: "read-only"), ["--sandbox", "read-only", "--ask-for-approval", "on-request"])
        for provider in ["claude", "codex", "gemini"] {
            // His explicit Bypass is the same launch R73 makes.
            XCTAssertEqual(BackendTAGLaunchArguments.explicitStart(["--resume", "x"], provider: provider, mode: Self.bypass[provider]!),
                           BackendTAGLaunchArguments.bypassing(["--resume", "x"], provider: provider))
        }
    }

    func testAChatStartedFromThePageKeepsAskFirstByName() {
        let key = BackendSessionChats.explicitPermissionKey
        XCTAssertEqual(BackendSessionChats.withChoices(["--permission-mode", "default"], provider: .claude, choices: ["permission": "default", key: "true"]),
                       ["--permission-mode", "default"])
        XCTAssertEqual(BackendSessionChats.withChoices(["--yolo"], provider: .gemini, choices: ["permission": "default", key: "true"]),
                       ["--approval-mode", "default"])
        // Every other chat: exactly as before.
        XCTAssertEqual(BackendSessionChats.withChoices(["--permission-mode", "default"], provider: .claude, choices: ["permission": "default"]), [])
        XCTAssertTrue(BackendSessionChats.withChoices(["--yolo"], provider: .gemini, choices: ["permission": "default"]).isEmpty)
    }

    /// Point 7: the running host says it starts in the pick through its hello. An older host's hello (no such key)
    /// reads as "no"; an older app reading the new hello ignores the key (synthesized Codable, unknown keys skipped).
    func testTheHostsHelloSaysWhetherItStartsInThePick() throws {
        let old = #"{"protocolVersion":2,"hostVersion":"0.21.3-host3","hostPID":1,"instance":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","chatService":1}"#
        let decoded = try JSONDecoder().decode(BackendHOSTProtocol.Hello.self, from: Data(old.utf8))
        XCTAssertNil(decoded.chosenStartPermission)
        var hello = decoded
        hello.chosenStartPermission = 1
        let again = try JSONDecoder().decode(BackendHOSTProtocol.Hello.self, from: JSONEncoder().encode(hello))
        XCTAssertEqual(again.chosenStartPermission, 1)
        struct OlderHello: Decodable { var protocolVersion: Int; var hostVersion: String; var hostPID: Int32; var instance: UUID; var chatService: Int? }
        XCTAssertEqual(try JSONDecoder().decode(OlderHello.self, from: JSONEncoder().encode(hello)).hostVersion, "0.21.3-host3")
    }

    func testTheInputCarriesThePickAndOtherInputsDoNot() throws {
        var input = BackendCreateSessionInput(cwd: "/work", provider: "claude")
        XCTAssertNil(input.chosenStartPermission)
        input.chosenStartPermission = "default"
        let decoded = try JSONDecoder().decode(BackendCreateSessionInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.chosenStartPermission, "default", "it reaches the session host too")
        let old = try JSONDecoder().decode(BackendCreateSessionInput.self, from: Data(#"{"cwd":"/work","cols":100,"rows":30}"#.utf8))
        XCTAssertNil(old.chosenStartPermission)
    }
}
