import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Accounts18VaultMigrationTests: XCTestCase {
    func testElectronUpgradeBacksUpTheStoreFileThenUsesNativeKeyWithoutLosingSlots() throws {
        // Short: a Unix socket path must fit in 104 bytes.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("a18-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("data/account-vault"), file = dir.appendingPathComponent("account-vault.bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = Data("fixture-electron-key".utf8), native = Data("fixture-native-key".utf8)
        let plain = #"{"version":1,"entries":[{"accountId":"work","provider":"claude","slots":{"keychain:Claude Code-credentials":{"value":"fixture-login","source":"adopted","updatedAt":1}}}]}"#
        let before = Data(try ChromiumSafeStorageCipher.encrypt(plain, password: old).base64EncodedString().utf8)
        try before.write(to: file)
        try Data("seat working file".utf8).write(to: dir.appendingPathComponent("metadata"))
        // The session helper's live socket sits in the same folder while sessions run; it cannot be copied.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let socketPath = dir.appendingPathComponent("vault.sock").path
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8.prefix($0.count - 1)) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound, 0)
        let backup = try XCTUnwrap(BackendAccountVaultMigration.migrate(file: file, legacyPassword: old, nativePassword: native, backupRoot: root.appendingPathComponent("backups")))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("account-vault.bin")), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backup.path), ["account-vault.bin"], "only the store file is copied")
        XCTAssertEqual(try BackendAccountVaultMigration.validatedPlain(Data(contentsOf: file), password: native), plain)
        XCTAssertThrowsError(try BackendAccountVaultMigration.validatedPlain(Data(contentsOf: file), password: old))
        XCTAssertNil(try BackendAccountVaultMigration.migrate(file: file, legacyPassword: old, nativePassword: native, backupRoot: root.appendingPathComponent("backups")))
    }
    func testDeniedOrWrongOriginalNeverOverwritesOrCreatesBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("accounts18-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("account-vault"), file = dir.appendingPathComponent("account-vault.bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let before = Data(try ChromiumSafeStorageCipher.encrypt(#"{"version":1,"entries":[]}"#, password: Data("original".utf8)).base64EncodedString().utf8)
        try before.write(to: file)
        XCTAssertThrowsError(try BackendAccountVaultMigration.migrate(file: file, legacyPassword: Data("wrong".utf8), nativePassword: Data("native".utf8), backupRoot: root.appendingPathComponent("backups")))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }
    func testLoginStoreBackupGoesInTheAppsOwnDataFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("accounts18-" + UUID().uuidString)
        let config = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "Terminal Deck", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/bin/true"), inheritedEnvironment: [:])
        XCTAssertEqual(BackendAccountVaultRecovery(configuration: config).backupRoot.path, root.appendingPathComponent("data/account-backups").path)
    }
    func testNewerVaultFormatNeverReencryptedAsVersionOne() throws {
        let key = Data("fixture".utf8)
        let encoded = Data(try ChromiumSafeStorageCipher.encrypt(#"{"version":2,"entries":[]}"#, password: key).base64EncodedString().utf8)
        XCTAssertThrowsError(try BackendAccountVaultMigration.validatedPlain(encoded, password: key))
    }
    func testFreshDevCopyUsesOnlyItsOwnKeyFileAndReopens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("accounts18-" + UUID().uuidString)
        defer { BackendAccountDevKey.reset(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = try BackendAccountConfiguration(dataDirectory: root, homeDirectory: root, appName: BackendDevCopy.name,
            appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/bin/true"), inheritedEnvironment: [:])
        let recovery = BackendAccountVaultRecovery(configuration: config)
        XCTAssertEqual(try recovery.prepareIfFreshOrMigratable()["ready"].bool, true)
        XCTAssertEqual(try recovery.status()["needsPermission"].bool, false)
        let cipher = BackendAccountKeychainCipher(appName: BackendDevCopy.name)
        let blob = try cipher.encrypt("fixture-login", existingVault: false)
        XCTAssertEqual(try cipher.decrypt(blob), "fixture-login")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("store.key").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
