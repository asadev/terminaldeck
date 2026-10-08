import Foundation

/// This describes available screens and actions, not approval to change a server.
public struct NativeAppsCapabilities: Equatable, Sendable {
    public let available: Bool
    public let features: Set<String>
    public var canChange: Bool { available && features.contains("apps:transaction-recovery") }

    /// Fixed copy only; raw server reasons may contain execution output.
    public var unavailableMessage: String? {
        if !available { return "App controls are not connected to this server." }
        if !canChange { return "Changes are turned off because the server cannot safely undo an interrupted change." }
        return nil
    }

    public init(available: Bool = false, features: Set<String> = []) {
        self.available = available
        self.features = features
    }
}

/// Values used by the simple Apps screens. Server replies are mapped into these
/// values by the UI transport layer; they do not store environment values.
public struct NativeAppsSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var status: String
    public var address: String?

    public init(id: String, name: String, kind: String, status: String, address: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.address = address
    }
}

public struct NativeAppsDetail: Equatable, Sendable, Identifiable {
    public var app: NativeAppsSummary
    public var source: String
    public var branch: String?
    public var port: Int?
    public var updatedAt: String?
    public var environment: [NativeAppsEnvironmentKey]
    public var deployments: [NativeAppsDeployment]
    public var addresses: [NativeAppsAddress]
    public var backups: [NativeAppsBackup]
    public var backupSchedule: NativeAppsBackupSchedule?
    public var id: String { app.id }

    public init(app: NativeAppsSummary, source: String, branch: String? = nil, port: Int? = nil,
                updatedAt: String? = nil, environment: [NativeAppsEnvironmentKey] = [],
                deployments: [NativeAppsDeployment] = [], addresses: [NativeAppsAddress] = [],
                backups: [NativeAppsBackup] = [], backupSchedule: NativeAppsBackupSchedule? = nil) {
        self.app = app
        self.source = source
        self.branch = branch
        self.port = port
        self.updatedAt = updatedAt
        self.environment = environment
        self.deployments = deployments
        self.addresses = addresses
        self.backups = backups
        self.backupSchedule = backupSchedule
    }
}

/// Only the key and its secret marker are shown; values stay out of UI state.
public struct NativeAppsEnvironmentKey: Equatable, Sendable, Identifiable {
    public var key: String
    public var isSecret: Bool
    public var id: String { key }

    public init(key: String, isSecret: Bool) {
        self.key = key
        self.isSecret = isSecret
    }
}

public struct NativeAppsDeployment: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var status: String
    public var createdAt: String?
    public var canRollback: Bool

    public init(id: String, title: String, status: String, createdAt: String? = nil, canRollback: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.canRollback = canRollback
    }
}

public struct NativeAppsAddress: Equatable, Sendable, Identifiable {
    public var hostname: String
    public var isPrimary: Bool
    public var isDefault: Bool
    public var dnsReady: Bool?
    public var httpsReady: Bool?
    public var expectedAddress: String?
    public var instructions: String?
    public var id: String { hostname }

    public init(hostname: String, isPrimary: Bool = false, dnsReady: Bool? = nil, httpsReady: Bool? = nil,
                expectedAddress: String? = nil, instructions: String? = nil, isDefault: Bool = false) {
        self.hostname = hostname
        self.isPrimary = isPrimary
        self.isDefault = isDefault
        self.dnsReady = dnsReady
        self.httpsReady = httpsReady
        self.expectedAddress = expectedAddress
        self.instructions = instructions
    }
}

public struct NativeAppsBackup: Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: String?
    public var size: String?

    public init(id: String, createdAt: String? = nil, size: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.size = size
    }
}

public struct NativeAppsBackupSchedule: Equatable, Sendable {
    public var enabled: Bool
    public var time: String
    public var retentionCount: Int
    public var calendar: String?

    public init(enabled: Bool = false, time: String = "02:00", retentionCount: Int = 7, calendar: String? = nil) {
        self.enabled = enabled
        self.time = time
        self.retentionCount = retentionCount
        self.calendar = calendar
    }
}

public struct NativeAppsRepository: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var defaultBranch: String

    public init(id: String, name: String, url: String, defaultBranch: String) {
        self.id = id
        self.name = name
        self.url = url
        self.defaultBranch = defaultBranch
    }
}

