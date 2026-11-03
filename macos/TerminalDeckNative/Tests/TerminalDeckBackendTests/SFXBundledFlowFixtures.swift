import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real-runtime fixture. Its sample is copied before setup, and every writable
/// path (project, HOME, runtime and preferences) stays inside one temporary root.
/// There is no injected engine, execution closure, Node executable or CLI reply.
struct SFXBundledFlowFixture: Sendable {
    let root: URL
    let original: URL
    let project: URL
    let userData: URL
    let productArchive: URL
    let fetcher: SFXBundledFlowDownloads
    let runtime: BackendNodelessStaysFixedRuntime

    static let greeting = """
    // A tiny Swift command copied into an isolated project before it is checked.
    print("Hello, world!")
    print("Total: 10.00")

    """
    static let command = "/usr/bin/swift SFXGreeting.swift --help"

    static func make() throws -> Self {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SFX-bundled-flow-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let original = root.appendingPathComponent("sample-original", isDirectory: true)
            let project = root.appendingPathComponent("sample-copy", isDirectory: true)
            let userData = root.appendingPathComponent("isolated-data", isDirectory: true)
            try fm.createDirectory(at: original, withIntermediateDirectories: false)
            try Data(greeting.utf8).write(to: original.appendingPathComponent("SFXGreeting.swift"))
            try Data("# SFX sample\nA tiny command written in Swift.\n".utf8).write(to: original.appendingPathComponent("README.md"))
            try fm.copyItem(at: original, to: project)
            let archive = try bundledArchive()
            let fetcher = SFXBundledFlowDownloads()
            let runtime = try BackendNodelessStaysFixedRuntime(userData: userData, bundledProduct: archive, fetcher: fetcher)
            return Self(root: root, original: original, project: project, userData: userData, productArchive: archive,
                        fetcher: fetcher, runtime: runtime)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    private static func bundledArchive() throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let archive = cursor.appendingPathComponent("vendor/" + BackendNodelessStaysFixedPins.bundledProductName)
            if FileManager.default.fileExists(atPath: archive.path) { return archive }
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }
            cursor = parent
        }
        throw NativeRPCError(code: "unavailable", message: "The repository's bundled Stays Fixed archive is missing. Run this test from macos/testpkg-p1 with its real source symlinks.")
    }

    func service(provisioning: (any BackendStaysFixedProvisioning)? = nil, events: SFXBundledFlowEvents = .init()) -> BackendStaysFixedService {
        BackendStaysFixedService(userData: userData, home: root.path, executable: nil,
            inheritedEnvironment: ["HOME": root.path, "TMPDIR": root.path],
            locate: { throw NativeRPCError(code: "unavailable", message: "A copied sample must use the pinned bundled runtime.") },
            loginPath: { "/usr/bin:/bin:/usr/sbin:/sbin" }, changed: { events.append($0) },
            provisioning: provisioning ?? runtime)
    }

    func createInitialCommit() throws {
        try git(["init", "--quiet"])
        try git(["add", "SFXGreeting.swift", "README.md"])
        if let config = BackendStaysFixedWhere.config(project.path) { try git(["add", config]) }
        if FileManager.default.fileExists(atPath: project.appendingPathComponent(".gitignore").path) { try git(["add", ".gitignore"]) }
        try git(["-c", "user.name=SFX Isolated Fixture", "-c", "user.email=sfx-fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "SFX copied sample baseline"])
    }

    func initializeRepository() throws { try git(["init", "--quiet"]) }

    func copyNoCoverageSample() throws -> URL {
        let fm = FileManager.default
        let origin = root.appendingPathComponent("empty-original", isDirectory: true)
        let copy = root.appendingPathComponent("empty-copy", isDirectory: true)
        try fm.createDirectory(at: origin, withIntermediateDirectories: false)
        try Data("# Empty sample\nNo runnable command or product source is present.\n".utf8).write(to: origin.appendingPathComponent("README.md"))
        try fm.copyItem(at: origin, to: copy)
        try git(["init", "--quiet"], at: copy)
        try git(["add", "README.md"], at: copy)
        try git(["-c", "user.name=SFX Isolated Fixture", "-c", "user.email=sfx-fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "SFX empty copied sample"], at: copy)
        return copy
    }

    private func git(_ arguments: [String], at copy: URL? = nil) throws {
        // Never consult the person's global Git configuration or signing setup.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = copy ?? project
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeRPCError(code: "failed", message: "Isolated sample git operation failed: " + String(decoding: bytes, as: UTF8.self))
        }
    }

    func setRegression(_ regressed: Bool) throws {
        let source = regressed ? Self.greeting.replacingOccurrences(of: "10.00", with: "99.00") : Self.greeting
        try Data(source.utf8).write(to: project.appendingPathComponent("SFXGreeting.swift"), options: .atomic)
    }

    func originalIsUntouched() throws -> Bool {
        try String(contentsOf: original.appendingPathComponent("SFXGreeting.swift"), encoding: .utf8) == Self.greeting
            && FileManager.default.contentsOfDirectory(atPath: original.path).sorted() == ["README.md", "SFXGreeting.swift"]
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

final class SFXBundledFlowDownloads: BackendNodelessStaysFixedFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [String] = []
    var requests: [String] { lock.withLock { requested } }
    func fetch(_ url: URL, to destination: URL, maximumBytes: Int) async throws {
        lock.withLock { requested.append(url.absoluteString) }
        // Production downloader and production pins; fixture success cannot be
        // manufactured by a fake archive or foreign executable.
        try await BackendNodelessStaysFixedURLFetch().fetch(url, to: destination, maximumBytes: maximumBytes)
    }
}

final class SFXBundledFlowEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String] = []
    func append(_ root: String) { lock.withLock { roots.append(root) } }
    var values: [String] { lock.withLock { roots } }
}
