import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Reachable no-process provider cases. The concrete command runner has no
/// fake execution seam; version/cache/login-PATH cases are logged as gaps.
final class BackendFoundationTestsAgentsProviders: XCTestCase {
    // providers.test.ts:118 shell clauses of the macOS table.
    func testMacShellUsesConfiguredLoginShellWithoutProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foundation-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("login-shell")
        // Executable-shaped inert fixture. resolve(shell) checks the file but
        // never executes it or asks for --version.
        try Data().write(to: shell); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: root,
            inheritedEnvironment: ["SHELL": shell.path], home: root.path, runner: BackendCommandRunner())
        let spec = try await providers.resolve(.init(cwd: root.path, provider: "shell"), loginPath: root.path)
        XCTAssertEqual(spec.command, shell.path); XCTAssertEqual(spec.args, ["-l"]); XCTAssertEqual(spec.resumeArgs, [])
    }
    // agent-binaries.test.ts:143 absent half of broken-vs-missing.
    // Nothing on this fixture PATH and no alternate => runner is never called.
    func testAbsentBinaryIsNotMistakenForABrokenInstalledLauncher() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foundation-missing-binary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: root,
            inheritedEnvironment: [:], home: root.path, runner: BackendCommandRunner())
        let binary = await providers.resolveBinary("codex", path: root.path)
        XCTAssertNil(binary.onPath); XCTAssertNil(binary.runnable); XCTAssertFalse(binary.broken)
    }
}
