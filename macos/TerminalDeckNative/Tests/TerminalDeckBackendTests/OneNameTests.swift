import Foundation
import XCTest
@testable import TerminalDeckBackend

/// One name (9 Nov, Asad: "everything on one name … so i can allow only one time not seprate for each").
/// The keepers are Terminal Deck.app's own background items: the shipped plists start the app's own program, carry no
/// user path or version (one item for every update), and the copied keeper itself is named "Terminal Deck".
final class OneNameTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func scratch() throws -> URL {
        let path = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("one-name-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    func testShippedKeeperItemsAreTheAppsOwnAndVersionFree() throws {
        for namespace: String? in [nil, "agents"] {
            let file = repo.appendingPathComponent("macos/TerminalDeckNative/Support/SessionHostAgents/" + BackendHOSTService.plistName(namespace: namespace))
            let shipped = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? NSDictionary)
            XCTAssertEqual(shipped, BackendHOSTService.properties(namespace: namespace) as NSDictionary, file.lastPathComponent)
            XCTAssertEqual(shipped["Label"] as? String, BackendHOSTLaunchAgent.productionLabel + (namespace.map { "." + $0 } ?? ""))
            XCTAssertEqual(shipped["BundleProgram"] as? String, "Contents/MacOS/TerminalDeckNative")
            XCTAssertNil(shipped["Program"]); XCTAssertNil(shipped["EnvironmentVariables"])
            XCTAssertEqual(shipped["AssociatedBundleIdentifiers"] as? [String], ["dev.terminaldeck.app"])
            XCTAssertEqual((shipped["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("/Users/")); XCTAssertFalse(text.contains("host3")); XCTAssertFalse(text.contains("Helper"))
        }
        let build = try String(contentsOf: repo.appendingPathComponent("macos/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("Support/SessionHostAgents")); XCTAssertTrue(build.contains("td_install_keeper_items"))
        XCTAssertTrue(build.contains(#"EXE="TerminalDeckNative""#))
    }

    func testKeeperCopyIsNamedTerminalDeckAndOlderFoldersStillResolve() throws {
        let root = try scratch()
        let plan = try BackendHOSTLaunchAgent(paths: BackendHOSTPaths(dataDirectory: root), version: "v1", launchAgentsDirectory: root)
        XCTAssertEqual(plan.helper.lastPathComponent, "Terminal Deck")
        let old = root.appendingPathComponent("old"), both = root.appendingPathComponent("both")
        for folder in [old, both] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        XCTAssertTrue(FileManager.default.createFile(atPath: old.appendingPathComponent("TerminalDeckNativeHelper").path, contents: Data()))
        XCTAssertEqual(BackendHOSTLaunchAgent.keeperExecutable(in: old).lastPathComponent, "TerminalDeckNativeHelper")
        for name in ["TerminalDeckNativeHelper", "Terminal Deck"] { XCTAssertTrue(FileManager.default.createFile(atPath: both.appendingPathComponent(name).path, contents: Data())) }
        XCTAssertEqual(BackendHOSTLaunchAgent.keeperExecutable(in: both).lastPathComponent, "Terminal Deck")
        XCTAssertEqual(BackendHOSTLaunchAgent.keeperExecutable(in: root.appendingPathComponent("new")).lastPathComponent, "Terminal Deck")
    }

    func testPruneRemovesOldBuildsOfEitherNameOnly() throws {
        let host = try scratch()
        func folder(_ name: String, files: [String]) throws {
            let directory = host.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in files { XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent(file).path, contents: Data("x".utf8))) }
        }
        try folder("0.21.3-host3-aaaaaaaaaaaa", files: ["TerminalDeckNativeHelper"])   // older name: removed
        try folder("0.21.4-host3-bbbbbbbbbbbb", files: ["Terminal Deck"])              // older build, new name: removed
        try folder("0.21.4-host3-cccccccccccc", files: ["Terminal Deck"])              // the current build: kept
        try folder("odd", files: ["Terminal Deck", "notes.txt"])                        // anything else inside: kept
        try folder("agents/0.21.3-host3-aaaaaaaaaaaa", files: ["TerminalDeckNativeHelper"]) // another namespace: kept
        let removed = BackendHOSTLaunchAgent.pruneOtherHelpers(in: host, keeping: "0.21.4-host3-cccccccccccc").sorted()
        XCTAssertEqual(removed, ["0.21.3-host3-aaaaaaaaaaaa", "0.21.4-host3-bbbbbbbbbbbb"])
        for kept in ["0.21.4-host3-cccccccccccc/Terminal Deck", "odd/notes.txt", "agents/0.21.3-host3-aaaaaaaaaaaa/TerminalDeckNativeHelper"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: host.appendingPathComponent(kept).path), kept)
        }
    }

    func testReleaseHandOverServesOnlyTheRealDataFolder() throws {
        // A bundle with the release identifier always serves the real folder and ignores any data-folder override; with
        // nothing requested and no sessions active it stops (planning only: nothing is created or started there).
        let root = try scratch()
        let contents = root.appendingPathComponent("Release.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/TerminalDeckNative"))
        let info: [String: Any] = ["CFBundleIdentifier": BackendHOSTService.releaseBundleIdentifier, "CFBundleExecutable": "TerminalDeckNative", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        XCTAssertEqual(bundle.bundleIdentifier, BackendHOSTService.releaseBundleIdentifier)
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminaldeck/host/launch-requested")
        try XCTSkipIf(FileManager.default.fileExists(atPath: real.path), "a real start request is pending; never consume it from a test")
        let activeReal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminaldeck/host/sessions-active")
        try XCTSkipIf(FileManager.default.fileExists(atPath: activeReal.path), "real sessions are active; never plan a start there from a test")
        guard case .stay = BackendHOSTService.launch(arguments: ["TerminalDeckNative", BackendHOSTService.launchArgument], bundle: bundle,
                                                     environment: ["TD_NATIVE_DATA_DIR": root.path], signingTeam: nil) else { return XCTFail("release hand-over started without a request") }
        guard case .stay = BackendHOSTService.launch(arguments: ["TerminalDeckNative", BackendHOSTService.launchArgument, "--data-folder", root.path],
                                                     bundle: bundle, environment: [:], signingTeam: nil) else { return XCTFail("release hand-over accepted another data folder") }
    }

    func testAppItemIsToldApartFromAnOlderLaunchFile() {
        // launchctl print, macOS 27.3: an SMAppService item shows managed_by and no program line; an old file shows both.
        XCTAssertTrue(BackendHOSTLaunchAgent.isAppItem((program: nil, arguments: nil, managedBy: "com.apple.xpc.ServiceManagement")))
        XCTAssertTrue(BackendHOSTLaunchAgent.isAppItem((program: nil, arguments: ["TerminalDeckNative", "--session-host-launch", "agents"], managedBy: nil)))
        XCTAssertFalse(BackendHOSTLaunchAgent.isAppItem((program: "/Users/x/Library/Application Support/terminaldeck/host/agents/0.21.3-host3-aa/TerminalDeckNativeHelper",
            arguments: ["/Users/x/Library/Application Support/terminaldeck/host/agents/0.21.3-host3-aa/TerminalDeckNativeHelper", "--session-host", "/d", "v", "agents"], managedBy: nil)))
        XCTAssertFalse(BackendHOSTLaunchAgent.isAppItem((program: nil, arguments: nil, managedBy: nil)))
    }

    /// review-one-name-0609 #1: after the owner lock is released, the request is written BEFORE the item registers
    /// (registering runs the app program at once, and that run must find the request), then kickstart; a job already
    /// running from that load-time run is accepted, a label launchd does not hold is an honest failure.
    func testServiceStartWritesTheRequestBeforeRegisteringThenKickstarts() async throws {
        let root = try scratch(), request = root.appendingPathComponent("launch-requested"), log = OneNameOrder()
        try await BackendHOSTLaunchAgent.startServiceItem(.init(
            writeRequest: { try Data("v1".utf8).write(to: request); log.add("request") },
            register: { log.add(FileManager.default.fileExists(atPath: request.path) ? "register after request" : "register before request") },
            kickstart: { log.add("kickstart"); return 37 },
            loaded: { log.add("loaded"); return true }))
        XCTAssertEqual(log.items, ["request", "register after request", "kickstart", "loaded"])
        let quiet = OneNameOrder()
        try await BackendHOSTLaunchAgent.startServiceItem(.init(writeRequest: { quiet.add("request") }, register: { quiet.add("register") },
            kickstart: { quiet.add("kickstart"); return 0 }, loaded: { quiet.add("loaded"); return true }))
        XCTAssertEqual(quiet.items, ["request", "register", "kickstart"])
        do {
            try await BackendHOSTLaunchAgent.startServiceItem(.init(writeRequest: {}, register: {}, kickstart: { 113 }, loaded: { false }))
            XCTFail("a label launchd does not hold must fail")
        } catch {}
        let failing = OneNameOrder()
        do {
            try await BackendHOSTLaunchAgent.startServiceItem(.init(writeRequest: { failing.add("request") },
                register: { throw BackendHOSTFailure.remote("switched off") }, kickstart: { failing.add("kickstart"); return 0 }, loaded: { true }))
            XCTFail("a refused registration must fail")
        } catch {}
        XCTAssertEqual(failing.items, ["request"], "no kickstart after a refused registration")
    }

    /// review-one-name-0609 #3: packaging gives a test copy's items labels of its own; the release keeps the real ones.
    func testPackagingGivesTestCopiesTheirOwnItemLabels() throws {
        for (bundle, expected) in [("dev.terminaldeck.app", ["dev.terminaldeck.session-host", "dev.terminaldeck.session-host.agents"]),
                                   ("dev.terminaldeck.review.unique", ["dev.terminaldeck.review.unique.session-host", "dev.terminaldeck.review.unique.session-host.agents"])] {
            let root = try scratch(), app = root.appendingPathComponent("Copy.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "source \"$1\"; td_install_keeper_items \"$2\" \"$3\" \"$4\"", "keeper-items",
                repo.appendingPathComponent("scripts/mac-keeper-items.sh").path,
                repo.appendingPathComponent("macos/TerminalDeckNative/Support/SessionHostAgents").path, app.path, bundle]
            process.standardOutput = pipe; process.standardError = pipe
            try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
            var labels: [String] = []
            for file in try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Contents/Library/LaunchAgents"), includingPropertiesForKeys: nil) {
                let item = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
                labels.append(try XCTUnwrap(item["Label"] as? String))
                XCTAssertEqual(item["AssociatedBundleIdentifiers"] as? [String], [bundle])
                XCTAssertEqual(item["BundleProgram"] as? String, "Contents/MacOS/TerminalDeckNative")
            }
            XCTAssertEqual(labels.sorted(), expected, bundle)
        }
        let build = try String(contentsOf: repo.appendingPathComponent("macos/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("td_install_keeper_items"))
    }

    func testPrivacyGuideNamesOnlyTerminalDeckForSessions() {
        XCTAssertTrue(BackendPrivacyIdentity.explanation.contains("share one entry"))
        XCTAssertFalse(BackendPrivacyIdentity.cleanupSteps.joined().contains("report the problem"))
    }
}

private final class OneNameOrder: @unchecked Sendable {
    private let lock = NSLock(); private var list: [String] = []
    func add(_ item: String) { lock.withLock { list.append(item) } }
    var items: [String] { lock.withLock { list } }
}
