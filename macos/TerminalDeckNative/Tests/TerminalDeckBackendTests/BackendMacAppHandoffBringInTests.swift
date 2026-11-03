import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendMacAppHandoffBringInTests: XCTestCase {
    private func fixture<T>(_ body: (URL, URL, BackendMacAppHandoffBringInTransfers) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("BackendMacAppHandoff-bring-" + UUID().uuidString), pictures = root.appendingPathComponent("Pictures"), granted = root.appendingPathComponent("granted")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfers = BackendFilesystemTransfers(authority: .init(scope: { _ in .local }), uploadsDirectory: { root.appendingPathComponent("unused-uploads") })
        return try await body(pictures, granted, .init(transfers: transfers))
    }
    func testCopyLandsInsideAndOriginalRemains() async throws {
        try await fixture { pictures, granted, transfers in
            let source = pictures.appendingPathComponent("holiday.png"); try Data("not really a png".utf8).write(to: source)
            let landed = try await transfers.bringOne(source: source.path, folder: granted.path, context: BackendMacAppHandoffContext())
            BackendMacAppHandoffEqual(landed, granted.appendingPathComponent("Terminal Deck/holiday.png").path); BackendMacAppHandoffEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(landed))), Data("not really a png".utf8)); BackendMacAppHandoffEqual(try Data(contentsOf: source), Data("not really a png".utf8))
        }
    }
    func testCollidingNamesLandBesideFirst() async throws {
        try await fixture { pictures, granted, transfers in
            let a = pictures.appendingPathComponent("shot.png"), nested = pictures.appendingPathComponent("nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let b = nested.appendingPathComponent("shot.png"); try Data("first".utf8).write(to: a); try Data("second".utf8).write(to: b)
            let first = try await transfers.bringOne(source: a.path, folder: granted.path, context: BackendMacAppHandoffContext()), second = try await transfers.bringOne(source: b.path, folder: granted.path, context: BackendMacAppHandoffContext())
            BackendMacAppHandoffEqual(first, granted.appendingPathComponent("Terminal Deck/shot.png").path); BackendMacAppHandoffEqual(second, granted.appendingPathComponent("Terminal Deck/shot (2).png").path); BackendMacAppHandoffEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(first))), Data("first".utf8))
        }
    }
    func testDirectoryIsRefusedWithoutRecursion() async throws { try await fixture { pictures, granted, transfers in let answer = try await transfers.bringOne(source: pictures.path, folder: granted.path, context: BackendMacAppHandoffContext()); XCTAssertNil(answer) } }
    func testMissingPathReturnsNil() async throws { try await fixture { pictures, granted, transfers in let answer = try await transfers.bringOne(source: pictures.appendingPathComponent("gone.png").path, folder: granted.path, context: BackendMacAppHandoffContext()); XCTAssertNil(answer) } }
    func testRecognizableSubfolderNotProjectRoot() async throws { try await fixture { pictures, granted, transfers in let source = pictures.appendingPathComponent("a.png"); try Data([1]).write(to: source); _ = try await transfers.bringOne(source: source.path, folder: granted.path, context: BackendMacAppHandoffContext()); let folder = BackendMacAppHandoffAttachRules.bringInDirectory(granted.path); BackendMacAppHandoffEqual(folder, granted.appendingPathComponent("Terminal Deck").path); var isDirectory: ObjCBool = false; XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)); XCTAssertTrue(isDirectory.boolValue) } }
    private func service(_ fake: BackendMacAppHandoffFakeBringIn, confined: Bool) -> BackendMacAppHandoffAttachments {
        .init(files: BackendMacAppHandoffFakeFiles(), clipboard: nil, panels: nil, boundaries: BackendMacAppHandoffFakeBoundaries(values: confined ? ["confined": .init(deviceKey: "phone", folder: "/granted")] : [:]), bringIn: fake, pasteDirectory: "/fixture/pasted", home: "/fixture")
    }
    func testConfinedIPCReportsOriginalAndLandingPaths() async throws { let fake = BackendMacAppHandoffFakeBringIn(["/Pictures/one.png": "/granted/Terminal Deck/one.png"]), registry = NativeChannelRegistry(); try await service(fake, confined: true).register(registry: registry); let result = try await registry.invoke("attach:bring-in", context: BackendMacAppHandoffContext(), arguments: [.string("confined"), .array([.string("/Pictures/one.png")])]); BackendMacAppHandoffEqual(result["brought"], .array([BackendMacAppHandoffObject(["from": .string("/Pictures/one.png"), "path": .string("/granted/Terminal Deck/one.png")])])); BackendMacAppHandoffEqual(result["refused"], .number(0)) }
    func testOrdinarySessionCopiesNothing() async throws { let fake = BackendMacAppHandoffFakeBringIn(), result = try await service(fake, confined: false).bring(.string("ordinary"), paths: .array([.string("/Pictures/one.png")]), context: BackendMacAppHandoffContext()), count = await fake.count(); BackendMacAppHandoffEqual(result["brought"], .array([])); BackendMacAppHandoffEqual(result["refused"], .number(1)); BackendMacAppHandoffEqual(count, 0) }
    func testDestinationCannotComeFromWindowArguments() async throws {
        let fake = BackendMacAppHandoffFakeBringIn(), source = service(fake, confined: true)
        let a = try await source.bring(.string(""), paths: .array([.string("/x")]), context: BackendMacAppHandoffContext()), b = try await source.bring(.string("confined"), paths: .string("not an array"), context: BackendMacAppHandoffContext()), c = try await source.bring(.string("confined"), paths: .array([.number(1), .string(""), .null]), context: BackendMacAppHandoffContext())
        let none = BackendMacAppHandoffObject(["brought": .array([]), "refused": .number(0)]); BackendMacAppHandoffEqual(a, none); BackendMacAppHandoffEqual(b, none); BackendMacAppHandoffEqual(c, none)
    }
}
