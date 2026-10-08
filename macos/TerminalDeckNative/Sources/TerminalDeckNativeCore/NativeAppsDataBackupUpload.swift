import Foundation

/// Public backup destination only. Access keys never arrive in saved UI state.
public struct NativeAppsDataBackupUpload: Equatable, Sendable {
    public let endpoint: String
    public let bucket: String
    public let prefix: String
    public init(endpoint: String, bucket: String, prefix: String) {
        self.endpoint = endpoint; self.bucket = bucket; self.prefix = prefix
    }
}

/// Reuses the existing schedule record and adds its public upload destination.
public struct NativeAppsDataBackupSettings: Equatable, Sendable {
    public let schedule: NativeAppsBackupSchedule
    public let upload: NativeAppsDataBackupUpload?
    public init(schedule: NativeAppsBackupSchedule, upload: NativeAppsDataBackupUpload? = nil) {
        self.schedule = schedule; self.upload = upload
    }

    public static func read(_ policy: NativeRPCValue) throws -> Self {
        let allowed: Set<String> = ["enabled", "schedule", "retention", "upload"]
        guard let fields = policy.fields, Set(fields.map(\.key)).count == fields.count,
              Set(fields.map(\.key)).isSubset(of: allowed) else {
            throw NativeRPCError.malformed("The backup policy returned fields outside its public settings.")
        }
        let schedule = try NativeAppsContract.backupSchedule(policy)
        if policy["upload"].isNullish { return .init(schedule: schedule) }
        let value = policy["upload"]
        let uploadAllowed: Set<String> = ["endpoint", "bucket", "prefix"]
        guard let uploadFields = value.fields, Set(uploadFields.map(\.key)).count == uploadFields.count,
              Set(uploadFields.map(\.key)).isSubset(of: uploadAllowed) else {
            throw NativeRPCError.malformed("The backup policy returned credentials instead of a public destination.")
        }
        let endpoint = try value["endpoint"].requireString("backup endpoint", nonempty: true)
        let bucket = try value["bucket"].requireString("backup bucket", nonempty: true)
        let prefix = value["prefix"].string ?? "terminaldeck"
        guard NativeAppsDataBackupUploadDraft.validDestination(endpoint: endpoint, bucket: bucket, prefix: prefix) else {
            throw NativeRPCError.malformed("The server returned an unreadable backup destination.")
        }
        return .init(schedule: schedule, upload: .init(endpoint: endpoint, bucket: bucket, prefix: prefix))
    }
}

/// Credentials exist only while this editor is visible and in the approved
/// write payload. Do not persist this draft or print its fields.
public struct NativeAppsDataBackupUploadDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var endpoint: String
    public var bucket: String
    public var prefix: String
    public var accessKey: String
    public var secretKey: String
    private let savedDestination: NativeAppsDataBackupUpload?

    public init(destination: NativeAppsDataBackupUpload? = nil) {
        savedDestination = destination
        endpoint = destination?.endpoint ?? ""
        bucket = destination?.bucket ?? ""
        prefix = destination?.prefix ?? "terminaldeck"
        accessKey = ""; secretKey = ""
    }

    public var description: String { "Backup upload settings (credentials hidden)" }
    public var debugDescription: String { description }

    public var validationMessage: String? {
        guard Self.validDestination(endpoint: endpoint, bucket: bucket, prefix: prefix) else {
            return "Enter an HTTPS endpoint, a bucket name and a folder using letters, numbers, slashes, hyphens or underscores."
        }
        if keepsSavedCredentials { return nil }
        guard Self.validCredential(accessKey, maximum: 256), Self.validCredential(secretKey, maximum: 4096) else {
            return "Enter both new keys when changing storage, or leave both blank to keep the keys for the same destination."
        }
        return nil
    }

    public mutating func clearCredentials() { accessKey = ""; secretKey = "" }

    public func uploadPayload() throws -> NativeRPCValue {
        guard validationMessage == nil else {
            throw NativeRPCError.invalidArguments(validationMessage ?? "Check your backup upload settings.")
        }
        var fields: [NativeRPCValue.Field] = [
            .init("endpoint", .string(endpoint.trimmingCharacters(in: .whitespacesAndNewlines))),
            .init("bucket", .string(bucket.trimmingCharacters(in: .whitespacesAndNewlines))),
            .init("prefix", .string(prefix))
        ]
        if !keepsSavedCredentials {
            fields.append(.init("accessKey", .string(accessKey)))
            fields.append(.init("secretKey", .string(secretKey)))
        }
        return .object(fields)
    }

    private var keepsSavedCredentials: Bool {
        accessKey.isEmpty && secretKey.isEmpty && savedDestination == NativeAppsDataBackupUpload(
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines), prefix: prefix)
    }

    static func validDestination(endpoint: String, bucket: String, prefix: String) -> Bool {
        guard endpoint.utf8.count <= 512, let url = URLComponents(string: endpoint),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              [endpoint, bucket, prefix].allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") }),
              url.port == nil || (1...65535).contains(url.port!),
              !url.path.split(separator: "/").contains(".."),
              bucket.range(of: #"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil,
              !bucket.contains(".."), !bucket.contains(".-"), !bucket.contains("-."),
              bucket.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) == nil,
              prefix.utf8.count <= 256,
              prefix.isEmpty || prefix.range(of: #"^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil else { return false }
        return true
    }

    private static func validCredential(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum &&
            value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/+_=.-").contains($0) }
    }
}

public enum NativeAppsDataBackupUploadChange: Sendable {
    case replace(NativeAppsDataBackupUploadDraft)
    case remove

    /// Keeps the server's existing timing while changing only the destination.
    /// No silent daily-time reset when a server uses another calendar pattern.
    public func policyPayload(settings: NativeAppsDataBackupSettings) throws -> NativeRPCValue {
        let upload: NativeRPCValue
        switch self {
        case .replace(let draft): upload = try draft.uploadPayload()
        case .remove: upload = .null
        }
        if !settings.schedule.enabled {
            // The server preserves any previous calendar/count. Upload also
            // applies to manual backups while the schedule stays off.
            return .object([.init("enabled", .bool(false)), .init("upload", upload)])
        }
        let schedule: String
        if let calendar = settings.schedule.calendar, !calendar.isEmpty { schedule = calendar }
        else {
            guard settings.schedule.time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else {
                throw NativeRPCError.invalidArguments("Refresh the saved backup schedule before changing its upload destination.")
            }
            schedule = "*-*-* " + settings.schedule.time + ":00"
        }
        guard (1...365).contains(settings.schedule.retentionCount) else {
            throw NativeRPCError.invalidArguments("Keep between 1 and 365 backups.")
        }
        return .object([
            .init("enabled", .bool(true)), .init("schedule", .string(schedule)),
            .init("retention", .number(Double(settings.schedule.retentionCount))), .init("upload", upload)
        ])
    }
}
