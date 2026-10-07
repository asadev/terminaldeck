import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendMacAppSetupUserDataTests: XCTestCase {
    actor IO: BackendMacAppSetupUserDataIO {
        var files: [String: String], trace: [String] = []
        init(_ files: [String: String] = [:]) { self.files = files }
        func ensureDirectory(_ path: String) async throws { trace.append("mkdir:" + path) }
        func exists(_ path: String) async throws -> Bool { files[path] != nil }
        func copy(_ source: String, to target: String) async throws { trace.append("copy"); files[target] = files[source] }
        func adopted(_ path: String) { trace.append("adopt:" + path) }
        func values() -> [String: String] { files }
        func operations() -> [String] { trace }
    }
    private func pin(_ path: String, args: [String] = [], io: IO) async -> String { await BackendMacAppSetupUserData.pin(current: path, arguments: args, io: io, adopt: { await io.adopted($0) }) }
    func testMovesDisplayNameToStableSlug() async { let io = IO(), selected = await pin("/test/Terminal Deck", io: io); XCTAssertEqual(selected, "/test/terminaldeck") }
    func testFirstRenameCopiesOnlyStateBytes() async { let bytes = "{\"projects\":[\"kept\"]}", io = IO(["/test/Pawl/state.json": bytes, "/test/Pawl/relay-identity.json": "credential"]); _ = await pin("/test/Pawl", io: io); let files = await io.values(); XCTAssertEqual(files["/test/terminaldeck/state.json"], bytes); XCTAssertNil(files["/test/terminaldeck/relay-identity.json"]) }
    func testNeverOverwritesExistingPinnedState() async { let io = IO(["/test/Pawl/state.json": "stale", "/test/terminaldeck/state.json": "current"]); _ = await pin("/test/Pawl", io: io); let files = await io.values(); XCTAssertEqual(files["/test/terminaldeck/state.json"], "current") }
    func testAlreadyPinnedPerformsNoIO() async { let io = IO(), selected = await pin("/test/terminaldeck", io: io), trace = await io.operations(); XCTAssertEqual(selected, "/test/terminaldeck"); XCTAssertEqual(trace, []) }
    func testExplicitFlagBothSpellings() { XCTAssertEqual(BackendMacAppSetupUserData.flag(["electron", "--user-data-dir=/tmp/probe"]), "/tmp/probe"); XCTAssertEqual(BackendMacAppSetupUserData.flag(["electron", "--user-data-dir", "/tmp/probe"]), "/tmp/probe") }
    func testMissingOrEmptyFlagDoesNotStealNextOption() { for args in [["electron", "."], ["electron", "--user-data-dir="], ["electron", "--user-data-dir", "--inspect"]] { XCTAssertNil(BackendMacAppSetupUserData.flag(args)) } }
    func testExplicitPathPreventsMigrationAndAdoption() async { let io = IO(), selected = await pin("/tmp/td-explicit", args: ["electron", "--user-data-dir=/tmp/td-explicit"], io: io), trace = await io.operations(); XCTAssertEqual(selected, "/tmp/td-explicit"); XCTAssertEqual(trace, []) }
}
