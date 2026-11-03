import Foundation

/// Apps contract v1 mapped to UI-only records. No environment values are retained.
public enum NativeAppsContract {
    public static func capabilities(_ value: NativeRPCValue) throws -> NativeAppsCapabilities {
        let allowed: Set<String> = ["available", "features", "unavailableReason"]
        guard let fields = value.fields, Set(fields.map(\.key)).count == fields.count,
              Set(fields.map(\.key)).isSubset(of: allowed),
              let available = value["available"].bool, let rows = value["features"].elements,
              value["unavailableReason"].isNullish || value["unavailableReason"].string != nil else {
            throw NativeRPCError.malformed("The server returned unreadable Apps capabilities.")
        }
        var features = Set<String>()
        for row in rows {
            guard let feature = row.string, !feature.isEmpty,
                  feature.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw NativeRPCError.malformed("The server returned unreadable Apps capabilities.")
            }
            features.insert(feature)
        }
        return NativeAppsCapabilities(available: available, features: features)
    }

    public static func records(_ value: NativeRPCValue) throws -> [NativeRPCValue] {
        guard let rows = value.elements else { throw NativeRPCError.malformed("The server returned an unreadable list.") }
        return rows
    }

    public static func summary(_ value: NativeRPCValue) throws -> NativeAppsSummary {
        let id = try value["id"].requireString("app id", nonempty: true)
        let name = try value["name"].requireString("app name", nonempty: true)
        return NativeAppsSummary(id: id, name: name, kind: value["kind"].string ?? "app",
                                 status: value["status"].string ?? "unknown", address: webAddress(value["address"].string))
    }

    public static func detail(_ value: NativeRPCValue) throws -> NativeAppsDetail {
        let app = try summary(value)
        let source = value["source"]
        let sourceText: String
        switch source["kind"].string {
        case "github":
            guard let repository = source["repository"].string,
                  repository.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil,
                  !repository.hasSuffix("/.."), !repository.hasSuffix("/.") else {
                throw NativeRPCError.malformed("The server returned an unreadable repository name.")
            }
            sourceText = repository
        case "template": sourceText = source["templateId"].string ?? "Template"
        case "database": sourceText = "Database"
        default: sourceText = app.kind == "app" ? "App" : "Database"
        }
        var addresses: [NativeAppsAddress] = []
        let host = app.address.flatMap { URL(string: $0)?.host?.lowercased() }
        if let host {
            addresses.append(NativeAppsAddress(hostname: host, isPrimary: true,
                                               isDefault: isDefaultHostname(host, appID: app.id)))
        }
        for rawHostname in try strings(value["domains"]) {
            guard NativeAppsRules.validHostname(rawHostname) else {
                throw NativeRPCError.malformed("The server returned an unreadable app address.")
            }
            let hostname = rawHostname.lowercased()
            if !addresses.contains(where: { $0.hostname == hostname }) {
                addresses.append(NativeAppsAddress(hostname: hostname,
                                                   isDefault: isDefaultHostname(hostname, appID: app.id)))
            }
        }
        var environmentNames = Set<String>()
        let environment = try strings(value["envKeys"]).map { name in
            guard NativeAppsRules.validEnvironmentKey(name), environmentNames.insert(name).inserted else {
                throw NativeRPCError.malformed("The server returned an unreadable setting name.")
            }
            return NativeAppsEnvironmentKey(key: name, isSecret: true)
        }
        var port: Int?
        if !source["port"].isNullish {
            guard let number = source["port"].number, let valid = Int(exactly: number), (1...65535).contains(valid) else {
                throw NativeRPCError.malformed("The server returned an invalid app port.")
            }
            port = valid
        }
        return NativeAppsDetail(app: app, source: sourceText, branch: source["branch"].string,
                                port: port, updatedAt: timestamp(value["updatedAt"]),
                                environment: environment, addresses: addresses, sourceKind: source["kind"].string,
                                activeDeploymentID: value["activeDeploymentId"].string)
    }

    /// A reply is usable only for the app the person asked to change/read.
    public static func scopedSummary(_ value: NativeRPCValue, appID: String) throws -> NativeAppsSummary {
        let candidate = try summary(value)
        guard candidate.id == appID else { throw NativeRPCError.malformed("The app reply does not match this request.") }
        return candidate
    }

    public static func environments(_ value: NativeRPCValue) throws -> [NativeAppsEnvironmentKey] {
        var names = Set<String>()
        return try records(value).map { row in
            guard let name = row["key"].string, NativeAppsRules.validEnvironmentKey(name), names.insert(name).inserted else {
                throw NativeRPCError.malformed("The server returned an unreadable setting name.")
            }
            return NativeAppsEnvironmentKey(key: name, isSecret: true)
        }
    }

    public static func deployments(_ value: NativeRPCValue, activeID: String?) throws -> [NativeAppsDeployment] {
        var identifiers = Set<String>()
        return try records(value).map { row in
            let id = try row["id"].requireString("deploy id", nonempty: true)
            guard identifiers.insert(id).inserted else { throw NativeRPCError.malformed("The server returned duplicate deploy records.") }
            let status = row["status"].string ?? row["phase"].string ?? "unknown"
            return NativeAppsDeployment(id: id, title: row["commit"].string ?? "Deploy \(id)", status: status,
                                        createdAt: timestamp(row["createdAt"]),
                                        canRollback: id != activeID && status == "running" && row["imageRemoved"].bool != true)
        }
    }

    public static func backups(_ value: NativeRPCValue) throws -> [NativeAppsBackup] {
        var identifiers = Set<String>()
        return try records(value).map { row in
            let id = try row["id"].requireString("backup id", nonempty: true)
            guard identifiers.insert(id).inserted else { throw NativeRPCError.malformed("The server returned duplicate backup records.") }
            let sizeValue = row.has("size") ? row["size"] : row["bytes"]
            var size: Int64?
            if !sizeValue.isNullish {
                guard let number = sizeValue.number, let valid = Int64(exactly: number), valid >= 0 else {
                    throw NativeRPCError.malformed("The server returned an invalid backup size.")
                }
                size = valid
            }
            return NativeAppsBackup(id: id, createdAt: timestamp(row["createdAt"]),
                                    size: size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        }
    }

    public static func templates(_ value: NativeRPCValue) throws -> [NativeAppsTemplate] {
        var identifiers = Set<String>()
        return try records(value).map { row in
            let id = try row["id"].requireString("template id", nonempty: true)
            guard identifiers.insert(id).inserted else { throw NativeRPCError.malformed("The server returned duplicate template records.") }
            return NativeAppsTemplate(id: id,
                               name: try row["name"].requireString("template name", nonempty: true),
                               description: row["description"].string ?? "", category: row["category"].string ?? "App",
                               credit: row["credit"].string, license: row["license"].string,
                               sourceURL: NativeAppsRules.safeAddress(row["sourceURL"].string)?.absoluteString,
                               applicationLicense: row["applicationLicense"].string,
                               applicationSourceURL: NativeAppsRules.safeAddress(row["applicationSourceURL"].string)?.absoluteString)
        }
    }

    public static func backupSchedule(_ value: NativeRPCValue) throws -> NativeAppsBackupSchedule {
        guard let enabled = value["enabled"].bool else { throw NativeRPCError.malformed("The server did not return its backup schedule status.") }
        var retention = 7
        if enabled && value["retention"].isNullish {
            throw NativeRPCError.malformed("The server did not return its enabled backup retention count.")
        }
        if !value["retention"].isNullish {
            guard let number = value["retention"].number, let count = Int(exactly: number), (1...365).contains(count) else {
                throw NativeRPCError.malformed("The server returned an invalid backup retention period.")
            }
            retention = count
        }
        let calendar: String?
        if value["schedule"].isNullish {
            guard !enabled else { throw NativeRPCError.malformed("The server did not return its enabled backup calendar.") }
            calendar = nil
        } else {
            guard let text = value["schedule"].string, !text.trimmingCharacters(in: .whitespaces).isEmpty, text.utf8.count <= 128,
                  text.rangeOfCharacter(from: .controlCharacters) == nil,
                  text.range(of: #"^[A-Za-z0-9 *,:/._+~\-]+$"#, options: .regularExpression) != nil else {
                throw NativeRPCError.malformed("The server returned an unreadable backup calendar.")
            }
            calendar = text
        }
        var time = calendar == nil && !enabled ? "02:00" : ""
        if let calendar, calendar.range(of: #"^\*-\*-\* ([01][0-9]|2[0-3]):[0-5][0-9]:00$"#, options: .regularExpression) != nil {
            time = String(calendar.suffix(8).prefix(5))
        }
        return NativeAppsBackupSchedule(enabled: enabled, time: time, retentionCount: retention, calendar: calendar)
    }

    public static func timestamp(_ value: NativeRPCValue) -> String? {
        guard let milliseconds = value.number, milliseconds >= 0, milliseconds <= 253_402_300_799_999 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    private static func strings(_ value: NativeRPCValue) throws -> [String] {
        if value.isNullish { return [] }
        return try records(value).map {
            guard let name = $0.string, !name.isEmpty else { throw NativeRPCError.malformed("The server returned an unreadable saved name.") }
            return name
        }
    }

    /// Legacy records have no explicit default-address field. Only the exact
    /// app prefix and a canonical IPv4 suffix identify the automatic pattern.
    private static func isDefaultHostname(_ hostname: String, appID: String) -> Bool {
        let prefix = appID + ".", suffix = ".sslip.io"
        guard hostname.hasPrefix(prefix), hostname.hasSuffix(suffix) else { return false }
        let address = hostname.dropFirst(prefix.count).dropLast(suffix.count)
        let separator: Character = appID.hasPrefix("td-test-") && !address.contains(".") ? "-" : "."
        let octets = address.split(separator: separator, omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            guard let number = Int($0), (0...255).contains(number) else { return false }
            return String(number) == String($0)
        }
    }

    public static func webAddress(_ address: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        let candidate = address.contains("://") ? address : "https://" + address
        guard let components = URLComponents(string: candidate), components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        return NativeAppsRules.safeAddress(candidate)?.absoluteString
    }

    /// The backend's reasons (shared constants, #597) select fixed copy. An unknown reason stays unknown;
    /// the screen supplies its own working read or navigation action.
    public static func unavailableProblem(_ reason: String? = nil) -> String {
        switch reason ?? "" {
        case NativeAppsUnavailableReason.recoveryNotConnected:
            return "Changes are turned off because the server cannot safely undo an interrupted change."
        case NativeAppsUnavailableReason.engineNotConnected, NativeAppsUnavailableReason.engineHasNoDocker:
            return "App controls are not connected to this server."
        case NativeAppsUnavailableReason.operationNotImplemented, NativeAppsUnavailableReason.dataActionUnavailable,
             NativeAppsUnavailableReason.operationUnavailableOnServer:
            return "This action is not connected in this version of Terminal Deck."
        case NativeAppsUnavailableReason.engineHasNoAddressManager, NativeAppsUnavailableReason.addressManagerNeedsPrivateConnection:
            return "App addresses do not have a private connection to this server."
        case NativeAppsUnavailableReason.addressManagerUnreachable:
            return "App addresses cannot be reached on this server."
        case NativeAppsUnavailableReason.addressManagerNotConfigured:
            return "App addresses are not set up on this server."
        case NativeAppsUnavailableReason.needsPublicIPv4:
            return "This server has no public address that automatic app addresses can use."
        case NativeAppsUnavailableReason.publicAddressUnavailable:
            return "The server's public address could not be read."
        case NativeAppsUnavailableReason.addressCheckUnfinished:
            return "The app address check did not finish."
        case NativeAppsUnavailableReason.dnsChecksUnavailable:
            return "DNS checks are not connected for this server."
        case NativeAppsUnavailableReason.dnsNotFound:
            return "DNS did not find this app address."
        case NativeAppsUnavailableReason.gitHubSignInUnusable:
            return "The GitHub connection could not sign in to read this repository."
        case NativeAppsUnavailableReason.autoDeployNotConnected:
            return "Automatic deploys are not connected to a verified GitHub connection."
        case NativeAppsUnavailableReason.noRunningService:
            return "This app has no running version yet."
        case NativeAppsUnavailableReason.liveLogsNeedEvents, NativeAppsUnavailableReason.liveLogsUnavailable,
             NativeAppsUnavailableReason.liveLogsNeedCleanup:
            return "Live logs are not connected for this window."
        case NativeAppsUnavailableReason.serverCommandUnfinished, NativeAppsUnavailableReason.privateConnectionUnfinished,
             NativeAppsUnavailableReason.databaseConnectionUnfinished,
             NativeAppsUnavailableReason.databaseServiceUnfinished:
            return "The server connection did not finish this request."
        case NativeAppsUnavailableReason.runningStateUnchecked, NativeAppsUnavailableReason.runningStatesUnchecked,
             NativeAppsUnavailableReason.runningStateUnreadable, NativeAppsUnavailableReason.restartStateUnchecked:
            return "The app's current status could not be read from this server."
        case NativeAppsUnavailableReason.databaseSettingsManaged:
            return "These database settings cannot be changed through the app settings editor."
        case NativeAppsUnavailableReason.buildsNeedRailpack:
            return "Automatic builds are not set up on this server."
        case NativeAppsUnavailableReason.choosePort:
            return "The app does not have a web port selected."
        case NativeAppsUnavailableReason.templateUpdateNeedsMaintenance,
             NativeAppsUnavailableReason.templateRollbackNeedsMaintenance:
            return "This app keeps saved data, and a safe way to change its version is not connected yet."
        case NativeAppsUnavailableReason.backupToolsWithAWS,
             NativeAppsUnavailableReason.scheduledBackupTools,
             NativeAppsUnavailableReason.backupToolsWithChecksums:
            return "The server is missing tools needed for these backups."
        case NativeAppsUnavailableReason.backupDatabaseVersionGone:
            return "The server no longer has the database version needed for this backup."
        default:
            return "This action is unavailable, but its cause could not be identified."
        }
    }

    /// Known safe copy only. Never surface raw execution output or submitted secrets.
    public static func problem(_ error: Error) -> String {
        let code = (error as? NativeRPCError)?.code ?? "unknown"
        switch code {
        case "unavailable": return unavailableProblem((error as? NativeRPCError)?.message)
        case "unknown-channel", "not-implemented": return "This action is not connected in this version of Terminal Deck."
        case "approval-required", "access-denied": return "This change needs your approval or server access. Review the approval request, then try again."
        case "confirmation-required": return "Type the app’s exact name to confirm this change."
        case "not-found": return "This app or saved item could not be found. Refresh the page."
        case "conflict": return "That name is already in use, or this app changed elsewhere. Refresh and try again."
        case "busy": return "Another change is already running for this app. Try again when it finishes."
        case "build-failed", "health-failed": return "The deploy did not finish successfully. Check the deploy history and logs."
        case "dns-mismatch": return "DNS is not pointing to this server yet. Check the address instructions."
        case "backup-failed", "restore-failed": return "The backup operation did not finish successfully. Your data needs checking before retrying."
        case "cancelled": return "The action was cancelled."
        case "invalid-arguments": return "Check the values you entered and try again."
        case "malformed": return "The server’s reply could not be read. Refresh to check what happened before trying again."
        default: return "No usable reply arrived from the server. Refresh to check what happened before trying again."
        }
    }
}
