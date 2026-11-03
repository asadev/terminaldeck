import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// DEV-KEYCHAIN (11 Oct): the dev copy kept asking Asad for his password for the REAL app's keychain item
/// "Terminal Deck Receiver Key". The dev configuration must never yield a real-app item name, and the dev copy
/// keeps its keys in its own data folder so a rebuild never prompts. The real app's names do not change.
final class DevCopyKeychainTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("td-dev-keychain-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        BackendAccountDevKey.reset()
    }
    override func tearDownWithError() throws {
        BackendAccountDevKey.reset()
        try? FileManager.default.removeItem(at: scratch)
    }

    private let realNames = ["Terminal Deck Safe Storage", "Terminal Deck Receiver Key", "Terminal Deck Connected Tasks"]

    func testTheDevConfigurationNeverYieldsTheRealAppsItemNames() throws {
        let dev = scratch.appendingPathComponent("Terminal Deck Dev", isDirectory: true)
        let configuration = try BackendCompositionSuppliers.configuration(dataRoot: dev, home: scratch, environment: [:],
                                                                          helper: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertEqual(configuration.appName, "Terminal Deck Dev")
        let services = BackendDevCopy.keychainServices(appName: configuration.appName)
        XCTAssertEqual(services, ["Terminal Deck Dev Safe Storage", "Terminal Deck Dev Receiver Key", "Terminal Deck Dev Connected Tasks"])
        XCTAssertTrue(Set(services).isDisjoint(with: realNames))
        XCTAssertNil(BackendDevCopy.originalSafeStorageName(dataDirectory: dev))
        // The dev bundle with its data folder moved elsewhere (TD_DEVLOOP_DATA) is still the dev copy.
        let moved = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        XCTAssertEqual(BackendDevCopy.appName(dataDirectory: moved, bundleID: BackendDevCopy.bundleID), "Terminal Deck Dev")
        XCTAssertNil(BackendDevCopy.originalSafeStorageName(dataDirectory: moved, bundleID: BackendDevCopy.bundleID))
        XCTAssertTrue(Set(BackendDevCopy.keychainServices(appName: BackendDevCopy.appName(dataDirectory: moved, bundleID: BackendDevCopy.bundleID))).isDisjoint(with: realNames))
    }

    func testTheRealAppKeepsItsNames() throws {
        let primary = BackendCompositionSuppliers.primaryDataDirectory(home: scratch)
        XCTAssertEqual(BackendDevCopy.appName(dataDirectory: primary, bundleID: "dev.terminaldeck.app"), "Terminal Deck")
        XCTAssertEqual(BackendDevCopy.keychainServices(appName: "Terminal Deck"), realNames)
        XCTAssertEqual(BackendDevCopy.originalSafeStorageName(dataDirectory: primary, bundleID: "dev.terminaldeck.app"), "Terminal Deck")
        let configuration = try BackendCompositionSuppliers.configuration(dataRoot: primary, home: scratch, environment: [:],
                                                                          helper: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertEqual(configuration.appName, "Terminal Deck")
        XCTAssertNil(BackendAccountDevKey.folderURL(), "the real app never adopts a dev key folder")
    }

    /// The dev copy's Receiver key and connected-task tokens live in owner-only files in its own data folder:
    /// nothing reaches the keychain, so a rebuilt dev copy has nothing to prompt about.
    func testTheDevCopyKeepsItsKeysInItsOwnFolder() throws {
        let dev = scratch.appendingPathComponent("Terminal Deck Dev", isDirectory: true)
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        let configuration = try BackendCompositionSuppliers.configuration(dataRoot: dev, home: scratch, environment: [:],
                                                                          helper: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertEqual(BackendAccountDevKey.folderURL()?.standardizedFileURL, dev.standardizedFileURL)

        let receiver = BackendRCVKeychainCipher(appName: configuration.appName)
        let sealed = try receiver.encrypt("hello", existingVault: false)
        XCTAssertEqual(try receiver.decrypt(sealed), "hello")
        let keyFile = dev.appendingPathComponent("receiver.key")
        XCTAssertEqual(try Data(contentsOf: keyFile).count, 32)
        let mode = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        // A second cipher (a rebuilt dev copy) opens the same data with the same file key.
        XCTAssertEqual(try BackendRCVKeychainCipher(appName: configuration.appName).decrypt(sealed), "hello")

        let tokens = BackendConnectedTasksKeychain(appName: configuration.appName)
        XCTAssertNil(try tokens.read("linear-1"))
        try tokens.write("linear-1", token: "tok-1")
        try tokens.write("linear-1", token: "tok-2")
        XCTAssertEqual(try tokens.read("linear-1"), "tok-2")
        let folder = dev.appendingPathComponent("connected-tasks")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        let tokenMode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(files[0]).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(tokenMode?.intValue, 0o600)
        try tokens.remove("linear-1")
        try tokens.remove("linear-1")
        XCTAssertNil(try tokens.read("linear-1"))
    }

    /// Receiver data the dev copy saved with the real app's key cannot be opened any more: it is set aside once.
    func testOldDevReceiverDataIsSetAsideOnce() throws {
        let dev = scratch.appendingPathComponent("Terminal Deck Dev", isDirectory: true)
        let folder = dev.appendingPathComponent("receiver", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("receiver.json"))
        _ = try BackendCompositionSuppliers.configuration(dataRoot: dev, home: scratch, environment: [:], helper: URL(fileURLWithPath: "/usr/bin/true"))
        BackendRCVKeychainCipher.setAsideDevRecordWithoutKey(folder: folder, fileName: "receiver.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("receiver.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("receiver.json.before-dev-key").path))
        // Once the dev key exists, its own record is left alone.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("receiver.json"))
        _ = try BackendRCVKeychainCipher(appName: "Terminal Deck Dev").encrypt("x", existingVault: false)
        BackendRCVKeychainCipher.setAsideDevRecordWithoutKey(folder: folder, fileName: "receiver.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("receiver.json").path))
    }
}
