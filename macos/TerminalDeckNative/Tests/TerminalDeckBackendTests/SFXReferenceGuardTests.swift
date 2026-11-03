import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class SFXReferenceGuardTests: XCTestCase {
    func testEmptyMissingAndBlockedChecksCannotBecomeReference() {
        for raw in [NativeRPCValue.object([]), result(paths: 0), result(paths: -1), result(paths: 3).setting("blocked", .bool(true))] {
            let answer = BackendSFXReferenceGuard.refusalForResult(raw)
            XCTAssertEqual(answer?["marked"], .bool(false))
            XCTAssertEqual(answer?["refusedFor"], .string("unchecked"))
            XCTAssertTrue(answer?["summary"].string?.localizedCaseInsensitiveContains("check") == true)
        }
        XCTAssertNil(BackendSFXReferenceGuard.refusalForResult(result(paths: 3)))
    }

    func testSavedEnvelopeIsReadBeforeReferenceApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SFX-reference-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".staysfixed/v2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("last-check.json")
        XCTAssertNotNil(BackendSFXReferenceGuard.refusal(root.path))
        for paths in [0.0, 2.0] {
            let raw = result(paths: paths).setting("candidate", .object([.init("id", .string("sample-build"))]))
            let envelope = NativeRPCValue.object([.init("result", .string(raw.compact))])
            try envelope.encodedJSON().write(to: file)
            try recording(root, channel: "results", refused: false, complete: true)
            XCTAssertEqual(BackendSFXReferenceGuard.refusal(root.path) == nil, paths > 0)
        }
        try Data("broken JSON".utf8).write(to: file)
        XCTAssertNotNil(BackendSFXReferenceGuard.refusal(root.path))
    }

    func testStaticRefusedAndTornRecordingsCannotBecomeGoodBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SFX-reference-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".staysfixed/v2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = result(paths: 3).setting("candidate", .object([.init("id", .string("sample-build"))]))
        try NativeRPCValue.object([.init("result", .string(raw.compact))]).encodedJSON()
            .write(to: folder.appendingPathComponent("last-check.json"))
        for (channel, refused, complete) in [("source", false, true), ("results", true, true), ("results", false, false)] {
            try recording(root, channel: channel, refused: refused, complete: complete)
            XCTAssertNotNil(BackendSFXReferenceGuard.refusal(root.path))
        }
        try recording(root, channel: "results", refused: false, complete: true)
        XCTAssertNil(BackendSFXReferenceGuard.refusal(root.path))
    }

    private func recording(_ root: URL, channel: String, refused: Bool, complete: Bool) throws {
        let folder = root.appendingPathComponent(".staysfixed/v2/builds/sample-build/chosen-command")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let header = NativeRPCValue.object([.init("kind", .string("capture"))])
        let observation = NativeRPCValue.object([.init("path", .string("output")), .init("channel", .string(channel)),
            .init("value", .string("Hello")), .init("meta", .object([.init("refused", .bool(refused))]))])
        let end = NativeRPCValue.object([.init("kind", .string("end")), .init("count", .number(1))])
        let lines = [header, observation] + (complete ? [end] : [])
        try Data((lines.map(\.compact).joined(separator: "\n") + "\n").utf8)
            .write(to: folder.appendingPathComponent("20261008-000001.jsonl"))
    }

    private func result(paths: Double) -> NativeRPCValue {
        .object([.init("coverage", .object([.init("paths", .number(paths))]))])
    }
}
