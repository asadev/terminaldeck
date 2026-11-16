import Foundation
import XCTest
@testable import TerminalDeckBackend

/// 13 Nov (Asad: "still feeling a little bit of slow connectivity with these terminal sessions" on the phone): what a
/// phone is sent when it opens a session, packed (`history.z`) and not. The measuring test prints numbers only.
final class PhoneSpeedTests: XCTestCase {
    /// A Claude Code style transcript at 120 columns: coloured bullets, dim tool lines, diff rows with a background.
    private func transcript(lines: Int) -> String {
        var out = ""
        for n in 0..<lines {
            switch n % 6 {
            case 0: out += "\u{1b}[38;2;215;119;87m⏺\u{1b}[0m \u{1b}[1mUpdate\u{1b}[0m(macos/Sources/File\(n).swift)\r\n"
            case 1: out += "  \u{1b}[2m⎿  Updated macos/Sources/File\(n).swift with \(n % 17) additions and \(n % 5) removals\u{1b}[0m\r\n"
            case 2: out += "\u{1b}[48;2;2;40;0m  \(n) + let value\(n) = try await host.read(\"session-\(n)\", limit: \(n * 3))" + String(repeating: " ", count: 40) + "\u{1b}[0m\r\n"
            case 3: out += "\u{1b}[48;2;61;1;0m  \(n) - let value\(n) = host.read(\"session-\(n)\")" + String(repeating: " ", count: 60) + "\u{1b}[0m\r\n"
            case 4: out += "The phone opens session \(n) and waits for its history before it shows anything; this line is prose.\r\n"
            default: out += "\u{1b}[38;2;153;153;153m  Thinking… (\(n)s · ↓ \(n * 7) tokens · esc to interrupt)\u{1b}[0m\r\n"
            }
        }
        return out + "\u{1b}[38;2;215;119;87m>\u{1b}[0m "
    }

    private func remount(_ text: String) -> String {
        let probe = BackendTerminalProbe(cols: 120, rows: 40)
        probe.feed(text)
        return probe.remount
    }

    private func unpack(_ frames: [BackendRemoteServerMessage]) throws -> String {
        try frames.map { frame -> String in
            guard let z = frame.value["z"].string else { return frame.value["data"].string ?? "" }
            XCTAssertEqual(frame.value["data"].string, "", "a packed frame keeps an empty data for older readers of the schema")
            let packed = try XCTUnwrap(Data(base64Encoded: z))
            let raw = try (packed as NSData).decompressed(using: .zlib) as Data
            return try XCTUnwrap(String(data: raw, encoding: .utf8))
        }.joined()
    }

    /// Packed history unpacks to exactly the plain history, every frame is flagged `replay`, and stays small.
    func testPackedHistoryIsTheSameTextInFewerSmallerFrames() throws {
        let text = remount(transcript(lines: 4_000))
        let plain = try BackendRemoteHost.historyFrames("s1", text)
        let packed = try BackendRemoteHost.historyFrames("s1", text, deflate: true)
        XCTAssertEqual(try unpack(packed), text)
        XCTAssertTrue(packed.allSatisfy { $0.kind == .output && $0.value["replay"] == .bool(true) })
        XCTAssertLessThan(packed.count, plain.count)
        for frame in packed { XCTAssertLessThan(try BackendRemoteProtocol.serialize(frame).utf8.count, 64 * 1024, "under the phones' message cap") }
        XCTAssertNil(plain.first?.value["z"].string, "a phone that did not claim history.z gets plain text, as before")
    }

    /// Text that does not pack (random) goes plain, in the ordinary 32 KB frames; a tiny screen too.
    func testWhatDoesNotPackGoesPlain() throws {
        var random = SystemRandomNumberGenerator()
        let noise = String((0..<300_000).map { _ in Character(UnicodeScalar(UInt8.random(in: 33...126, using: &random))) })
        let frames = try BackendRemoteHost.historyFrames("s1", noise, deflate: true)
        XCTAssertEqual(try unpack(frames), noise)
        XCTAssertTrue(frames.allSatisfy { $0.value["z"].string == nil || (try? BackendRemoteProtocol.serialize($0).utf8.count) ?? .max < 64 * 1024 })
        let small = try BackendRemoteHost.historyFrames("s1", "$ ", deflate: true)
        XCTAssertEqual(try unpack(small), "$ ")
    }

    /// Multi-byte text split into pieces never cuts a code point (each piece must unpack to valid UTF-8 on its own).
    func testPiecesSplitOnCodePoints() throws {
        let text = String(repeating: "⏺ émoji 🚀 ", count: 60_000)
        let pieces = BackendRemoteProtocol.historyPieces(text)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.map(\.raw).joined(), text)
        XCTAssertTrue(pieces.allSatisfy { $0.raw.utf8.count <= BackendRemoteProtocol.historyPieceBytes })
    }

    /// Measuring (numbers only): the snapshot a phone is sent for a small screen and a long scrollback.
    func testMeasureSnapshotSizes() throws {
        for lines in [30, 1_000, 4_000] {
            let fed = transcript(lines: lines)
            let renderAt = Date()
            let text = remount(fed)
            let renderMs = Date().timeIntervalSince(renderAt) * 1_000
            let plainAt = Date()
            let plain = try BackendRemoteHost.historyFrames("s1", text)
            let plainMs = Date().timeIntervalSince(plainAt) * 1_000
            let plainWire = try plain.reduce(0) { $0 + (try BackendRemoteProtocol.serialize($1).utf8.count) }
            let packAt = Date()
            let packed = try BackendRemoteHost.historyFrames("s1", text, deflate: true)
            let packMs = Date().timeIntervalSince(packAt) * 1_000
            let packedWire = try packed.reduce(0) { $0 + (try BackendRemoteProtocol.serialize($1).utf8.count) }
            let unpackAt = Date()
            _ = try unpack(packed)
            let unpackMs = Date().timeIntervalSince(unpackAt) * 1_000
            print(String(format: "PHONE-SPEED snapshot lines=%d text=%d KB render=%.1f ms | plain %d frames %d KB json, frame %.1f ms | packed %d frames %d KB json, pack %.1f ms, unpack %.1f ms",
                         lines, text.utf8.count / 1024, renderMs, plain.count, plainWire / 1024, plainMs, packed.count, packedWire / 1024, packMs, unpackMs))
        }
    }
}
