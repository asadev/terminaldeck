/**
 * The upload state machine, driven against a fake wire and a real file.
 *
 * What is worth testing here is not "does it send the bytes" — it is the three
 * properties that make the feature trustworthy, and each of them is invisible
 * from a screenshot of a working transfer:
 *
 *  1. **Nothing is read until the Mac has named a path.** The path on screen is
 *     what the user cancels against; an upload that started reading before the
 *     answer would already be sending when they read it.
 *  2. **No more than one window is ever in flight.** Without it the feature works
 *     on every file small enough to fit in the socket buffer and drops the phone
 *     on every one that does not — a bug that only appears on the large files.
 *  3. **The digest is over what was read.** It is the only thing standing between
 *     a dropped slice and a corrupt file with a correct-looking name.
 */

import CryptoKit
import XCTest
@testable import TerminalDeck

@MainActor
final class FileUploadTests: XCTestCase {

    /// Collects frames instead of sending them, and can refuse like a dead socket.
    private final class FakeWire: UploadWire {
        var sent: [ClientMessage] = []
        var accepting = true

        @discardableResult
        func send(_ message: ClientMessage) -> Bool {
            guard accepting else { return false }
            sent.append(message)
            return true
        }

        var slices: [Data] {
            sent.compactMap { if case let .uploadData(_, data) = $0 { return data } else { return nil } }
        }

        var digestSent: String? {
            sent.compactMap { if case let .uploadEnd(_, hex) = $0 { return hex } else { return nil } }.first
        }
    }

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func file(named name: String, bytes: Int) -> PickedFile {
        let url = scratch.appendingPathComponent(name)
        var data = Data(count: bytes)
        // Not zeros: a digest over a run of zeros matches a digest over a
        // *different* run of zeros, so a chunking bug that dropped a slice would
        // still produce the right hash.
        for index in 0 ..< bytes { data[index] = UInt8((index &* 31 &+ 7) % 251) }
        try? data.write(to: url)
        return PickedFile(url: url, name: name, size: bytes, temporary: false)
    }

    private func upload(_ file: PickedFile, wire: FakeWire, onLanded: @escaping (String) -> Void = { _ in })
        -> FileUpload {
        FileUpload(file: file, wire: wire, onLanded: onLanded)
    }

    func testNothingIsReadUntilTheMacNamesAPath() {
        let wire = FakeWire()
        let transfer = upload(file(named: "a.bin", bytes: 100_000), wire: wire)
        transfer.start()

        XCTAssertEqual(wire.sent.count, 1, "only the announcement")
        if case let .uploadBegin(_, name, size) = wire.sent[0] {
            XCTAssertEqual(name, "a.bin")
            XCTAssertEqual(size, 100_000)
        } else {
            XCTFail("expected upload.begin, got \(wire.sent[0])")
        }
        XCTAssertTrue(wire.slices.isEmpty, "nothing may be read before upload.ready")
        XCTAssertEqual(transfer.phase, .opening)
    }

    func testTheWindowIsNeverExceeded() {
        let wire = FakeWire()
        // Ten windows' worth, so the cap has to hold rather than happening to.
        let size = Wire.uploadWindowBytes * 10
        let transfer = upload(file(named: "big.bin", bytes: size), wire: wire)
        transfer.start()
        transfer.receive(.uploadReady(id: transfer.id, path: "/tmp/big.bin"))

        let inFlight = wire.slices.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(inFlight, Wire.uploadWindowBytes)
        XCTAssertGreaterThan(inFlight, 0, "the pump must actually start")
        // And no slice is larger than a frame will carry.
        for slice in wire.slices {
            XCTAssertLessThanOrEqual(slice.count, Wire.maxUploadChunkBytes)
        }
    }

    func testAcknowledgementsRefillTheWindowAndDriveProgress() {
        let wire = FakeWire()
        let size = Wire.uploadWindowBytes * 3
        let transfer = upload(file(named: "big.bin", bytes: size), wire: wire)
        transfer.start()
        transfer.receive(.uploadReady(id: transfer.id, path: "/tmp/big.bin"))

        XCTAssertEqual(transfer.acked, 0)
        XCTAssertEqual(transfer.fraction, 0)
        let before = wire.slices.count

        // Acknowledge one slice; exactly one more should be read to replace it.
        transfer.receive(.uploadAck(id: transfer.id, bytes: Wire.maxUploadChunkBytes))

        XCTAssertEqual(transfer.acked, Wire.maxUploadChunkBytes)
        XCTAssertGreaterThan(transfer.fraction, 0)
        XCTAssertEqual(wire.slices.count, before + 1)
    }

    func testTheDigestIsOverWhatWasRead() {
        let wire = FakeWire()
        let source = file(named: "a.bin", bytes: 60_000)
        let transfer = upload(source, wire: wire)
        transfer.start()
        transfer.receive(.uploadReady(id: transfer.id, path: "/tmp/a.bin"))
        // Acknowledge everything, a window at a time, until the end goes out.
        while transfer.acked < source.size {
            let outstanding = wire.slices.reduce(0) { $0 + $1.count } - transfer.acked
            transfer.receive(.uploadAck(id: transfer.id, bytes: outstanding))
        }

        let expected = SHA256.hash(data: try! Data(contentsOf: source.url))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(wire.digestSent, expected)
        // And the slices reassemble into the file, which is the property the
        // digest is standing in for on the wire.
        XCTAssertEqual(wire.slices.reduce(Data(), +), try! Data(contentsOf: source.url))
    }

