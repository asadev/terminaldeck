import Foundation
import zlib
import XCTest
@testable import TerminalDeckBackend

enum BackendOSTestPortZipFixture {
    struct Entry { let path: String, bytes: Data; var store = false; var mode: UInt32 = 0o100644; var statedSize: Int? }
    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream(); guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NSError(domain: "fixture", code: 1) }; defer { deflateEnd(&stream) }
        return try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = UInt32(input.count); var result = Data()
            while true { let before = stream.avail_in; var block = [UInt8](repeating: 0, count: 65536); let code = block.withUnsafeMutableBytes { bytes in stream.next_out = bytes.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = 65536; return zlib.deflate(&stream, Z_FINISH) }; let written = block.count - Int(stream.avail_out); result.append(contentsOf: block.prefix(written)); if code == Z_STREAM_END { return result }; guard code == Z_OK, written > 0 || stream.avail_in < before else { throw NSError(domain: "fixture", code: 2) } }
        }
    }
    static func zip(_ entries: [Entry]) throws -> Data {
        func u16(_ value: Int) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
        func u32(_ value: Int) -> Data { u16(value) + u16(value >> 16) }
        var local = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8), bytes = entry.store ? entry.bytes : try deflate(entry.bytes), declared = entry.statedSize ?? entry.bytes.count
            let method: Int = entry.store ? 0 : 8
            var header = Data()
            header.append(u32(0x04034b50)); header.append(u16(20)); header.append(u16(0)); header.append(u16(method))
            header.append(u32(0)); header.append(u32(0)); header.append(u32(bytes.count)); header.append(u32(declared))
            header.append(u16(name.count)); header.append(u16(0))
            var index = Data()
            index.append(u32(0x02014b50)); index.append(u16(20)); index.append(u16(20)); index.append(u16(0)); index.append(u16(method))
            index.append(u32(0)); index.append(u32(0)); index.append(u32(bytes.count)); index.append(u32(declared))
            index.append(u16(name.count)); index.append(u16(0)); index.append(u16(0)); index.append(u16(0)); index.append(u16(0))
            index.append(u32(Int(entry.mode << 16))); index.append(u32(local.count))
            central.append(index); central.append(name); local.append(header); local.append(name); local.append(bytes)
        }
        var end = Data()
        end.append(u32(0x06054b50)); end.append(u16(0)); end.append(u16(0)); end.append(u16(entries.count)); end.append(u16(entries.count))
        end.append(u32(central.count)); end.append(u32(local.count)); end.append(u16(0))
        var archive = local
        archive.append(central); archive.append(end)
        return archive
    }
}

