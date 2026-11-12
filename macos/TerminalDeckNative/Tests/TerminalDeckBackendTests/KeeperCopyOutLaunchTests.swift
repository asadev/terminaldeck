import Foundation
import Security
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 0.21.3 was stopped (6 Nov): the keeper named `@rpath/LiveKitWebRTC.framework` strongly. The app copies the keeper out
/// of its bundle to `<data>/host[/agents]/<version>/Terminal Deck` (before 9 Nov: `TerminalDeckNativeHelper`) and runs it
/// there, where no framework sits
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
            let copy = BackendHOSTLaunchAgent.keeperExecutable(in: folder)
            try BackendHOSTLaunchAgent.installKeeper(from: packaged, to: copy)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Terminal Deck"])

            // The app's own check (resources.configure), which failed on 0.21.3: the copy must start and answer protocol 3.
            XCTAssertNoThrow(try BackendAccountSecurityShimClient.verifyHelper(copy), "copied keeper in \(folder.path) did not start")
            // A clean environment, as launchd gives it (no DYLD_* or Xcode paths from this test run).
            let probe = try run(copy.path, ["--session-host-capabilities"], environment: ["PATH": "/usr/bin:/bin"])
            XCTAssertEqual(probe.code, 0, probe.output)
            XCTAssertFalse(probe.output.contains("Library not loaded"), probe.output)
            XCTAssertTrue(probe.output.contains("\"sessionHost\":"), probe.output)
        }
    }

    /// One name (9 Nov): launchd starts the app's own program with `--session-host-launch`; it copies this bundle's keeper
    /// out (when launchd restarts it after a crash) or takes the build the app asked for, then hands over with the exact
    /// production arguments. A test bundle can only ever name its own data folder.
    func testAppProgramHandsOverToTheCopiedKeeperWithProductionArguments() throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("keeper-hand-over-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Hand Over.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("MacOS/TerminalDeckNative"))
        try FileManager.default.copyItem(at: builtKeeper, to: app.appendingPathComponent("MacOS/TerminalDeckSessionHostHelper"))
        let signedSource = try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "dev.terminaldeck.app.session-host",
                                                        app.appendingPathComponent("MacOS/TerminalDeckSessionHostHelper").path])
        XCTAssertEqual(signedSource.code, 0, signedSource.output)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.terminaldeck.handover." + UUID().uuidString.prefix(8).lowercased(),
            "CFBundleExecutable": "TerminalDeckNative", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.9"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app.deletingLastPathComponent()))
        let data = root.appendingPathComponent("data")
        try BackendHOSTFiles.privateDirectory(data)
        let environment = [NativeLaunchSwitches.dataFolder: data.path]
        let paths = try BackendHOSTPaths(dataDirectory: data, namespace: "agents")
        let arguments = ["TerminalDeckNative", BackendHOSTService.launchArgument, "agents"]
        let scratchEnvironment = [NativeLaunchSwitches.agentConfigReadOnly: "1", NativeLaunchSwitches.dataFolder: data.path]

        // Nothing requested and no sessions: launchd's load-time run stops at once.
        guard case .stay = BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: environment, signingTeam: nil) else { return XCTFail("started unrequested") }
        // A test copy never reaches the real data folder, and must name its own.
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminaldeck").path
        guard case .stay = BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: [NativeLaunchSwitches.dataFolder: real], signingTeam: nil) else { return XCTFail("test copy reached the real data folder") }
        guard case .stay = BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: [:], signingTeam: nil) else { return XCTFail("test copy without a data folder") }
        guard case .stay = BackendHOSTService.launch(arguments: ["TerminalDeckNative", BackendHOSTService.launchArgument, "other"], bundle: bundle, environment: environment, signingTeam: nil) else { return XCTFail("unknown namespace") }

        // Crash recovery (sessions were active): this bundle's keeper is copied out like installHelper and started.
        try paths.prepare()
        try BackendHOSTFiles.atomicWrite(Data("active".utf8), to: paths.activeFile)
        let version = try BackendHOSTLaunchAgent.buildVersion(marketing: "0.0.9" + BackendHOSTLaunchAgent.hostGeneration, helper: app.appendingPathComponent("MacOS/TerminalDeckSessionHostHelper"))
        let copy = paths.directory.appendingPathComponent(version).appendingPathComponent("Terminal Deck")
        XCTAssertEqual(BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: environment, signingTeam: nil),
                       .exec(path: copy.path, arguments: [copy.path, "--session-host", data.path, version, "agents"], environment: scratchEnvironment))
        var info_ = stat(); XCTAssertEqual(lstat(copy.path, &info_), 0); XCTAssertEqual(info_.st_mode & 0o777, 0o700)
        let probe = try run(copy.path, ["--session-host-capabilities"], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(probe.code, 0, probe.output)
        XCTAssertTrue(probe.output.contains("\"sessionHost\":"), probe.output)
        // launchd passes no environment to a transient test job: the same start by argument.
        XCTAssertEqual(BackendHOSTService.launch(arguments: arguments + ["--data-folder", data.path], bundle: bundle, environment: [:], signingTeam: nil),
                       .exec(path: copy.path, arguments: [copy.path, "--session-host", data.path, version, "agents"], environment: scratchEnvironment))
        _ = unlink(paths.activeFile.path)

        // The app's request names the build it installed; it is consumed, and a missing build is never guessed.
        let request = paths.directory.appendingPathComponent(BackendHOSTService.launchRequestFile)
        try BackendHOSTFiles.atomicWrite(Data(version.utf8), to: request)
        XCTAssertEqual(BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: environment, signingTeam: nil),
                       .exec(path: copy.path, arguments: [copy.path, "--session-host", data.path, version, "agents"], environment: scratchEnvironment))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
        try BackendHOSTFiles.atomicWrite(Data("../escape".utf8), to: request)
        guard case .stay = BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: environment, signingTeam: nil) else { return XCTFail("bad request accepted") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
    }

    /// review-one-name-0609 #2: the hand-over runs only this developer's keeper under the app's grants. A damaged,
    /// unsigned or foreign copy is refused (exit 0, like a missing keeper); a Developer ID app also pins its team.
    func testHandOverRefusesAKeeperThatIsNotThisDevelopersOwn() throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("keeper-signature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Signed.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("MacOS/TerminalDeckNative"))
        let source = app.appendingPathComponent("MacOS/TerminalDeckSessionHostHelper")
        try FileManager.default.copyItem(at: builtKeeper, to: source)
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "dev.terminaldeck.app.session-host", source.path]).code, 0)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.terminaldeck.signature." + UUID().uuidString.prefix(8).lowercased(),
            "CFBundleExecutable": "TerminalDeckNative", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.8"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app.deletingLastPathComponent()))
        let data = root.appendingPathComponent("data")
        try BackendHOSTFiles.privateDirectory(data)
        let paths = try BackendHOSTPaths(dataDirectory: data, namespace: "agents")
        try paths.prepare()
        let environment = [NativeLaunchSwitches.dataFolder: data.path]
        let arguments = ["TerminalDeckNative", BackendHOSTService.launchArgument, "agents"]
        let version = try BackendHOSTLaunchAgent.buildVersion(marketing: "0.0.8" + BackendHOSTLaunchAgent.hostGeneration, helper: source)
        let copy = paths.directory.appendingPathComponent(version).appendingPathComponent("Terminal Deck")
        let request = paths.directory.appendingPathComponent(BackendHOSTService.launchRequestFile)
        func start(team: String? = nil) throws -> BackendHOSTService.Launch {
            try BackendHOSTFiles.atomicWrite(Data(version.utf8), to: request)    // names the build whose copy is there
            return BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: environment, signingTeam: team)
        }
        // The good copy (installed the way crash recovery does) starts.
        try BackendHOSTFiles.atomicWrite(Data("active".utf8), to: paths.activeFile)
        guard case .exec = BackendHOSTService.launch(arguments: arguments, bundle: bundle, environment: environment, signingTeam: nil) else { return XCTFail("good copy refused") }
        _ = unlink(paths.activeFile.path)
        guard case .exec = try start() else { return XCTFail("good copy refused by request") }

        // A Developer ID app pins its own team: an ad-hoc copy cannot meet it.
        let requirement = try XCTUnwrap(BackendHOSTService.keeperRequirement(team: "6U4VNX5W87", appIdentifier: "dev.terminaldeck.app"))
        XCTAssertTrue(requirement.contains("identifier \"dev.terminaldeck.app.session-host\"")); XCTAssertTrue(requirement.contains("6U4VNX5W87"))
        XCTAssertTrue(requirement.contains("1.2.840.113635.100.6.1.13")); XCTAssertTrue(requirement.contains("anchor apple generic"))
        var compiled: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &compiled), errSecSuccess)
        XCTAssertFalse(BackendHOSTService.keeperSignatureValid(copy, requirement: requirement))
        guard case .stay = try start(team: "6U4VNX5W87") else { return XCTFail("ad-hoc copy met a Developer ID team") }
        XCTAssertNil(BackendHOSTService.keeperRequirement(team: nil, appIdentifier: "dev.terminaldeck.app"))
        XCTAssertNil(BackendHOSTService.keeperRequirement(team: "not a team", appIdentifier: "dev.terminaldeck.app"))

        // A foreign identifier, a damaged copy and an unsigned copy are all refused.
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "com.example.other", copy.path]).code, 0)
        XCTAssertEqual(chmod(copy.path, 0o700), 0)
        guard case .stay = try start() else { return XCTFail("foreign identifier accepted") }
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "dev.terminaldeck.app.session-host", copy.path]).code, 0)
        XCTAssertEqual(chmod(copy.path, 0o700), 0)
        guard case .exec = try start() else { return XCTFail("re-signed good copy refused") }
        let handle = try FileHandle(forWritingTo: copy)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size / 2); try handle.write(contentsOf: Data(repeating: 0xA5, count: 64)); try handle.close()
        guard case .stay = try start() else { return XCTFail("damaged copy accepted") }
        XCTAssertEqual(try run("/usr/bin/codesign", ["--remove-signature", copy.path]).code, 0)
        XCTAssertEqual(chmod(copy.path, 0o700), 0)
        guard case .stay = try start() else { return XCTFail("unsigned copy accepted") }
    }
}
