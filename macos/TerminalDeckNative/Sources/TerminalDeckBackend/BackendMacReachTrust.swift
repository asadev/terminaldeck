import Darwin
import Foundation
import TerminalDeckNativeCore

/// Boot uses the existing pairing identity and current grants. Re-read the person's files on every takeover, so a
/// revocation is never undone by a stale copied roster. Only fixed filenames are read, with no symlinks or root writes.
public enum BackendMacReachTrust {
    public struct Counts: Sendable { public let controllers: Int; public let phones: Int }
    public static let files = ["relay-identity.json", "remote-auth.json", "remote-device-kinds.json", "remote-access.json"]
    public static func stage(from source: URL, owner: uid_t, to target: URL) throws -> Counts {
        let directory = Darwin.open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw refused }
        defer { Darwin.close(directory) }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0, metadata.st_uid == owner else { throw refused }
        var values: [String: NativeRPCValue] = [:]
        for name in files {
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT, name != files[0], name != files[1] { values[name] = .object([]); continue }
            guard fd >= 0 else { throw refused }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard fstat(fd, &metadata) == 0, metadata.st_uid == owner,
                  metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
                  metadata.st_size > 0, metadata.st_size <= 1_048_576,
                  let data = try handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { throw refused }
            values[name] = try NativeRPCValue.parseJSON(data, maximumBytes: 1_048_576)
        }
        let identity = values[files[0]] ?? .null
        guard let secret = identity["hostSecret"].string.flatMap({ Data(base64Encoded: $0) }), secret.count == 32,
              let key = identity["privateKey"].string.flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              let publicKey = identity["publicKey"].string.flatMap({ Data(base64Encoded: $0) }),
              try BackendSealedIdentity(privateKey: key).publicKey == publicKey else { throw refused }
        let filtered = eligible(auth: values[files[1]] ?? .null, kinds: values[files[2]] ?? .null, access: values[files[3]] ?? .null)
        for name in files {
            let value = name == files[1] ? NativeRPCValue.object([.init("version", .number(1)), .init("devices", .array(filtered))]) : values[name] ?? .null
            try BackendRemoteTrustStorage.write(value, file: target.appendingPathComponent(name))
        }
        let auth = values[files[1]] ?? .null, access = values[files[3]] ?? .null
        let phones = (auth["devices"].elements ?? []).filter { device in
            guard let id = device["id"].string, device["approved"].bool == true, device["revoked"].bool != true else { return false }
            return access["devices"][id].string != nil || ["ios", "android"].contains(device["platform"].string ?? "")
        }.count
        return Counts(controllers: filtered.count, phones: phones)
    }
    public static func eligible(auth: NativeRPCValue, kinds: NativeRPCValue, access: NativeRPCValue) -> [NativeRPCValue] {
        (auth["devices"].elements ?? []).prefix(64).filter { device in
            guard let id = device["id"].string, device["revoked"].bool != true else { return false }
            return MacReach.mayControl(kind: kinds["devices"][id]["kind"].string ?? "guest", access: access["devices"][id].string,
                                       approved: device["approved"].bool == true)
        }
    }
    private static var refused: NativeRPCError { .init(code: "reach-trust", message: "The Mac access helper could not confirm this Mac's current device approvals.") }
}

extension BackendMacReachTrust {
    /// The file is the current source of truth, including an Off written just before the app stopped. Missing keys
    /// retain the product defaults; an unreadable existing file fails closed. The root helper never writes here.
    public static func screenAllowed(trustDirectory: URL, owner: uid_t) -> Bool {
        let file = trustDirectory.deletingLastPathComponent().appendingPathComponent("settings.json")
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == owner, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= 4_194_304,
              let data = try? handle.read(upToCount: 4_194_305), data.count <= 4_194_304,
              let raw = try? NativeRPCValue.parseJSON(data, maximumBytes: 4_194_304) else { return false }
        let values = raw["values"].fields != nil ? raw["values"] : raw
        return values["remote.macScreenAllowed"].bool ?? true
    }
}
