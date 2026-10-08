import Foundation
import TerminalDeckNativeCore

/// Backups and timers live on the server. The Mac owns no scheduler or authoritative backup state.
public struct BackendAppsBackups: Sendable {
    public let runtime: BackendAppsRuntime
    public let store: BackendAppsStore
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore) { self.runtime = runtime; self.store = store }

    public func list(serverID: String, appID: String) async throws -> NativeRPCValue {
        try BackendAppsDatabases.validateRuntime(runtime)
        let app = try await store.read(serverID, appID)
        _ = try Self.database(app)
        let directory = try store.directory(appID)
        let result = try await runtime.checked(serverID, """
        set -eu
        command -v jq >/dev/null 2>&1 || exit 69
        dir=\(BackendAppsRuntime.quote(directory))
        if [ ! -d "$dir/backups" ]; then printf '[]'; exit 0; fi
        find "$dir/backups" -mindepth 2 -maxdepth 2 -name manifest.json -type f -exec cat {} \\; | jq -s 'sort_by(.createdAt) | reverse'
        """, message: "Saved backups could not be read. The server needs jq to read its backup records.")
        let entries = try NativeRPCValue.parseJSON(Data(result.utf8)).requireArray("backups")
        return .array(try entries.map { try Self.publicManifest($0, appID: appID, kind: app["kind"].string ?? "") })
    }

    public func create(serverID: String, appID: String) async throws -> NativeRPCValue {
        try BackendAppsDatabases.validateRuntime(runtime)
        _ = try BackendAppsValidation.id(appID)
        return try await store.withLock(serverID, appID) {
            let record = try await store.read(serverID, appID)
            _ = try Self.database(record)
            try await checkDependencies(serverID: serverID, scheduled: false, upload: false)
            let directory = try store.directory(appID)
            try await installRunner(serverID: serverID, appID: appID)
            let backupID = "\(runtime.resourcePrefix)-\(Int(runtime.now()))-\(UUID().uuidString.lowercased())"
            let result = try await runtime.checked(serverID, "sh \(BackendAppsRuntime.quote(directory + "/backup-run.sh")) --already-locked \(BackendAppsRuntime.quote(backupID))", timeoutMS: 3_600_000, code: "backup-failed", message: "The backup did not finish or pass verification. Previous backups were preserved.")
            return try Self.publicManifest(NativeRPCValue.parseJSON(Data(result.utf8)), appID: appID, kind: record["kind"].string ?? "")
        }
    }

    public func policy(serverID: String, appID: String, request: NativeRPCValue) async throws -> NativeRPCValue {
        try BackendAppsDatabases.validateRuntime(runtime)
        _ = try BackendAppsValidation.id(appID)
        _ = try request.requireObject("backup policy")
        let enabled = request["enabled"].bool ?? true
        let directory = try store.directory(appID)
        let unit = "\(runtime.resourcePrefix)-\(appID)-backup"
        _ = try BackendAppsValidation.identifier(unit)
        if !enabled {
            return try await store.withLock(serverID, appID) {
                var record = try await store.read(serverID, appID)
                _ = try Self.database(record)
                let command = """
                set -eu
                command -v systemctl >/dev/null 2>&1 || exit 69
                file=\(BackendAppsRuntime.quote("/etc/systemd/system/" + unit + ".timer"))
                if [ -f "$file" ]; then
                  grep -Fx \(BackendAppsRuntime.quote(Self.marker(appID))) "$file" >/dev/null || exit 73
                  systemctl disable --now \(BackendAppsRuntime.quote(unit + ".timer")) >/dev/null 2>&1
                  test "$(systemctl is-enabled \(BackendAppsRuntime.quote(unit + ".timer")) 2>/dev/null || true)" != enabled
                  test "$(systemctl is-active \(BackendAppsRuntime.quote(unit + ".timer")) 2>/dev/null || true)" != active
                fi
                """
                _ = try await runtime.checked(serverID, command, message: "Scheduled backups could not be disabled. Only this app's managed timer can be changed.")
                let policy = BackendAppsValidation.object([("enabled", .bool(false))])
                try await store.writeFile(serverID, path: directory + "/backup-policy.json", contents: policy.encodedJSON())
                record = record.setting("backupPolicy", policy).setting("updatedAt", .number(runtime.now()))
                try await store.write(serverID, appID, record)
                return policy
            }
        }
        let schedule = try request["schedule"].requireString("schedule", nonempty: true)
        guard schedule.utf8.count <= 128, schedule.range(of: #"^[A-Za-z0-9 *,:/._+~\-]+$"#, options: .regularExpression) != nil,
              let retention = request["retention"].number, retention.rounded() == retention, (1...365).contains(retention) else {
            throw NativeRPCError.invalidArguments("Choose a systemd calendar schedule and keep between 1 and 365 backups.")
        }
        let upload = try Self.upload(request["upload"])
        return try await store.withLock(serverID, appID) {
            var record = try await store.read(serverID, appID)
            _ = try Self.database(record)
            try await checkDependencies(serverID: serverID, scheduled: true, upload: upload != nil)
            _ = try await runtime.checked(serverID, "systemd-analyze calendar \(BackendAppsRuntime.quote(schedule)) >/dev/null 2>&1", message: "That backup schedule is not a valid systemd calendar.")
            let originalRecord = record
            let previous = record["backupPolicy"].fields == nil ? BackendAppsValidation.object([("enabled", .bool(false))]) : record["backupPolicy"]
            let oldPolicy = try await store.readFile(serverID, path: directory + "/backup-policy.json")
            let oldCredentials = try await store.readFile(serverID, path: directory + "/.backup-s3-credentials")
            let oldService = try await readUnit(serverID: serverID, name: unit + ".service", appID: appID)
            let oldTimer = try await readUnit(serverID: serverID, name: unit + ".timer", appID: appID)
            var publicPolicy = BackendAppsValidation.object([("enabled", .bool(true)), ("schedule", .string(schedule)), ("retention", .number(retention))])
            if let upload {
                publicPolicy = publicPolicy.setting("upload", BackendAppsValidation.object([("endpoint", .string(upload.endpoint)), ("bucket", .string(upload.bucket)), ("prefix", .string(upload.prefix))]))
            }
            let service = """
            \(Self.marker(appID))
            [Unit]
            Description=Terminal Deck database backup
            After=docker.service
            [Service]
            Type=oneshot
            User=root
            UMask=0077
            ExecStart=/bin/sh \(directory)/backup-run.sh
            StandardOutput=null
            StandardError=null
            TimeoutStartSec=3600

            """
            let timer = """
            \(Self.marker(appID))
            [Unit]
            Description=Terminal Deck scheduled database backup
            [Timer]
            OnCalendar=\(schedule)
            Persistent=true
            Unit=\(unit).service
            [Install]
            WantedBy=timers.target

            """
            // An interrupted change is visible from another Mac before any scheduling side effect.
            record = record.setting("backupPolicy", previous.setting("status", .string("updating"))).setting("updatedAt", .number(runtime.now()))
            try await store.write(serverID, appID, record)
            do {
                try await stopTimer(serverID: serverID, unit: unit, appID: appID)
                try await store.write(serverID, appID, record.setting("backupPolicy", publicPolicy.setting("enabled", .bool(false)).setting("status", .string("updating"))))
                try await installRunner(serverID: serverID, appID: appID)
                if let upload {
                    let credentials = "[terminaldeck]\naws_access_key_id = \(upload.accessKey)\naws_secret_access_key = \(upload.secretKey)\n"
                    try await store.writeFile(serverID, path: directory + "/.backup-s3-credentials", contents: Data(credentials.utf8))
                } else { try await replaceProtectedFile(serverID: serverID, path: directory + "/.backup-s3-credentials", contents: nil) }
                try await store.writeFile(serverID, path: directory + "/backup-policy.json", contents: publicPolicy.encodedJSON())
                try await writeUnit(serverID: serverID, name: unit + ".service", contents: service)
                try await writeUnit(serverID: serverID, name: unit + ".timer", contents: timer)
                // Persist the possibility of active scheduling before enabling it, even if the connection then fails.
                try await store.write(serverID, appID, originalRecord.setting("backupPolicy", publicPolicy.setting("status", .string("activating"))).setting("updatedAt", .number(runtime.now())))
                _ = try await runtime.checked(serverID, "systemd-analyze verify \(BackendAppsRuntime.quote("/etc/systemd/system/" + unit + ".service")) \(BackendAppsRuntime.quote("/etc/systemd/system/" + unit + ".timer")) >/dev/null 2>&1 && systemctl daemon-reload && systemctl enable --now \(BackendAppsRuntime.quote(unit + ".timer")) >/dev/null 2>&1 && systemctl is-active --quiet \(BackendAppsRuntime.quote(unit + ".timer")) && systemctl is-enabled --quiet \(BackendAppsRuntime.quote(unit + ".timer"))", message: "Scheduled backups could not be enabled and verified. Check systemd on the server.")
                record = originalRecord.setting("backupPolicy", publicPolicy).setting("updatedAt", .number(runtime.now()))
                try await store.write(serverID, appID, record)
                return publicPolicy
            } catch {
                // Cancellation must not skip compensation and leave a hidden enabled timer.
                let restored = await Task.detached {
                    await rollbackPolicy(serverID: serverID, appID: appID, directory: directory, unit: unit, oldPolicy: oldPolicy, oldCredentials: oldCredentials, oldService: oldService, oldTimer: oldTimer, originalRecord: originalRecord, previous: previous)
                }.value
                if !restored {
                    let failed = publicPolicy.setting("enabled", .bool(true)).setting("status", .string("failed")).setting("message", .string("The backup timer may still be enabled. Check its server service before retrying."))
                    let saved = originalRecord.setting("backupPolicy", failed).setting("updatedAt", .number(runtime.now()))
                    _ = await Task.detached { try? await store.write(serverID, appID, saved) }.value
                    throw NativeRPCError(code: "state-failed", message: "The backup policy failed and its previous timer could not be fully restored. Its failed state is saved; check the server timer.")
                }
                throw NativeRPCError(code: "state-failed", message: "The backup policy could not be saved. The previous policy and timer were restored.")
            }
        }
    }

    public func restore(serverID: String, appID: String, backupID: String, confirmation: String) async throws -> NativeRPCValue {
        try BackendAppsDatabases.validateRuntime(runtime)
        _ = try BackendAppsValidation.id(appID)
        _ = try BackendAppsValidation.identifier(backupID)
        return try await store.withLock(serverID, appID) {
            var record = try await store.read(serverID, appID)
            let originalRecord = record
            guard confirmation == record["name"].string else {
                throw NativeRPCError(code: "confirmation-required", message: "Type the database's exact name to restore over its data.")
            }
            let database = try Self.database(record)
            let directory = try store.directory(appID)
            guard let manifestData = try await store.readFile(serverID, path: directory + "/backups/\(backupID)/manifest.json") else {
                throw NativeRPCError(code: "not-found", message: "That saved backup could not be found.")
            }
            let manifest = try NativeRPCValue.parseJSON(manifestData)
            _ = try Self.publicManifest(manifest, appID: appID, kind: database.kind)
            guard manifest["id"].string == backupID, let imageID = manifest["imageId"].string,
                  imageID.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw NativeRPCError(code: "restore-failed", message: "The backup's software identity is invalid.")
            }
            try await checkDependencies(serverID: serverID, scheduled: false, upload: false)
            let file = directory + "/backups/\(backupID)/data"
            _ = try await runtime.checked(serverID, """
            set -eu
            file=\(BackendAppsRuntime.quote(file))
            test -f "$file" && test ! -L "$file"
            test "$(sha256sum "$file" | cut -d ' ' -f 1)" = \(BackendAppsRuntime.quote(manifest["sha256"].string ?? ""))
            test "$(wc -c < "$file" | tr -d ' ')" = \(BackendAppsRuntime.quote(String(Int(manifest["bytes"].number ?? 0))))
            """, code: "restore-failed", message: "The saved backup failed its size or checksum check. The database has not been changed.")
            let image = try await runtime.docker(serverID, "GET", "/images/\(imageID)/json", nil)
            guard image.ok else { throw BackendAppsRuntime.unavailable("The exact database software used by this backup is no longer saved on the server.") }
            let source = try await runtime.docker(serverID, "GET", "/containers/\(database.containerID)/json", nil)
            guard source.ok else { throw NativeRPCError(code: "restore-failed", message: "The current database could not be inspected.") }
            let inspect = try source.value()
            guard inspect["Config"]["Labels"]["io.terminaldeck.app"].string == appID,
                  inspect["Config"]["Labels"]["io.terminaldeck.managed"].string == "true" else {
                throw NativeRPCError(code: "restore-failed", message: "The current database is not owned by this app.")
            }
            let originalRunning = inspect["State"]["Running"].bool == true
            let suffix = UUID().uuidString.lowercased()
            let newVolume = "\(runtime.resourcePrefix)-\(appID)-restore-\(suffix)"
            let newName = "\(runtime.resourcePrefix)-\(appID)-restore-\(suffix)"
            let labels = BackendAppsValidation.object([("io.terminaldeck.app", .string(appID)), ("io.terminaldeck.managed", .string("true")), ("io.terminaldeck.restore", .string(backupID))])
            let volume = try await runtime.docker(serverID, "POST", "/volumes/create", try BackendAppsValidation.object([("Name", .string(newVolume)), ("Labels", labels)]).encodedJSON())
            guard volume.ok else { throw NativeRPCError(code: "restore-failed", message: "A separate recovery space could not be created. The database has not been changed.") }
            let environment = try await store.environment(serverID, appID)
            let spec = try BackendAppsDatabaseSpec(kind: database.kind, version: database.image.split(separator: ":").last.map(String.init))
            var body = spec.container(appID: appID, volume: newVolume, environment: environment, labels: labels, network: runtime.privateNetwork, prefix: runtime.resourcePrefix, alias: false)
            body = body.setting("Image", .string(imageID))
            let created = try await runtime.docker(serverID, "POST", "/containers/create?name=\(newName)", try body.encodedJSON())
            guard created.ok, let candidate = try created.value()["Id"].string,
                  candidate.range(of: #"^[a-f0-9]{12,64}$"#, options: .regularExpression) != nil else {
                throw NativeRPCError(code: "restore-failed", message: "The recovery database could not be created. The original data was preserved.")
            }
            do {
                let stop = try await runtime.docker(serverID, "POST", "/containers/\(database.containerID)/stop?t=30", nil)
                guard stop.ok || stop.status == 304 else { throw NativeRPCError(code: "restore-failed", message: "The database could not be stopped safely.") }
                if database.kind == "redis" {
                    _ = try await runtime.checked(serverID, Self.redisRestoreScript(file: file, containerID: candidate, imageID: imageID, volume: newVolume, helperName: "\(runtime.resourcePrefix)-\(appID)-restore-copy-\(suffix)", appID: appID), timeoutMS: 600_000, code: "restore-failed", message: "The Redis backup could not be copied and verified in the recovery space.")
                }
                let start = try await runtime.docker(serverID, "POST", "/containers/\(candidate)/start", nil)
                guard start.ok else { throw NativeRPCError(code: "restore-failed", message: "The recovery database could not start.") }
                try await BackendAppsDatabases.waitHealthy(runtime: runtime, serverID: serverID, containerID: candidate)
                if database.kind != "redis" {
                    _ = try await runtime.checked(serverID, Self.restoreScript(kind: database.kind, file: file, containerID: candidate), timeoutMS: 3_600_000, code: "restore-failed", message: "The backup could not be restored. The original data was preserved.")
                    try await BackendAppsDatabases.waitHealthy(runtime: runtime, serverID: serverID, containerID: candidate)
                }
                // Move the stable private name only after the restored data has passed checks.
                let disconnect = try await runtime.docker(serverID, "POST", "/networks/\(runtime.privateNetwork)/disconnect", try BackendAppsValidation.object([("Container", .string(database.containerID)), ("Force", .bool(false))]).encodedJSON())
                guard disconnect.ok else { throw NativeRPCError(code: "restore-failed", message: "The original database's private address could not be released.") }
                let candidateDisconnect = try await runtime.docker(serverID, "POST", "/networks/\(runtime.privateNetwork)/disconnect", try BackendAppsValidation.object([("Container", .string(candidate)), ("Force", .bool(false))]).encodedJSON())
                guard candidateDisconnect.ok else { throw NativeRPCError(code: "restore-failed", message: "The recovery database's private address could not be changed.") }
                let connect = try await runtime.docker(serverID, "POST", "/networks/\(runtime.privateNetwork)/connect", try BackendAppsValidation.object([("Container", .string(candidate)), ("EndpointConfig", BackendAppsValidation.object([("Aliases", .array([.string("\(runtime.resourcePrefix)-\(appID)")]))]))]).encodedJSON())
                guard connect.ok else { throw NativeRPCError(code: "restore-failed", message: "The restored database's private address could not be activated.") }
                let recovery = BackendAppsValidation.object([("containerId", .string(database.containerID)), ("volumeName", .string(database.volume)), ("createdAt", .number(runtime.now())), ("reason", .string("before-restore"))])
                var recoveries = record["databaseRecovery"].elements ?? []
                recoveries.append(recovery)
                record = record.setting("databaseRecovery", .array(recoveries)).setting("containerId", .string(candidate)).setting("database", record["database"].setting("containerId", .string(candidate)).setting("volumeName", .string(newVolume)).setting("imageId", .string(imageID))).setting("status", .string("running")).setting("updatedAt", .number(runtime.now()))
                try await store.write(serverID, appID, record)
                return BackendAppsValidation.object([("restored", .bool(true)), ("recoveryPreserved", .bool(true))])
            } catch {
                // Never delete either volume. Stop failed candidate and reattach/restart the original.
                _ = try? await runtime.docker(serverID, "POST", "/containers/\(candidate)/stop?t=30", nil)
                _ = try? await runtime.docker(serverID, "POST", "/networks/\(runtime.privateNetwork)/disconnect", try BackendAppsValidation.object([("Container", .string(candidate)), ("Force", .bool(true))]).encodedJSON())
                _ = try? await runtime.docker(serverID, "POST", "/networks/\(runtime.privateNetwork)/connect", try BackendAppsValidation.object([("Container", .string(database.containerID)), ("EndpointConfig", BackendAppsValidation.object([("Aliases", .array([.string("\(runtime.resourcePrefix)-\(appID)")]))]))]).encodedJSON())
                if originalRunning { _ = try? await runtime.docker(serverID, "POST", "/containers/\(database.containerID)/start", nil) }
                var preserved = originalRecord["databaseRecovery"].elements ?? []
                preserved.append(BackendAppsValidation.object([("containerId", .string(candidate)), ("volumeName", .string(newVolume)), ("createdAt", .number(runtime.now())), ("reason", .string("failed-restore"))]))
                try? await store.write(serverID, appID, originalRecord.setting("databaseRecovery", .array(preserved)).setting("updatedAt", .number(runtime.now())))
                throw NativeRPCError(code: "restore-failed", message: "Restore did not finish. The original data and recovery space were preserved; check the database's status before retrying.")
            }
        }
    }

    private func checkDependencies(serverID: String, scheduled: Bool, upload: Bool) async throws {
        let commands = ["docker", "jq", "sha256sum", "gzip", "find", "date", "wc", "cut", "tr", "sort", "sed"] + (scheduled ? ["systemctl", "systemd-analyze"] : []) + (upload ? ["aws"] : [])
        let command = "set -eu; " + commands.map { "command -v \(BackendAppsRuntime.quote($0)) >/dev/null 2>&1" }.joined(separator: "; ") + (scheduled ? "; test -d /run/systemd/system" : "")
        _ = try await runtime.checked(serverID, command, message: upload ? "Backups need Docker, jq, gzip, sha256sum, systemd and the AWS CLI on this server. No software was installed." : (scheduled ? "Scheduled backups need Docker, jq, gzip, sha256sum and systemd on this server. No software was installed." : "Backups need Docker, jq, gzip and sha256sum on this server. No software was installed."))
    }
    private func installRunner(serverID: String, appID: String) async throws {
        let directory = try store.directory(appID)
        try await store.writeFile(serverID, path: directory + "/backup-run.sh", contents: Data(Self.runner(directory: directory, appID: appID, prefix: runtime.resourcePrefix).utf8))
    }
    private func writeUnit(serverID: String, name: String, contents: String) async throws {
        _ = try BackendAppsValidation.identifier(name)
        let path = "/etc/systemd/system/" + name
        let temporary = path + "." + UUID().uuidString + ".tmp"
        let q = BackendAppsRuntime.quote
        _ = try await runtime.checked(serverID, """
        set -eu
        umask 077
        test -d /etc/systemd/system && test ! -L /etc/systemd/system
        test ! -L \(q(path))
        trap 'rm -f -- \(q(temporary))' EXIT
        trap 'exit 130' HUP INT TERM
        set -C
        cat > \(q(temporary))
        chmod 600 \(q(temporary))
        sync -f \(q(temporary))
        mv -f -- \(q(temporary)) \(q(path))
        sync -f /etc/systemd/system
        """, stdin: Data(contents.utf8), code: "state-failed", message: "The app's own backup timer could not be safely saved.")
    }
    private func readUnit(serverID: String, name: String, appID: String) async throws -> Data? {
        _ = try BackendAppsValidation.identifier(name)
        let path = BackendAppsRuntime.quote("/etc/systemd/system/" + name)
        let result = try await runtime.run(serverID, "test -e \(path) || exit 44; test ! -L \(path) && test -f \(path) || exit 73; grep -Fx \(BackendAppsRuntime.quote(Self.marker(appID))) \(path) >/dev/null || exit 73; cat -- \(path)")
        if result.code == 44 { return nil }
        guard result.code == 0, !result.truncated else { throw NativeRPCError(code: "conflict", message: "A different or unsafe service already uses this backup timer's name.") }
        return Data(result.stdout.utf8)
    }
    private func stopTimer(serverID: String, unit: String, appID: String) async throws {
        _ = try await runtime.checked(serverID, """
        set -eu
        file=\(BackendAppsRuntime.quote("/etc/systemd/system/" + unit + ".timer"))
        if [ -e "$file" ]; then
          test ! -L "$file"
          grep -Fx \(BackendAppsRuntime.quote(Self.marker(appID))) "$file" >/dev/null
          systemctl disable --now \(BackendAppsRuntime.quote(unit + ".timer")) >/dev/null 2>&1
        fi
        if systemctl is-active --quiet \(BackendAppsRuntime.quote(unit + ".timer")) || systemctl is-enabled --quiet \(BackendAppsRuntime.quote(unit + ".timer")); then exit 73; fi
        """, message: "The app's own backup timer could not be safely stopped.")
    }
    private func replaceProtectedFile(serverID: String, path: String, contents: Data?) async throws {
        if let contents { try await store.writeFile(serverID, path: path, contents: contents); return }
        _ = try await runtime.checked(serverID, "test ! -L \(BackendAppsRuntime.quote(path)) && rm -f -- \(BackendAppsRuntime.quote(path))", code: "state-failed", message: "The previous protected backup settings could not be restored.")
    }
    private func replaceUnit(serverID: String, name: String, appID: String, contents: Data?) async throws {
        if let contents {
            guard let text = String(data: contents, encoding: .utf8) else { throw NativeRPCError(code: "state-failed", message: "The saved timer is unreadable.") }
            try await writeUnit(serverID: serverID, name: name, contents: text)
            return
        }
        let path = BackendAppsRuntime.quote("/etc/systemd/system/" + name)
        _ = try await runtime.checked(serverID, "if [ -e \(path) ]; then test ! -L \(path) && grep -Fx \(BackendAppsRuntime.quote(Self.marker(appID))) \(path) >/dev/null && rm -f -- \(path); fi", code: "state-failed", message: "The incomplete backup timer could not be removed safely.")
    }
    private func rollbackPolicy(serverID: String, appID: String, directory: String, unit: String, oldPolicy: Data?, oldCredentials: Data?, oldService: Data?, oldTimer: Data?, originalRecord: NativeRPCValue, previous: NativeRPCValue) async -> Bool {
        do {
            try await stopTimer(serverID: serverID, unit: unit, appID: appID)
            try await replaceProtectedFile(serverID: serverID, path: directory + "/backup-policy.json", contents: oldPolicy)
            try await replaceProtectedFile(serverID: serverID, path: directory + "/.backup-s3-credentials", contents: oldCredentials)
            try await replaceUnit(serverID: serverID, name: unit + ".service", appID: appID, contents: oldService)
            try await replaceUnit(serverID: serverID, name: unit + ".timer", appID: appID, contents: oldTimer)
            _ = try await runtime.checked(serverID, "systemctl daemon-reload", message: "The previous backup timer could not be reloaded.")
            if previous["enabled"].bool == true {
                guard oldTimer != nil, oldService != nil else { return false }
                _ = try await runtime.checked(serverID, "systemctl enable --now \(BackendAppsRuntime.quote(unit + ".timer")) >/dev/null 2>&1 && systemctl is-active --quiet \(BackendAppsRuntime.quote(unit + ".timer")) && systemctl is-enabled --quiet \(BackendAppsRuntime.quote(unit + ".timer"))", message: "The previous backup timer could not be restarted.")
            }
            try await store.write(serverID, appID, originalRecord)
            return true
        } catch { return false }
    }
    private static func marker(_ appID: String) -> String { "# Terminal Deck managed backup for \(appID)" }
    private struct Database: Sendable { let kind: String; let containerID: String; let volume: String; let image: String }
    private static func database(_ record: NativeRPCValue) throws -> Database {
        guard let kind = record["kind"].string, ["postgres", "mysql", "redis", "mongodb"].contains(kind),
              let container = record["database"]["containerId"].string,
              container.range(of: #"^[a-f0-9]{12,64}$"#, options: .regularExpression) != nil,
              let volume = record["database"]["volumeName"].string,
              volume.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,191}$"#, options: .regularExpression) != nil,
              let image = record["database"]["image"].string else {
            throw BackendAppsRuntime.unavailable("Backups are available for managed databases with saved data.")
        }
        return Database(kind: kind, containerID: container, volume: volume, image: image)
    }
    private static func publicManifest(_ manifest: NativeRPCValue, appID: String, kind: String) throws -> NativeRPCValue {
        guard manifest["appId"].string == appID, manifest["kind"].string == kind, manifest["verified"].bool == true,
              let id = manifest["id"].string, let bytes = manifest["bytes"].number, bytes > 0, bytes.rounded() == bytes, bytes < 9_007_199_254_740_991,
              let sha = manifest["sha256"].string, sha.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              let created = manifest["createdAt"].number, created > 0 else {
            throw NativeRPCError(code: "backup-failed", message: "A saved backup record did not pass validation.")
        }
        _ = try BackendAppsValidation.identifier(id)
        return BackendAppsValidation.object([("id", .string(id)), ("appId", .string(appID)), ("kind", .string(kind)), ("createdAt", .number(created)), ("bytes", .number(bytes)), ("sha256", .string(sha)), ("verified", .bool(true)), ("uploaded", .bool(manifest["uploaded"].bool ?? false))])
    }
    private struct Upload: Sendable { let endpoint: String; let bucket: String; let prefix: String; let accessKey: String; let secretKey: String }
    private static func upload(_ value: NativeRPCValue) throws -> Upload? {
        if value.isNullish { return nil }
        _ = try value.requireObject("upload")
        let endpoint = try value["endpoint"].requireString("upload endpoint", nonempty: true)
        let bucket = try value["bucket"].requireString("upload bucket", nonempty: true)
        let prefix = value["prefix"].string ?? "terminaldeck"
        let access = try value["accessKey"].requireString("upload access key", nonempty: true)
        let secret = try value["secretKey"].requireString("upload secret key", nonempty: true)
        guard let url = URLComponents(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              endpoint.utf8.count <= 512, bucket.range(of: #"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil,
              prefix.range(of: #"^[A-Za-z0-9/_-]{0,256}$"#, options: .regularExpression) != nil,
              [access, secret].allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") && !$0.contains("[") && !$0.contains("]") }) else {
            throw NativeRPCError.invalidArguments("Use an HTTPS S3 endpoint, a bucket name and single-line credentials.")
        }
        return Upload(endpoint: endpoint, bucket: bucket, prefix: prefix, accessKey: access, secretKey: secret)
    }

    // The only shell programs are sent to the server, as permitted by BRIEF.md.
    public static func runner(directory: String, appID: String, prefix: String) -> String {
        """
        #!/bin/sh
        set -eu
        umask 077
        dir=\(BackendAppsRuntime.quote(directory))
        app=\(BackendAppsRuntime.quote(appID))
        prefix=\(BackendAppsRuntime.quote(prefix))
        locked=0
        work=
        cleanup() { [ -z "$work" ] || rm -rf -- "$work"; [ "$locked" = 0 ] || rmdir "$dir/.lock"; }
        trap cleanup EXIT
        trap 'exit 130' HUP INT TERM
        if [ "${1:-}" = --already-locked ]; then
          test -d "$dir/.lock" || exit 73
          id="$2"
        else
          mkdir "$dir/.lock" 2>/dev/null || exit 75
          locked=1
          id="$prefix-$(date +%s)-$(cat /proc/sys/kernel/random/uuid)"
        fi
        case "$id" in *[!a-zA-Z0-9_.-]*|''|.|..) exit 65;; esac
        case "$app" in *[!a-z0-9-]*|'') exit 65;; esac
        container=$(jq -er '.database.containerId' "$dir/state.json")
        kind=$(jq -er '.kind' "$dir/state.json")
        case "$container" in *[!a-f0-9]*|'') exit 65;; esac
        test "$(docker inspect --format '{{ index .Config.Labels "io.terminaldeck.app" }}' "$container" 2>/dev/null)" = "$app"
        test "$(docker inspect --format '{{ index .Config.Labels "io.terminaldeck.managed" }}' "$container" 2>/dev/null)" = true
        image=$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null)
        mkdir -p "$dir/backups"
        chmod 700 "$dir/backups"
        work="$dir/backups/.partial-$id"
        mkdir "$work"
        chmod 700 "$work"
        case "$kind" in
          postgres)
            docker exec "$container" sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dump --format=custom --no-owner --no-acl --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' > "$work/data" 2>/dev/null
            docker exec -i "$container" pg_restore --list < "$work/data" >/dev/null 2>&1
            ;;
          mysql)
            docker exec "$container" sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysqldump --user=root --single-transaction --routines --events --triggers --set-gtid-purged=OFF --column-statistics=0 --databases "$MYSQL_DATABASE"' > "$work/plain" 2>/dev/null
            test -s "$work/plain"
            gzip -c "$work/plain" > "$work/data"
            rm "$work/plain"
            gzip -t "$work/data"
            ;;
          redis)
            docker exec "$container" sh -c 'export REDISCLI_AUTH="$REDIS_PASSWORD"; test "$(redis-cli SAVE)" = OK; redis-check-rdb /data/dump.rdb >/dev/null; exec cat /data/dump.rdb' > "$work/data" 2>/dev/null
            ;;
          mongodb)
            docker exec "$container" sh -c \(BackendAppsRuntime.quote(mongoDumpCommand)) > "$work/data" 2>/dev/null
            gzip -t "$work/data"
            ;;
          *) exit 65;;
        esac
        test -s "$work/data"
        sum=$(sha256sum "$work/data" | cut -d ' ' -f 1)
        bytes=$(wc -c < "$work/data" | tr -d ' ')
        uploaded=false
        retention=7
        if [ -f "$dir/backup-policy.json" ]; then
          retention=$(jq -er '.retention // 7 | select(. >= 1 and . <= 365 and floor == .)' "$dir/backup-policy.json")
          endpoint=$(jq -r '.upload.endpoint // empty' "$dir/backup-policy.json")
          if [ -n "$endpoint" ]; then
            bucket=$(jq -er '.upload.bucket' "$dir/backup-policy.json")
            path=$(jq -r '.upload.prefix // "terminaldeck"' "$dir/backup-policy.json")
            key="${path:+$path/}$app/$id/data"
            export AWS_SHARED_CREDENTIALS_FILE="$dir/.backup-s3-credentials" AWS_EC2_METADATA_DISABLED=true AWS_DEFAULT_REGION=us-east-1
            aws --profile terminaldeck --endpoint-url "$endpoint" s3api put-object --bucket "$bucket" --key "$key" --body "$work/data" --metadata "sha256=$sum" >/dev/null 2>&1
            aws --profile terminaldeck --endpoint-url "$endpoint" s3api head-object --bucket "$bucket" --key "$key" > "$work/upload.json" 2>/dev/null
            test "$(jq -er '.Metadata.sha256' "$work/upload.json")" = "$sum"
            test "$(jq -er '.ContentLength' "$work/upload.json")" = "$bytes"
            rm "$work/upload.json"
            uploaded=true
          fi
        fi
        jq -n --arg id "$id" --arg app "$app" --arg kind "$kind" --arg sum "$sum" --arg image "$image" --argjson bytes "$bytes" --argjson created "$(date +%s)000" --argjson uploaded "$uploaded" '{id:$id,appId:$app,kind:$kind,sha256:$sum,imageId:$image,bytes:$bytes,createdAt:$created,verified:true,uploaded:$uploaded}' > "$work/manifest.json"
        test "$(sha256sum "$work/data" | cut -d ' ' -f 1)" = "$sum"
        test ! -e "$dir/backups/$id"
        mv "$work" "$dir/backups/$id"
        work=
        # Retention runs only after dump, checksum, optional upload and atomic publication succeed.
        find "$dir/backups" -mindepth 2 -maxdepth 2 -name manifest.json -type f -exec cat {} \\; | jq -s -r --arg app "$app" --arg kind "$kind" --argjson keep "$retention" '[.[] | select(.verified == true and .appId == $app and .kind == $kind)] | sort_by(.createdAt) | reverse | .[$keep:][] | .id' > "$dir/backups/.retention-$id"
        while IFS= read -r old; do
          case "$old" in *[!a-zA-Z0-9_.-]*|''|.|..) continue;; esac
          test "$old" != "$id" || continue
          rm -rf -- "$dir/backups/$old"
        done < "$dir/backups/.retention-$id"
        rm "$dir/backups/.retention-$id"
        cat "$dir/backups/$id/manifest.json"
        """
    }

    private static let mongoDumpCommand = #"set -eu; umask 077; conf=$(mktemp); locked=0; unlock() { result=$?; if [ "$locked" = 1 ]; then mongosh --quiet --eval 'const a=process.env; if(db.getSiblingDB("admin").auth(a.MONGO_INITDB_ROOT_USERNAME,a.MONGO_INITDB_ROOT_PASSWORD)!==1) quit(1); if(!db.getSiblingDB("admin").fsyncUnlock().ok) quit(1)' >/dev/null 2>&1 || result=70; fi; rm -f "$conf"; exit "$result"; }; trap unlock EXIT; trap 'exit 130' HUP INT TERM; password=$(printf '%s' "$MONGO_INITDB_ROOT_PASSWORD" | sed "s/'/''/g"); printf "password: '%s'\n" "$password" > "$conf"; mongosh --quiet --eval 'const a=process.env; if(db.getSiblingDB("admin").auth(a.MONGO_INITDB_ROOT_USERNAME,a.MONGO_INITDB_ROOT_PASSWORD)!==1) quit(1); if(!db.getSiblingDB("admin").fsyncLock().ok) quit(1)' >/dev/null; locked=1; mongodump --config="$conf" --username="$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase=admin --db="$MONGO_INITDB_DATABASE" --archive --gzip"#

    public static func restoreScript(kind: String, file: String, containerID: String) -> String {
        let command: String
        switch kind {
        case "postgres": command = #"export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_restore --exit-on-error --clean --if-exists --no-owner --no-acl --username="$POSTGRES_USER" --dbname="$POSTGRES_DB""#
        case "mysql": command = #"export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql --user=root"#
        default: command = #"set -eu; umask 077; conf=$(mktemp); trap 'rm -f "$conf"' EXIT; trap 'exit 130' HUP INT TERM; password=$(printf '%s' "$MONGO_INITDB_ROOT_PASSWORD" | sed "s/'/''/g"); printf "password: '%s'\n" "$password" > "$conf"; mongorestore --config="$conf" --username="$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase=admin --nsInclude="$MONGO_INITDB_DATABASE.*" --archive --gzip --drop --stopOnError"#
        }
        if kind == "mysql" {
            // Materialise gzip first: a pipeline must never conceal a decompression failure.
            return "set -eu; umask 077; plain=$(mktemp); trap 'rm -f \"$plain\"' EXIT; trap 'exit 130' HUP INT TERM; gzip -dc \(BackendAppsRuntime.quote(file)) > \"$plain\"; docker exec -i \(BackendAppsRuntime.quote(containerID)) sh -c \(BackendAppsRuntime.quote(command)) < \"$plain\" >/dev/null 2>&1"
        }
        return "set -eu; docker exec -i \(BackendAppsRuntime.quote(containerID)) sh -c \(BackendAppsRuntime.quote(command)) < \(BackendAppsRuntime.quote(file)) >/dev/null 2>&1"
    }
    private static func redisRestoreScript(file: String, containerID: String, imageID: String, volume: String, helperName: String, appID: String) -> String {
        // The copy helper is transient, private and labelled. The original volume is never mounted here.
        """
        set -eu
        helper=\(BackendAppsRuntime.quote(helperName))
        trap 'docker rm -f "$helper" >/dev/null 2>&1 || true' EXIT
        trap 'exit 130' HUP INT TERM
        docker create --name "$helper" --network none --label \(BackendAppsRuntime.quote("io.terminaldeck.app=" + appID)) --label io.terminaldeck.managed=true --mount \(BackendAppsRuntime.quote("type=volume,source=" + volume + ",target=/data")) --entrypoint sh \(BackendAppsRuntime.quote(imageID)) -c 'redis-check-rdb /data/dump.rdb >/dev/null && chown redis:redis /data/dump.rdb' >/dev/null 2>&1
        docker cp \(BackendAppsRuntime.quote(file)) "$helper:/data/dump.rdb" >/dev/null 2>&1
        docker start -a "$helper" >/dev/null 2>&1
        test "$(docker inspect --format '{{.State.ExitCode}}' "$helper")" = 0
        """
    }
}
