import Foundation
import Darwin
import SQLite3
import WebKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class CookieMigrationCoverageTests: XCTestCase {
    func testMissingSourcesNeverAskForAStorageKeyOrOpenAProfileStore() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var keys = 0, stores = 0
        let migration = NativeBrowserCookieMigration(storagePassword: { _ in
            keys += 1; throw NativeRPCError(code: "test-denied", message: "No key should be requested")
        }, storeForProfile: { _ in stores += 1; return .nonPersistent() })
        let report = await migration.run(dataRoot: root)
        XCTAssertTrue(report.complete, report.summary)
        XCTAssertEqual(report.profiles.first?.state, .noSource)
        XCTAssertEqual(keys, 0)
        XCTAssertEqual(stores, 0)
    }

    func testAKeyDenialIsSharedAcrossProfilesSanitizedAndRetriedOnlyOnRequest() async throws {
        let root = try scratch(), profile = UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["profiles": [["id": profile]]]).write(to: root.appendingPathComponent("browser-profiles.json"))
        let row = "INSERT INTO cookies VALUES ('example.invalid','private-cookie-name','',X'76313000000000000000000000000000000000','/',0,0,0,0,-1);"
        let first = try database(root: root, profile: "default", rows: row)
        let second = try database(root: root, profile: profile, rows: row)
        let before = try [Data(contentsOf: first), Data(contentsOf: second)]
        var attempts = 0
        let migration = NativeBrowserCookieMigration(storagePassword: { _ in
            attempts += 1
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-key-error-detail"])
        }, storeForProfile: { _ in .nonPersistent() })
        let report = await migration.run(dataRoot: root)
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.profiles.count, 2)
        XCTAssertTrue(report.profiles.allSatisfy { $0.state == .incomplete })
        XCTAssertEqual(attempts, 1)
        let text = report.summary + report.profiles.flatMap(\.errors).joined()
        for privateText in ["private-key-error-detail", "private-cookie-name", root.path] {
            XCTAssertFalse(text.contains(privateText))
        }
        _ = await migration.run(dataRoot: root)
        XCTAssertEqual(attempts, 1)
        let retried = await migration.run(dataRoot: root, retry: true)
        XCTAssertFalse(retried.complete)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try Data(contentsOf: first), before[0])
        XCTAssertEqual(try Data(contentsOf: second), before[1])
    }

    func testImportKeepsExistingCookiesAndTheCompletionMarkerPreventsASecondImport() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try database(root: root, profile: "default", rows: """
            INSERT INTO cookies VALUES ('example.invalid','kept','legacy',X'','/',0,0,0,0,1);
            INSERT INTO cookies VALUES ('example.invalid','new','migrated',X'','/',0,0,0,0,1);
            """)
        let before = try Data(contentsOf: source)
        let store = WKWebsiteDataStore.nonPersistent()
        let existing = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.invalid", .path: "/", .name: "kept", .value: "current", .discard: "TRUE"]))
        await withCheckedContinuation { continuation in store.httpCookieStore.setCookie(existing) { continuation.resume() } }
        var keys = 0, stores = 0
        let migration = NativeBrowserCookieMigration(storagePassword: { _ in
            keys += 1; throw NativeRPCError(code: "test-denied", message: "Clear cookies need no key")
        }, storeForProfile: { _ in stores += 1; return store })
        let report = await migration.run(dataRoot: root)
        XCTAssertTrue(report.complete, report.summary)
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.profiles.first?.keptExisting, 1)
        let saved: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(saved.first { $0.name == "kept" }?.value, "current")
        XCTAssertEqual(saved.first { $0.name == "new" }?.value, "migrated")
        if !report.complete, let cookie = saved.first(where: { $0.name == "new" }) {
            print("Fixture cookie traits: domain=\(cookie.domain), session=\(cookie.isSessionOnly), sameSite=\(cookie.sameSitePolicy?.rawValue ?? "nil"), secure=\(cookie.isSecure), httpOnly=\(cookie.isHTTPOnly), expiry=\(String(describing: cookie.expiresDate))")
        }
        _ = await migration.run(dataRoot: root)
        let retried = await migration.run(dataRoot: root, retry: true)
        XCTAssertEqual(retried.profiles.first?.state, .alreadyCompleted)
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(keys, 0)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    private func scratch() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw NativeRPCError(code: "fixture", message: "The scratch directory could not be resolved")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path)).appendingPathComponent("native-cookie-test-" + UUID().uuidString)
    }
    private func database(root: URL, profile: String, rows: String) throws -> URL {
        let partition = profile == "default" ? "terminaldeck-browser" : "terminaldeck-browser-" + profile
        let folder = root.appendingPathComponent("Partitions").appendingPathComponent(partition)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Cookies")
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else {
            throw NativeRPCError(code: "fixture", message: "Could not make the test cookie database")
        }
        defer { sqlite3_close(handle) }
        let sql = """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO meta VALUES ('version', '23'), ('last_compatible_version', '23');
            CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
                expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, is_persistent INTEGER, samesite INTEGER);
            \(rows)
            """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NativeRPCError(code: "fixture", message: "Could not fill the test cookie database")
        }
        return file
    }
}