final class BackendOSTestPortArchive: XCTestCase {
    let limits = BackendOSStoreArchive.Limits.small
    func tar(_ entries: [BackendOSStoreArchiveFixture.Entry], corrupt: Bool = false, limits: BackendOSStoreArchive.Limits = .small) throws -> BackendOSStoreArchive.Result { BackendOSStoreArchive.readTarGzip(try BackendOSStoreArchiveFixture.tarGzip(entries, corruptChecksum: corrupt), limits: limits) }
    func testStoreArchive23PlainTarGzipFilesAndContents() throws {
        let result = try tar([.init("item/SKILL.md", "# hello"), .init("item/", type: 53), .init("item/notes/two.md", "two")]), files = try XCTUnwrap(result.files)
        XCTAssertEqual(files.map(\.path).sorted(), ["item/SKILL.md", "item/notes/two.md"]); XCTAssertEqual(String(decoding: files[0].bytes, as: UTF8.self), "# hello")
    }
    func testStoreArchive38ModeRetainedForTier() throws { let files = try XCTUnwrap(tar([.init("a/run", "#!/bin/sh\n", mode: 0o755)]).files); XCTAssertNotEqual(files[0].mode & 0o111, 0) }
    func testStoreArchive45PaxLongName() throws { let long = "item/" + String(repeating: "d", count: 120) + "/deep.md", files = try XCTUnwrap(tar([.init("PaxHeader", BackendOSStoreArchiveFixture.pax("path", long), type: 120), .init(String(long.prefix(90)), "deep")]).files); XCTAssertEqual(files[0].path, long) }
    func testStoreArchive60GlobalMetadataIgnored() throws { let files = try XCTUnwrap(tar([.init("pax_global_header", BackendOSStoreArchiveFixture.pax("comment", String(repeating: "a", count: 40)), type: 103), .init("item/SKILL.md", "x")]).files); XCTAssertEqual(files.map(\.path), ["item/SKILL.md"]) }
    func testStoreArchive75ParentTraversalRefused() throws { let result = try tar([.init("../../.claude/settings.json", "{}")]); XCTAssertNil(result.files); XCTAssertTrue(result.why?.contains("will not write") == true) }
    func testStoreArchive82AbsolutePathRefused() throws { XCTAssertNil(try tar([.init("/etc/hosts", "x")]).files) }
    func testStoreArchive87SymlinkRefusesWholeArchive() throws { let result = try tar([.init("item/SKILL.md", "ok"), .init("item/keys", type: 50)]); XCTAssertNil(result.files); XCTAssertTrue(result.why?.contains("link") == true) }
    func testStoreArchive100HardLinkRefused() throws { XCTAssertNil(try tar([.init("item/x", type: 49)]).files) }
    func testStoreArchive104DeviceRefused() throws { XCTAssertNil(try tar([.init("item/null", type: 51)]).files) }
    func testStoreArchive108ChecksumDamageRefused() throws { let result = try tar([.init("item/a.md", "a")], corrupt: true); XCTAssertNil(result.files); XCTAssertTrue(result.why?.contains("damaged") == true) }
    func testStoreArchive115ClaimedSizePastEndRefused() throws { let result = try tar([.init("item/a.md", "a", statedSize: 900000)]); XCTAssertNil(result.files); XCTAssertTrue(result.why?.contains("cut short") == true) }
    func testStoreArchive122FileCountCap() throws { let result = try tar((0..<12).map { .init("item/f\($0).md", "x") }, limits: .init(archiveBytes: limits.archiveBytes, totalBytes: limits.totalBytes, files: 4)); XCTAssertNil(result.files); XCTAssertTrue(result.why?.contains("more files") == true) }
    func testStoreArchive130DecompressedCap() throws { XCTAssertNil(try tar([.init("item/big.md", String(repeating: "x", count: 4096))], limits: .init(archiveBytes: limits.archiveBytes, totalBytes: 1024, files: limits.files)).files) }
    func testStoreArchive138EmptyArchiveRefused() throws { XCTAssertNil(try tar([]).files) }
    func testStoreArchive144ReaderChosenByGzipBytes() throws { XCTAssertNotNil(BackendOSStoreArchive.read(try BackendOSStoreArchiveFixture.tarGzip([.init("a/b.md", "x")])).files) }
    func testStoreArchive148UnknownContainerRefused() { let result = BackendOSStoreArchive.read(Data("not an archive at all, just text".utf8)); XCTAssertNil(result.files); XCTAssertTrue(result.why?.contains("not an archive") == true) }
    func testStoreArchive155CompressedCapBeforeDecompress() throws { let result = BackendOSStoreArchive.read(try BackendOSStoreArchiveFixture.tarGzip([.init("a/b.md", "x")]), limits: .init(archiveBytes: 4, totalBytes: limits.totalBytes, files: limits.files)); XCTAssertNil(result.files); XCTAssertTrue(result.why?.contains("larger than") == true) }
    var files: [BackendOSStoreArchive.File] { [.init(path: "repo-abc/terminaldeck.json", bytes: Data("{}".utf8)), .init(path: "repo-abc/skill/SKILL.md", bytes: Data("# s".utf8))] }
    func testStoreArchive169SingleRootRemoved() { XCTAssertEqual(BackendOSStoreArchive.stripSingleRoot(files).map(\.path).sorted(), ["skill/SKILL.md", "terminaldeck.json"]) }
    func testStoreArchive173TwoRootsNotGuessed() { let files: [BackendOSStoreArchive.File] = [.init(path: "one/a.md", bytes: Data()), .init(path: "two/b.md", bytes: Data())]; XCTAssertEqual(BackendOSStoreArchive.stripSingleRoot(files).map(\.path).sorted(), ["one/a.md", "two/b.md"]) }
    func testStoreArchive181SubtreeHasPrefixRemoved() { XCTAssertEqual(BackendOSStoreArchive.filesUnder(BackendOSStoreArchive.stripSingleRoot(files), directory: "skill").map(\.path), ["SKILL.md"]) }
    func testStoreArchive185DotMeansWholeTree() { XCTAssertEqual(BackendOSStoreArchive.filesUnder(BackendOSStoreArchive.stripSingleRoot(files), directory: ".").count, 2) }
    func testStoreArchive189ExactFileLookup() { XCTAssertNotNil(BackendOSStoreArchive.fileAt(BackendOSStoreArchive.stripSingleRoot(files), path: "terminaldeck.json")); XCTAssertNil(BackendOSStoreArchive.fileAt(BackendOSStoreArchive.stripSingleRoot(files), path: "nothing.json")) }
    var zipLimits: BackendOSStoreArchive.Limits { .init(archiveBytes: 2_000_000, totalBytes: 1_000_000, files: 100) }
    func testUnzip18EveryUnsafeEntryName() { for path in ["../escape", "a/../../escape", "/etc/passwd", "C:/Windows/System32/x", "a\\b", "a//b", "./a"] { XCTAssertNil(BackendOSStoreArchive.safePath(path), path) } }
    func testUnzip30NulRefused() { XCTAssertNil(BackendOSStoreArchive.safePath("a\0b")) }
    func testUnzip34NestedPathPreserved() { XCTAssertEqual(BackendOSStoreArchive.safePath("js/background/index.js"), "js/background/index.js") }
    func testUnzip38ArchiveRefusedRatherThanSanitized() throws { let zip = try BackendOSTestPortZipFixture.zip([.init(path: "../escape.js", bytes: Data("x".utf8))]); XCTAssertTrue(BackendOSStoreArchive.readZip(zip, limits: zipLimits).why?.contains("will not write") == true) }
    func testUnzip51UnixModeSymlinkRefused() throws { let zip = try BackendOSTestPortZipFixture.zip([.init(path: "link", bytes: Data("/etc/passwd".utf8), mode: 0o120777)]); XCTAssertTrue(BackendOSStoreArchive.readZip(zip, limits: zipLimits).why?.contains("symbolic link") == true) }
    func testUnzip58UnpackedSizeCap() throws { let zip = try BackendOSTestPortZipFixture.zip([.init(path: "big.js", bytes: Data(repeating: 0x61, count: 50000))]); XCTAssertTrue(BackendOSStoreArchive.readZip(zip, limits: .init(archiveBytes: 2_000_000, totalBytes: 1000, files: 100)).why?.contains("unpacks to more than") == true) }
    func testUnzip63CentralEntryCountCap() throws { let zip = try BackendOSTestPortZipFixture.zip((0..<10).map { .init(path: "f\($0).js", bytes: Data("x".utf8)) }); XCTAssertTrue(BackendOSStoreArchive.readZip(zip, limits: .init(archiveBytes: 2_000_000, totalBytes: 1_000_000, files: 3)).why?.contains("more than this app will unpack") == true) }
    func testUnzip73DeclaredAndActualSizesMustAgree() throws { let zip = try BackendOSTestPortZipFixture.zip([.init(path: "a.js", bytes: Data("hello".utf8), statedSize: 99)]); XCTAssertTrue(BackendOSStoreArchive.readZip(zip, limits: zipLimits).why?.contains("not the size the archive says") == true) }
    func testUnzip83NotAZip() { XCTAssertEqual(BackendOSStoreArchive.readZip(Data("not a zip, just some text".utf8), limits: zipLimits).why, "it is not a zip archive") }
    func testUnzip87EmptyZip() throws { XCTAssertEqual(BackendOSStoreArchive.readZip(try BackendOSTestPortZipFixture.zip([]), limits: zipLimits).why, "it contains no files") }
    func testUnzip93DeflatedBytesRoundTrip() throws { let body = Data((String(repeating: "a", count: 5000) + "tail").utf8), files = try XCTUnwrap(BackendOSStoreArchive.readZip(try BackendOSTestPortZipFixture.zip([.init(path: "x.js", bytes: body)]), limits: zipLimits).files); XCTAssertEqual(files[0].bytes, body) }
    func testUnzip101StoredBinaryBytesRoundTrip() throws { let body = Data([0, 1, 2, 253, 254, 255]), files = try XCTUnwrap(BackendOSStoreArchive.readZip(try BackendOSTestPortZipFixture.zip([.init(path: "x.bin", bytes: body, store: true)]), limits: zipLimits).files); XCTAssertEqual(files[0].bytes, body) }
    func testUnzip111DirectoryEntriesSkipped() throws { let zip = try BackendOSTestPortZipFixture.zip([.init(path: "dir/", bytes: Data(), store: true), .init(path: "dir/a.js", bytes: Data("x".utf8))]), files = try XCTUnwrap(BackendOSStoreArchive.readZip(zip, limits: zipLimits).files); XCTAssertEqual(files.map(\.path), ["dir/a.js"]) }
}