public struct NativeAppsTemplate: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var category: String
    public var credit: String?
    public var license: String?
    public var sourceURL: String?
    public var applicationLicense: String?
    public var applicationSourceURL: String?

    public init(id: String, name: String, description: String, category: String,
                credit: String? = nil, license: String? = nil, sourceURL: String? = nil,
                applicationLicense: String? = nil, applicationSourceURL: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.credit = credit
        self.license = license
        self.sourceURL = sourceURL
        self.applicationLicense = applicationLicense
        self.applicationSourceURL = applicationSourceURL
    }
}

public enum NativeAppsTab: String, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case overview, deploys, logs, settings, address, backups

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .deploys: "Deploys"
        case .logs: "Logs"
        case .settings: "Settings"
        case .address: "Address"
        case .backups: "Backups"
        }
    }
}

public enum NativeAppsRules {
    /// Bind connection help to this app in the two declared fleet namespaces.
    /// Other prefixes need a checked app ID in the server's public reply first.
    public static func databaseHostMatches(host: String, appID: String) -> Bool {
        guard appID.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil else { return false }
        if host == "terminaldeck-" + appID { return true }
        return appID.hasPrefix("td-test-") && host == "td-test-" + appID
    }

    /// These values initialize a database's saved data. Changing only its
    /// environment cannot safely change the running database's login.
    public static func isDatabaseLoginKey(kind: String, key: String) -> Bool {
        switch kind {
        case "postgres": ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"].contains(key)
        case "mysql": ["MYSQL_ROOT_PASSWORD", "MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_DATABASE"].contains(key)
        case "redis": key == "REDIS_PASSWORD"
        case "mongodb": ["MONGO_INITDB_ROOT_USERNAME", "MONGO_INITDB_ROOT_PASSWORD", "MONGO_INITDB_DATABASE"].contains(key)
        default: false
        }
    }

    /// The server's reason selects fixed copy; it is never displayed verbatim.
    public static func logEndMessage(_ reason: String) -> String {
        switch reason {
        case "closed": "Live logs stopped."
        case "eof": "The app’s log stream ended. Open Logs again to reconnect."
        case "error": "Live logs stopped after a connection error. Try again."
        case "overflow": "Live logs stopped because too much output arrived. Open Logs again to continue."
        default: "Live logs stopped. Try again."
        }
    }

    /// App links can open a web page, but cannot launch another app or carry credentials.
    public static func safeAddress(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    /// Destructive confirmation is exact: spaces and letter case are significant.
    public static func matchesConfirmation(typed: String, name: String) -> Bool {
        !name.isEmpty && typed == name
    }

    /// A public DNS name, without a scheme, path, port, or wildcard.
    public static func validHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        let lowercased = value.lowercased()
        guard labels.count >= 2,
              labels.last?.unicodeScalars.contains(where: isASCIILetter) == true,
              !lowercased.hasSuffix(".localhost"), !lowercased.hasSuffix(".local"),
              !lowercased.hasSuffix(".internal") else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  let first = label.unicodeScalars.first, let last = label.unicodeScalars.last,
                  isASCIILetterOrDigit(first), isASCIILetterOrDigit(last) else { return false }
            return label.unicodeScalars.allSatisfy { isASCIILetterOrDigit($0) || $0.value == 45 }
        }
    }

    /// POSIX environment names use ASCII letters or an underscore first, then digits too.
    public static func validEnvironmentKey(_ value: String) -> Bool {
        guard value.utf8.count <= 128, let first = value.unicodeScalars.first,
              isASCIILetter(first) || first.value == 95 else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy { isASCIILetterOrDigit($0) || $0.value == 95 }
    }

    public static func friendlyStatus(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running", "healthy", "ready", "live": "Running"
        case "unhealthy", "failed", "error": "Needs attention"
        case "stopped", "exited": "Stopped"
        case "starting", "restarting": "Starting"
        case "deploying": "Deploying"
        case "building": "Building"
        case "queued", "pending": "Waiting"
        case "created": "Ready to deploy"
        case "paused": "Paused"
        case "succeeded", "success", "complete", "completed": "Complete"
        case "cancelled", "canceled": "Cancelled"
        default: "Unknown"
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (48...57).contains(scalar.value)
    }
}
