import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("window-grants.test.ts exact port")
struct BackendRemoteServeWindowPortGrants: Sendable {
    @Test func ownDeviceDrivesWithoutAnExplicitRow() async throws {
        let disk = try disk(); defer { disk.remove() }
        let grants = await store(disk, mine: ["my-laptop"])
        #expect(try await grants.drives("my-laptop")); #expect(try await grants.list() == [])
    }
    @Test func guestStaysOffUntilTicked() async throws {
        let disk = try disk(); defer { disk.remove() }
        let grants = await store(disk, mine: ["my-laptop"])
        #expect(try await grants.drives("their-phone") == false)
        #expect(try await grants.set(.string("their-phone"), drives: .bool(true)))
        #expect(try await grants.drives("their-phone"))
    }
    @Test func missingKindsMeansAllGuestsAndEmptyIDIsDenied() async throws {
        let disk = try disk(); defer { disk.remove() }
        let grants = BackendRemoteServeWindowGrants(directory: disk.directory); await grants.open()
        #expect(try await grants.drives("device-a") == false)
        #expect(try await grants.list() == [])
        #expect(try await grants.drives("") == false)
    }
    @Test func kindChangesLandOnTheVeryNextCall() async throws {
        let disk = try disk(); defer { disk.remove() }; let kind = BackendRemoteServeWindowPortKind()
        let grants = BackendRemoteServeWindowGrants(directory: disk.directory, kindOf: { _ in await kind.value }); await grants.open()
        #expect(try await grants.drives("device-a") == false)
        await kind.set(.mine); #expect(try await grants.drives("device-a"))
    }
    @Test func ownDeviceNoSurvivesRestartAndCanBeTurnedBackOn() async throws {
        let disk = try disk(); defer { disk.remove() }; let grants = await store(disk, mine: ["my-laptop"])
        #expect(try await grants.set(.string("my-laptop"), drives: .bool(false)) == false)
        #expect(try await grants.drives("my-laptop") == false)
        let no = await store(disk, mine: ["my-laptop"]); #expect(try await no.drives("my-laptop") == false)
        #expect(try await grants.set(.string("my-laptop"), drives: .bool(true)))
        let yes = await store(disk, mine: ["my-laptop"]); #expect(try await yes.drives("my-laptop"))
    }
    @Test func explicitGuestYesSurvivesRestart() async throws {
        let disk = try disk(); defer { disk.remove() }; let grants = await store(disk)
        _ = try await grants.set(.string("device-a"), drives: .bool(true))
        let reopened = await store(disk); #expect(try await reopened.drives("device-a"))
    }
    @Test func explicitAnswersSurviveKindChanges() async throws {
        let disk = try disk(), secondDisk = try self.disk(); defer { disk.remove(); secondDisk.remove() }
        let grants = await store(disk); _ = try await grants.set(.string("device-a"), drives: .bool(true))
        let promoted = await store(disk, mine: ["device-a"]); #expect(try await promoted.drives("device-a"))
        let second = await store(secondDisk, mine: ["device-b"])
        _ = try await second.set(.string("device-b"), drives: .bool(false)); #expect(try await second.drives("device-b") == false)
    }
    @Test func writesBothSetsAndReadsTheOldYesOnlySchema() async throws {
        let disk = try disk(), oldDisk = try self.disk(); defer { disk.remove(); oldDisk.remove() }
        let grants = await store(disk, mine: ["my-laptop"])
        _ = try await grants.set(.string("device-a"), drives: .bool(true)); _ = try await grants.set(.string("my-laptop"), drives: .bool(false))
        #expect(try disk.read() == .object([.init("version", .number(1)), .init("devices", .array([.string("device-a")])), .init("denied", .array([.string("my-laptop")]))]))
        try oldDisk.write("{\"version\":1,\"devices\":[\"device-a\"]}")
        let old = await store(oldDisk); #expect(try await old.drives("device-a")); #expect(try await old.drives("device-b") == false)
    }
    @Test func revokedIDsAreForgottenFromBothSetsAndSecondForgetIsANoop() async throws {
        let disk = try disk(); defer { disk.remove() }; let grants = await store(disk, mine: ["my-laptop"])
        _ = try await grants.set(.string("device-a"), drives: .bool(true))
        #expect(try await grants.forget("device-a")); #expect(try await grants.drives("device-a") == false)
        _ = try await grants.set(.string("my-laptop"), drives: .bool(false)); #expect(try await grants.forget("my-laptop"))
        #expect(try await grants.forget("device-a") == false)
    }
    @Test func refusesInvalidIDsWithoutStoringThem() async throws {
        let disk = try disk(); defer { disk.remove() }; let grants = await store(disk)
        for value in [NativeRPCValue.number(42), .string(""), .string("  "), .string(String(repeating: "x", count: 500))] {
            #expect(try await grants.set(value, drives: .bool(true)) == false)
        }
        #expect(try await grants.list() == [])
    }
    @Test func onlyLiteralTrueMeansYes() async throws {
        let disk = try disk(); defer { disk.remove() }; let grants = await store(disk)
        #expect(try await grants.set(.string("device-a"), drives: .string("yes")) == false)
        #expect(try await grants.drives("device-a") == false)
    }
    @Test func unreadableFilesKeepOnlyKindDefaults() async throws {
        let disk = try disk(), wrongDisk = try self.disk(); defer { disk.remove(); wrongDisk.remove() }
        try disk.write("{ not json at all")
        let guest = await store(disk); #expect(try await guest.list() == []); #expect(try await guest.drives("device-a") == false)
        let own = await store(disk, mine: ["my-laptop"]); #expect(try await own.drives("my-laptop"))
        try wrongDisk.write("{\"version\":1,\"devices\":\"all\"}")
        let wrong = await store(wrongDisk); #expect(try await wrong.drives("device-a") == false)
    }
    @Test func keepsReadableEntriesAndDropsTheRest() async throws {
        let disk = try disk(); defer { disk.remove() }
        try disk.write("{\"version\":1,\"devices\":[\"device-a\",7,\"\",null,\"device-b\"],\"denied\":[3,\"device-c\"]}")
        let grants = await store(disk); #expect(try await grants.list() == ["device-a", "device-b"])
        #expect(try await grants.drives("device-c") == false)
    }
    @Test func handwrittenNoBeatsYesAndTheOwnKindDefault() async throws {
        let disk = try disk(); defer { disk.remove() }
        try disk.write("{\"version\":1,\"devices\":[\"device-a\"],\"denied\":[\"device-a\"]}")
        let grants = await store(disk, mine: ["device-a"]); #expect(try await grants.drives("device-a") == false)
    }
    @Test func implausiblyLargeFileIsIgnored() async throws {
        let disk = try disk(); defer { disk.remove() }
        try disk.write("{\"version\":1,\"devices\":[\"device-a" + String(repeating: "x", count: 199_992) + "\"]}")
        let grants = await store(disk); #expect(try await grants.list() == [])
    }
    private func store(_ disk: BackendRemoteServeWindowPortDisk, mine: Set<String> = []) async -> BackendRemoteServeWindowGrants {
        let grants = BackendRemoteServeWindowGrants(directory: disk.directory, kindOf: { mine.contains($0) ? .mine : .guest }, report: { _ in }); await grants.open(); return grants
    }
    private func disk() throws -> BackendRemoteServeWindowPortDisk { try .init() }
}
private struct BackendRemoteServeWindowPortDisk: Sendable {
    let directory: URL
    var file: URL { directory.appendingPathComponent(BackendRemoteServeWindowGrants.fileName) }
    init() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRemoteServeWindowPort-" + UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func write(_ text: String) throws { try Data(text.utf8).write(to: file) }
    func read() throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(contentsOf: file)) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
private actor BackendRemoteServeWindowPortKind {
    private(set) var value: BackendRemoteDeviceKind = .guest
    func set(_ value: BackendRemoteDeviceKind) { self.value = value }
}
