import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

public enum BackendPluginsFiles {
    public struct Limits: Sendable, Hashable {
        public let maxFiles, maxBytes, maxDepth: Int
        public init(maxFiles: Int = 5000, maxBytes: Int = 64 * 1024 * 1024, maxDepth: Int = 24) {
            self.maxFiles = maxFiles; self.maxBytes = maxBytes; self.maxDepth = maxDepth
        }
    }
    public struct Hash: Sendable { public let hash: String; public let files, bytes: Int }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func hash(_ dir: URL, limits: Limits = .init()) throws -> Hash {
        var entries: [(String, Int, String)] = [], total = 0
        func walk(_ folder: URL, relative: String, depth: Int) throws {
            guard depth <= limits.maxDepth else { throw BackendPluginsManifestReader.refusal("it is nested more than \(limits.maxDepth) folders deep") }
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
                let file = folder.appendingPathComponent(name), path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(file.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: throw BackendPluginsManifestReader.refusal("\(path) is a link, and a plugin’s files must be its own")
                case S_IFDIR: try walk(file, relative: path, depth: depth + 1)
                case S_IFREG:
                    guard entries.count + 1 <= limits.maxFiles else { throw BackendPluginsManifestReader.refusal("it has more than \(limits.maxFiles) files") }
                    total += Int(info.st_size)
                    guard total <= limits.maxBytes else { throw BackendPluginsManifestReader.refusal("it is larger than \(Int((Double(limits.maxBytes) / 1_048_576).rounded())) MB") }
                    entries.append((path, Int(info.st_size), digest(try Data(contentsOf: file))))
                default: throw BackendPluginsManifestReader.refusal("\(path) is not an ordinary file")
                }
            }
        }
        do { try walk(dir, relative: "", depth: 0) }
        catch let error as NativeRPCError { throw error }
        catch { throw BackendPluginsManifestReader.refusal("its files could not be read (\(error.localizedDescription))") }
        let body = entries.map { "\($0.0)\0\($0.1)\0\($0.2)\n" }.joined()
        return Hash(hash: digest(Data(body.utf8)), files: entries.count, bytes: total)
    }
    /// Actor-owned cache: metadata includes ctime and inode, so replacing a file or
    /// restoring its old size/mtime cannot keep a previously granted content hash.
    struct HashCache {
        private struct Key: Hashable { let path: String; let limits: Limits }
        private var values: [Key: (stamp: String, value: Hash)] = [:]
        private let read: (URL, Limits) throws -> Hash
        init(read: @escaping (URL, Limits) throws -> Hash = { try BackendPluginsFiles.hash($0, limits: $1) }) { self.read = read }
        mutating func hash(_ dir: URL, limits: Limits) throws -> Hash {
            let key = Key(path: dir.standardizedFileURL.path, limits: limits)
            let before = try BackendPluginsFiles.fingerprint(dir, limits: limits)
            if let cached = values[key], cached.stamp == before { return cached.value }
            let value = try read(dir, limits)
            guard try BackendPluginsFiles.fingerprint(dir, limits: limits) == before else {
                values[key] = nil
                throw BackendPluginsManifestReader.refusal("its files changed while they were being verified")
            }
            values[key] = (before, value)
            return value
        }
    }
    private static func fingerprint(_ dir: URL, limits: Limits) throws -> String {
        var rows: [String] = [], files = 0, bytes = 0
        func walk(_ file: URL, relative: String, depth: Int) throws {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { throw BackendPluginsManifestReader.refusal("\(relative) is not an ordinary file or folder") }
            rows.append("\(relative)\0\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\n")
            if kind == S_IFDIR {
                guard depth <= limits.maxDepth else { throw BackendPluginsManifestReader.refusal("it is nested more than \(limits.maxDepth) folders deep") }
                for name in try FileManager.default.contentsOfDirectory(atPath: file.path).sorted() {
                    let path = relative.isEmpty ? name : relative + "/" + name
                    try walk(file.appendingPathComponent(name), relative: path, depth: depth + 1)
                }
            } else {
                files += 1; bytes += Int(info.st_size)
                guard files <= limits.maxFiles, bytes <= limits.maxBytes else { throw BackendPluginsManifestReader.refusal("its files exceed the plugin verification limits") }
            }
        }
        try walk(dir, relative: "", depth: 0)
        return digest(Data(rows.joined().utf8))
    }
    /// realpath form (plugins/files.ts realpathSync): what Seatbelt matches; Foundation would strip /private.
    public static func real(_ path: String) -> String { BackendMacConfinement.kernelPath(path) }
}

