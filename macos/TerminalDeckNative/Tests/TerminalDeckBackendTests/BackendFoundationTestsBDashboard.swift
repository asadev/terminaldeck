import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendFoundationTestsBDashboard: XCTestCase {
    private func layout(_ id: String = "w1") -> NativeRPCValue { .object([.init("version", .number(1)), .init("widgets", .array([.object([.init("id", .string(id)), .init("type", .string("github"))])]))]) }
    private func names(_ fixture: BackendFoundationTestsBFixture) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: fixture.file("dashboards").path) }
    func testCanonicalProjectNamesAreStableUniqueSafeAndRootHasProjectPrefix() async throws {
        let fixture = try BackendFoundationTestsBFixture("dashboard-names"), store = try BackendDashboardStore(userData: fixture.root, ownership: .exclusive)
        try await store.save(projectPath: "/Users/asad/Projects/example", layout: layout())
        let one = try names(fixture)
        try await store.save(projectPath: "/Users/asad/Projects/example/", layout: layout())
        XCTAssertEqual(try names(fixture), one)
        try await store.save(projectPath: "/different/tree/example", layout: layout()); XCTAssertEqual(try names(fixture).count, 2)
        try await store.save(projectPath: "/Users/asad/Projects/my app (v2)", layout: layout())
        for name in try names(fixture) { XCTAssertFalse(name.contains("/")); XCTAssertNotNil(name.range(of: "^[a-zA-Z0-9._-]+\\.json$", options: .regularExpression)) }
        try await store.save(projectPath: "/", layout: layout())
        XCTAssertTrue(try names(fixture).contains { $0.range(of: "^project-[0-9a-f]{10}\\.json$", options: .regularExpression) != nil })
    }
    func testRoundTripEmptyDashboardCallerIdentityAndAtomicReplacement() async throws {
        let fixture = try BackendFoundationTestsBFixture("dashboard-roundtrip"), store = try BackendDashboardStore(userData: fixture.root, ownership: .exclusive), project = "/Users/asad/Projects/terminaldeck"
        try await store.save(projectPath: project, layout: layout())
        let roundTrip = try await store.load(projectPath: project); XCTAssertEqual(roundTrip, layout().setting("projectPath", .string(project)))
        try await store.save(projectPath: project, layout: .object([.init("widgets", .array([]))]))
        let empty = try await store.load(projectPath: project); XCTAssertEqual(empty["widgets"], .array([]))
        try await store.save(projectPath: project, layout: layout().setting("projectPath", .string("/somewhere/else")))
        let identified = try await store.load(projectPath: project); XCTAssertEqual(identified["projectPath"].string, project)
        try await store.save(projectPath: project, layout: layout("first")); try await store.save(projectPath: project, layout: layout("second"))
        let changed = try await store.load(projectPath: project); XCTAssertEqual(changed, layout("second").setting("projectPath", .string(project)))
        XCTAssertFalse(try names(fixture).contains { $0.hasSuffix(".tmp") })
    }
    func testJunkAnd201WidgetsUseOriginalRefusalTextAndRelativePathRefused() async throws {
        let fixture = try BackendFoundationTestsBFixture("dashboard-refusals"), store = try BackendDashboardStore(userData: fixture.root, ownership: .exclusive)
        let junk: [NativeRPCValue] = [.null, .number(42), .string("nope"), .array([]), .object([]), .object([.init("widgets", .string("lots"))])]
        let widgets: [NativeRPCValue] = (0..<201).map { .object([.init("id", .string("w\($0)")), .init("type", .string("github"))]) }
        let over = NativeRPCValue.object([.init("widgets", .array(widgets))])
        for value in junk + [over] {
            do { try await store.save(projectPath: "/project", layout: value); XCTFail("Non-layout must be refused") }
            catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("not a layout"), "TS dashboard-store.test.ts preserves its refusal contract") }
        }
        do { try await store.save(projectPath: "projects/terminaldeck", layout: layout()); XCTFail("Relative save must be refused") } catch { XCTAssertTrue(error.localizedDescription.contains("absolute")) }
        do { _ = try await store.load(projectPath: "projects/terminaldeck"); XCTFail("Relative load must be refused") } catch { XCTAssertTrue(error.localizedDescription.contains("absolute")) }
    }
    func testAbsentCorruptAnd600000ByteLayoutReturnNullAndClearIsIdempotent() async throws {
        let fixture = try BackendFoundationTestsBFixture("dashboard-load"), store = try BackendDashboardStore(userData: fixture.root, ownership: .exclusive), project = "/Users/asad/Projects/truncated"
        let absent = try await store.load(projectPath: project); XCTAssertEqual(absent, .null)
        try await store.save(projectPath: project, layout: layout())
        let name = try XCTUnwrap(try names(fixture).first), file = fixture.file("dashboards/" + name)
        try Data("{\"widgets\": [{\"id\":".utf8).write(to: file)
        let corrupt = try await store.load(projectPath: project); XCTAssertEqual(corrupt, .null)
        try Data(("{\"widgets\":[],\"pad\":\"" + String(repeating: "x", count: 600_000) + "\"}").utf8).write(to: file)
        let huge = try await store.load(projectPath: project); XCTAssertEqual(huge, .null)
        try await store.clear(projectPath: project); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let cleared = try await store.load(projectPath: project); XCTAssertEqual(cleared, .null)
        try await store.clear(projectPath: "/Users/asad/Projects/never-saved")
    }
}
