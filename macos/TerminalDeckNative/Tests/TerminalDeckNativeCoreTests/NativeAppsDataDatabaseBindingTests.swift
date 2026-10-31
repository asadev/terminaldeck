import XCTest
@testable import TerminalDeckNativeCore

final class NativeAppsDataDatabaseBindingTests: XCTestCase {
    func testOnlyExistingOrdinaryAppsAreEligible() {
        let apps = [app("first"), app("database", kind: "postgres"), app("second"), app("unsafe\n")]
        XCTAssertEqual(NativeAppsDataDatabaseBindingDraft.eligibleApps(apps, databaseID: "first").map(\.id), ["second"])
        var draft = NativeAppsDataDatabaseBindingDraft(kind: "postgres", targetAppID: "missing")
        XCTAssertNotNil(draft.validationMessage(apps: apps, databaseID: "database"))
        draft.targetAppID = "database"
        XCTAssertNotNil(draft.validationMessage(apps: apps, databaseID: "database"))
    }

    func testRedisDefaultAndStrictSettingName() {
        var draft = NativeAppsDataDatabaseBindingDraft(kind: "redis", targetAppID: "web")
        XCTAssertEqual(draft.key, "REDIS_URL")
        XCTAssertNil(draft.validationMessage(apps: [app("web")], databaseID: "cache"))
        for key in ["DATABASE_URL\n", "9INVALID", "URL=secret", String(repeating: "A", count: 129)] {
            draft.key = key
            XCTAssertNotNil(draft.validationMessage(apps: [app("web")], databaseID: "cache"))
        }
        XCTAssertEqual(NativeAppsDataDatabaseBindingDraft(kind: "postgres").key, "DATABASE_URL")
    }

    func testAcknowledgementMustBeMaskedAndMatchRequestedDestination() throws {
        let valid = NativeRPCValue.object([
            .init("bound", .bool(true)), .init("appId", .string("database")), .init("targetAppId", .string("web")),
            .init("key", .string("DATABASE_URL")), .init("value", .string("••••••••")),
            .init("secret", .bool(true)), .init("requiresDeploy", .bool(true))
        ])
        XCTAssertNoThrow(try NativeAppsDataDatabaseBindingDraft.verifyReceipt(valid, databaseID: "database", targetAppID: "web", key: "DATABASE_URL"))
        for unsafe in [valid.setting("value", .string("postgres://user:password@host")),
                       valid.setting("targetAppId", .string("another-app")),
                       valid.setting("key", .string("OTHER_URL")), valid.setting("requiresDeploy", .bool(false)),
                       valid.setting("uri", .string("postgres://user:password@host"))] {
            XCTAssertThrowsError(try NativeAppsDataDatabaseBindingDraft.verifyReceipt(unsafe, databaseID: "database", targetAppID: "web", key: "DATABASE_URL"))
        }
    }

    private func app(_ id: String, kind: String = "app") -> NativeAppsSummary {
        NativeAppsSummary(id: id, name: id, kind: kind, status: "running")
    }
}
