import Foundation
import zlib
import TerminalDeckNativeCore

/// Generic ZIP and gzip/tar utility retained from store-archive and the generic
/// reader formerly named browser-extension-unzip. Chrome runtime is retired;
/// archive safety remains required by the community store.
public enum BackendOSStoreArchive {
    public struct File: Equatable, Sendable {
        public let path: String; public let bytes: Data; public let mode: Int
        public init(path: String, bytes: Data, mode: Int = 0) { self.path = path; self.bytes = bytes; self.mode = mode }
    }
    public struct Limits: Equatable, Sendable {
        public let archiveBytes: Int; public let totalBytes: Int; public let files: Int
        public init(archiveBytes: Int, totalBytes: Int, files: Int) { self.archiveBytes = archiveBytes; self.totalBytes = totalBytes; self.files = files }
        public static let small = Self(archiveBytes: 2 * 1024 * 1024, totalBytes: 16 * 1024 * 1024, files: 2_000)
        public static let large = Self(archiveBytes: 32 * 1024 * 1024, totalBytes: 256 * 1024 * 1024, files: 20_000)
    }
    public enum Result: Equatable, Sendable {
        case unpacked([File]), refused(String)
        public var files: [File]? { if case .unpacked(let files) = self { return files }; return nil }
        public var why: String? { if case .refused(let why) = self { return why }; return nil }
    }
    public static func safePath(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf16.count <= 512, !raw.contains("\0"), !raw.contains("\\"), !raw.hasPrefix("/"),
              raw.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else { return nil }
        let parts = raw.components(separatedBy: "/")
        for (index, part) in parts.enumerated() {
            if part == ".." || part == "." || (part.isEmpty && index != parts.count - 1) { return nil }
        }
        return raw
    }
    public static func read(_ data: Data, limits: Limits = .small) -> Result {
        guard data.count <= limits.archiveBytes else { return .refused("this download is larger than this app will unpack") }
        let bytes = Array(data.prefix(4))
        if data.count > 2, bytes[0] == 0x1f, bytes[1] == 0x8b { return readTarGzip(data, limits: limits) }
        if data.count > 4, bytes[0] == 0x50, bytes[1] == 0x4b { return readZip(data, limits: limits) }
        return .refused("this download is not an archive this app can open")
    }
    public static func decompress(_ data: Data, windowBits: Int32, limit: Int) -> Data? {
        guard limit >= 0, data.count <= Int(UInt32.max) else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return data.withUnsafeBytes { input -> Data? in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = UInt32(data.count)
            var result = Data()
            while true {
                var chunk = [UInt8](repeating: 0, count: min(64 * 1024, max(1, limit - result.count + 1)))
                let capacity = chunk.count
                let before = stream.avail_in
                let code: Int32 = chunk.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = UInt32(capacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let written = chunk.count - Int(stream.avail_out)
                guard result.count + written <= limit else { return nil }; result.append(contentsOf: chunk.prefix(written))
                if code == Z_STREAM_END {
                    if windowBits == 31, stream.avail_in > 0 {
                        let remaining = UnsafeBufferPointer(start: stream.next_in, count: Int(stream.avail_in))
                        if remaining.allSatisfy({ $0 == 0 }) { return result }
                        guard remaining.count >= 2, remaining[0] == 0x1f, remaining[1] == 0x8b, inflateReset2(&stream, windowBits) == Z_OK else { return nil }
                        continue
                    }
                    return result
                }
                guard code == Z_OK, written > 0 || stream.avail_in < before else { return nil }
            }
        }
    }
    public static func readTarGzip(_ data: Data, limits: Limits = .small) -> Result {
        guard let tar = decompress(data, windowBits: 31, limit: limits.totalBytes) else { return .refused("this archive could not be unpacked, or it unpacks to more than this app will read") }
        return readTar(tar, limits: limits)
    }
    public static func readTar(_ data: Data, limits: Limits = .small) -> Result {
        let bytes = Array(data); var files: [File] = [], total = 0, at = 0; var pendingName: String?
        while at + 512 <= bytes.count {
            let block = Array(bytes[at..<(at + 512)]); at += 512
            if block.allSatisfy({ $0 == 0 }) { continue }
            guard let stated = octal(block, at: 148, length: 8) else { return .refused("this archive is damaged: one of its file headers does not add up") }
            var unsigned = 0, signed = 0
            for index in 0..<512 { let byte = (148..<156).contains(index) ? 32 : Int(block[index]); unsigned += byte; signed += byte > 127 ? byte - 256 : byte }
            guard stated == unsigned || stated == signed else { return .refused("this archive is damaged: one of its file headers does not add up") }
            guard let size = octal(block, at: 124, length: 12), let mode = octal(block, at: 100, length: 8) else { return .refused("this archive is damaged: a file in it has no readable size") }
            let dataAt = at
            guard size <= bytes.count - dataAt else { return .refused("this archive is cut short: a file in it claims more bytes than are there") }
            at += ((size + 511) / 512) * 512
            let type = block[156] == 0 ? 48 : block[156], body = Data(bytes[dataAt..<(dataAt + size)])
            if type == 120 || type == 103 { if type == 120, let path = paxPath(body) { pendingName = path }; continue }
            if type == 76 { pendingName = String(decoding: body, as: UTF8.self).replacingOccurrences(of: #"\x00+$"#, with: "", options: .regularExpression); continue }
            if type == 49 || type == 50 { return .refused("this archive contains a link, and a link points somewhere this app did not check. Nothing was unpacked.") }
            if [51, 52, 54, 55].contains(type) { return .refused("this archive contains something that is not a file or a folder. Nothing was unpacked.") }
            let prefix = field(block, at: 345, length: 155), name = field(block, at: 0, length: 100)
            let raw = pendingName ?? (prefix.isEmpty ? name : prefix + "/" + name); pendingName = nil
            if type == 53 { continue }
            guard type == 48 else { return .refused("this archive contains something that is not a file or a folder. Nothing was unpacked.") }
            guard let path = safePath(raw), !path.hasSuffix("/") else { return .refused("this archive contains a name this app will not write: " + BackendOSTrace.prefix(raw, limit: 80)) }
            total += size
            guard total <= limits.totalBytes else { return .refused("this archive unpacks to more than this app will read") }
            guard files.count < limits.files else { return .refused("this archive contains more files than this app will read") }
            files.append(File(path: path, bytes: body, mode: mode & 0o7777))
        }
        return files.isEmpty ? .refused("this archive has nothing in it") : .unpacked(files)
    }
    private static func octal(_ bytes: [UInt8], at: Int, length: Int) -> Int? {
        let part = bytes[at..<(at + length)].prefix { $0 != 0 && $0 != 32 }
        let text = String(decoding: part, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard text.range(of: #"^[0-7]+$"#, options: .regularExpression) != nil else { return nil }; return Int(text, radix: 8)
    }
    private static func field(_ bytes: [UInt8], at: Int, length: Int) -> String { String(decoding: bytes[at..<(at + length)].prefix { $0 != 0 }, as: UTF8.self) }
    private static func paxPath(_ data: Data) -> String? {
        let bytes = Array(data); var at = 0; var found: String?
        while at < bytes.count {
            guard let space = bytes[at...].firstIndex(of: 32), let length = Int(String(decoding: bytes[at..<space], as: UTF8.self)),
                  length > 0, length <= bytes.count - at, space + 1 <= at + length else { return found }
            let record = String(decoding: bytes[(space + 1)..<(at + length)], as: UTF8.self).replacingOccurrences(of: #"\n$"#, with: "", options: .regularExpression)
            if record.hasPrefix("path=") { found = String(record.dropFirst(5)) }; at += length
        }
        return found
    }
    public static func readZip(_ data: Data, limits: Limits = .small) -> Result {
        let b = Array(data)
        func little(_ at: Int, _ count: Int) -> Int? {
            guard at >= 0, count > 0, at <= b.count - count else { return nil }; var value: UInt64 = 0
            for index in 0..<count { value |= UInt64(b[at + index]) << (index * 8) }
            guard value <= 9_007_199_254_740_991, value <= UInt64(Int.max) else { return nil }; return Int(value)
        }
        guard b.count >= 22 else { return .refused("it is not a zip archive") }
        var end: Int?
        for at in stride(from: b.count - 22, through: max(0, b.count - 22 - 0xffff), by: -1) { if little(at, 4) == 0x06054b50 { end = at; break } }
        guard let end, var count = little(end + 10, 2), var offset = little(end + 16, 4) else { return .refused("it is not a zip archive") }
        if count == 0xffff || offset == 0xffffffff {
            guard little(end - 20, 4) == 0x07064b50, let end64 = little(end - 12, 8), little(end64, 4) == 0x06064b50,
                  let nextCount = little(end64 + 32, 8), let nextOffset = little(end64 + 48, 8) else { return .refused("it is not a zip archive") }
            count = nextCount; offset = nextOffset
        }
        guard offset >= 0, offset < b.count else { return .refused("it is not a zip archive") }
        if count > limits.files { return .refused("it contains \(count) files, more than this app will unpack") }
        var files: [File] = [], at = offset, total = 0
        for _ in 0..<count {
            guard at <= b.count - 46 else { return .refused("its index is truncated") }
            guard little(at, 4) == 0x02014b50 else { return .refused("its index is damaged") }
            let flags = little(at + 8, 2)!, method = little(at + 10, 2)!, nameLength = little(at + 28, 2)!, extraLength = little(at + 30, 2)!, commentLength = little(at + 32, 2)!, attributes = little(at + 38, 4)!
            var compressed = little(at + 20, 4)!, unpacked = little(at + 24, 4)!, local = little(at + 42, 4)!
            let nameAt = at + 46
            guard nameAt + nameLength + extraLength + commentLength <= b.count else { return .refused("its index is truncated") }
            let name = String(decoding: b[nameAt..<(nameAt + nameLength)], as: UTF8.self)
            if compressed == 0xffffffff || unpacked == 0xffffffff || local == 0xffffffff {
                var extra = nameAt + nameLength; let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let tag = little(extra, 2)!, length = little(extra + 2, 2)!; var field = extra + 4
                    guard length <= extraEnd - field else { return .refused("its index is truncated") }
                    if tag == 1 {
                        if unpacked == 0xffffffff { guard field + 8 <= extraEnd, let value = little(field, 8) else { return .refused("its index is damaged") }; unpacked = value; field += 8 }
                        if compressed == 0xffffffff { guard field + 8 <= extraEnd, let value = little(field, 8) else { return .refused("its index is damaged") }; compressed = value; field += 8 }
                        if local == 0xffffffff { guard field + 8 <= extraEnd, let value = little(field, 8) else { return .refused("its index is damaged") }; local = value }
                        break
                    }; extra += 4 + length
                }
            }
            at = nameAt + nameLength + extraLength + commentLength
            if name.hasSuffix("/") { continue }
            guard let path = safePath(name) else { return .refused("it contains a file this app will not write: " + BackendOSTrace.prefix(name, limit: 80)) }
            if ((attributes >> 16) & 0xf000) == 0xa000 { return .refused("it contains a symbolic link (\(path)), which is not unpacked here") }
            guard method == 0 || method == 8 else { return .refused("\(path) uses a compression method this app cannot read") }
            if flags & 1 != 0 { return .refused("it is encrypted") }
            guard unpacked <= limits.totalBytes - total else { return .refused("it unpacks to more than \(limits.totalBytes) bytes, which this app will not write") }; total += unpacked
            guard local <= b.count - 30 else { return .refused("\(path) points outside the file") }
            guard little(local, 4) == 0x04034b50 else { return .refused("\(path) has a damaged header") }
            let dataAt = local + 30 + little(local + 26, 2)! + little(local + 28, 2)!
            guard dataAt <= b.count, compressed <= b.count - dataAt else { return .refused("\(path) runs past the end of the file") }
            let raw = Data(b[dataAt..<(dataAt + compressed)])
            let bytes: Data
            if method == 0 { bytes = raw }
            else { guard let expanded = decompress(raw, windowBits: -15, limit: limits.totalBytes) else { return .refused("\(path) could not be decompressed") }; bytes = expanded }
            guard bytes.count == unpacked else { return .refused("\(path) is not the size the archive says it is") }
            files.append(File(path: path, bytes: bytes))
        }
        return files.isEmpty ? .refused("it contains no files") : .unpacked(files)
    }
    public static func stripSingleRoot(_ files: [File]) -> [File] {
        guard let first = files.first?.path.components(separatedBy: "/").first, !first.isEmpty,
              files.allSatisfy({ $0.path.hasPrefix(first + "/") }) else { return files }
        return files.map { File(path: String($0.path.dropFirst(first.count + 1)), bytes: $0.bytes, mode: $0.mode) }
    }
    public static func filesUnder(_ files: [File], directory: String) -> [File] {
        if directory.isEmpty || directory == "." { return files }
        let prefix = directory.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression) + "/"
        return files.filter { $0.path.hasPrefix(prefix) }.map { File(path: String($0.path.dropFirst(prefix.count)), bytes: $0.bytes, mode: $0.mode) }
    }
    public static func fileAt(_ files: [File], path: String) -> File? { files.first { $0.path == path } }
}
