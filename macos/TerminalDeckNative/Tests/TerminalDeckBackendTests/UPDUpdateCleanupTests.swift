import Foundation
import CryptoKit
import Darwin
import XCTest
import TerminalDeckNativeCore

/// Scratch files only. The installer moves inert signed bundles; it never runs them.
final class UPDUpdateCleanupTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_WIP"]?.contains("UPD") == true else {
            throw XCTSkip("WIP UPD: awaiting protected updater changes and focused gate")
        }
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("UPD-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func folder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("owned fixture".utf8).write(to: url.appendingPathComponent("payload"))
    }

    func testTwentySevenOwnShipItCopiesOnly() throws {
        let root = try scratch()
        let own = (0..<27).map { "dev.terminaldeck.app.ShipIt.UPD\($0)" }
        let foreign = ["com.other.app.ShipIt.UPD0", "dev.terminaldeck.app.ShipIt", "unrelated.app"]
        for name in own + foreign { try folder(root.appendingPathComponent(name)) }
        XCTAssertTrue(NativeUpdateSweep.shipItStaging(tmp: root, bundleIdentifier: "dev.terminaldeck.app", shipItRunning: true).isEmpty)
        XCTAssertEqual(Set(NativeUpdateSweep.shipItStaging(tmp: root, bundleIdentifier: "dev.terminaldeck.app", shipItRunning: false)), Set(own))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(foreign))
    }

    func testShipItLinkDoesNotDeleteAnotherApp() throws {
        let root = try scratch(), foreign = root.appendingPathComponent("foreign")
        try folder(foreign)
        let link = root.appendingPathComponent("dev.terminaldeck.app.ShipIt.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        XCTAssertTrue(NativeUpdateSweep.shipItStaging(tmp: root, bundleIdentifier: "dev.terminaldeck.app", shipItRunning: false).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("payload").path))
    }

    func testSymlinkedSweepRootIsRefused() throws {
        let root = try scratch(), foreign = root.appendingPathComponent("foreign")
        try folder(foreign.appendingPathComponent("dev.terminaldeck.app.ShipIt.foreign"))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        XCTAssertTrue(NativeUpdateSweep.shipItStaging(tmp: link, bundleIdentifier: "dev.terminaldeck.app", shipItRunning: false).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("dev.terminaldeck.app.ShipIt.foreign/payload").path))
    }

    private struct Fixture {
        let root: URL, current: URL, stage: URL, stagedApp: URL, archive: URL, pending: URL
        let arguments: [String]
    }

    private func command(_ path: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func app(_ path: URL, version: String, signed: Bool) throws {
        let contents = path.appendingPathComponent("Contents"), binary = contents.appendingPathComponent("MacOS/UPDFixture")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "dev.terminaldeck.app", "CFBundleShortVersionString": version,
                    "CFBundleVersion": version, "CFBundleExecutable": "UPDFixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        if signed {
            let result = try command("/usr/bin/codesign", ["--force", "--sign", "-", path.path])
            XCTAssertEqual(result.0, 0, result.1)
        }
    }

    private func fixture(parent: Int32, signed: Bool = false, validHash: Bool = false) throws -> Fixture {
        let root = try scratch(), updates = root.appendingPathComponent("native-updates")
        let stage = updates.appendingPathComponent(UUID().uuidString), current = root.appendingPathComponent("Current.app")
        let stagedApp = stage.appendingPathComponent("unpacked/Next.app"), archive = stage.appendingPathComponent("update.zip")
        try app(current, version: "1.0.0", signed: signed)
        try app(stagedApp, version: "1.0.1", signed: signed)
        let bytes = Data("UPD archive fixture".utf8)
        try bytes.write(to: archive)
        // The product will write this identity before downloading any bytes.
        try Data("dev.terminaldeck.app\n".utf8).write(to: stage.appendingPathComponent(".terminaldeck-update-stage"))
        let pending = updates.appendingPathComponent("pending.json")
        try JSONSerialization.data(withJSONObject: ["directory": stage.absoluteString, "release": ["version": "1.0.1"]]).write(to: pending)
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/native-standalone/install-update.sh")
        let hash = validHash ? Data(SHA512.hash(data: bytes)).base64EncodedString() : "wrong hash"
        return Fixture(root: root, current: current, stage: stage, stagedApp: stagedApp, archive: archive, pending: pending,
            arguments: [helper.path, "--current", current.path, "--staged", stagedApp.path, "--archive", archive.path,
                        "--sha512", hash, "--size", String(bytes.count), "--version", "1.0.1",
                        "--bundle-id", "dev.terminaldeck.app", "--executable", "UPDFixture", "--parent-pid", String(parent),
                        "--team", "", "--ready", stage.appendingPathComponent("helper-ready").path, "--relaunch", "0"])
    }

    func testEarlyInstallerFailureDropsItsOwnLargeCopies() throws {
        let f = try fixture(parent: getpid())
        let result = try command("/bin/bash", f.arguments)
        XCTAssertNotEqual(result.0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.archive.path), result.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.stage.appendingPathComponent("unpacked").path), result.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.current.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
    }

    func testEarlyFailureNeverDeletesANewerPendingRecord() throws {
        let f = try fixture(parent: getpid()), another = f.stage.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let bytes = try JSONSerialization.data(withJSONObject: ["directory": another.absoluteString, "release": ["version": "1.0.1"]])
        try bytes.write(to: f.pending)
        let result = try command("/bin/bash", f.arguments)
        XCTAssertNotEqual(result.0, 0)
        XCTAssertEqual(try Data(contentsOf: f.pending), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.archive.path), result.1)
    }

    func testUnmarkedInstallerInputIsNeverDeleted() throws {
        let f = try fixture(parent: getpid())
        try FileManager.default.removeItem(at: f.stage.appendingPathComponent(".terminaldeck-update-stage"))
        let result = try command("/bin/bash", f.arguments)
        XCTAssertNotEqual(result.0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.stagedApp.path))
    }

    func testSuccessfulHelperClearsStagingWithoutLaunchingAnApp() throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["20"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() } }
        let f = try fixture(parent: parent.processIdentifier, signed: true, validHash: true)
        let helper = Process(), output = Pipe()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash"); helper.arguments = f.arguments
        helper.standardOutput = output; helper.standardError = output
        try helper.run()
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        let ready = f.stage.appendingPathComponent("helper-ready"), deadline = Date().addingTimeInterval(5)
        while helper.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { usleep(25_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Helper must acknowledge the scratch sleeper")
        parent.terminate(); parent.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0, text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.stagedApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: f.current.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: String]
        XCTAssertEqual(info?["CFBundleShortVersionString"], "1.0.1")
    }
}
