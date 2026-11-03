import Foundation
import zlib
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// store-archive.fixture.ts. In-test byte fixtures, never a production loader.
enum BackendOSStoreArchiveFixture {
    struct Entry {
        let name: String, body: Data, type: UInt8, mode: Int, statedSize: Int?
        init(_ name: String, _ body: String = "", type: UInt8 = 48, mode: Int = 0o644, statedSize: Int? = nil) { self.name = name; self.body = Data(body.utf8); self.type = type; self.mode = mode; self.statedSize = statedSize }
    }
    static func tar(_ entries: [Entry], corruptChecksum: Bool = false) -> Data {
        var output = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at: Int, length: Int) { for (offset, byte) in text.utf8.prefix(length).enumerated() { header[at + offset] = byte } }
            put(entry.name, at: 0, length: 100)
            put(String(repeating: "0", count: max(0, 7 - String(entry.mode, radix: 8).count)) + String(entry.mode, radix: 8), at: 100, length: 7)
            let size = entry.statedSize ?? entry.body.count, sizeText = String(size, radix: 8)
            put(String(repeating: "0", count: max(0, 11 - sizeText.count)) + sizeText, at: 124, length: 11)
            header[156] = entry.type; put("ustar", at: 257, length: 5); put("00", at: 263, length: 2); put("        ", at: 148, length: 8)
            let sum = corruptChecksum ? 0 : header.reduce(0) { $0 + Int($1) }, sumText = String(sum, radix: 8)
            put(String(repeating: "0", count: max(0, 6 - sumText.count)) + sumText + "\0 ", at: 148, length: 8)
            output.append(contentsOf: header); output.append(entry.body)
            let padding = (512 - entry.body.count % 512) % 512; output.append(Data(repeating: 0, count: padding))
        }
        output.append(Data(repeating: 0, count: 1024)); return output
    }
    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NativeRPCError(code: "fixture", message: "Could not create gzip fixture") }
        defer { deflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = UInt32(data.count)
            var result = Data()
            while true {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let code = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = 64 * 1024
                    return deflate(&stream, Z_FINISH)
                }
                result.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                if code == Z_STREAM_END { return result }
                guard code == Z_OK else { throw NativeRPCError(code: "fixture", message: "Could not finish gzip fixture") }
            }
        }
    }
    static func tarGzip(_ entries: [Entry], corruptChecksum: Bool = false) throws -> Data { try gzip(tar(entries, corruptChecksum: corruptChecksum)) }
    static func pax(_ key: String, _ value: String) -> String {
        let body = " \(key)=\(value)\n"; var count = body.utf8.count + 1
        while String(count).utf8.count + body.utf8.count != count { count = String(count).utf8.count + body.utf8.count }; return String(count) + body
    }
    static func storedZip(name: String, body: Data, attributes: UInt32 = 0, flags: UInt16 = 0) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16)) }
        let nameBytes = Data(name.utf8), size = UInt32(body.count)
        u32(0x04034b50); u16(20); u16(flags); u16(0); u32(0); u32(0); u32(size); u32(size); u16(UInt16(nameBytes.count)); u16(0); data.append(nameBytes); data.append(body)
        let central = UInt32(data.count)
        u32(0x02014b50); u16(20); u16(20); u16(flags); u16(0); u32(0); u32(0); u32(size); u32(size); u16(UInt16(nameBytes.count)); u16(0); u16(0); u16(0); u16(0); u32(attributes); u32(0); data.append(nameBytes)
        let centralSize = UInt32(data.count) - central
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(centralSize); u32(central); u16(0); return data
    }
}
