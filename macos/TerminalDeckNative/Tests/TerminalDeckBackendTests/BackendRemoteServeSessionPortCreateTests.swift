import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeSessionPortCreateTests: XCTestCase {
    func testExplicitFolderSizeAndProviderReachActualSpawnAndCreatedFrame() async throws {
        let fake = Starter(), creator = fake.creator()
        let result = await creator.create(.init(deviceID: "device-phone", cwd: "/Users/apple/Projects/kiwi", provider: "shell", cols: 100, rows: 30))
        let requests = await fake.inputs()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].cwd, "/Users/apple/Projects/kiwi"); XCTAssertEqual(requests[0].deviceID, "device-phone")
        XCTAssertEqual(requests[0].provider, "shell"); XCTAssertEqual(requests[0].cols, 100); XCTAssertEqual(requests[0].rows, 30)
        let value = try result.message().value["session"]
        XCTAssertEqual(value, .object([.init("id", .string("sess-new")), .init("title", .string("terminaldeck")), .init("cwd", .string("/Users/apple/Projects/kiwi")), .init("provider", .string("claude")), .init("status", .string("idle")), .init("exitCode", .null)]))
    }
    func testFirstFolderAndPlainDefaultSizeNeverInventProvider() async {
        let fake = Starter(), creator = fake.creator()
        _ = await creator.create(.init(deviceID: "device-phone"))
        let inputs = await fake.inputs()
        XCTAssertEqual(inputs.first?.cwd, "/Users/apple/Projects/terminaldeck"); XCTAssertEqual(inputs.first?.cols, 80); XCTAssertEqual(inputs.first?.rows, 24); XCTAssertNil(inputs.first?.provider)
    }
    func testEquivalentFolderSpellingIsForwardedUnchanged() async {
        let fake = Starter(), creator = fake.creator()
        let result = await creator.create(.init(deviceID: "device-phone", cwd: "/Users/apple/Projects/kiwi/"))
        XCTAssertNotNil(result.session)
        let input = await fake.inputs().first; XCTAssertEqual(input?.cwd, "/Users/apple/Projects/kiwi/")
    }
    func testRefusedFolderRelativeTraversalAndSubdirectoryNeverSpawnOrSubstitute() async throws {
        let fake = Starter(), creator = fake.creator()
        let denied = ["/etc", "/Users/apple/Projects/gone", "/Users/apple/Projects/terminaldeck/../../.ssh", "/Users/apple/Projects/kiwi/..", "/Users/apple/Projects/terminaldeck/node_modules", "Projects/kiwi", ".", "..", "~/Projects/kiwi"]
        for path in denied {
            let result = await creator.create(.init(deviceID: "device-phone", cwd: path))
            XCTAssertNil(result.session); let value = try result.message().value
            XCTAssertEqual(value["code"], .string("unauthorized")); XCTAssertEqual(value["message"], .string("This Mac is not offering that folder to this device. Pick one from the list it sent."))
        }
        let calls = await fake.inputs(); XCTAssertEqual(calls.count, 0)
    }
    func testDynamicDeviceListsAndLookupCallsAreReReadEachTime() async {
        let fake = Starter(), creator = fake.creator()
        await fake.setFolders(["/Users/apple/Projects/alpha"], device: "device-a")
        await fake.setFolders(["/Users/apple/Projects/beta"], device: "device-b")
        _ = await creator.create(.init(deviceID: "device-a")); _ = await creator.create(.init(deviceID: "device-b"))
        let calls = await fake.lookups(), inputs = await fake.inputs()
        XCTAssertEqual(calls, ["device-a", "device-b"]); XCTAssertEqual(inputs.map(\.cwd), ["/Users/apple/Projects/alpha", "/Users/apple/Projects/beta"])
        let wrong = await creator.create(.init(deviceID: "device-a", cwd: "/Users/apple/Projects/beta")); XCTAssertNil(wrong.session)
        await fake.setFolders(["/Users/apple/Projects/alpha", "/Users/apple/Projects/beta"], device: "device-a")
        let added = await creator.create(.init(deviceID: "device-a", cwd: "/Users/apple/Projects/beta")); XCTAssertNotNil(added.session)
        await fake.setFolders(["/Users/apple/Projects/alpha"], device: "device-a")
        let removed = await creator.create(.init(deviceID: "device-a", cwd: "/Users/apple/Projects/beta")); XCTAssertNil(removed.session)
        let total = await fake.inputs(); XCTAssertEqual(total.count, 3)
    }
    func testPickerAndCreateUseSameLiveListWithoutCaching() async throws {
        let fake = Starter(), creator = fake.creator()
        await fake.setFolders(["/Users/apple/Projects/alpha"], device: "device-a")
        let first = try await creator.folders("device-a"), second = try await creator.folders("device-a")
        XCTAssertEqual(first, ["/Users/apple/Projects/alpha"]); XCTAssertEqual(second, first)
        let calls = await fake.lookups(); XCTAssertEqual(calls, ["device-a", "device-a"])
        let allowed = await creator.create(.init(deviceID: "device-a", cwd: first[0])), denied = await creator.create(.init(deviceID: "device-a", cwd: "/Users/apple/Projects/beta"))
        XCTAssertNotNil(allowed.session); XCTAssertNil(denied.session)
    }
    func testEmptyUnchosenAndRemovedFolderListsNeverCreateAnything() async throws {
        let fake = Starter(), creator = fake.creator()
        await fake.setFolders([], device: "device-phone")
        let absent = await creator.create(.init(deviceID: "never-chosen")), empty = await creator.create(.init(deviceID: "device-phone")), named = await creator.create(.init(deviceID: "device-phone", cwd: "/Users/apple/Projects/alpha"))
        XCTAssertNil(absent.session); XCTAssertNil(empty.session); XCTAssertNil(named.session)
        XCTAssertEqual(try empty.message().value["message"], .string("This Mac has no folders chosen for this device. Choose one in its remote access settings."))
        let inputs = await fake.inputs(); XCTAssertEqual(inputs.count, 0)
    }
    func testUnknownProviderRefusesWithoutEchoAndEveryKnownProviderReachesSpawn() async throws {
        let fake = Starter(), creator = fake.creator()
        for provider in ["copilot", "evilagent"] {
            let result = await creator.create(.init(deviceID: "device-phone", provider: provider))
            XCTAssertNil(result.session); XCTAssertEqual(try result.message().value["code"], .string("unauthorized"))
            XCTAssertEqual(try result.message().value["message"], .string("This Mac does not have an agent by that name. It can start: claude, codex, gemini, shell."))
        }
        let before = await fake.inputs(); XCTAssertEqual(before.count, 0)
        for name in BackendRemoteServeSessionCreate.providers { let created = await creator.create(.init(deviceID: "device-phone", provider: name)); XCTAssertNotNil(created.session) }
        let inputs = await fake.inputs(); XCTAssertEqual(inputs.map(\.provider), BackendRemoteServeSessionCreate.providers.map(Optional.some))
    }
    func testFailureRemediesAndNetworkTextAreExactAndNonEchoing() async throws {
        let folder = "/etc/<script>alert(1)</script>", fake = Starter(), creator = fake.creator()
        let noFolder = await creator.create(.init(deviceID: "device-phone", cwd: folder)), noAgent = await creator.create(.init(deviceID: "device-phone", cwd: "/etc", provider: "copilot"))
        XCTAssertEqual(try noAgent.message().value["message"], .string("This Mac is not offering that folder to this device. Pick one from the list it sent."))
        XCTAssertFalse(try noFolder.message().value["message"].requireString("message").contains("script"))
        let generic = BackendRemoteServeSessionCreate(folders: { _ in ["/work"] }, spawn: { _ in throw Failure.moved })
        let failed = await generic.create(.init(deviceID: "phone"))
        XCTAssertEqual(try failed.message().value["code"], .string("unavailable")); XCTAssertEqual(try failed.message().value["message"], .string("This Mac could not start a session there. The folder may have moved."))
    }
    private enum Failure: Error { case moved }
    private actor Starter {
        var choices: [String: [String]] = ["device-phone": ["/Users/apple/Projects/terminaldeck", "/Users/apple/Projects/kiwi"]]
        var requested: [BackendRemoteCreateRequest] = [], asked: [String] = []
        func setFolders(_ folders: [String], device: String) { choices[device] = folders }
        func folders(_ device: String) -> [String] { asked.append(device); return choices[device] ?? [] }
        func spawn(_ input: BackendRemoteCreateRequest) throws -> BackendSessionMeta { requested.append(input); return try BackendRemoteServeAccountPortFixture.meta(cwd: input.cwd) }
        func inputs() -> [BackendRemoteCreateRequest] { requested }
        func lookups() -> [String] { asked }
        nonisolated func creator() -> BackendRemoteServeSessionCreate { .init(folders: { await self.folders($0) }, spawn: { try await self.spawn($0) }) }
    }
}
