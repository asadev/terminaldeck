import Foundation
import TerminalDeckNativeCore

public struct BackendServersKeyFileOffer: Codable, Equatable, Sendable {
    public var path: String, name: String, what: String
    public var locked: Bool?
    public var wireValue: NativeRPCValue { .object([.init("path", .string(path)), .init("name", .string(name)), .init("what", .string(what)), .init("locked", locked.map(NativeRPCValue.bool) ?? .null)]) }
}
public struct BackendServersKeyFolderReader: Sendable {
    public let entries: @Sendable (String) throws -> [String]
    public let read: @Sendable (String) throws -> String
    public let size: @Sendable (String) throws -> Int
    public init(entries: @escaping @Sendable (String) throws -> [String], read: @escaping @Sendable (String) throws -> String, size: @escaping @Sendable (String) throws -> Int) { self.entries = entries; self.read = read; self.size = size }
    public static let filesystem = Self(entries: { try FileManager.default.contentsOfDirectory(atPath: $0) },
        read: { try String(contentsOfFile: $0, encoding: .utf8) }, size: { let attr = try FileManager.default.attributesOfItem(atPath: $0); return (attr[.size] as? NSNumber)?.intValue ?? Int.max })
}
public enum BackendServersKeyfiles {
    public static let maximumBytes = 64 * 1024
    public static func describeKey(_ text: String, name: String) -> BackendServersKeyFileOffer? {
        let value = text.drop(while: \.isWhitespace)
        let heads: [(String, String, Bool?)] = [
            ("OPENSSH PRIVATE KEY", "A key made by OpenSSH", nil), ("RSA PRIVATE KEY", "An RSA key", false),
            ("DSA PRIVATE KEY", "A DSA key", false), ("EC PRIVATE KEY", "An elliptic-curve key", false),
            ("PRIVATE KEY", "A key", false), ("ENCRYPTED PRIVATE KEY", "A key, with a password on it", true)]
        guard let found = heads.first(where: { value.hasPrefix("-----BEGIN \($0.0)-----") }) else { return nil }
        let pemLocked = String(value.prefix(400)).range(of: #"(?m)^Proc-Type:\s*4,ENCRYPTED"#, options: .regularExpression) != nil
        return .init(path: "", name: name, what: found.1, locked: found.2.map { $0 || pemLocked } ?? opensshLocked(String(value)))
    }
    public static func opensshLocked(_ text: String) -> Bool? {
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let raw = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        let magic = Data("openssh-key-v1\0".utf8), at = magic.count
        guard raw.starts(with: magic), raw.count >= at + 4 else { return nil }
        let count = raw[at..<(at + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 64, raw.count >= at + 4 + Int(count) else { return nil }
        return String(decoding: raw[(at + 4)..<(at + 4 + Int(count))], as: UTF8.self) != "none"
    }
    public static func listKeyFiles(_ directory: URL, reader: BackendServersKeyFolderReader = .filesystem) -> [BackendServersKeyFileOffer] {
        guard let names = try? reader.entries(directory.path) else { return [] }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard !name.hasSuffix(".pub"), !name.hasPrefix(".") else { return nil }
            let file = directory.appendingPathComponent(name).path
            guard let count = try? reader.size(file), count <= maximumBytes, let text = try? reader.read(file), var offer = describeKey(text, name: name) else { return nil }
            offer.path = file; return offer
        }
    }
}
/// Only paths offered by native code enter this set. Key roots are explicit;
/// there is no implicit home-directory walk or SSH config/agent lookup.
public final class BackendServersKeyFileOffers: @unchecked Sendable {
    private let keyRoot: URL, reader: BackendServersKeyFolderReader
    private let lock = NSLock(); private var allowed: Set<String> = []
    public init(keyRoot: URL, reader: BackendServersKeyFolderReader = .filesystem) { self.keyRoot = keyRoot; self.reader = reader }
    public func list() -> [BackendServersKeyFileOffer] {
        let offers = BackendServersKeyfiles.listKeyFiles(keyRoot, reader: reader)
        lock.withLock { allowed.formUnion(offers.map(\.path)) }; return offers
    }
    /// Call from the native panel's completion, never with a renderer claim that
    /// it selected a file. Selection authority belongs to the facade.
    public func chose(_ path: String) -> BackendServersKeyFileOffer? {
        guard let size = try? reader.size(path), size <= BackendServersKeyfiles.maximumBytes, let text = try? reader.read(path),
              var offer = BackendServersKeyfiles.describeKey(text, name: URL(fileURLWithPath: path).lastPathComponent) else { return nil }
        offer.path = path; lock.withLock { allowed.insert(path) }; return offer
    }
    public func read(_ path: String) -> NativeRPCValue {
        guard lock.withLock({ allowed.contains(path) }) else { return .object([.init("ok", .bool(false)), .init("sentence", .string("That file was not one this app offered, so it has not been read."))]) }
        guard let size = try? reader.size(path), size <= BackendServersKeyfiles.maximumBytes, let text = try? reader.read(path) else {
            return .object([.init("ok", .bool(false)), .init("sentence", .string("That file could not be read. Check that it is still where it was."))])
        }
        guard BackendServersKeyfiles.describeKey(text, name: URL(fileURLWithPath: path).lastPathComponent) != nil else {
            return .object([.init("ok", .bool(false)), .init("sentence", .string("That file is not a key. Choose the private key file, not the one ending in .pub."))])
        }
        return .object([.init("ok", .bool(true)), .init("key", .string(text))])
    }
}
