import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// platform/lookup.test.ts. The where.exe / CRLF / Windows-null cases are
/// Windows-only (lookupSpec, firstLookupPath, loginPathSpec do not exist in the
/// Mac port); the Mac equivalent is BackendNativeProviders.lookup (PATH search).
final class BackendFoundationTestsS6C2PlatformLookup: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s6c2-lookup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // lookup.test.ts:5 (darwin half) / :32 "takes the single line which prints": a PATH hit is an absolute path.
    func testS6C2LookupFindsExecutableOnPath() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("tailscale")
        try Data("#!/bin/sh\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        XCTAssertEqual(BackendNativeProviders.lookup("tailscale", path: "relative:" + dir.path), bin.path)
    }

    // lookup.test.ts:44 "answers null for nothing at all" / :49 diagnostics are never a path.
    func testS6C2LookupAnswersNilForNothing() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(BackendNativeProviders.lookup("definitely-not-installed", path: dir.path))
        XCTAssertNil(BackendNativeProviders.lookup("", path: dir.path))
        XCTAssertNil(BackendNativeProviders.lookup("INFO: Could not find files for the given pattern(s).", path: dir.path))
    }

    // lookup.test.ts:12 "passes the name as an argument, never inside the command": a hostile name is not run, only matched.
    func testS6C2LookupTreatsHostileNameAsDataAndSkipsNonExecutables() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(BackendNativeProviders.lookup("a b; rm -rf /", path: dir.path))
        let plain = dir.appendingPathComponent("notexec")
        try Data("x".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        XCTAssertNil(BackendNativeProviders.lookup("notexec", path: dir.path))
        XCTAssertNil(BackendNativeProviders.lookup("x\0y", path: dir.path))
    }
}