/// Access only through BackendPluginsHost, so the native settings window remains the grant owner.
final class BackendPluginsGrants {
    private let file: URL
    private var records = NativeRPCValue.object([])
    init(userData: URL) {
        file = userData.appendingPathComponent("plugin-grants.json")
        if let data = try? Data(contentsOf: file), let value = try? NativeRPCValue.parseJSON(data), value["format"].number == 1, value["plugins"].fields != nil {
            for field in value["plugins"].fields ?? [] where field.value.fields != nil {
                records = records.setting(field.key, .object([.init("enabled", .bool(field.value["enabled"].bool == true)), .init("grant", readGrant(field.value["grant"]))]))
            }
        }
    }
    private func readGrant(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let hash = value["hash"].string, BackendPluginsManifestReader.matches(hash, "^[0-9a-f]{64}$") else { return .null }
        return .object([.init("hash", .string(hash)), .init("capabilities", .array((value["capabilities"].elements ?? []).filter { PluginCatalog.capabilities.contains($0.string ?? "") })), .init("projects", .array((value["projects"].elements ?? []).filter { $0.string != nil })), .init("grantedAt", .number(value["grantedAt"].number ?? 0))])
    }
    func record(_ id: String) -> NativeRPCValue {
        records[id].fields == nil ? .object([.init("enabled", .bool(false)), .init("grant", .null)]) : records[id]
    }
    func valid(_ id: String, hash: String?) -> NativeRPCValue? {
        guard let hash, record(id)["grant"]["hash"].string == hash else { return nil }
        return record(id)["grant"]
    }
    private func save() throws {
        let value = NativeRPCValue.object([.init("format", .number(1)), .init("plugins", records)])
        var data = try value.encodedJSON(pretty: true); data.append(10)
        try BackendAccountFiles.writeAtomic(data, to: file)
    }
    func enabled(_ id: String, _ enabled: Bool) throws { records = records.setting(id, record(id).setting("enabled", .bool(enabled))); try save() }
    func grant(_ id: String, _ value: NativeRPCValue, enabled: Bool) throws {
        records = records.setting(id, .object([.init("enabled", .bool(enabled)), .init("grant", value)])); try save()
    }
    func forget(_ id: String) throws {
        guard records.has(id) else { return }; records = records.removing(id)
        if records.fields?.isEmpty == true { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
        else { try save() }
    }
}

public enum BackendPluginsSandbox {
    public static let confinement = "Each plugin runs in a sandbox the Mac enforces: it can read only its own folder, write only its own data folder, and has no network. It can reach your work only through what you allow here."
    public static func runtimeRoot(_ runtime: String) -> String {
        let real = BackendPluginsFiles.real(runtime), parts = real.components(separatedBy: "/")
        if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }), index > 0 { return parts.prefix(index + 1).joined(separator: "/") }
        return URL(fileURLWithPath: real).deletingLastPathComponent().deletingLastPathComponent().path
    }
    public static func command(runtime: String, main: String, folder: String, data: String) -> (String, [String]) {
        let data = BackendPluginsFiles.real(data)
        let plan = BackendMacConfinement.Plan(folder: data, home: data, writable: [data], readable: BackendMacConfinement.systemReadRoots + [runtimeRoot(runtime), BackendPluginsFiles.real(folder)], readableFiles: [], readOnlyProjects: [])
        let profile = BackendMacConfinement.profile(plan) + "\n; A plugin has no network: its reach is the list it was allowed.\n(deny network*)\n"
        return ("/usr/bin/sandbox-exec", ["-p", profile, runtime, main])
    }
    public static func environment(home: String, parent: [String: String]) -> [String: String] {
        var env = ["HOME": home, "TMPDIR": home + "/tmp", "ELECTRON_RUN_AS_NODE": "1", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = parent[key], BackendPluginsManifestReader.matches(value, #"^[A-Za-z]{1,8}(?:_[A-Za-z]{1,8})?(?:\.[A-Za-z0-9-]{1,16})?(?:@[A-Za-z0-9]{1,16})?$"#) { env[key] = value }
        }
        return env.filter { !BackendPluginsManifestReader.matches($0.key, #"(?i)TOKEN|SECRET|PASSW|API_?KEY|ACCESS_?KEY|PRIVATE|CREDENTIAL|COOKIE|SESSION|AUTH|ANTHROPIC|OPENAI|GITHUB|^GH_|CLAUDE|CODEX|GEMINI|TERMINALDECK|^AWS_|^AZURE_|^GOOGLE_|NPM_CONFIG|NODE_OPTIONS"#) }
    }
}
