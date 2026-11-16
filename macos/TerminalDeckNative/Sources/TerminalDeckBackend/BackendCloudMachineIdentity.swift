import Foundation
import CryptoKit
import IOKit
import SystemConfiguration
import TerminalDeckNativeCore

/// MAC-NEXT-10 (one row per machine): what this Mac tells the Cloud service about itself so the service keeps ONE
/// row per machine and shows its friendly name.
///
/// `machineId` = first 32 hex characters of SHA-256("TD-CLOUD-MACHINE-1\n" + hardware UUID + "\n" + account subject).
/// It survives sign-out, app reinstall and OS updates (the hardware UUID does), differs per Mac and per account, and
/// reveals neither input. The hardware UUID is read on demand, only to compute this; it is never stored, logged or
/// sent. A Mac restored from another device's backup has other hardware, so it gets another id: correct, it is another
/// machine. The pair the service accepted is remembered only as a hash (device id, machine id, name).
public struct BackendCloudMachineFacts: Sendable {
    public let hardwareUUID: @Sendable () -> String?
    public let computerName: @Sendable () -> String
    public let accepted: @Sendable () -> String?
    public let remember: @Sendable (String) -> Void
    /// Empty for the real app. Another copy of the app on the same Mac (a dev copy) names itself here, so its row
    /// never retires the real app's row.
    public let copy: String
    public init(hardwareUUID: @escaping @Sendable () -> String?, computerName: @escaping @Sendable () -> String,
                accepted: @escaping @Sendable () -> String?, remember: @escaping @Sendable (String) -> Void, copy: String = "") {
        self.hardwareUUID = hardwareUUID; self.computerName = computerName; self.accepted = accepted; self.remember = remember; self.copy = copy
    }

    public struct Pair: Sendable, Equatable {
        public let machineId: String; public let displayName: String
        /// MAC-NEXT-11: the host name the Mac recorded for its registrations (its label); nil = not sent.
        public var hostName: String? = nil
        public init(machineId: String, displayName: String, hostName: String? = nil) { self.machineId = machineId; self.displayName = displayName; self.hostName = hostName }
    }

    /// Nil when the hardware id cannot be read (the fields are then simply not sent).
    public func pair(subject: String, hostName: String? = nil) -> Pair? {
        guard let hardware = hardwareUUID(), !subject.isEmpty, let id = Self.machineId(hardwareUUID: hardware, subject: subject, copy: copy) else { return nil }
        return .init(machineId: id, displayName: Self.displayName(computerName()), hostName: hostName.flatMap { $0.isEmpty ? nil : $0 })
    }
    public static func machineId(hardwareUUID: String, subject: String, copy: String = "") -> String? {
        let hardware = hardwareUUID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !hardware.isEmpty, !subject.isEmpty else { return nil }
        let label = copy.isEmpty ? "TD-CLOUD-MACHINE-1" : "TD-CLOUD-MACHINE-1 " + copy
        let digest = SHA256.hash(data: Data((label + "\n" + hardware + "\n" + subject).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }
    /// Trimmed, controls removed, at most 64 characters (UTF-16, as the service counts); "Mac" when nothing is left.
    public static func displayName(_ raw: String) -> String {
        let plain = String(String.UnicodeScalarView(raw.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
        var name = String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        while name.utf16.count > 64 { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }
    /// The remembered mark of one accepted pair for one device registration (no input readable from it).
    public static func mark(deviceId: String, _ pair: Pair) -> String {
        // A pair sent with its host name has another mark than one sent without (ed50f277): such a Mac sends once more.
        let host = pair.hostName.map { "\nhost " + $0 } ?? ""
        return SHA256.hash(data: Data((deviceId + "\n" + pair.machineId + "\n" + pair.displayName + host).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The real Mac: IOPlatformUUID, the Sharing name (System Settings → General → Sharing), the host name without
    /// ".local" as fallback; the accepted mark lives in one small file of this copy's data folder.
    public static func system(markFile: URL, copy: String = "") -> Self {
        .init(hardwareUUID: { platformUUID() }, computerName: { computerName() },
              accepted: { (try? String(contentsOf: markFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) },
              remember: { mark in
                  try? FileManager.default.createDirectory(at: markFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                  try? Data(mark.utf8).write(to: markFile, options: .atomic)
              }, copy: copy)
    }
    /// Which copy of the app this is, for the id's label: empty for the released app on its standard data folder
    /// (`~/Library/Application Support/terminaldeck`), so its id is unchanged. Another app name adds the name; another
    /// data folder adds a hash of its resolved path, so two copies on one Mac never retire each other's row.
    public static func copyName(appName: String, dataRoot: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let standard = resolved(home.appendingPathComponent("Library/Application Support/terminaldeck", isDirectory: true))
        let folder = resolved(dataRoot)
        var parts: [String] = []
        if appName != "Terminal Deck" { parts.append(appName) }
        if folder != standard {
            let hash = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
            parts.append("folder " + String(hash.prefix(16)))
        }
        return parts.joined(separator: " ")
    }
    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty { return local }
        return hostWithoutLocal(ProcessInfo.processInfo.hostName)
    }
    static func hostWithoutLocal(_ host: String) -> String {
        host.lowercased().hasSuffix(".local") ? String(host.dropLast(6)) : host
    }
}

/// The real transport lets a device describe ITSELF (machine id + friendly name) through the rename call.
public protocol BackendCloudDeviceSelfDescription: Sendable {
    func describeOwnDevice(label: String, machineId: String, displayName: String, hostName: String?) async throws -> String?
}
extension CloudSyncTransport: BackendCloudDeviceSelfDescription {}
