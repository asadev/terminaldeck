import Foundation
import Darwin
import Security
import TerminalDeckNativeCore

public struct BackendRemoteHostIdentity: Sendable {
    public let hostSecret: Data
    public let keys: BackendSealedIdentity
    public var hostID: String { BackendRelayPacketCodec.hostID(for: hostSecret) }
    public var fingerprint: String { keys.fingerprint }
    public var publicKey: String { keys.publicKey.base64EncodedString() }
}

enum BackendRemoteTrustStorage {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw NativeRPCError(code: "random", message: "Could not create remote trust randomness") }
        return Data(bytes)
    }
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func base64(_ string: String) -> Data? { Data(base64Encoded: string, options: .ignoreUnknownCharacters) }
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decodeURL(_ text: String) -> Data? {
        guard text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.utf8.count % 4 != 0 { value.append("=") }
        return base64(value)
    }
    static func read(_ file: URL, maximumBytes: Int) throws -> NativeRPCValue? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else {
            throw NativeRPCError(code: "trust-file", message: "The remote trust file is too large")
        }
        return try NativeRPCValue.parseJSON(Data(contentsOf: file), maximumBytes: maximumBytes)
    }
    static func write(_ value: NativeRPCValue, file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = file.path + ".\(getpid()).\(UUID().uuidString).tmp"
        let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw filesystem("create remote trust temporary file") }
        var open = true
        defer { if open { Darwin.close(descriptor) }; Darwin.unlink(temporary) }
        let data = try value.encodedJSON(pretty: true)
        try data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, address.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw filesystem("write remote trust data") }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw filesystem("flush remote trust data") }
        let status = Darwin.close(descriptor); open = false
        guard status == 0, Darwin.rename(temporary, file.path) == 0 else { throw filesystem("replace remote trust atomically") }
    }
    static func quarantine(_ file: URL) throws {
        let target = file.path + ".corrupt-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        guard Darwin.rename(file.path, target) == 0 else { throw filesystem("preserve the unreadable remote trust file") }
    }
    static func identity(directory: URL) throws -> BackendRemoteHostIdentity {
        let file = directory.appendingPathComponent("relay-identity.json")
        let raw: NativeRPCValue?
        do { raw = try read(file, maximumBytes: 65536) }
        catch { try quarantine(file); return try freshIdentity(file) }
        guard let raw else { return try freshIdentity(file) }
        guard let secretText = raw["hostSecret"].string, secretText.utf16.count <= 128,
              let secret = base64(secretText), secret.count == 32,
              let privateText = raw["privateKey"].string, privateText.utf16.count <= 128,
              let privateKey = base64(privateText), privateKey.count == 32,
              let publicText = raw["publicKey"].string, publicText.utf16.count <= 128,
              let publicKey = base64(publicText), publicKey.count == 32 else {
            try quarantine(file); return try freshIdentity(file)
        }
        // Runtime failure is allowed to throw without moving or replacing a
        // potentially good identity. A demonstrated public/private mismatch is
        // the only crypto verdict that causes quarantine.
        let keys = try BackendSealedIdentity(privateKey: privateKey)
        guard equal(keys.publicKey, publicKey) else { try quarantine(file); return try freshIdentity(file) }
        return BackendRemoteHostIdentity(hostSecret: secret, keys: keys)
    }
    private static func freshIdentity(_ file: URL) throws -> BackendRemoteHostIdentity {
        let value = BackendRemoteHostIdentity(hostSecret: try random(32), keys: .generate())
        try write(.object([.init("version", .number(1)), .init("hostSecret", .string(value.hostSecret.base64EncodedString())),
            .init("publicKey", .string(value.keys.publicKey.base64EncodedString())), .init("privateKey", .string(value.keys.privateKey.base64EncodedString()))]), file: file)
        return value
    }
    static func filesystem(_ action: String) -> NativeRPCError { .init(code: "trust-storage", message: "Could not \(action): \(String(cString: strerror(errno)))") }
}

final class BackendRemoteTrustLease: @unchecked Sendable {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent(".native-remote-owner.lock").path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BackendRemoteTrustStorage.filesystem("open remote trust ownership") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw NativeRPCError(code: "trust-owner", message: "Another native remote host owns this trust directory") }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
