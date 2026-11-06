import Foundation
import XCTest
@testable import TerminalDeckBackend

/// 0.21.3 was stopped (6 Nov): the keeper named `@rpath/LiveKitWebRTC.framework` strongly. The app copies the keeper out
/// of its bundle to `<data>/host[/agents]/<version>/TerminalDeckNativeHelper` and runs it there, where no framework sits
/// beside it, so dyld killed it before main() and the engine said "The bundled helper does not implement the native
/// account-vault protocol". Dev copies hid it: their keeper runs beside the build's libraries.
/// This repeats production: package the built keeper the way build-app.sh does (no build-machine rpaths, the bundle's
/// Frameworks rpath), copy it out the way BackendHOSTLaunchAgent.installHelper does, then run the app's own check on it.
final class KeeperCopyOutLaunchTests: XCTestCase {
    private var builtKeeper: URL {
        Bundle(for: KeeperCopyOutLaunchTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TerminalDeckSessionHostHelper")
    }
    private func run(_ command: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (code: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    private func loadCommands(_ file: URL) throws -> String {
        let result = try run("/usr/bin/otool", ["-l", file.path])
        XCTAssertEqual(result.code, 0, result.output)
        return result.output
    }
    /// (command, name) for every library load and rpath, in file order.
    private func entries(_ commands: String) -> [(command: String, value: String)] {
        let pattern = try! NSRegularExpression(pattern: #"cmd (LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|LC_REEXPORT_DYLIB|LC_LOAD_UPWARD_DYLIB|LC_RPATH)\s+cmdsize \d+\s+(?:name|path) (.*?) \(offset"#)
        let text = commands as NSString
        return pattern.matches(in: commands, range: NSRange(location: 0, length: text.length)).map {
            (text.substring(with: $0.range(at: 1)), text.substring(with: $0.range(at: 2)))
        }
    }

    func testKeeperNeedsNoLibraryBesideItsCopy() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: builtKeeper.path), "build the keeper first: \(builtKeeper.path)")
        let found = entries(try loadCommands(builtKeeper))
        let required = found.filter { $0.command != "LC_RPATH" && $0.command != "LC_LOAD_WEAK_DYLIB" }
            .map(\.value).filter { !$0.hasPrefix("/System/Library/") && !$0.hasPrefix("/usr/lib/") }
        XCTAssertEqual(required, [], "The copied keeper has no libraries beside it; link these weakly or keep them out of the keeper")
        // The weak link is what keeps the Mac sign-in helper's direct screen link (it runs inside the app bundle).
        XCTAssertTrue(found.contains { $0.command == "LC_LOAD_WEAK_DYLIB" && $0.value.hasSuffix("LiveKitWebRTC.framework/LiveKitWebRTC") })
    }

    func testCopiedOutKeeperStartsAndAnswersTheAccountVaultCheck() throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("keeper-copy-out-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Packaging (build-app.sh): the bundle's keeper loses every build-machine rpath and gains the bundle's Frameworks.
        let packaged = root.appendingPathComponent("Packaged.app/Contents/MacOS/TerminalDeckSessionHostHelper")
        try FileManager.default.createDirectory(at: packaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: builtKeeper, to: packaged)
        for entry in entries(try loadCommands(packaged)) where entry.command == "LC_RPATH" && entry.value.hasPrefix("/") {
            let removed = try run("/usr/bin/install_name_tool", ["-delete_rpath", entry.value, packaged.path])
            XCTAssertEqual(removed.code, 0, removed.output)
        }
        if !entries(try loadCommands(packaged)).contains(where: { $0.command == "LC_RPATH" && $0.value == "@executable_path/../Frameworks" }) {
            let added = try run("/usr/bin/install_name_tool", ["-add_rpath", "@executable_path/../Frameworks", packaged.path])
            XCTAssertEqual(added.code, 0, added.output)
        }
        let signed = try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", packaged.path])
        XCTAssertEqual(signed.code, 0, signed.output)
        XCTAssertFalse(try loadCommands(packaged).contains("/Users/"), "the packaged keeper still names a build-machine path")

        // Copy-out (installHelper): only the executable, mode 0700, in its versioned folder; both namespaces.
        let data = root.appendingPathComponent("data")
        try BackendHOSTFiles.privateDirectory(data)
        let version = try BackendHOSTLaunchAgent.buildVersion(marketing: "0.0.0-host3", helper: packaged)
        for namespace in [nil, "agents"] as [String?] {
            let paths = try BackendHOSTPaths(dataDirectory: data, namespace: namespace)
            try paths.prepare()
            let folder = paths.directory.appendingPathComponent(version, isDirectory: true)
            try BackendHOSTFiles.privateDirectory(folder)
            let copy = folder.appendingPathComponent("TerminalDeckNativeHelper")
            try FileManager.default.copyItem(at: packaged, to: copy)
            XCTAssertEqual(chmod(copy.path, 0o700), 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["TerminalDeckNativeHelper"])

            // The app's own check (resources.configure), which failed on 0.21.3: the copy must start and answer protocol 3.
            XCTAssertNoThrow(try BackendAccountSecurityShimClient.verifyHelper(copy), "copied keeper in \(folder.path) did not start")
            // A clean environment, as launchd gives it (no DYLD_* or Xcode paths from this test run).
            let probe = try run(copy.path, ["--session-host-capabilities"], environment: ["PATH": "/usr/bin:/bin"])
            XCTAssertEqual(probe.code, 0, probe.output)
            XCTAssertFalse(probe.output.contains("Library not loaded"), probe.output)
            XCTAssertTrue(probe.output.contains("\"sessionHost\":"), probe.output)
        }
    }
}