    func testTheEndIsSentExactlyOnce() {
        let wire = FakeWire()
        let transfer = upload(file(named: "a.bin", bytes: 1000), wire: wire)
        transfer.start()
        transfer.receive(.uploadReady(id: transfer.id, path: "/tmp/a.bin"))
        transfer.receive(.uploadAck(id: transfer.id, bytes: 1000))
        // A duplicate or late acknowledgement must not send a second digest —
        // the Mac would answer the second one with "no upload with that id".
        transfer.receive(.uploadAck(id: transfer.id, bytes: 1000))

        let ends = wire.sent.filter { if case .uploadEnd = $0 { return true } else { return false } }
        XCTAssertEqual(ends.count, 1)
    }

    func testLandingTypesThePathExactlyOnce() {
        let wire = FakeWire()
        var typed: [String] = []
        let transfer = upload(file(named: "a.bin", bytes: 100), wire: wire) { typed.append($0) }
        transfer.start()
        transfer.receive(.uploadReady(id: transfer.id, path: "/tmp/a.bin"))
        transfer.receive(.uploadAck(id: transfer.id, bytes: 100))
        transfer.receive(.uploadDone(id: transfer.id, path: "/tmp/a (2).bin", bytes: 100, sha256: "x"))

        // The path from `done`, not from `ready`: a second file of the same name
        // lands beside the first and the phone must type where it actually went.
        XCTAssertEqual(typed, ["/tmp/a (2).bin"])
        XCTAssertEqual(transfer.phase, .landed(path: "/tmp/a (2).bin"))
    }

    func testCancelTellsTheMacAndStops() {
        let wire = FakeWire()
        let transfer = upload(file(named: "big.bin", bytes: Wire.uploadWindowBytes * 4), wire: wire)
        transfer.start()
        transfer.receive(.uploadReady(id: transfer.id, path: "/tmp/big.bin"))
        let before = wire.slices.count

        transfer.cancel()

        XCTAssertTrue(wire.sent.contains { if case .uploadCancel = $0 { return true } else { return false } })
        // Nothing more is read after a cancel, however many acknowledgements are
        // still in flight behind it.
        transfer.receive(.uploadAck(id: transfer.id, bytes: Wire.maxUploadChunkBytes))
        XCTAssertEqual(wire.slices.count, before)
    }

    func testADroppedSocketEndsTheTransferRatherThanStalling() {
        let wire = FakeWire()
        let transfer = upload(file(named: "big.bin", bytes: Wire.uploadWindowBytes * 4), wire: wire)
        transfer.start()
        transfer.receive(.uploadReady(id: transfer.id, path: "/tmp/big.bin"))

        wire.accepting = false
        transfer.receive(.uploadAck(id: transfer.id, bytes: Wire.maxUploadChunkBytes))

        // A bar creeping against a socket that will never answer is the exact
        // failure this app is written not to have.
        if case let .failed(reason) = transfer.phase {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("expected a failure, got \(transfer.phase)")
        }
    }

    func testAFrameForAnotherUploadIsNotClaimed() {
        let wire = FakeWire()
        let transfer = upload(file(named: "a.bin", bytes: 100), wire: wire)
        transfer.start()
        XCTAssertFalse(transfer.receive(.uploadReady(id: "someone-else", path: "/tmp/x")))
        XCTAssertFalse(transfer.receive(.uploadAck(id: "someone-else", bytes: 10)))
        XCTAssertEqual(transfer.phase, .opening)
    }

    func testTheStagedCopyIsDeletedWhenTheTransferEnds() {
        let wire = FakeWire()
        let url = scratch.appendingPathComponent("staged.bin")
        try! Data(count: 64).write(to: url)
        let transfer = FileUpload(
            file: PickedFile(url: url, name: "staged.bin", size: 64, temporary: true),
            wire: wire,
            onLanded: { _ in })
        transfer.start()
        transfer.cancel()

        // iOS empties `tmp` only under storage pressure, so a phone that sent ten
        // videos would otherwise be holding two copies of each.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

/// The two formatting helpers that appear in refusals, where two numbers produced
/// different ways would make the sentence read as nonsense.
final class UploadFormattingTests: XCTestCase {

    func testByteSizeReadsLikeAFileSize() {
        XCTAssertEqual(byteSize(512), "512 bytes")
        XCTAssertEqual(byteSize(1024), "1.0 KB")
        XCTAssertEqual(byteSize(3_400_000), "3.4 MB")
        XCTAssertEqual(byteSize(1024 * 1024), "1.0 MB")
    }

    func testAPathIsQuotedSoAShellReadsItAsOneWord() {
        XCTAssertEqual(shellQuoted("/tmp/a.bin"), "'/tmp/a.bin'")
        XCTAssertEqual(
            shellQuoted("/Users/a/Downloads/Terminal Deck/IMG 1.HEIC"),
            "'/Users/a/Downloads/Terminal Deck/IMG 1.HEIC'")
    }

    func testAQuoteInAFileNameIsClosedEscapedAndReopened() {
        // The one character single quotes cannot contain. `it's` must not end the
        // quoting and leave `s` as a bare word.
        XCTAssertEqual(shellQuoted("/tmp/it's here.txt"), "'/tmp/it'\\''s here.txt'")
    }

    func testShellPunctuationIsQuotedRatherThanRemoved() {
        // This is why `safeName` on the desktop deliberately leaves these in
        // people's file names: the hazard is handled here, once.
        let quoted = shellQuoted("/tmp/$(rm -rf ~)`whoami`;echo.txt")
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertFalse(quoted.dropFirst().dropLast().contains("'"))
    }
}
