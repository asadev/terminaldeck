import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// platform/paths.test.ts. The electronPaths case is Electron-only (skipped).
final class BackendFoundationTestsS6C2PlatformPaths: XCTestCase {
    private func node(_ platform: NativePlatformPaths.Platform, _ env: [String: String], _ home: String) throws -> NativePlatformPaths {
        try NativePlatformPaths.node(platform: platform, environment: env, home: home, appRoot: "/app", applicationID: "terminaldeck")
    }

    func testS6C2LinuxStateUnderXdgDataHome() throws {
        let p = try node(.linux, ["XDG_DATA_HOME": "/home/asad/.local/share"], "/home/asad")
        XCTAssertEqual(p.userData, "/home/asad/.local/share/terminaldeck")
    }
    func testS6C2LinuxFallsBackWhenXdgUnset() throws {
        XCTAssertEqual(try node(.linux, [:], "/home/asad").userData, "/home/asad/.local/share/terminaldeck")
    }
    func testS6C2LinuxIgnoresRelativeXdgDataHome() throws {
        XCTAssertEqual(try node(.linux, ["XDG_DATA_HOME": "share"], "/home/asad").userData, "/home/asad/.local/share/terminaldeck")
    }
    func testS6C2MacApplicationSupportDirectory() throws {
        XCTAssertEqual(try node(.darwin, [:], "/Users/asad").userData, "/Users/asad/Library/Application Support/terminaldeck")
    }
    func testS6C2WindowsUsesAppDataAndDerivesWhenMissing() throws {
        let a = try node(.win32, ["APPDATA": "C:\\Users\\Asad\\AppData\\Roaming"], "C:\\Users\\Asad")
        XCTAssertEqual(a.userData.replacingOccurrences(of: "\\", with: "/"), "C:/Users/Asad/AppData/Roaming/terminaldeck")
        let b = try node(.win32, [:], "C:\\Users\\Asad")
        XCTAssertEqual(b.userData.replacingOccurrences(of: "\\", with: "/"), "C:/Users/Asad/AppData/Roaming/terminaldeck")
    }
    func testS6C2XdgDownloadDirHonouredOnLinuxOnly() throws {
        XCTAssertEqual(try node(.linux, ["XDG_DOWNLOAD_DIR": "/srv/incoming"], "/home/asad").downloads, "/srv/incoming")
        XCTAssertEqual(try node(.darwin, ["XDG_DOWNLOAD_DIR": "/srv/incoming"], "/Users/asad").downloads, "/Users/asad/Downloads")
    }

    // paths.test.ts:62 nothing installed -> refusal naming the problem.
    func testS6C2UninstalledProviderThrows() async {
        let installation = NativePlatformPathInstallation()
        do { _ = try await installation.paths(); XCTFail("expected throw") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "paths-uninstalled") }
        catch { XCTFail("\(error)") }
    }

    // paths.test.ts:67 same context twice is fine, a different one conflicts.
    func testS6C2SecondDifferentProviderRefused() async throws {
        let installation = NativePlatformPathInstallation()
        let first = try node(.linux, [:], "/home/a")
        try await installation.install(first)
        try await installation.install(first)
        do { try await installation.install(try node(.linux, [:], "/home/b")); XCTFail("expected conflict") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "paths-conflict") }
        catch { XCTFail("\(error)") }
    }
}
