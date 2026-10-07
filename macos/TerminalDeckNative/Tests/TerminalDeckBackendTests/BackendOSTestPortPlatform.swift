import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSTestPortPlatform: XCTestCase {
    private let paths = NativePlatformPaths(platform: .darwin, userData: "/data", home: "/home", downloads: "/downloads", appRoot: "/app")
    func testPlatformHost23CurrentMacPlatform() { XCTAssertEqual(BackendOSPlatform.platform, "darwin") }
    func testPlatformHost43PosixCaseSensitivity() { XCTAssertEqual(paths.environmentPath(["Path": "wrong", "PATH": "right"]), "right"); XCTAssertEqual(paths.environmentPath(["Path": "not POSIX PATH"]), "") }
    func testPlatformHost48AbsentPathIsEmpty() { XCTAssertEqual(paths.environmentPath([:]), "") }
    func testPlatformHost53MacPathClassification() { XCTAssertEqual(paths.pathKey(in: ["Path": "unrelated"]), "PATH"); XCTAssertEqual(paths.environmentPath(["PATH": "yes", "Path": "no"]), "yes") }
    func testPlatformHost60KeepsMacPathSpelling() { XCTAssertEqual(paths.pathKey(in: ["Path": "/nonsense"]), "PATH") }
    func testPlatformHost78PosixPathOverride() { XCTAssertEqual(paths.withPath("new", environment: ["PATH": "old", "HOME": "/home"]), ["PATH": "new", "HOME": "/home"]) }
    func testPlatformHost86PreservesUnrelatedPosixPathSpelling() { XCTAssertEqual(paths.withPath("new", environment: ["PATH": "old", "Path": "unrelated"]), ["PATH": "new", "Path": "unrelated"]) }
    func testPlatformHost93DoesNotMutateInput() { let original = ["PATH": "old", "HOME": "/home"]; _ = paths.withPath("new", environment: original); XCTAssertEqual(original, ["PATH": "old", "HOME": "/home"]) }
    func testPlatformHost99NoUndefinedIntroduced() { XCTAssertEqual(paths.withPath("x", environment: [:]), ["PATH": "x"]) }
    func testPlatformHost117BonjourSuffixRemoved() { XCTAssertEqual(BackendOSPlatform.machineName("My-Mac.local"), "My-Mac"); XCTAssertEqual(BackendOSPlatform.machineName("My-Mac.LOCAL"), "My-Mac") }
    func testPlatformHost122NoInventedMachineName() { XCTAssertEqual(BackendOSPlatform.machineName(""), ""); XCTAssertEqual(BackendOSPlatform.machineName("  real-host  "), "real-host") }
    func testPlatformLoginEnv10OwnInteractiveLoginShell() { let spec = BackendOSPlatform.loginEnvironmentNamesSpec(environment: ["SHELL": "/bin/bash"]); XCTAssertEqual(spec.command, "/bin/bash"); XCTAssertEqual(spec.arguments[0], "-lic") }
    func testPlatformLoginEnv21DefaultZsh() { XCTAssertEqual(BackendOSPlatform.loginEnvironmentNamesSpec(environment: [:]).command, "/bin/zsh") }
    func testPlatformLoginEnv25NamesNotValues() { let command = BackendOSPlatform.loginEnvironmentNamesSpec(environment: ["SHELL": "/bin/zsh"]).arguments[1]; XCTAssertTrue(command.contains("printenv")); XCTAssertTrue(command.contains("=.*/")); XCTAssertFalse(command.contains("echo $")) }
    func testPlatformLoginEnv46NothingInterpolated() { let spec = BackendOSPlatform.loginEnvironmentNamesSpec(environment: ["SHELL": "/bin/zsh"]); XCTAssertFalse(spec.arguments.joined(separator: " ").contains("for ")); XCTAssertFalse(spec.arguments.joined(separator: " ").contains("eval")) }
    func testPlatformLoginEnv66OneNamePerLine() { XCTAssertEqual(BackendOSPlatform.parseEnvironmentNames("PATH\nHOME\nGITHUB_TOKEN\n"), ["PATH", "HOME", "GITHUB_TOKEN"]) }
    func testPlatformLoginEnv70OnlyShellIdentifiers() { XCTAssertEqual(BackendOSPlatform.parseEnvironmentNames("GITHUB_TOKEN\n-----BEGIN CERTIFICATE-----\n   \n9LIVES\nHOME"), ["GITHUB_TOKEN", "HOME"]) }
    func testPlatformLoginEnv87CRLFAndEmpty() { XCTAssertEqual(BackendOSPlatform.parseEnvironmentNames("A\r\nB\r\n"), ["A", "B"]); XCTAssertEqual(BackendOSPlatform.parseEnvironmentNames(""), []) }
    func testPlatformCredentials5KnownMacIsolation() { let value = BackendOSPlatform.profileIsolation; XCTAssertEqual(value["isolated"].bool, true); XCTAssertEqual(value["store"].string, "macos-keychain"); XCTAssertTrue(value["note"].string?.contains("Keychain") == true) }
    func testPlatformCredentials42ConfigFileCannotOverruleKeychain() { let value = BackendOSPlatform.profileIsolation; XCTAssertEqual(value["store"].string, "macos-keychain"); XCTAssertTrue(value["note"].string?.contains("does not sign it out") == true) }
    func testPlatformCredentials54MacCopyHasUsefulSentence() { let note = BackendOSPlatform.profileIsolation["note"].string ?? ""; XCTAssertGreaterThan(note.count, 60); XCTAssertTrue(note.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".")) }
    func testPlatformTailscale7OriginalMacCandidates() { XCTAssertEqual(BackendOSPlatform.tailscaleCandidates, ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]) }
    func testPlatformTailscale16WindowsEnvironmentCannotChangeMacCandidates() { XCTAssertEqual(BackendOSPlatform.tailscaleCandidates, ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]) }
    func testPlatformTailscale78LookupNameHasNoExtension() { XCTAssertTrue(BackendOSPlatform.tailscaleCandidates.allSatisfy { !$0.hasSuffix(".exe") }); XCTAssertEqual(URL(fileURLWithPath: BackendOSPlatform.tailscaleCandidates[0]).lastPathComponent, "tailscale") }
}
