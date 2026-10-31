// QUIT (9 Oct 2026): leftover update copies (27 ShipIt staging folders of 248 MB) are swept at launch,
// only the updater's own folders, never while ShipIt runs.
import Foundation
import XCTest
import TerminalDeckNativeCore

final class QUITUpdateSweepTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdq-sweep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func folder(_ url: URL, file: String = "payload") throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent(file))
    }
    private func names(_ url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }

    func testShipItStagingOnlyOwnFoldersAndNeverWhileShipItRuns() throws {
        let tmp = try scratch()
        for name in ["dev.terminaldeck.app.ShipIt.AbC123", "dev.terminaldeck.app.ShipIt.zz9", "com.other.app.ShipIt.AbC123", "dev.terminaldeck.app.ShipIt", "unrelated"] {
            try folder(tmp.appendingPathComponent(name))
        }
        try Data("f".utf8).write(to: tmp.appendingPathComponent("dev.terminaldeck.app.ShipIt.file"))
        XCTAssertEqual(NativeUpdateSweep.shipItStaging(tmp: tmp, bundleIdentifier: "dev.terminaldeck.app", shipItRunning: true), [])
        XCTAssertEqual(try names(tmp).count, 6)
        XCTAssertEqual(NativeUpdateSweep.shipItStaging(tmp: tmp, bundleIdentifier: "dev.terminaldeck.app", shipItRunning: false),
                       ["dev.terminaldeck.app.ShipIt.AbC123", "dev.terminaldeck.app.ShipIt.zz9"])
        XCTAssertEqual(try names(tmp), ["com.other.app.ShipIt.AbC123", "dev.terminaldeck.app.ShipIt", "dev.terminaldeck.app.ShipIt.file", "unrelated"])
    }

    func testNativeStagingKeepsTheNewerPendingUpdateOnly() throws {
        let root = try scratch(), pending = UUID().uuidString, old = UUID().uuidString, older = UUID().uuidString
        for name in [pending, old, older, "not-a-download"] { try folder(root.appendingPathComponent(name)) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("pending.json"))
        XCTAssertEqual(Set(NativeUpdateSweep.nativeStaging(updatesRoot: root, keep: root.appendingPathComponent(pending))), Set([old, older]))
        XCTAssertEqual(try names(root), [pending, "not-a-download", "pending.json"].sorted())
        // Nothing newer pending (already installed, or unreadable): every download and the record go.
        XCTAssertEqual(Set(NativeUpdateSweep.nativeStaging(updatesRoot: root, keep: nil)), Set([pending, "pending.json"]))
        XCTAssertEqual(try names(root), ["not-a-download"])
    }

    func testInstallWorkFoldersNextToTheAppGo() throws {
        let parent = try scratch()
        for name in [".td-native-update.a1b2c3", ".td-native-update.zzz", "Terminal Deck.app", ".other"] { try folder(parent.appendingPathComponent(name)) }
        XCTAssertEqual(NativeUpdateSweep.installWork(appParent: parent), [".td-native-update.a1b2c3", ".td-native-update.zzz"])
        XCTAssertEqual(try names(parent), [".other", "Terminal Deck.app"])
    }
}
