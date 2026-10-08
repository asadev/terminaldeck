import Foundation
import TerminalDeckNativeCore

/// APD's contract-compatible backup service. Approvals belong to the injected channel authorizer.
/// Construction is inert: no Mac timer, process, authoritative state or credential cache.
public struct BackendAppsDataBackups: Sendable {
    public let runtime: BackendAppsRuntime
    public let store: BackendAppsStore
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore) { self.runtime = runtime; self.store = store }

    public func policyRead(serverID: String, appID: String) async throws -> NativeRPCValue {
        try validate(serverID: serverID, appID: appID)
        let record = try await store.read(serverID, appID)
        _ = try database(record)
        return try BackendAppsDataBackupPolicy.publicSaved(record["backupPolicy"])
    }

    public func list(serverID: String, appID: String) async throws -> NativeRPCValue {
        try validate(serverID: serverID, appID: appID)
        let record = try await store.read(serverID, appID), database = try database(record)
        let directory = try store.directory(appID)
        let script = #"""
        set -eu
        \#(Self.pathChecks(directory))
        dir=\#(BackendAppsRuntime.quote(directory))
        app=\#(BackendAppsRuntime.quote(appID))
        prefix=\#(BackendAppsRuntime.quote(runtime.resourcePrefix))
        command -v jq > /dev/null 2>&1
        test ! -L "$dir/backups"
        if [ ! -e "$dir/backups" ]; then printf '[]'; exit 0; fi
        test -d "$dir/backups"
        count=0
        {
          for folder in "$dir/backups"/*; do
            [ -d "$folder" ] && [ ! -L "$folder" ] || continue
            id=${folder##*/}
            case "$id" in "$prefix-"*) ;; *) continue;; esac
            case "$id" in *[!a-zA-Z0-9_.-]*|''|.|..) exit 65;; esac
            count=$((count + 1))
            test "$count" -le 512
            test -f "$folder/manifest.json" && test ! -L "$folder/manifest.json"
            test -f "$folder/data" && test ! -L "$folder/data"
            jq -ce --arg id "$id" --arg app "$app" '. | select(.id == $id and .appId == $app)' "$folder/manifest.json"
          done
        } > /dev/stdout
        """#
        // Avoid a shell pipeline: a failed manifest read must not be hidden by jq's successful empty array.
        let result = try await runtime.run(serverID, script, maximumBytes: 1_048_576)
        guard result.code == 0, !result.truncated else { throw NativeRPCError(code: "backup-failed", message: "Saved backup records could not be read safely.") }
        if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" { return .array([]) }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count <= 512 else { throw NativeRPCError(code: "backup-failed", message: "The saved backup list exceeds this build's limit.") }
        var records: [NativeRPCValue] = []
        do {
            for line in lines {
                records.append(try publicManifest(NativeRPCValue.parseJSON(Data(line.utf8)), appID: appID, kind: database.kind))
            }
        } catch { throw NativeRPCError(code: "backup-failed", message: "A saved backup record did not pass validation.") }
        return .array(records.sorted { ($0["createdAt"].number ?? 0) > ($1["createdAt"].number ?? 0) })
    }

    public func create(serverID: String, appID: String) async throws -> NativeRPCValue {
        try validate(serverID: serverID, appID: appID)
        return try await store.withLock(serverID, appID) {
            let record = try await store.read(serverID, appID), database = try database(record)
            let directory = try store.directory(appID)
            try await requireNoRecovery(serverID: serverID, directory: directory)
            let policy = try BackendAppsDataBackupPolicy.publicSaved(record["backupPolicy"])
            try await dependencies(serverID: serverID, scheduled: false, upload: !policy["upload"].isNullish)
            _ = try await inspect(serverID: serverID, appID: appID, database: database)
            let runner = try BackendAppsDataBackupRunner.script(directory: directory, appID: appID, prefix: runtime.resourcePrefix, network: runtime.privateNetwork)
            try await store.writeFile(serverID, path: directory + "/backup-run.sh", contents: Data(runner.utf8))
            let backupID = runtime.resourcePrefix + "-" + UUID().uuidString.lowercased()
            let output = try await runtime.checked(serverID, "sh " + BackendAppsRuntime.quote(directory + "/backup-run.sh") + " --already-locked " + BackendAppsRuntime.quote(backupID), timeoutMS: 3_600_000, code: "backup-failed", message: "The backup did not pass verification. Earlier backups were preserved.")
            do {
                let manifest = try NativeRPCValue.parseJSON(Data(output.utf8))
                return try publicManifest(manifest, appID: appID, kind: database.kind, expectedID: backupID)
            } catch { throw NativeRPCError(code: "backup-failed", message: "The server did not return a verified backup record.") }
        }
    }

    public func policy(serverID: String, appID: String, request: NativeRPCValue) async throws -> NativeRPCValue {
        try validate(serverID: serverID, appID: appID)
        // Validate user syntax before reaching the server, then resolve preservation while locked.
        _ = try BackendAppsDataBackupPolicy(request: request, allowUnresolvedPreservation: true)
        return try await store.withLock(serverID, appID) {
            let record = try await store.read(serverID, appID), database = try database(record)
            let directory = try store.directory(appID)
            try await requireNoRecovery(serverID: serverID, directory: directory)
            var existingUpload: BackendAppsDataS3Upload?
            let uploadRequest = request["upload"]
            let needsExisting = uploadRequest == .missing ||
                (!uploadRequest.isNullish && uploadRequest["accessKey"] == .missing && uploadRequest["secretKey"] == .missing)
            let savedPolicy = try BackendAppsDataBackupPolicy.publicSaved(record["backupPolicy"])
            if needsExisting {
                let saved = savedPolicy
                if !saved["upload"].isNullish {
                    let path = directory + "/.backup-s3-credentials"
                    _ = try await runtime.checked(serverID, "set -eu; " + Self.pathChecks(directory) + "; test ! -L " + BackendAppsRuntime.quote(path) + "; test -f " + BackendAppsRuntime.quote(path) + "; test \"$(stat -c %a " + BackendAppsRuntime.quote(path) + ")\" = 600; test \"$(stat -c %u " + BackendAppsRuntime.quote(path) + ")\" = \"$(id -u)\"", code: "state-failed", message: "Saved backup credentials are missing or not protected. Enter new credentials.")
                    guard let bytes = try await store.readFile(serverID, path: path) else {
                        throw NativeRPCError(code: "state-failed", message: "Saved backup credentials are missing. Enter new credentials.")
                    }
                    existingUpload = try BackendAppsDataS3Upload.fromProtectedFile(publicValue: saved["upload"], bytes: bytes)
                }
            }
            let policy = try BackendAppsDataBackupPolicy(request: request, preserving: existingUpload, previous: savedPolicy)
            try await dependencies(serverID: serverID, scheduled: true, upload: policy.upload != nil)
            _ = try await inspect(serverID: serverID, appID: appID, database: database)
            let payload = try BackendAppsDataBackupSchedule.payload(directory: directory, appID: appID, prefix: runtime.resourcePrefix, network: runtime.privateNetwork, policy: policy, now: runtime.now())
            let script = try BackendAppsDataBackupSchedule.transaction(directory: directory, appID: appID, prefix: runtime.resourcePrefix, policy: policy)
            let recoveryPlan = try await policyRecovery(directory: directory)
            do {
                _ = try await runtime.checked(serverID, script, stdin: payload, timeoutMS: 90_000, code: "state-failed", message: "The backup policy could not be saved and verified. Its previous state was restored when possible; check server recovery notes before retrying.")
                let savedRecord = try await store.read(serverID, appID)
                let saved = try BackendAppsDataBackupPolicy.publicSaved(savedRecord["backupPolicy"])
                guard Self.equalPublicPolicy(saved, policy.publicValue) else { throw NativeRPCError(code: "state-failed", message: "The server's saved backup policy does not match the requested policy.") }
                return saved
            } catch {
                if let recoveryPlan {
                    let restored = await Task { await recoverPolicy(recoveryPlan) }.value
                    throw NativeRPCError(code: "state-failed", message: restored ? "The backup policy did not finish. Its captured files and timer state were restored." : "The backup policy needs recovery. Its protected notes and snapshots remain; the previous timer state was not verified.")
                }
                throw error
            }
        }
    }

    public func restore(serverID: String, appID: String, backupID: String, confirmation: String) async throws -> NativeRPCValue {
        try validate(serverID: serverID, appID: appID)
        guard backupID.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("The backup ID is invalid.") }
        guard backupID.hasPrefix(runtime.resourcePrefix + "-") else { throw NativeRPCError.invalidArguments("That backup belongs to a different server namespace.") }
        return try await store.withLock(serverID, appID) {
            let original = try await store.read(serverID, appID)
            guard confirmation == original["name"].string else { throw NativeRPCError(code: "confirmation-required", message: "Type the database's exact name to restore over its data.") }
            let database = try database(original), directory = try store.directory(appID)
            try await requireNoRecovery(serverID: serverID, directory: directory)
            guard let bytes = try await store.readFile(serverID, path: directory + "/backups/" + backupID + "/manifest.json") else { throw NativeRPCError(code: "not-found", message: "That saved backup could not be found.") }
            let manifest: NativeRPCValue
            do { manifest = try NativeRPCValue.parseJSON(bytes); _ = try publicManifest(manifest, appID: appID, kind: database.kind, expectedID: backupID) }
            catch { throw NativeRPCError(code: "restore-failed", message: "The saved backup record did not pass validation.") }
            let imageID = manifest["imageId"].string!
            guard runtime.recovery == nil || imageID == database.imageID else {
                throw BackendAppsRuntime.unavailable("Safe recovery currently requires the backup and current database to use the same exact software. This older-version backup needs a separate recovery workflow; no database data was changed.")
            }
            let backupImage = manifest["image"].string ?? ""
            let backupVersion: String
            if backupImage.isEmpty {
                guard imageID == database.imageID else { throw BackendAppsRuntime.unavailable("This older backup has no saved software version. Its exact version needs a recovery check.") }
                backupVersion = database.version
            } else {
                guard !backupImage.contains("\n"), !backupImage.contains("\r"), !backupImage.contains("\0"), let colon = backupImage.lastIndex(of: ":") else { throw NativeRPCError(code: "restore-failed", message: "The backup's saved software version is invalid.") }
                backupVersion = String(backupImage[backupImage.index(after: colon)...])
                let savedSpec = try BackendAppsDatabaseSpec(kind: database.kind, version: backupVersion)
                guard savedSpec.image == backupImage else { throw NativeRPCError(code: "restore-failed", message: "The backup's saved software version is invalid.") }
            }
            try await dependencies(serverID: serverID, scheduled: false, upload: false)
            let file = directory + "/backups/" + backupID + "/data"
            _ = try await runtime.checked(serverID, Self.verificationScript(directory: directory, backupID: backupID, sha256: manifest["sha256"].string!, bytes: Int64(manifest["bytes"].number!)), code: "restore-failed", message: "The saved backup failed its size or checksum check. The database has not been changed.")
            let source = try await inspect(serverID: serverID, appID: appID, database: database)
            let healthTest = source["Config"]["Healthcheck"]["Test"].elements
            guard healthTest == [.string("CMD-SHELL"), .string(try BackendAppsDataDatabases.authenticatedHealthcheck(kind: database.kind))] else {
                throw BackendAppsRuntime.unavailable("This database needs a verified sign-in health check before restore. Its data has not been changed.")
            }
            let image = try await request(serverID, "GET", "/images/" + imageID + "/json", nil)
            guard image.ok, try image.value()["Id"].string == imageID else { throw BackendAppsRuntime.unavailable("The exact database software used by this backup is no longer saved on the server.") }
            let wasRunning = source["State"]["Running"].bool == true
            let suffix = UUID().uuidString.lowercased()
            let volume = runtime.resourcePrefix + "-" + appID + "-restore-" + suffix
            let name = volume
            let restoreToken = UUID().uuidString.lowercased()
            let transaction = BackendAppsRecoveryContext.current
            var labels = BackendAppsValidation.object([("io.terminaldeck.app", .string(appID)), ("io.terminaldeck.managed", .string("true")), ("io.terminaldeck.restore", .string(backupID)), ("io.terminaldeck.restore-token", .string(restoreToken))])
            if let transaction { labels = labels.setting("io.terminaldeck.transaction", .string(transaction.scope.ownerToken)) }
            let previous = try await request(serverID, "GET", "/volumes/" + volume, nil)
            guard previous.status == 404 else { throw NativeRPCError(code: "conflict", message: "A recovery data volume already uses this name. No existing data was changed.") }
            var journal = BackendAppsValidation.object([
                ("appId", .string(appID)), ("backupId", .string(backupID)), ("phase", .string("preparing")),
                ("originalContainerId", .string(database.containerID)), ("originalVolumeName", .string(database.volume)),
                ("candidateVolumeName", .string(volume)), ("candidateImageId", .string(imageID)), ("restoreToken", .string(restoreToken)), ("originalRunning", .bool(wasRunning)), ("createdAt", .number(runtime.now()))
            ])
            let journalPath = directory + "/data-restore-intent.json"
            // Before-images are sealed while the original approval remains live, before any mutation.
            let databaseRecovery = try await transaction?.register(.recoverDatabase(originalID: database.containerID))
            let stateRecovery = try await transaction?.register(.restoreAppFile(path: directory + "/state.json"))
            let journalRecovery = try await transaction?.register(.restoreAppFile(path: journalPath))
            var candidate: String?
            var candidateVerified = false
            var originalStopped = false
            var oldDisconnected = false
            var candidateConnected = false
            var stateCommitted = false
            do {
                try await store.writeFile(serverID, path: journalPath, contents: journal.encodedJSON())
                let createdVolume = try await request(serverID, "POST", "/volumes/create", try BackendAppsValidation.object([("Name", .string(volume)), ("Labels", labels)]).encodedJSON())
                guard createdVolume.ok else { throw NativeRPCError(code: "restore-failed", message: "The recovery data volume could not be created.") }
                let volumeResponse = try await request(serverID, "GET", "/volumes/" + volume, nil)
                guard volumeResponse.ok else { throw NativeRPCError(code: "restore-failed", message: "The recovery data volume could not be inspected.") }
                let volumeValue = try volumeResponse.value()
                guard volumeValue["Name"].string == volume, volumeValue["Driver"].string == "local",
                      volumeValue["Labels"]["io.terminaldeck.app"].string == appID,
                      volumeValue["Labels"]["io.terminaldeck.managed"].string == "true",
                      volumeValue["Labels"]["io.terminaldeck.restore-token"].string == restoreToken,
                      volumeValue["Options"].isNullish || volumeValue["Options"].fields?.isEmpty == true else {
                    throw NativeRPCError(code: "restore-failed", message: "The recovery data volume belongs to a different operation. No data was restored.")
                }
                let env = try await store.environment(serverID, appID)
                let spec = try BackendAppsDatabaseSpec(kind: database.kind, version: backupVersion)
                let body = BackendAppsDataDatabases.container(spec: spec, appID: appID, volume: volume, environment: env, labels: labels, network: runtime.privateNetwork, prefix: runtime.resourcePrefix, alias: false).setting("Image", .string(imageID))
                let response = try await request(serverID, "POST", "/containers/create?name=" + name, try body.encodedJSON())
                guard response.ok, let id = try response.value()["Id"].string, id.range(of: #"\A[a-f0-9]{12,64}\z"#, options: .regularExpression) != nil else { throw NativeRPCError(code: "restore-failed", message: "The recovery database could not be created.") }
                candidate = id
                journal = journal.setting("candidateContainerId", .string(id)).setting("phase", .string("restoring"))
                try await store.writeFile(serverID, path: journalPath, contents: journal.encodedJSON())
                let candidateInspect = try await BackendAppsDataDatabases.inspectOwned(runtime: runtime, serverID: serverID, appID: appID, containerID: id, volumeName: volume, expectedImageID: imageID, kind: database.kind)
                guard candidateInspect["Config"]["Labels"]["io.terminaldeck.restore-token"].string == restoreToken else { throw NativeRPCError(code: "restore-failed", message: "The recovery database belongs to a different operation. No data was restored.") }
                candidateVerified = true
                let stop = try await request(serverID, "POST", "/containers/" + database.containerID + "/stop?t=30", nil)
                guard stop.ok || stop.status == 304 else { throw NativeRPCError(code: "restore-failed", message: "The original database could not be stopped safely.") }
                originalStopped = true
                let stopped = try await inspect(serverID: serverID, appID: appID, database: database)
                guard stopped["State"]["Running"].bool == false else { throw NativeRPCError(code: "restore-failed", message: "The original database did not stop safely.") }
                // Recheck immediately before data consumption while the selected app remains locked.
                _ = try await runtime.checked(serverID, Self.verificationScript(directory: directory, backupID: backupID, sha256: manifest["sha256"].string!, bytes: Int64(manifest["bytes"].number!)), code: "restore-failed", message: "The backup changed before restore. The original data was preserved.")
                if database.kind == "redis" {
                    _ = try await runtime.checked(serverID, Self.redisCopyScript(file: file, volume: volume, imageID: imageID, appID: appID, helperName: runtime.resourcePrefix + "-" + appID + "-restore-copy-" + suffix, transactionToken: transaction?.scope.ownerToken), timeoutMS: 600_000, code: "restore-failed", message: "The Redis recovery copy did not pass verification.")
                }
                let start = try await request(serverID, "POST", "/containers/" + id + "/start", nil)
                guard start.ok || start.status == 304 else { throw NativeRPCError(code: "restore-failed", message: "The recovery database could not start.") }
                try await BackendAppsDataDatabases.waitHealthy(runtime: runtime, serverID: serverID, appID: appID, containerID: id, volumeName: volume, expectedImageID: imageID, kind: database.kind)
                if database.kind != "redis" {
                    _ = try await runtime.checked(serverID, BackendAppsBackups.restoreScript(kind: database.kind, file: file, containerID: id), timeoutMS: 3_600_000, code: "restore-failed", message: "The backup could not be restored into the recovery database.")
                    try await BackendAppsDataDatabases.waitHealthy(runtime: runtime, serverID: serverID, appID: appID, containerID: id, volumeName: volume, expectedImageID: imageID, kind: database.kind)
                }
                journal = journal.setting("phase", .string("switching"))
                try await store.writeFile(serverID, path: journalPath, contents: journal.encodedJSON())
                try await network(serverID: serverID, method: "disconnect", containerID: database.containerID)
                oldDisconnected = true
                try await network(serverID: serverID, method: "disconnect", containerID: id)
                try await network(serverID: serverID, method: "connect", containerID: id, alias: runtime.resourcePrefix + "-" + appID)
                candidateConnected = true
                try await BackendAppsDataDatabases.waitHealthy(runtime: runtime, serverID: serverID, appID: appID, containerID: id, volumeName: volume, expectedImageID: imageID, kind: database.kind)
                let activated = try await BackendAppsDataDatabases.inspectOwned(runtime: runtime, serverID: serverID, appID: appID, containerID: id, volumeName: volume, expectedImageID: imageID, kind: database.kind)
                guard activated["NetworkSettings"]["Networks"][runtime.privateNetwork]["Aliases"].elements?.contains(.string(runtime.resourcePrefix + "-" + appID)) == true else { throw NativeRPCError(code: "restore-failed", message: "The restored database's private address did not pass verification.") }
                let detached = try await request(serverID, "GET", "/containers/" + database.containerID + "/json", nil)
                guard detached.ok else { throw NativeRPCError(code: "restore-failed", message: "The original database's released address could not be verified.") }
                let oldState = try detached.value()
                guard oldState["Id"].string == database.containerID,
                      oldState["Config"]["Labels"]["io.terminaldeck.app"].string == appID,
                      oldState["Config"]["Labels"]["io.terminaldeck.managed"].string == "true",
                      oldState["NetworkSettings"]["Networks"][runtime.privateNetwork].isNullish else { throw NativeRPCError(code: "restore-failed", message: "The original database's private address was not released safely.") }
                let recoveries = (original["databaseRecovery"].elements ?? []) + [Self.recovery(containerID: database.containerID, volume: database.volume, now: runtime.now(), reason: "before-restore")]
                let updated = original.setting("containerId", .string(id)).setting("database", original["database"].setting("containerId", .string(id)).setting("volumeName", .string(volume)).setting("imageId", .string(imageID)).setting("image", .string(spec.image))).setting("databaseRecovery", .array(recoveries)).setting("status", .string("running")).setting("updatedAt", .number(runtime.now()))
                try await store.write(serverID, appID, updated)
                stateCommitted = true
                // Durable state is already switched; cleanup failure must never roll a successful switch back.
                try await removeJournal(serverID: serverID, directory: directory)
                return BackendAppsValidation.object([("restored", .bool(true)), ("recoveryPreserved", .bool(true))])
            } catch {
                if stateCommitted {
                    throw NativeRPCError(code: "restore-failed", message: "The restored database is active and its original data is preserved, but recovery notes could not be cleared. Inspect the saved restore journal before another change.")
                }
                let heldCandidate = candidate, heldVerified = candidateVerified, heldStopped = originalStopped, heldDisconnected = oldDisconnected, heldConnected = candidateConnected, heldJournal = journal
                // A fresh task inherits RPC identity. Expired/cancelled approval tickets still fail closed;
                // DKA must provide a scoped transaction-recovery lease before exposing these writes.
                let recovered: Bool
                if runtime.recovery != nil {
                    guard let transaction, let databaseRecovery, let stateRecovery, let journalRecovery else {
                        throw NativeRPCError(code: "restore-failed", message: "The database's sealed recovery plans are unavailable. Both data volumes and the restore journal were preserved.")
                    }
                    let result = await Task { () -> (recovered: Bool, noteCleanupUncertain: Bool) in
                        // The combined plan verifies candidate quiescence, original aliases/authenticated
                        // health, and candidate fallback on failure. It never deletes a container/volume.
                        guard (try? await transaction.perform(databaseRecovery).completed) == true else { return (false, false) }
                        guard (try? await transaction.perform(stateRecovery).completed) == true else { return (false, false) }
                        guard (try? await transaction.perform(journalRecovery).completed) == true else { return (false, true) }
                        return (true, false)
                    }.value
                    if result.noteCleanupUncertain {
                        throw NativeRPCError(code: "restore-failed", message: "The original database and its captured state were restored, but recovery-note cleanup could not be verified. Both data volumes were kept; inspect the server notes before another change.")
                    }
                    recovered = result.recovered
                } else {
                    recovered = await Task { await compensate(serverID: serverID, appID: appID, original: original, database: database, directory: directory, candidate: heldCandidate, candidateVerified: heldVerified, volume: volume, wasRunning: wasRunning, originalStopped: heldStopped, oldDisconnected: heldDisconnected, candidateConnected: heldConnected, journal: heldJournal) }.value
                }
                throw NativeRPCError(code: "restore-failed", message: recovered ? "Restore did not finish. The original database was recovered and all saved data was preserved." : "Restore did not finish. The saved database data and restore journal were preserved; the original database needs a status check before retrying.")
            }
        }
    }

    private struct Database: Sendable {
        let kind: String, containerID: String, volume: String, imageID: String, version: String
    }
    private func validate(serverID: String, appID: String) throws {
        try BackendAppsDataDatabases.validateRuntime(runtime, appID: appID)
        guard !serverID.isEmpty, serverID.utf8.count <= 128, !serverID.contains("\0"),
              runtime.resourcePrefix != "td-test" || appID.hasPrefix("td-test-") else {
            throw NativeRPCError.invalidArguments("Use a saved server and database in the selected namespace.")
        }
    }
    private func database(_ record: NativeRPCValue) throws -> Database {
        guard let kind = record["kind"].string, ["postgres", "mysql", "redis", "mongodb"].contains(kind),
              let container = record["database"]["containerId"].string, container.range(of: #"\A[a-f0-9]{12,64}\z"#, options: .regularExpression) != nil,
              record["containerId"].string == container,
              let volume = record["database"]["volumeName"].string, volume.hasPrefix(runtime.resourcePrefix + "-"), volume.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,191}\z"#, options: .regularExpression) != nil,
              let imageID = record["database"]["imageId"].string, imageID.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
              let image = record["database"]["image"].string, !image.contains("\n"), !image.contains("\r"), !image.contains("\0"), let colon = image.lastIndex(of: ":") else { throw BackendAppsRuntime.unavailable("Backups need a managed database with verified saved data and software identity.") }
        let version = String(image[image.index(after: colon)...]), spec = try BackendAppsDatabaseSpec(kind: kind, version: version)
        guard spec.image == image, record["database"]["network"].string == runtime.privateNetwork, record["database"]["dataPath"].string == spec.dataPath else { throw NativeRPCError(code: "state-failed", message: "The database's saved data location does not match its managed configuration.") }
        return Database(kind: kind, containerID: container, volume: volume, imageID: imageID, version: version)
    }

    private func inspect(serverID: String, appID: String, database: Database) async throws -> NativeRPCValue {
        try await BackendAppsDataDatabases.inspectOwned(runtime: runtime, serverID: serverID, appID: appID, containerID: database.containerID, volumeName: database.volume, expectedImageID: database.imageID, kind: database.kind)
    }

    public func publicManifest(_ manifest: NativeRPCValue, appID: String, kind: String, expectedID: String? = nil) throws -> NativeRPCValue {
        guard manifest["appId"].string == appID, manifest["kind"].string == kind, manifest["verified"].bool == true,
              let id = manifest["id"].string, id.hasPrefix(runtime.resourcePrefix + "-"), expectedID == nil || id == expectedID,
              let bytes = manifest["bytes"].number, bytes.isFinite, bytes > 0, bytes.rounded() == bytes, bytes < 9_007_199_254_740_991,
              let created = manifest["createdAt"].number, created.isFinite, created > 0, created.rounded() == created,
              let sha = manifest["sha256"].string, sha.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
              let image = manifest["imageId"].string, image.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
              let uploaded = manifest["uploaded"].bool else { throw NativeRPCError(code: "backup-failed", message: "A saved backup record did not pass validation.") }
        guard id.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil else { throw NativeRPCError(code: "backup-failed", message: "A saved backup ID is invalid.") }
        return BackendAppsValidation.object([("id", .string(id)), ("appId", .string(appID)), ("kind", .string(kind)), ("createdAt", .number(created)), ("bytes", .number(bytes)), ("sha256", .string(sha)), ("verified", .bool(true)), ("uploaded", .bool(uploaded))])
    }

    public static func verificationScript(directory: String, backupID: String, sha256: String, bytes: Int64) throws -> String {
        guard directory.range(of: #"\A/var/lib/(?:terminaldeck/apps|[a-z][a-z0-9-]{0,47}-apps)/[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil,
              backupID.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil,
              sha256.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil, bytes > 0 else {
            throw NativeRPCError.invalidArguments("The backup verification input is invalid.")
        }
        return #"""
        set -eu
        \#(pathChecks(directory))
        dir=\#(BackendAppsRuntime.quote(directory))
        folder="$dir/backups/\#(backupID)"
        test -d "$dir/backups" && test ! -L "$dir/backups"
        test -d "$folder" && test ! -L "$folder"
        file="$folder/data"
        test -f "$file" && test ! -L "$file"
        test -f "$folder/manifest.json" && test ! -L "$folder/manifest.json"
        test "$(sha256sum "$file" | cut -d ' ' -f 1)" = \#(BackendAppsRuntime.quote(sha256))
        test "$(wc -c < "$file" | tr -d ' ')" = \#(BackendAppsRuntime.quote(String(bytes)))
        """#
    }

    private static func pathChecks(_ directory: String) -> String {
        let root = String(directory[..<directory.lastIndex(of: "/")!])
        return "test ! -L /var/lib/terminaldeck; test ! -L " + BackendAppsRuntime.quote(root) + "; test -d " + BackendAppsRuntime.quote(directory) + "; test ! -L " + BackendAppsRuntime.quote(directory)
    }

    private func requireNoRecovery(serverID: String, directory: String) async throws {
        _ = try await runtime.checked(serverID, "set -eu; " + Self.pathChecks(directory) + "; for file in data-restore-intent.json data-backup-policy-recovery.json; do test ! -e " + BackendAppsRuntime.quote(directory) + "/\"$file\" && test ! -L " + BackendAppsRuntime.quote(directory) + "/\"$file\" || exit 73; done", code: "conflict", message: "This database has saved recovery notes. Inspect them before another backup or restore change.")
    }

    private func dependencies(serverID: String, scheduled: Bool, upload: Bool) async throws {
        let commands = ["docker", "jq", "sha256sum", "gzip", "date", "wc", "cut", "tr", "stat", "id", "sync", "cp", "mv", "rm", "mkdir", "chmod", "cat", "grep"] + (scheduled ? ["systemctl", "systemd-analyze"] : []) + (upload ? ["aws"] : [])
        let script = "set -eu; " + commands.map { "command -v " + BackendAppsRuntime.quote($0) + " > /dev/null 2>&1" }.joined(separator: "; ") + (scheduled ? "; test -d /run/systemd/system; test \"$(id -u)\" = 0" : "")
        _ = try await runtime.checked(serverID, script, code: "unavailable", message: upload ? "Backups need the server's database tools, systemd and AWS CLI. No software was installed." : (scheduled ? "Scheduled backups need the server's database tools and systemd. No software was installed." : "Backups need the server's database tools, jq, gzip and sha256sum. No software was installed."))
    }

    private func network(serverID: String, method: String, containerID: String, alias: String? = nil) async throws {
        var value = BackendAppsValidation.object([("Container", .string(containerID))])
        if method == "disconnect" { value = value.setting("Force", .bool(false)) }
        else if let alias { value = value.setting("EndpointConfig", BackendAppsValidation.object([("Aliases", .array([.string(alias)]))])) }
        let response = try await request(serverID, "POST", "/networks/" + runtime.privateNetwork + "/" + method, try value.encodedJSON())
        guard response.ok else { throw NativeRPCError(code: "restore-failed", message: "The database's private address could not be changed safely.") }
    }

    private struct PolicyRecovery: Sendable {
        let transaction: BackendAppsRecoveryTransaction
        let files: [BackendAppsRecoveryHandle]
        let timer: BackendAppsRecoveryHandle
        let notes: BackendAppsRecoveryHandle
    }
    private func policyRecovery(directory: String) async throws -> PolicyRecovery? {
        guard runtime.recovery != nil else { return nil }
        guard let transaction = BackendAppsRecoveryContext.current, transaction.scope.appDirectory == directory else {
            throw NativeRPCError(code: "access-denied", message: "This backup policy has no scoped recovery transaction.")
        }
        let unit = transaction.scope.resourcePrefix + "-" + transaction.scope.appID + "-backup"
        var files: [BackendAppsRecoveryHandle] = []
        for path in [directory + "/backup-policy.json", directory + "/backup-run.sh", directory + "/.backup-s3-credentials", directory + "/state.json", "/etc/systemd/system/" + unit + ".service", "/etc/systemd/system/" + unit + ".timer"] {
            files.append(try await transaction.register(.restoreAppFile(path: path)))
        }
        let timer = try await transaction.register(.restoreBackupTimer(unit: unit + ".timer"))
        let notes = try await transaction.register(.restoreAppFile(path: directory + "/data-backup-policy-recovery.json"))
        return PolicyRecovery(transaction: transaction, files: files, timer: timer, notes: notes)
    }
    private func recoverPolicy(_ plan: PolicyRecovery) async -> Bool {
        var filesRestored = true
        for handle in plan.files {
            if (try? await plan.transaction.perform(handle).completed) != true { filesRestored = false }
        }
        guard filesRestored, (try? await plan.transaction.perform(plan.timer).completed) == true else { return false }
        // Remove the captured-absent note only after every file and the timer baseline are verified.
        return (try? await plan.transaction.perform(plan.notes).completed) == true
    }

    private func compensate(serverID: String, appID: String, original: NativeRPCValue, database: Database, directory: String, candidate: String?, candidateVerified: Bool, volume: String, wasRunning: Bool, originalStopped: Bool, oldDisconnected: Bool, candidateConnected: Bool, journal: NativeRPCValue) async -> Bool {
        var recovered = true
        if let candidate {
            do {
                guard candidateVerified else { throw BackendAppsRuntime.unavailable("The candidate identity was not verified.") }
                let response = try await request(serverID, "GET", "/containers/" + candidate + "/json", nil)
                guard response.ok else { throw BackendAppsRuntime.unavailable("The candidate could not be inspected for recovery.") }
                let current = try response.value()
                guard current["Id"].string == candidate, current["Config"]["Labels"]["io.terminaldeck.app"].string == appID,
                      current["Config"]["Labels"]["io.terminaldeck.managed"].string == "true",
                      current["Config"]["Labels"]["io.terminaldeck.restore-token"] == journal["restoreToken"] else {
                    throw BackendAppsRuntime.unavailable("The candidate's ownership changed during recovery.")
                }
                let stop = try await request(serverID, "POST", "/containers/" + candidate + "/stop?t=30", nil)
                guard stop.ok || stop.status == 304 else { throw BackendAppsRuntime.unavailable("The recovery candidate could not be stopped safely.") }
                if current["NetworkSettings"]["Networks"][runtime.privateNetwork].fields != nil { try await network(serverID: serverID, method: "disconnect", containerID: candidate) }
                let detached = try await request(serverID, "GET", "/containers/" + candidate + "/json", nil)
                guard detached.ok else { throw BackendAppsRuntime.unavailable("The candidate address was not released.") }
                let checked = try detached.value()
                guard checked["State"]["Running"].bool == false, checked["NetworkSettings"]["Networks"][runtime.privateNetwork].isNullish else { throw BackendAppsRuntime.unavailable("The candidate did not stop and release its address.") }
            } catch { recovered = false }
        }
        guard recovered else { return false }
        do {
            let response = try await request(serverID, "GET", "/containers/" + database.containerID + "/json", nil)
            guard response.ok else { throw BackendAppsRuntime.unavailable("The original could not be inspected for recovery.") }
            let current = try response.value()
            guard current["Id"].string == database.containerID, current["Image"].string == database.imageID,
                  current["Config"]["Labels"]["io.terminaldeck.app"].string == appID,
                  current["Config"]["Labels"]["io.terminaldeck.managed"].string == "true" else { throw BackendAppsRuntime.unavailable("The original's ownership changed during recovery.") }
            if current["NetworkSettings"]["Networks"][runtime.privateNetwork].fields == nil {
                try await network(serverID: serverID, method: "connect", containerID: database.containerID, alias: runtime.resourcePrefix + "-" + appID)
            }
            if wasRunning && current["State"]["Running"].bool != true {
                let start = try await request(serverID, "POST", "/containers/" + database.containerID + "/start", nil)
                guard start.ok || start.status == 304 else { throw BackendAppsRuntime.unavailable("Recovery restart failed.") }
            }
            if wasRunning { try await BackendAppsDataDatabases.waitHealthy(runtime: runtime, serverID: serverID, appID: appID, containerID: database.containerID, volumeName: database.volume, expectedImageID: database.imageID, kind: database.kind) }
        } catch { recovered = false }
        if recovered {
            do {
                let checked = try await inspect(serverID: serverID, appID: appID, database: database)
                guard checked["State"]["Running"].bool == wasRunning,
                      checked["NetworkSettings"]["Networks"][runtime.privateNetwork]["Aliases"].elements?.contains(.string(runtime.resourcePrefix + "-" + appID)) == true else { throw BackendAppsRuntime.unavailable("Recovery state could not be verified.") }
                var recoveries = original["databaseRecovery"].elements ?? []
                recoveries.append(Self.recovery(containerID: candidate, volume: volume, now: runtime.now(), reason: "failed-restore"))
                try await store.write(serverID, appID, original.setting("databaseRecovery", .array(recoveries)).setting("updatedAt", .number(runtime.now())))
                try await removeJournal(serverID: serverID, directory: directory)
            } catch { recovered = false }
        }
        if !recovered {
            try? await store.writeFile(serverID, path: directory + "/data-restore-intent.json", contents: journal.setting("phase", .string("recovery-required")).encodedJSON())
        }
        return recovered
    }

    private func removeJournal(serverID: String, directory: String) async throws {
        let path = directory + "/data-restore-intent.json"
        _ = try await runtime.checked(serverID, "set -eu; " + Self.pathChecks(directory) + "; test ! -L " + BackendAppsRuntime.quote(path) + "; rm -- " + BackendAppsRuntime.quote(path) + "; sync -f " + BackendAppsRuntime.quote(directory), code: "state-failed", message: "The database's restore notes could not be safely cleared.")
    }

    private static func recovery(containerID: String?, volume: String, now: Double, reason: String) -> NativeRPCValue {
        BackendAppsValidation.object([("containerId", containerID.map(NativeRPCValue.string) ?? .null), ("volumeName", .string(volume)), ("createdAt", .number(now)), ("reason", .string(reason))])
    }

    private static func equalPublicPolicy(_ lhs: NativeRPCValue, _ rhs: NativeRPCValue) -> Bool {
        lhs["enabled"] == rhs["enabled"] && lhs["schedule"] == rhs["schedule"] && lhs["retention"] == rhs["retention"] &&
        lhs["upload"]["endpoint"] == rhs["upload"]["endpoint"] && lhs["upload"]["bucket"] == rhs["upload"]["bucket"] && lhs["upload"]["prefix"] == rhs["upload"]["prefix"]
    }

    private func request(_ serverID: String, _ method: String, _ path: String, _ body: Data?) async throws -> BackendAppsHTTPResponse {
        do { return try await runtime.docker(serverID, method, path, body) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendAppsRuntime.unavailable("The database service connection did not finish. Check the saved server connection.") }
    }

    private static func redisCopyScript(file: String, volume: String, imageID: String, appID: String, helperName: String, transactionToken: String?) -> String {
        let transactionLabel = transactionToken.map { "--label " + BackendAppsRuntime.quote("io.terminaldeck.transaction=" + $0) } ?? ""
        return #"""
        set -eu
        helper=\#(BackendAppsRuntime.quote(helperName))
        owned=0
        cleanup() { result=$?; if [ "$owned" = 1 ]; then docker rm -f "$helper" >/dev/null 2>&1 || result=70; fi; exit "$result"; }
        trap cleanup EXIT
        trap 'exit 130' HUP INT TERM
        docker create --name "$helper" --network none --label \#(BackendAppsRuntime.quote("io.terminaldeck.app=" + appID)) --label io.terminaldeck.managed=true \#(transactionLabel) --mount \#(BackendAppsRuntime.quote("type=volume,source=" + volume + ",target=/data")) --entrypoint sh \#(BackendAppsRuntime.quote(imageID)) -c 'redis-check-rdb /data/dump.rdb >/dev/null && chown redis:redis /data/dump.rdb' >/dev/null 2>&1
        owned=1
        docker cp \#(BackendAppsRuntime.quote(file)) "$helper:/data/dump.rdb" >/dev/null 2>&1
        docker start -a "$helper" >/dev/null 2>&1
        test "$(docker inspect --format '{{.State.ExitCode}}' "$helper")" = 0
        """#
    }
}
