import Foundation
import TerminalDeckNativeCore

/// Copying dropped files into a container (what `docker cp` does): plain files
/// only, packed into one in-memory tar and sent with Docker's archive API into
/// the container's working directory. Existing files are never overwritten.
public enum BackendDockerUpload {
    public static let maximumFiles = 20
    public static let maximumBytes = 32 * 1_024 * 1_024
    public struct File: Sendable, Equatable {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }

    /// One plain file name: no folders, no hidden-path tricks, fits a tar header.
    public static func validName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return (1...100).contains(bytes.count) && name != "." && name != ".." && !name.contains("/") &&
            !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    /// files: [{name, data: base64}] exactly as the channel and MCP tool receive them.
    public static func files(_ value: NativeRPCValue) throws -> [File] {
        guard let rows = value.elements, !rows.isEmpty, rows.count <= maximumFiles else {
            throw NativeRPCError.invalidArguments("Choose 1 to \(maximumFiles) files to copy into the container.")
        }
        var output: [File] = [], names: Set<String> = [], total = 0
        for row in rows {
            guard let fields = row.fields, Set(fields.map(\.key)).isSubset(of: ["name", "data"]),
                  let name = row["name"].string, validName(name), names.insert(name).inserted else {
                throw NativeRPCError.invalidArguments("Each file needs its own plain name, without folders.")
            }
            guard let encoded = row["data"].string, let data = Data(base64Encoded: encoded) else {
                throw NativeRPCError.invalidArguments("Each file's contents must be base64.")
            }
            total += data.count
            guard total <= maximumBytes else { throw NativeRPCError.invalidArguments("Files copied into a container can add up to 32 MB at a time.") }
            output.append(.init(name: name, data: data))
        }
        return output
    }

    /// POSIX ustar: one 512-byte header per file, contents padded to 512, two
    /// empty blocks at the end. Regular files, mode 0644, owned by root.
    public static func tar(_ files: [File], modified: Date = Date()) -> Data {
        var archive = Data()
        let mtime = max(0, Int(modified.timeIntervalSince1970))
        for file in files {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int, length: Int) {
                let bytes = Array(text.utf8.prefix(length))
                for (index, byte) in bytes.enumerated() { header[offset + index] = byte }
            }
            func octal(_ value: Int, at offset: Int, length: Int) {
                put(String(String(value, radix: 8).suffix(length - 1)).leftPadded(to: length - 1), at: offset, length: length - 1)
            }
            put(file.name, at: 0, length: 100)
            octal(0o644, at: 100, length: 8); octal(0, at: 108, length: 8); octal(0, at: 116, length: 8)
            octal(file.data.count, at: 124, length: 12); octal(mtime, at: 136, length: 12)
            for index in 148..<156 { header[index] = 0x20 }
            header[156] = UInt8(ascii: "0")
            put("ustar", at: 257, length: 6); put("00", at: 263, length: 2)
            put("root", at: 265, length: 32); put("root", at: 297, length: 32)
            let sum = header.reduce(0) { $0 + Int($1) }
            put(String(String(sum, radix: 8)).leftPadded(to: 6), at: 148, length: 6)
            header[154] = 0; header[155] = 0x20
            archive.append(contentsOf: header)
            archive.append(file.data)
            let pad = (512 - file.data.count % 512) % 512
            if pad > 0 { archive.append(Data(repeating: 0, count: pad)) }
        }
        archive.append(Data(repeating: 0, count: 1_024))
        return archive
    }

    public static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { count >= length ? self : String(repeating: "0", count: length - count) + self }
}
