import Foundation
import Security
import TerminalDeckNativeCore

/// The earlier (Electron) app sealed `servers/server-credentials.bin` with its own Safe Storage key: Keychain
/// service "<app> Safe Storage", account "<app> Key". The Mac app seals with account "<app>". When the earlier
/// app's data was carried over only the login store was moved to the new key (BackendAccountVaultMigration);
/// the saved server sign-ins never were (13 Nov, the owner's MacBook). This reads the earlier key so the Servers
/// owner can move that one file. It never creates, changes or deletes either Keychain item.
public struct BackendServersEarlierAppKey: Sendable {
    public enum Lookup: Sendable { case key(Data), missing, needsPermission }
    /// Never shows a dialog. `needsPermission`: the item exists but macOS would ask before handing it over.
    public let quiet: @Sendable () -> Lookup
    /// Only from the person's own press on the Servers page: macOS may ask once.
    public let withPermission: @Sendable () throws -> Data
    public init(quiet: @escaping @Sendable () -> Lookup, withPermission: @escaping @Sendable () throws -> Data) {
        self.quiet = quiet; self.withPermission = withPermission
    }
    /// The real app's earlier key. The dev copy gets none (it never reads the real app's Keychain items).
    public static func keychain(appName: String) -> Self? {
        guard appName != BackendDevCopy.name else { return nil }
        let service = appName + " Safe Storage", account = appName + " Key"
        @Sendable func read(_ interaction: Bool) -> (OSStatus, Data?) {
            SecKeychainSetUserInteractionAllowed(interaction)
            defer { SecKeychainSetUserInteractionAllowed(false) }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: interaction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            return (status, found as? Data)
        }
        return .init(quiet: {
            let (status, data) = read(false)
            if status == errSecItemNotFound { return .missing }
            guard status == errSecSuccess, let data, !data.isEmpty else { return .needsPermission }
            return .key(data)
        }, withPermission: {
            let (status, data) = read(true)
            guard status == errSecSuccess, let data, !data.isEmpty else {
                throw NativeRPCError(code: "keychain", message: "macOS did not hand over the earlier app's key (Keychain status \(status)). Nothing was changed.")
            }
            return data
        })
    }
}

/// What the Servers owner knows about saved sign-ins left by the earlier app.
public enum BackendServersEarlierStanding: String, Sendable, Equatable {
    /// Nothing to convert: no file, or this app's key already opens it.
    case clear = "none"
    /// Converted just now; the original is kept beside it as a dated backup.
    case converted
    /// The earlier key is on this Mac but macOS will ask before handing it over: one press on the Servers page.
    case needsOK = "needs-ok"
    /// The earlier key opens the file, but it could not be converted here yet (this copy may not write, or the
    /// new key could not be used). Nothing was changed.
    case notConverted = "not-converted"
    /// Neither this app's key nor the earlier app's key opens the file.
    case keyGone = "key-gone"

    public static let notConvertedSentence = "Saved server sign-ins from the earlier app have not been converted on this Mac yet."
    public static let keyGoneSentence = "The key that opens this Mac's saved server sign-ins is gone."
    public var pending: Bool { self == .needsOK || self == .notConverted }
    /// The line for the Servers page; nil when there is nothing to say.
    public var sentence: String? {
        switch self {
        case .clear, .converted: return nil
        case .needsOK: return Self.notConvertedSentence + " Choose Convert saved sign-ins; if your Mac asks, allow it."
        case .notConverted: return Self.notConvertedSentence + " Nothing was changed. Try again in a moment."
        case .keyGone: return Self.keyGoneSentence + " Nothing was changed or deleted."
        }
    }
    public var wireValue: NativeRPCValue {
        .object([.init("state", .string(rawValue)), .init("sentence", sentence.map(NativeRPCValue.string) ?? .null),
                 .init("canConvert", .bool(pending))])
    }
}

/// Pure file move with injected keys. Plaintext stays in memory; nothing secret is logged or returned.
enum BackendServersEarlierAppMigration {
    static let maximum = 4 * 1024 * 1024
    static let backupMarker = ".before-key-move-"
    enum Result: Equatable { case notNeeded, converted(URL), oldKeyCannotOpen }
    /// Opens `file` with the earlier key and seals it again with `cipher`, after keeping the exact original bytes
    /// beside it (`<name>.before-key-move-<date>`). The file is replaced atomically only after the new blob is
    /// proven to open. A file the current key opens is left alone, so a second run changes nothing.
    static func convert(file: URL, earlierKey: Data, cipher: BackendBrowserPasswordsCipher, now: Date = Date()) throws -> Result {
        guard let before = try BackendAccountFiles.boundedRead(file, maximum: maximum),
              let blob = Data(base64Encoded: String(decoding: before, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return .notNeeded }
        if (try? cipher.decrypt(blob)) != nil { return .notNeeded }
        guard let plain = try? ChromiumSafeStorageCipher.decrypt(blob, password: earlierKey),
              let raw = try? NativeRPCValue.parseJSON(Data(plain.utf8), maximumBytes: maximum),
              raw["version"].number == 1, raw["entries"].elements != nil else { return .oldKeyCannotOpen }
        guard try cipher.available() else { throw NativeRPCError(code: "unavailable", message: BackendServersCredentials.noSecureStore) }
        let sealed = try cipher.encrypt(plain, true)
        guard try cipher.decrypt(sealed) == plain else { throw NativeRPCError(code: "checksum", message: "The converted sign-ins did not read back. Nothing was changed.") }
        let replacement = Data(sealed.base64EncodedString().utf8)
        let backup = try keepBackup(before, of: file, now: now)
        guard try BackendAccountFiles.boundedRead(file, maximum: maximum) == before else {
            throw NativeRPCError(code: "changed", message: "The saved sign-ins changed while they were being converted. Nothing was changed.")
        }
        try BackendRemoteServeSecretFile.write(directory: file.deletingLastPathComponent(), file: file, contents: replacement)
        return .converted(backup)
    }
    /// A new owner-only file that is never overwritten; its bytes are read back before anything else happens.
    private static func keepBackup(_ bytes: Data, of file: URL, now: Date) throws -> URL {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate, .withTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "")
        let folder = file.deletingLastPathComponent()
        for attempt in 0..<100 {
            let copy = folder.appendingPathComponent(file.lastPathComponent + backupMarker + stamp + (attempt == 0 ? "" : "-\(attempt)"))
            let fd = Darwin.open(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 { if errno == EEXIST { continue }; break }
            let written = bytes.withUnsafeBytes { buffer -> Bool in
                var done = 0
                while done < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    done += count
                }
                return Darwin.fsync(fd) == 0
            }
            let closed = Darwin.close(fd) == 0
            guard written, closed, (try? Data(contentsOf: copy)) == bytes else { Darwin.unlink(copy.path); break }
            return copy
        }
        throw NativeRPCError(code: "backup", message: "A copy of the saved sign-ins could not be kept, so nothing was converted.")
    }
}
