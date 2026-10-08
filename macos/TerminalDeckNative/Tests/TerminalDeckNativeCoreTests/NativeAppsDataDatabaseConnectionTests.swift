import XCTest
@testable import TerminalDeckNativeCore

final class NativeAppsDataDatabaseConnectionTests: XCTestCase {
    func testMongoProjectionIncludesPrivateAddressAndAdminAuthentication() throws {
        let connection = try NativeAppsDataDatabaseConnection.read(mongo())
        XCTAssertEqual(connection.address, "terminaldeck-demo:27017")
        XCTAssertEqual(connection.database, "terminaldeck")
        XCTAssertEqual(connection.authenticationDatabase, "admin")
        XCTAssertEqual(connection.passwordKey, "MONGO_INITDB_ROOT_PASSWORD")
        XCTAssertFalse(connection.address.contains("@"))
        XCTAssertFalse(connection.address.contains("••••••••"))
    }

    func testCredentialBearingOrPublicConnectionIsRefused() {
        for unsafe in [mongo().setting("password", .string("actual-password")),
                       mongo().setting("scope", .string("public")),
                       mongo().setting("uri", .string("mongodb://user:password@host")),
                       mongo().setting("host", .string("user:password@host")),
                       mongo().setting("host", .string("terminaldeck-demo\n"))] {
            XCTAssertThrowsError(try NativeAppsDataDatabaseConnection.read(unsafe))
        }
    }

    func testUnexpectedDatabasePortOrAuthenticationIsRefused() {
        for unsafe in [mongo().setting("port", .number(443)),
                       mongo().setting("port", .number(27017.5)),
                       mongo().setting("authenticationDatabase", .string("elsewhere")),
                       mongo().setting("passwordKey", .string("ARBITRARY_SECRET")),
                       mongo().setting("username", .string("different-user"))] {
            XCTAssertThrowsError(try NativeAppsDataDatabaseConnection.read(unsafe))
        }
    }

    func testRedisProjectionHasNoDatabaseOrAuthenticationName() throws {
        let value = mongo().setting("kind", .string("redis")).setting("port", .number(6379))
            .setting("username", .string("default")).setting("passwordKey", .string("REDIS_PASSWORD"))
            .setting("database", .null).setting("authenticationDatabase", .null)
        let connection = try NativeAppsDataDatabaseConnection.read(value)
        XCTAssertNil(connection.database)
        XCTAssertNil(connection.authenticationDatabase)
        XCTAssertEqual(connection.address, "terminaldeck-demo:6379")
    }

    private func mongo() -> NativeRPCValue {
        .object([
            .init("kind", .string("mongodb")), .init("host", .string("terminaldeck-demo")), .init("port", .number(27017)),
            .init("database", .string("terminaldeck")), .init("username", .string("terminaldeck")),
            .init("password", .string("••••••••")), .init("passwordKey", .string("MONGO_INITDB_ROOT_PASSWORD")),
            .init("scope", .string("private-network")), .init("network", .string("terminaldeck-apps")),
            .init("authenticationDatabase", .string("admin")), .init("status", .string("running"))
        ])
    }
}
