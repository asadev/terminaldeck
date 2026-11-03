import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ProviderConcurrentPathTests: XCTestCase {
    func testConcurrentWaitersIncludeOfficialInstallFolder() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/path-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try Data("#!/bin/sh\n/bin/sleep 0.2\nprintf '\\000/usr/bin\\000'\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let store = NativeStateStore()
        let provider = try BackendNativeProviders(store: store, dataRoot: root, inheritedEnvironment: ["SHELL": shell.path, "PATH": "/usr/bin"], home: root.path, runner: BackendCommandRunner())
        let paths = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await provider.loginPath() } }
            var paths: [String] = []
            for try await path in group { paths.append(path) }
            return paths
        }
        XCTAssertEqual(paths.count, 8)
        XCTAssertEqual(Set(paths), ["/usr/bin:" + root.appendingPathComponent(".local/bin").path])
        await store.close()
    }
}
