import Foundation
import CryptoKit
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// An in-memory server command boundary. It interprets only the protected file
/// and lock operations used by BackendAppsStore. It never executes a shell,
/// opens SSH, or writes /var/lib. Unknown commands fail instead of succeeding.
actor DKTAppsServerFiles {
    struct Invocation: Sendable {
        let serverID: String
        let script: String
        let stdin: Data?
        let timeoutMS: Int
        let maximumBytes: Int
    }
    private var files: [String: Data] = [:]
    private var locks: Set<String> = []
    private var failedWrites: [String: Int] = [:]
    private var writesBeforeFailure: [String: Int] = [:]
    private var scriptReplies: [(contains: String, result: BackendServersRunResult)] = []
    private(set) var invocations: [Invocation] = []
    private(set) var unsupportedCommands: [String] = []
    private(set) var boundaryEvents: [String] = []
    private var acceptedRecoveryRequests: [UUID: NativeRPCContext] = [:]
    private var pinnedRecoveryScopes: Set<UUID> = []
    private(set) var recoveryAudit: [BackendAppsRecoveryAudit] = []

    func seed(path: String, data: Data) { files[path] = data }
    func contents(path: String) -> Data? { files[path] }
    func lockPaths() -> Set<String> { locks }
    func failNextWrite(path: String, count: Int = 1, afterSuccessfulWrites: Int = 0) {
        failedWrites[path] = count
        writesBeforeFailure[path] = afterSuccessfulWrites
    }
    func noteBoundary(_ event: String) { boundaryEvents.append(event) }
    func replyToScript(containing: String, code: Int = 0, stdout: String = "", stderr: String = "") {
        scriptReplies.append((containing, .init(code: code, stdout: stdout, stderr: stderr)))
    }

    func acceptRecoveryApproval(_ action: BackendAppsAction, context: NativeRPCContext) throws {
        try context.require(BackendAppsDataChannels.writeChannels.contains(action.channel) ? "apps.write" : "apps.read")
        guard action.serverID == DKTAppsFixtures.serverID, action.appID == DKTAppsFixtures.appID,
              context.ownerID == "dkt-owner" else { throw NativeRPCError(code: "access-denied", message: "Approval is outside the synthetic app scope.") }
        if BackendAppsDataChannels.writeChannels.contains(action.channel) { acceptedRecoveryRequests[context.requestID] = context }
    }

    private func checkRecoveryReceipt(_ scope: BackendAppsRecoveryScope, context: NativeRPCContext?) throws {
        guard let context, let accepted = acceptedRecoveryRequests[context.requestID],
              context.caller == accepted.caller, context.ownerID == accepted.ownerID,
              context.capabilities == accepted.capabilities, context.capabilities.contains("apps.write"),
              scope.requestID == context.requestID, scope.ownerID == context.ownerID,
              scope.serverID == DKTAppsFixtures.serverID, scope.appID == DKTAppsFixtures.appID else {
            throw NativeRPCError(code: "access-denied", message: "The synthetic recovery capture has no matching accepted write receipt.")
        }
    }
    private func pinRecovery(_ scope: BackendAppsRecoveryScope, context: NativeRPCContext?) throws {
        try checkRecoveryReceipt(scope, context: context)
        pinnedRecoveryScopes.insert(scope.transactionID)
    }
    private func checkPinnedRecovery(_ scope: BackendAppsRecoveryScope) throws {
        guard pinnedRecoveryScopes.contains(scope.transactionID) else {
            throw NativeRPCError(code: "access-denied", message: "The synthetic pinned recovery transport is closed.")
        }
    }
    private func closePinnedRecovery(_ scope: BackendAppsRecoveryScope) { pinnedRecoveryScopes.remove(scope.transactionID) }
    private func noteRecoveryAudit(_ event: BackendAppsRecoveryAudit) { recoveryAudit.append(event) }

    func execute(serverID: String, command: String, stdin: Data?, timeoutMS: Int,
                 maximumBytes: Int, caddy: DKTFakeCaddy? = nil) throws -> BackendServersRunResult {
        let script = Self.unwrap(command)
        invocations.append(.init(serverID: serverID, script: script, stdin: stdin,
                                 timeoutMS: timeoutMS, maximumBytes: maximumBytes))
        guard serverID == "dkt-fake-server" else { throw NativeRPCError(code: "access-denied", message: "The fixture accepts only its synthetic server.") }

        if script == "cat '/var/lib/td-test-caddy/autosave.json'", let caddy {
            boundaryEvents.append("caddy-autosave-read")
            return result(0, stdout: String(decoding: try caddy.persistedSnapshot(), as: UTF8.self))
        }

        if script.contains("td_owner=''"), script.contains("IFS= read -r td_owner < "),
           script.contains("rm -- "), script.contains("rmdir ") {
            guard let ownerPath = Self.paths(in: script).first(where: { $0.hasSuffix("-caddy-lock/owner") }),
                  let expected = Self.captures(#"\[ "\$td_owner" = '([A-Za-z0-9_.-]{1,128})' \]"#, in: script).first?.first else {
                return result(74)
            }
            let lockPath = String(ownerPath.dropLast("/owner".count))
            let quote = BackendAppsRuntime.quote
            guard locks.contains(lockPath), files[ownerPath] == Data(expected.utf8),
                  script.contains("test ! -L " + quote(lockPath)),
                  script.contains("test ! -L " + quote(ownerPath)),
                  script.contains("test -f " + quote(ownerPath)),
                  script.contains("rm -- " + quote(ownerPath)),
                  script.contains("rmdir " + quote(lockPath)) else { return result(74) }
            files[ownerPath] = nil
            locks.remove(lockPath)
            boundaryEvents.append("lock-release:" + lockPath)
            return result(0)
        }

        if script.contains("rmdir -- "), script.contains("/owner") {
            let paths = Self.paths(in: script)
            guard let lockPath = paths.last else { return result(45) }
            if !locks.contains(lockPath), files[lockPath + "/owner"] == nil,
               script.contains("test -e " + BackendAppsRuntime.quote(lockPath) + " || exit 0") { return result(0) }
            guard let owner = files[lockPath + "/owner"],
                  script.contains("= '" + String(decoding: owner, as: UTF8.self) + "'"),
                  locks.remove(lockPath) != nil else { return result(45) }
            files[lockPath + "/owner"] = nil
            return result(0)
        }
        if script.contains("$(cat -- "), script.contains("/owner"), !script.contains("mkdir "),
           !script.contains("rm -- "), let ownerPath = Self.paths(in: script).first(where: { $0.hasSuffix("/owner") }) {
            let lockPath = String(ownerPath.dropLast("/owner".count))
            guard let owner = files[ownerPath], locks.contains(lockPath),
                  script.contains("= '" + String(decoding: owner, as: UTF8.self) + "'") else { return result(45) }
            return result(0)
        }
        if let marker = script.range(of: "sha256sum -- "),
           let path = Self.paths(in: String(script[marker.upperBound...])).first, let data = files[path] {
            return result(0, stdout: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\n")
        }
        if script.contains("rm -f -- "), !script.contains("mv -f -- "), script.contains("test ! -e "),
           let path = Self.paths(in: script).last, !path.hasSuffix("/owner") {
            files[path] = nil
            return result(0)
        }
        if script.contains("td_timer_file="),
           let path = Self.paths(in: script).first(where: { $0.hasPrefix("/etc/systemd/system/") }) {
            if let file = files[path] {
                guard String(decoding: file, as: UTF8.self).split(separator: "\n")
                    .contains(Substring("# Terminal Deck managed backup for " + DKTAppsFixtures.appID)) else { return result(73) }
                return result(0, stdout: "present\n")
            }
            return result(0, stdout: "absent\n")
        }
        if script.hasPrefix("systemctl show --no-pager --all --property=FragmentPath ") {
            let unit = "td-test-" + DKTAppsFixtures.appID + "-backup.timer"
            guard script.hasSuffix(BackendAppsRuntime.quote(unit)), files["/etc/systemd/system/" + unit] == nil else { return result(69) }
            return result(0, stdout: "FragmentPath=\nLoadState=not-found\nUnitFileState=not-found\nActiveState=inactive\nNeedDaemonReload=no\n")
        }

        if script.contains("sha256sum \"$file\""), script.contains("wc -c < \"$file\"") {
            var selectedPath: String?
            if let fileLine = script.split(separator: "\n").first(where: { $0.hasPrefix("file=") }) {
                selectedPath = Self.paths(in: String(fileLine)).first
            }
            if selectedPath == nil,
               let directoryLine = script.split(separator: "\n").first(where: { $0.hasPrefix("dir=") }),
               let directory = Self.paths(in: String(directoryLine)).first,
               let folder = script.split(separator: "\n").first(where: { $0.hasPrefix("folder=\"$dir/backups/") }) {
                let id = String(folder.dropFirst("folder=\"$dir/backups/".count).dropLast())
                guard id.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return result(65) }
                selectedPath = directory + "/backups/" + id + "/data"
            }
            guard let path = selectedPath, let data = files[path],
                  let manifestData = files[String(path.dropLast("data".count)) + "manifest.json"],
                  let manifest = try? NativeRPCValue.parseJSON(manifestData) else { return result(65) }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard manifest["sha256"].string == actual, manifest["bytes"].number == Double(data.count),
                  script.contains("= '" + actual + "'"), script.contains("= '" + String(data.count) + "'") else {
                boundaryEvents.append("backup-verification-failed")
                return result(65)
            }
            boundaryEvents.append("backup-verified")
            return result(0)
        }
        if script.contains("for file in data-restore-intent.json data-backup-policy-recovery.json;"),
           let directory = Self.paths(in: script).last {
            return result(["data-restore-intent.json", "data-backup-policy-recovery.json"].allSatisfy {
                files[directory + "/" + $0] == nil
            } ? 0 : 73)
        }
        if script.contains(".backup-policy-transaction-"), let stdin {
            guard let payload = try? NativeRPCValue.parseJSON(stdin), payload["policy"]["enabled"].bool == false,
                  let directoryLine = script.split(separator: "\n").first(where: { $0.hasPrefix("dir=") }),
                  let directory = Self.paths(in: String(directoryLine)).first,
                  locks.contains(directory + "/.lock"),
                  let saved = files[directory + "/state.json"],
                  let record = try? NativeRPCValue.parseJSON(saved),
                  payload["service"].string?.contains("# Terminal Deck managed backup for " + DKTAppsFixtures.appID) == true,
                  payload["timer"].string?.contains("# Terminal Deck managed backup for " + DKTAppsFixtures.appID) == true else { return result(65) }
            let updated = record.setting("backupPolicy", payload["policy"]).setting("updatedAt", payload["updatedAt"])
            files[directory + "/state.json"] = try updated.encodedJSON()
            files[directory + "/backup-policy.json"] = try payload["policy"].encodedJSON()
            boundaryEvents.append("backup-policy-transaction")
            return result(0)
        }
        if script.contains("rm -- "), script.contains("data-restore-intent.json"), script.contains("sync -f "),
           let path = Self.paths(in: script).first(where: { $0.hasSuffix("/data-restore-intent.json") }) {
            return result(files.removeValue(forKey: path) != nil ? 0 : 1)
        }
        if let reply = scriptReplies.first(where: { script.contains($0.contains) }) {
            boundaryEvents.append("scripted:" + reply.contains)
            return reply.result
        }

        if let marker = script.range(of: "mv -f -- ") {
            let line = String(script[marker.upperBound...]).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            guard let destination = Self.paths(in: line).last, let stdin else { return result(45) }
            // These assertions describe the requested server commands. They do
            // not pretend that a real Linux chmod/fsync was exercised.
            let recoveryWrite = script.contains(".recovery-") && locks.contains(Self.appLock(for: destination))
            guard script.contains("umask 077"), script.contains("chmod 700 -- ") || recoveryWrite,
                  script.contains("chmod 600 -- ") || recoveryWrite && script.contains("chmod 600 "), script.contains("sync -f "),
                  script.contains("test ! -L "), script.contains("set -C") else { return result(45) }
            if let skipped = writesBeforeFailure[destination], skipped > 0 {
                writesBeforeFailure[destination] = skipped - 1
            } else if let remaining = failedWrites[destination], remaining > 0 {
                failedWrites[destination] = remaining - 1
                boundaryEvents.append("state-write-failed:" + destination)
                return result(74, stderr: "DKT_DUMMY_SECRET_WRITE_FAILURE")
            }
            files[destination] = stdin
            boundaryEvents.append("state-write:" + destination)
            return result(0)
        }
        if script.contains("mv -- "), script.contains("/.archived-state.json") {
            let moves = Self.captures(#"mv -- '([^']+)' '([^']+)'"#, in: script)
            guard (2...3).contains(moves.count), moves.allSatisfy({ $0.count == 2 }),
                  moves[0][0].hasSuffix("/state.json") else { return result(45) }
            let source = String(moves[0][0].dropLast("/state.json".count)), destination = moves[1][1]
            guard moves[0][1] == source + "/.archived-state.json", moves[1][0] == source,
                  Self.paths(in: destination) == [destination],
                  destination.hasPrefix(String(source[..<source.lastIndex(of: "/")!]) + "/"),
                  moves.count == 2 || moves[2] == [moves[0][1], moves[0][0]],
                  let saved = files.removeValue(forKey: moves[0][0]) else { return result(45) }
            files[moves[0][1]] = saved
            for key in Array(files.keys) where key.hasPrefix(source + "/") {
                let relocated = destination + String(key.dropFirst(source.count))
                files[relocated] = files.removeValue(forKey: key)
            }
            for key in Array(locks) where key.hasPrefix(source + "/") {
                locks.remove(key)
                locks.insert(destination + String(key.dropFirst(source.count)))
            }
            return result(0)
        }
        if script.hasPrefix("rm -rf -- "), let work = Self.paths(in: script).first,
           work.contains("/td-test-builds/td-test-deploy-") {
            for key in Array(files.keys) where key.hasPrefix(work + "/") { files[key] = nil }
            boundaryEvents.append("build-directory-cleanup")
            return result(0)
        }
        if script.contains("find /var/lib/terminaldeck/apps -mindepth 2") {
            let paths = files.keys.filter { $0.hasSuffix("/state.json") }.sorted()
            let directories = paths.map { String($0.dropLast("/state.json".count)) }
            return result(0, stdout: directories.joined(separator: "\n"))
        }
        if let marker = script.range(of: "cat -- ") {
            let tail = String(script[marker.upperBound...])
            guard let path = Self.paths(in: tail).first else { return result(45) }
            guard let data = files[path] else { return result(44) }
            return result(0, stdout: String(decoding: data, as: UTF8.self))
        }
        if script.hasPrefix("rmdir "), let path = Self.paths(in: script).last {
            return result(locks.remove(path) != nil ? 0 : 1)
        }
        if script.contains("umask 077;"), script.contains("mkdir "), let path = Self.paths(in: script).last, path.hasSuffix("-caddy-lock") {
            let marker = Self.captures(#"printf '%s' '([A-Za-z0-9_.-]{1,128})' > '([^']+)'"#, in: script).first
            guard let marker, marker.count == 2, marker[1] == path + "/owner",
                  script.contains("set -C"), script.contains("chmod 600 " + BackendAppsRuntime.quote(marker[1])) else {
                return result(74)
            }
            guard locks.insert(path).inserted else { return result(73) }
            files[marker[1]] = Data(marker[0].utf8)
            boundaryEvents.append("lock-acquire:" + path)
            return result(0)
        }
        if script.contains("mkdir -- "), let lockPath = Self.paths(in: script).last(where: { $0.hasSuffix("/.lock") }) {
            guard locks.insert(lockPath).inserted else { return result(73) }
            if let stdin { files[lockPath + "/owner"] = stdin }
            return result(0)
        }
        unsupportedCommands.append(script)
        return result(127, stderr: "Command unavailable in the in-memory server fixture")
    }

    nonisolated func runtime(caddy: DKTFakeCaddy? = nil, docker: DKTDockerFake? = nil,
                            viaUnixSocket: Bool = false, privateNetwork: String = "terminaldeck-apps",
                            resourcePrefix: String = "terminaldeck", caddyServerKey: String? = nil,
                            logSource: DKTAppsLogSource? = nil,
                            stateRoot: String = "/var/lib/terminaldeck/apps", recoveryEnabled: Bool = false) -> BackendAppsRuntime {
        let base = BackendAppsRuntime(execute: { serverID, command, stdin, timeoutMS, maximumBytes in
            try await self.execute(serverID: serverID, command: command, stdin: stdin,
                                   timeoutMS: timeoutMS, maximumBytes: maximumBytes, caddy: caddy)
        }, docker: { serverID, method, path, body in
            guard serverID == "dkt-fake-server", let docker else {
                throw BackendAppsRuntime.unavailable("No synthetic Docker connection was supplied.")
            }
            await self.noteBoundary("docker:" + method + " " + path)
            let headers = body == nil ? [:] : ["Content-Type": "application/json"]
            if viaUnixSocket {
                let response = try DKTUnixHTTPClient.request(socketPath: docker.socketPath, method: method,
                                                             target: path, headers: headers, body: body ?? Data())
                return BackendAppsHTTPResponse(status: response.statusCode, body: response.body)
            }
            let response = docker.respond(to: .init(method: method, target: path, headers: headers, body: body ?? Data()))
            return BackendAppsHTTPResponse(status: response.statusCode, body: response.body)
        }, caddy: { serverID, method, path, body in
            guard serverID == "dkt-fake-server", let caddy else {
                throw BackendAppsRuntime.unavailable("No synthetic Caddy connection was supplied.")
            }
            await self.noteBoundary("caddy:" + method + " " + path)
            var headers = body == nil ? [:] : ["Content-Type": "application/json"]
            headers["Host"] = "localhost:2019"
            if viaUnixSocket {
                let response = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, method: method,
                                                             target: path, headers: headers, body: body ?? Data())
                return BackendAppsHTTPResponse(status: response.statusCode, body: response.body)
            }
            let response = caddy.respond(to: .init(method: method, target: path, headers: headers, body: body ?? Data()))
            return BackendAppsHTTPResponse(status: response.statusCode, body: response.body)
        }, serverAddresses: { serverID in
            guard serverID == "dkt-fake-server" else { throw BackendAppsRuntime.unavailable("Unknown synthetic server.") }
            return ["192.0.2.5"]
        }, resolveDNS: { _ in ["192.0.2.5"] }, watchLogs: { server, container, send in
            guard let logSource else { throw BackendAppsRuntime.unavailable("No synthetic log connection was supplied.") }
            return await logSource.watch(server: server, container: container, send: send)
        }, features: recoveryEnabled ? [BackendAppsDataChannels.recoveryFeature] : [], privateNetwork: privateNetwork,
           resourcePrefix: resourcePrefix, caddyServerKey: caddyServerKey, caddyAutosavePath: "/var/lib/td-test-caddy/autosave.json",
           stateRoot: stateRoot,
           now: { 1_791_392_400_000 })
        guard recoveryEnabled else { return base }
        let recovery = BackendAppsRecovery(capture: { scope, context in
            guard scope.stateRoot == stateRoot, scope.privateNetwork == privateNetwork,
                  scope.resourcePrefix == resourcePrefix, scope.caddyServerKey == caddyServerKey,
                  scope.caddyAutosavePath == base.caddyAutosavePath else {
                throw NativeRPCError(code: "access-denied", message: "The synthetic recovery runtime identity changed.")
            }
            try await self.pinRecovery(scope, context: context)
            return BackendAppsRecoveryTransport(execute: base.execute, docker: base.docker, caddy: base.caddy,
                authorizeRegistration: { context in try await self.checkRecoveryReceipt(scope, context: context) },
                validateBinding: { try await self.checkPinnedRecovery(scope) },
                close: { await self.closePinnedRecovery(scope) })
        }, audit: { event in await self.noteRecoveryAudit(event) })
        return BackendAppsRuntime(execute: base.execute, docker: base.docker, caddy: base.caddy,
            githubCredential: base.githubCredential, serverAddresses: base.serverAddresses, resolveDNS: base.resolveDNS,
            watchLogs: base.watchLogs, features: base.features, privateNetwork: base.privateNetwork,
            resourcePrefix: base.resourcePrefix, caddyServerKey: base.caddyServerKey, caddyAutosavePath: base.caddyAutosavePath,
            stateRoot: base.stateRoot, recovery: recovery, now: base.now)
    }

    private func result(_ code: Int, stdout: String = "", stderr: String = "") -> BackendServersRunResult {
        .init(code: code, stdout: stdout, stderr: stderr)
    }

    private static func unwrap(_ command: String) -> String {
        let prefix = "sh -c '"
        guard command.hasPrefix(prefix), command.hasSuffix("'") else { return command }
        return String(command.dropFirst(prefix.count).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    private static func paths(in script: String) -> [String] {
        // The store permits only this safe path alphabet. Tokenising it here
        // cannot run expansions, substitutions, redirections, or shell code.
        let expression = try? NSRegularExpression(pattern: #"(?:/var/lib/(?:(?:terminaldeck/apps|td-test-apps)/[A-Za-z0-9/_.-]+|[a-z][a-z0-9-]*-caddy-lock(?:/owner)?)|/etc/systemd/system/td-test-[a-z0-9-]+-backup\.(?:service|timer))"#)
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        return expression?.matches(in: script, range: range).compactMap {
            Range($0.range, in: script).map { String(script[$0]) }
        } ?? []
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    private static func appLock(for path: String) -> String {
        for root in ["/var/lib/terminaldeck/apps", "/var/lib/td-test-apps"] where path.hasPrefix(root + "/") {
            let relative = path.dropFirst(root.count + 1)
            guard let app = relative.split(separator: "/").first else { return "" }
            return root + "/" + String(app) + "/.lock"
        }
        if path.hasPrefix("/etc/systemd/system/td-test-") {
            return "/var/lib/td-test-apps/" + DKTAppsFixtures.appID + "/.lock"
        }
        return ""
    }
}

actor DKTAppsLogSource {
    private struct Listener: Sendable {
        let server: String
        let container: String
        let send: @Sendable (BackendAppsLogEvent) async -> Void
    }
    private var listeners: [UUID: Listener] = [:]
    private var cancellationObservers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private(set) var watchCount = 0
    private(set) var cancellationCount = 0
    var listenerCount: Int { listeners.count }

    func watch(server: String, container: String,
               send: @escaping @Sendable (BackendAppsLogEvent) async -> Void) -> NativeRPCSubscription {
        let id = UUID()
        listeners[id] = .init(server: server, container: container, send: send)
        watchCount += 1
        return NativeRPCSubscription(id: id) { await self.cancel(id) }
    }

    func send(_ text: String) async {
        let active = Array(listeners.values)
        for listener in active { await listener.send(.text(text)) }
    }

    func finish(failed: Bool = false) async {
        let active = Array(listeners.values)
        for listener in active { await listener.send(.ended(failed: failed)) }
    }

    /// NativeRPCSubscription.cancel() schedules teardown. Wait for the actual
    /// fixture cancellation event, with a deadline; never change the expected
    /// listener/cancellation counts or use a timing sleep as success evidence.
    func waitForCancellationCount(_ count: Int) async throws {
        guard cancellationCount < count else { return }
        let id = UUID()
        let pair = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancellationObservers[id] = pair.continuation
        defer { cancellationObservers[id] = nil; pair.continuation.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await observed in pair.stream {
                    if observed >= count { return }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw DKTHTTPServerError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func cancel(_ id: UUID) {
        if listeners.removeValue(forKey: id) != nil {
            cancellationCount += 1
            for observer in cancellationObservers.values { observer.yield(cancellationCount) }
        }
    }
}

actor DKTAppsEventRecorder {
    struct Event: Sendable {
        let channel: String
        let value: NativeRPCValue
        let owner: String
    }
    private(set) var events: [Event] = []
    func record(channel: String, value: NativeRPCValue, owner: String) {
        events.append(.init(channel: channel, value: value, owner: owner))
    }
}

struct DKTAppsBackupFixture: Sendable {
    let files: DKTAppsServerFiles
    let docker: DKTDockerFake
    let runtime: BackendAppsRuntime
    let store: BackendAppsStore
    let service: BackendAppsChannels
    let dataService: BackendAppsDataChannels
    let registrar: DKTAppsDataRegistrar
    let originalRecord: NativeRPCValue
    let backupData: Data

    static func make(restoreCode: Int = 0, registrar: DKTAppsDataRegistrar = .inheritedAPE) async throws -> Self {
        let files = DKTAppsServerFiles()
        let docker = DKTDockerFake()
        let labels = ["io.terminaldeck.app": DKTAppsFixtures.appID, "io.terminaldeck.managed": "true"]
        docker.seedImage(id: DKTAppsFixtures.databaseImageID, tags: ["postgres:17"], labels: labels)
        docker.seedNetwork(id: "td-test-network", name: DKTAppsRollbackFixture.network, labels: labels)
        _ = docker.respond(to: .init(method: "POST", target: "/volumes/create", body: try BackendAppsValidation.object([
            ("Name", .string(DKTAppsFixtures.originalDatabaseVolumeName)), ("Labels", .object(labels.map { .init($0.key, .string($0.value)) }))
        ]).encodedJSON()))
        let environment = ["POSTGRES_PASSWORD": DKTAppsFixtures.dummyPassword,
                           "POSTGRES_USER": "terminaldeck", "POSTGRES_DB": "terminaldeck"]
        let spec = try BackendAppsDatabaseSpec(kind: "postgres", version: "17")
        let specification = BackendAppsDataDatabases.container(spec: spec, appID: DKTAppsFixtures.appID, volume: DKTAppsFixtures.originalDatabaseVolumeName,
                                               environment: environment,
                                               labels: .object(labels.map { .init($0.key, .string($0.value)) }),
                                               network: DKTAppsRollbackFixture.network, prefix: "td-test")
            .setting("Image", .string(DKTAppsFixtures.databaseImageID))
        let created = docker.respond(to: .init(method: "POST", target: "/containers/create?name=td-test-database",
                                                body: try specification.encodedJSON()))
        guard created.statusCode == 201,
              let originalID = try NativeRPCValue.parseJSON(created.body)["Id"].string else {
            throw NativeRPCError(code: "unavailable", message: "The synthetic private database could not be prepared.")
        }
        _ = docker.respond(to: .init(method: "POST", target: "/containers/" + originalID + "/start"))
        let record = DKTAppsFixtures.databaseRecord().setting("containerId", .string(originalID))
            .setting("database", DKTAppsFixtures.databaseRecord()["database"]
                .setting("containerId", .string(originalID)).setting("imageId", .string(DKTAppsFixtures.databaseImageID))
                .setting("network", .string(DKTAppsRollbackFixture.network)).setting("port", .number(5432))
                .setting("databaseName", .string("terminaldeck")).setting("dataPath", .string(spec.dataPath)))
        if registrar == .appsData {
            // Fail at setup with the exact component if a stale/malformed
            // fixture identity reaches this build. Then run APD's actual
            // ownership preflight over shared fake state; no success override.
            guard originalID.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
                throw NativeRPCError(code: "fixture-invalid", message: "The synthetic original container ID is not 64 hexadecimal characters.")
            }
            guard record["database"]["imageId"].string == DKTAppsFixtures.databaseImageID,
                  DKTAppsFixtures.databaseImageID.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
                throw NativeRPCError(code: "fixture-invalid", message: "The synthetic original database image identity is invalid.")
            }
            guard record["database"]["volumeName"].string == "td-test-" + DKTAppsFixtures.appID + "-original-data" else {
                throw NativeRPCError(code: "fixture-invalid", message: "The synthetic original database volume is outside its exact app namespace.")
            }
            let setupRuntime = files.runtime(docker: docker, privateNetwork: DKTAppsRollbackFixture.network,
                                              resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps")
            // Direct fake callbacks keep setup reads out of the recorded Unix
            // requests used to prove no mutation before restore confirmation.
            _ = try await BackendAppsDataDatabases.inspectOwned(runtime: setupRuntime,
                serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                containerID: originalID, volumeName: DKTAppsFixtures.originalDatabaseVolumeName,
                expectedImageID: DKTAppsFixtures.databaseImageID, kind: "postgres")
        }
        let stateRoot = registrar == .appsData ? "/var/lib/td-test-apps" : BackendAppsStore.root
        let path = stateRoot + "/" + DKTAppsFixtures.appID
        let data = Data("DKT synthetic backup bytes; no real database data".utf8)
        await files.seed(path: path + "/state.json", data: try record.encodedJSON())
        await files.seed(path: path + "/.env", data: Data(("POSTGRES_PASSWORD=" + DKTAppsFixtures.dummyPassword + "\nPOSTGRES_USER=terminaldeck\nPOSTGRES_DB=terminaldeck\n").utf8))
        await files.seed(path: path + "/backups/" + DKTAppsFixtures.backupID + "/manifest.json",
                          data: try DKTAppsFixtures.manifest(data: data).encodedJSON())
        await files.seed(path: path + "/backups/" + DKTAppsFixtures.backupID + "/data", data: data)
        await files.replyToScript(containing: "command -v 'docker'")
        await files.replyToScript(containing: "pg_restore --exit-on-error", code: restoreCode,
                                 stderr: restoreCode == 0 ? "" : DKTAppsFixtures.dummyPassword)
        try docker.start()
        let runtime = files.runtime(docker: docker, viaUnixSocket: true, privateNetwork: DKTAppsRollbackFixture.network,
                                    resourcePrefix: "td-test", stateRoot: stateRoot, recoveryEnabled: registrar == .appsData)
        let store = BackendAppsStore(runtime: runtime)
        let service = BackendAppsChannels(runtime: runtime, store: store, authorize: { _, _ in })
        let dataService = BackendAppsDataChannels(runtime: runtime, store: store, authorize: { action, context in
            try await files.acceptRecoveryApproval(action, context: context)
        })
        return Self(files: files, docker: docker, runtime: runtime, store: store, service: service,
                    dataService: dataService, registrar: registrar,
                    originalRecord: record, backupData: data)
    }

    func stop() { docker.stop() }
    func invoke(_ channel: String, request: NativeRPCValue) async throws -> NativeRPCValue {
        let registry = NativeChannelRegistry()
        if registrar == .appsData {
            try await BackendAppsDataChannels.register(registry: registry, service: dataService, ownerID: "dkt-apps-data")
        } else {
            try await BackendAppsChannels.register(registry: registry, service: service, ownerID: "dkt-apps")
        }
        return try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: "dkt-owner",
                                                                               capabilities: ["apps.read", "apps.write"]),
                                         arguments: [request])
    }

    func restore(confirmation: String = DKTAppsFixtures.appName) async throws -> NativeRPCValue {
        try await invoke("apps:backups:restore", request: BackendAppsValidation.object([
                                            ("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID)),
                                            ("backupId", .string(DKTAppsFixtures.backupID)), ("confirmation", .string(confirmation))
                                         ]))
    }

    var originalContainerID: String { originalRecord["database"]["containerId"].string ?? "" }
}

enum DKTAppsDataRegistrar: String, CaseIterable, Sendable {
    case inheritedAPE
    case appsData
}

enum DKTAppsFixtures {
    static let serverID = "dkt-fake-server"
    static let appID = "td-test-app"
    static let originalDatabaseVolumeName = "td-test-" + appID + "-original-data"
    static let appName = "DKT synthetic app"
    static let dummySecret = "DKT_DUMMY_SECRET_NOT_A_REAL_CREDENTIAL"
    static let dummyPassword = "DKT_DUMMY_PASSWORD_NOT_A_REAL_CREDENTIAL"
    static let databaseContainerID = String(repeating: "f", count: 64)
    static let databaseImageID = "sha256:" + String(repeating: "f", count: 64)
    static let backupID = "td-test-backup"

    static func databaseRecord() -> NativeRPCValue {
        appRecord().setting("kind", .string("postgres")).setting("activeDeploymentId", .null)
            .setting("containerId", .string(databaseContainerID)).setting("source", .null)
            .setting("database", BackendAppsValidation.object([
                ("kind", .string("postgres")), ("containerId", .string(databaseContainerID)),
                ("volumeName", .string(originalDatabaseVolumeName)), ("image", .string("postgres:17"))
            ]))
    }

    static func manifest(data: Data) -> NativeRPCValue {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return BackendAppsValidation.object([
            ("id", .string(backupID)), ("appId", .string(appID)), ("kind", .string("postgres")),
            ("verified", .bool(true)), ("bytes", .number(Double(data.count))), ("sha256", .string(sha)),
            ("uploaded", .bool(false)),
            ("createdAt", .number(1_791_392_400_000)), ("imageId", .string(databaseImageID))
        ])
    }

    static func appRecord(status: String = "running", activeDeploymentID: String = "dkt-old") -> NativeRPCValue {
        BackendAppsValidation.object([
            ("id", .string(appID)), ("name", .string(appName)), ("kind", .string("app")),
            ("status", .string(status)), ("activeDeploymentId", .string(activeDeploymentID)),
            ("createdAt", .number(1_791_392_400_000)), ("updatedAt", .number(1_791_392_400_000)),
            ("address", .string("td-test-app.192.0.2.5.sslip.io")),
            ("envKeys", .array([.string("API_TOKEN")])),
            ("source", BackendAppsValidation.object([
                ("kind", .string("github")), ("repository", .string("fixture/synthetic-app")),
                ("branch", .string("main")), ("build", .string("dockerfile")), ("port", .number(8080))
            ]))
        ])
    }
}

/// Actual rollback service + both Unix HTTP fakes. Saved app files are synthetic;
/// every Docker/Caddy request crosses the same temporary HTTP sockets used by
/// the standalone fixture checks. No clone/build command is simulated here.
struct DKTAppsRollbackFixture: Sendable {
    static let oldContainerID = String(repeating: "a", count: 64)
    static let retainedImageID = "sha256:" + String(repeating: "b", count: 64)
    static let retainedDeploymentID = "td-test-retained"
    static let firstCandidateID = String(repeating: "0", count: 63) + "1"
    static let network = "td-test-private"
    static let routeID = "td-test-" + DKTAppsFixtures.appID
    let files: DKTAppsServerFiles
    let caddy: DKTFakeCaddy
    let docker: DKTDockerFake
    let runtime: BackendAppsRuntime
    let store: BackendAppsStore
    let service: BackendAppsChannels
    let originalRecord: NativeRPCValue
    let caddyBefore: Data

    static func make() async throws -> Self {
        let files = DKTAppsServerFiles()
        let caddy = try DKTFakeCaddy.protectedDemo(strictAdminHost: true)
        let docker = DKTDockerFake()
        let repository = "td-test-" + DKTAppsFixtures.appID
        let domains = ["td-test-app.192.0.2.5.sslip.io"]
        let labels = ["io.terminaldeck.managed": "true", "io.terminaldeck.app": DKTAppsFixtures.appID]
        docker.seedContainer(id: oldContainerID, name: "td-test-old", labels: labels)
        docker.seedImage(id: retainedImageID, tags: [repository + ":" + retainedDeploymentID], labels: labels)
        docker.seedNetwork(id: "td-test-network", name: network, labels: ["io.terminaldeck.managed": "true"])
        try caddy.start()
        do { try docker.start() }
        catch { caddy.stop(); throw error }
        let runtime = files.runtime(caddy: caddy, docker: docker, viaUnixSocket: true,
                                    privateNetwork: network, resourcePrefix: "td-test", caddyServerKey: "terminaldeck")
        let store = BackendAppsStore(runtime: runtime)
        let old = deployment(id: "td-test-active", imageTag: repository + ":td-test-active",
                             imageID: "sha256:" + String(repeating: "a", count: 64),
                             containerID: oldContainerID, upstream: "172.18.0.2", domains: domains)
        let retained = deployment(id: retainedDeploymentID, imageTag: repository + ":" + retainedDeploymentID,
                                  imageID: retainedImageID, containerID: String(repeating: "c", count: 64),
                                  upstream: "172.18.0.4", domains: domains)
        let record = DKTAppsFixtures.appRecord(activeDeploymentID: "td-test-active")
            .setting("containerId", .string(oldContainerID)).setting("domains", .array(domains.map(NativeRPCValue.string)))
            .setting("deployments", .array([old, retained]))
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID)
        await files.seed(path: path + "/state.json", data: try record.encodedJSON())
        await files.seed(path: path + "/.env", data: Data(("API_TOKEN=" + DKTAppsFixtures.dummySecret + "\n").utf8))
        do {
            try await BackendAppsCaddy(runtime: runtime).swap(serverID: DKTAppsFixtures.serverID,
                                                               appID: DKTAppsFixtures.appID, domains: domains,
                                                               upstream: "172.18.0.2", port: 8080)
        } catch { caddy.stop(); docker.stop(); throw error }
        let service = BackendAppsChannels(runtime: runtime, store: store, authorize: { _, _ in })
        return Self(files: files, caddy: caddy, docker: docker, runtime: runtime, store: store, service: service,
                    originalRecord: record, caddyBefore: try caddy.configSnapshot())
    }

    func stop() { caddy.stop(); docker.stop() }

    func rollback() async throws -> NativeRPCValue {
        let registry = NativeChannelRegistry()
        try await BackendAppsChannels.register(registry: registry, service: service, ownerID: "dkt-apps")
        return try await registry.invoke("apps:rollback", context: .init(caller: .nativeApp, ownerID: "dkt-owner",
                                                                         capabilities: ["apps.read", "apps.write"]),
                                         arguments: [BackendAppsValidation.object([
                                            ("serverId", .string(DKTAppsFixtures.serverID)),
                                            ("appId", .string(DKTAppsFixtures.appID)),
                                            ("deploymentId", .string(Self.retainedDeploymentID))
                                         ])])
    }

    private static func deployment(id: String, imageTag: String, imageID: String, containerID: String,
                                   upstream: String, domains: [String]) -> NativeRPCValue {
        BackendAppsValidation.object([
            ("id", .string(id)), ("imageTag", .string(imageTag)), ("imageId", .string(imageID)),
            ("containerId", .string(containerID)), ("upstream", .string(upstream)), ("port", .number(8080)),
            ("domains", .array(domains.map(NativeRPCValue.string))), ("status", .string("running")),
            ("commit", .string(String(repeating: "d", count: 40))), ("createdAt", .number(1_791_392_400_000))
        ])
    }
}
