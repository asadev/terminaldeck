import Foundation
import TerminalDeckNativeCore

/// SRV2: the Mac-started deploy. It writes the app's recipe, prepares the
/// source on the server, runs `recipe.sh deploy` there (detached from the SSH
/// session, so a dropped connection doesn't stop it halfway) and records the
/// result in the app's record in the same shape as the existing history, so
/// deploy history and rollback keep working. The server-started deploy (SRV1)
/// runs the same recipe.
public struct BackendAppsSRV2Deployer: Sendable {
    public enum Source: Sendable {
        case github(revision: String?)
        /// A source folder already on the server, inside this app's builds folder (tests, CI hand-offs).
        case prepared(path: String)
        /// Roll back: start a retained version; no build, no before/after commands.
        case image(tag: String)
    }

    /// SRV1's server probe (the ONE router detection), used only when the shared
    /// router record is missing. INT2 injects it (BackendAppsSRV2Wiring).
    public typealias RouterProbe = @Sendable (_ serverID: String) async throws -> BackendAppsSRV2Router.Facts?
    public let runtime: BackendAppsRuntime
    public let store: BackendAppsStore
    public let variables: BackendAppsSRV2Variables
    public let routerProbe: RouterProbe?
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore, routerProbe: RouterProbe? = nil) {
        self.runtime = runtime; self.store = store; self.variables = BackendAppsSRV2Variables(store: store); self.routerProbe = routerProbe
    }

    var prefix: String { runtime.resourcePrefix }
    func routeID(_ appID: String) -> String { prefix + "-" + appID }
    func imageRepository(_ appID: String) -> String { prefix == "terminaldeck" ? "terminaldeck/" + appID : prefix + "-" + appID }

    // MARK: recipe

    public func domains(_ serverID: String, _ appID: String, record: NativeRPCValue, facts: BackendAppsSRV2Router.Facts) async throws -> [String] {
        if let values = record["domains"].elements, !values.isEmpty { return try values.map { try BackendAppsCaddy.hostname($0.requireString("App address", nonempty: true)) } }
        guard facts.info.canServeAddresses else { return [] }
        return [try await BackendAppsCaddy(runtime: runtime).defaultDomain(serverID: serverID, appID: appID)]
    }

    /// Renders and saves `recipe.sh`. The caller holds the app lock.
    @discardableResult
    public func writeRecipe(_ serverID: String, _ appID: String, record: NativeRPCValue, facts: BackendAppsSRV2Router.Facts? = nil) async throws -> (recipe: String, facts: BackendAppsSRV2Router.Facts, domains: [String]) {
        let facts = try await resolvedFacts(serverID, facts)
        let options = try BackendAppsSRV2Definition.options(record)
        let keys = try await variables.keys(serverID, appID)
        let domains = try await domains(serverID, appID, record: record, facts: facts)
        let port = record["source"]["port"].number.map { Int($0) }
        let input = BackendAppsSRV2Recipe.Input(appID: appID, prefix: prefix, appDirectory: try store.directory(appID), network: runtime.privateNetwork,
                                                imageRepository: imageRepository(appID), port: port, options: options, domains: domains, facts: facts,
                                                buildKeys: keys.build, runKeys: keys.run, routeID: routeID(appID))
        let recipe = try BackendAppsSRV2Recipe.render(input)
        try await store.writeFile(serverID, path: try store.directory(appID) + "/recipe.sh", contents: Data(recipe.utf8))
        return (recipe, facts, domains)
    }

    func resolvedFacts(_ serverID: String, _ facts: BackendAppsSRV2Router.Facts?) async throws -> BackendAppsSRV2Router.Facts {
        if let facts { return facts }
        // ONE router detection: SRV1's probe, saved by server setup as <stateRoot>/router.json.
        var detected: BackendAppsSRV2Router.Facts
        if let saved = BackendAppsSRV2Router.record(try? await store.readFile(serverID, path: store.stateRoot + "/router.json")) {
            detected = saved
        } else if let probe = routerProbe, let probed = try await probe(serverID) {
            detected = probed
        } else {
            detected = BackendAppsSRV2Router.notSetUp
        }
        // How an existing Caddy keeps addresses across its own restarts is read from the live process.
        if detected.mode == .caddy || detected.mode == .ownCaddy, detected.caddyPersistence == nil {
            detected = try await BackendAppsSRV2Router.withPersistence(detected, runtime: runtime, serverID: serverID, prefix: runtime.resourcePrefix)
        }
        // The live-test namespace binds an existing Caddy server key explicitly.
        if let key = runtime.caddyServerKey, detected.mode == .caddy || detected.mode == .ownCaddy { detected.caddyServerKey = key }
        return detected
    }

    /// Re-applies the app's address with its current options (Caddy only; Traefik needs a deploy).
    public func route(_ serverID: String, _ appID: String, action: String) async throws -> String {
        guard ["ensure-route", "apply-route", "persist-route", "unroute"].contains(action) else { throw NativeRPCError.invalidArguments("Unknown address action.") }
        let q = BackendAppsRuntime.quote
        let result = try await runtime.run(serverID, "test -f \(q(try store.directory(appID) + "/recipe.sh")) || exit 44; sh \(q(try store.directory(appID) + "/recipe.sh")) \(action)", timeoutMS: 120_000, maximumBytes: 16_384)
        if result.code == 44 { return "route=no-recipe" }
        let values = BackendAppsSRV2Recipe.result(result.stdout)
        guard result.code == 0 else {
            let code = values["error"]?.last ?? "route-failed"
            throw NativeRPCError(code: code == "route-uncertain" ? "route-failed" : "route-failed", message: BackendAppsSRV2Recipe.message(code))
        }
        return values["route"]?.last ?? "route=unchanged"
    }

    // MARK: deploy

    /// A deploy that has been started on the server and is waiting for its recipe.
    struct Started: Sendable {
        let row: NativeRPCValue
        let environment: [(String, String)]
        let cleanup: String?
        let domains: [String]
        let router: BackendAppsSRV2Router.Facts
        var id: String { row["id"].string ?? "" }
    }

    /// The app's lock is held only to start a deploy and to record its result.
    /// The long server-side run in between (build, health wait, route) holds no
    /// lock, so other changes to the app go ahead meanwhile; the record's
    /// pendingDeploymentId keeps a second deploy, a roll back, an address change
    /// and removal away until it finishes.
    public func deploy(serverID: String, appID: String, source: Source) async throws -> NativeRPCValue {
        _ = try BackendAppsValidation.id(appID)
        let started = try await store.withLock(serverID, appID) { try await start(serverID, appID, source: source) }
        // The server removes the downloaded source once the recipe stops, so a dropped
        // connection never deletes it under a build that is still running there.
        let outcome = try await run(serverID, appID, deploymentID: started.id, environment: started.environment, cleanup: started.cleanup)
        return try await recordResult(serverID, appID, started, outcome: outcome)
    }

    /// Inside the lock: settles an earlier deploy, writes the recipe, prepares the
    /// source and saves the "deploying" row with its (still empty) result file.
    func start(_ serverID: String, _ appID: String, source: Source) async throws -> Started {
        var record = try await store.read(serverID, appID)
        guard record["kind"].string == "app" else { throw NativeRPCError.invalidArguments("Only apps can be deployed this way.") }
        record = try await settle(serverID, appID, record)
        let written = try await writeRecipe(serverID, appID, record: record)
        if written.facts.mode == .caddy || written.facts.mode == .ownCaddy, !written.domains.isEmpty {
            try await checkConflicts(serverID, appID, domains: written.domains, admin: written.facts.caddyAdmin)
        }
        let deploymentID = prefix + "-deploy-" + UUID().uuidString.lowercased()
        let directory = try store.directory(appID)
        let work = directory + "/" + prefix + "-builds/" + deploymentID
        var environment: [(String, String)] = [("TD_DEPLOYMENT", deploymentID)]
        var commit: NativeRPCValue = .missing
        var cleanup: String?
        switch source {
        case .github(let revision):
            guard record["source"]["kind"].string == "github" else { throw NativeRPCError.invalidArguments("This app doesn't deploy from a GitHub repository.") }
            commit = .string(try await clone(serverID, record["source"], work: work, directory: directory, revision: revision))
            environment.append(("TD_SOURCE", work + "/source")); cleanup = work
        case .prepared(let path):
            guard path.hasPrefix(directory + "/" + prefix + "-builds/"), !path.contains(".."),
                  path.range(of: #"^[A-Za-z0-9/_.-]+$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("The prepared source must be inside this app's builds folder.") }
            environment.append(("TD_SOURCE", path))
        case .image(let tag):
            guard tag.hasPrefix(imageRepository(appID) + ":"), tag.range(of: #"^[a-z0-9/_.:-]+$"#, options: .regularExpression) != nil else { throw NativeRPCError(code: "not-found", message: "That app version is no longer kept on the server.") }
            environment.append(("TD_IMAGE", tag))
        }
        var row = Self.object([("id", .string(deploymentID)), ("status", .string("deploying")), ("createdAt", .number(runtime.now())), ("commit", commit)])
        if case .image(let tag) = source { row = row.setting("imageTag", .string(tag)) } else { row = row.setting("imageTag", .string(imageRepository(appID) + ":" + deploymentID)) }
        try await store.write(serverID, appID, Self.appending(row, to: record).setting("pendingDeploymentId", .string(deploymentID)))
        // The result file exists from here on, so `settle` sees this deploy as running
        // (not interrupted) while its recipe holds no lock. The recipe fills it in.
        let q = BackendAppsRuntime.quote
        _ = try await runtime.checked(serverID, "umask 077; mkdir -p \(q(directory + "/deploys")) && chmod 700 \(q(directory + "/deploys")) && : > \(q(directory + "/deploys/" + deploymentID + ".result"))",
                                      timeoutMS: 15_000, code: "state-failed", message: "The deploy could not be started on the server.")
        return Started(row: row, environment: environment, cleanup: cleanup, domains: written.domains, router: written.facts)
    }

    /// Inside the lock again: the result goes onto the app's current record, so
    /// changes saved while the recipe ran are kept.
    func recordResult(_ serverID: String, _ appID: String, _ started: Started, outcome: (code: Int, values: [String: [String]])) async throws -> NativeRPCValue {
        var attempt = 0
        while true {
            do {
                return try await store.withLock(serverID, appID) {
                    let current = try await store.read(serverID, appID)
                    guard current["pendingDeploymentId"].string == started.id else {
                        // Another action already recorded this deploy from the server's result file.
                        let saved = Self.rows(current).first { $0["id"].string == started.id }
                        if let saved, saved["status"].string == "running" { return Self.publicDeployment(saved) }
                        throw NativeRPCError(code: "build-failed", message: saved?["message"].string ?? "The deploy did not finish. Its details are in the app's deploy history.")
                    }
                    return try await finish(serverID, appID, record: current, row: started.row, outcome: outcome, domains: started.domains, router: started.router)
                }
            } catch let error as NativeRPCError where error.code == "busy" {
                // Another change is saving right now; those take seconds.
                attempt += 1
                guard attempt < 60 else {
                    throw NativeRPCError(code: "busy", message: "The deploy finished on the server, but another change to this app kept running, so its result is recorded with the app's next change.")
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Runs the recipe detached (nohup) and reads its result file. The shell ignores a
    /// hang-up and prints nothing until the recipe stops, so `cleanup` is removed on the
    /// server only after the recipe is done, even when the Mac's connection dropped.
    func run(_ serverID: String, _ appID: String, deploymentID: String, environment: [(String, String)], cleanup: String? = nil) async throws -> (code: Int, values: [String: [String]]) {
        let q = BackendAppsRuntime.quote, directory = try store.directory(appID)
        let assignments = environment.map { $0.0 + "=" + q($0.1) }.joined(separator: " ")
        let resultPath = directory + "/deploys/" + deploymentID + ".result"
        let removal = cleanup.map { " rm -rf -- \(q($0));" } ?? ""
        let script = "cd / && trap '' HUP; nohup env \(assignments) sh \(q(directory + "/recipe.sh")) deploy >/dev/null 2>&1 </dev/null; code=$?;\(removal) cat \(q(resultPath)) 2>/dev/null; echo \"exitcode=$code\""
        let result = try await runtime.run(serverID, script, timeoutMS: 3_600_000, maximumBytes: 65_536)
        let values = BackendAppsSRV2Recipe.result(result.stdout)
        guard let code = values["exitcode"]?.last.flatMap(Int.init) else {
            throw NativeRPCError(code: "unavailable", message: "The deploy's result could not be read. It may still be finishing on the server; check the app again shortly.")
        }
        return (code, values)
    }

    func finish(_ serverID: String, _ appID: String, record: NativeRPCValue, row: NativeRPCValue, outcome: (code: Int, values: [String: [String]]),
                domains: [String], router: BackendAppsSRV2Router.Facts) async throws -> NativeRPCValue {
        let values = outcome.values
        func last(_ key: String) -> String? { values[key]?.last }
        let options = (try? BackendAppsSRV2Definition.options(record)) ?? NativeAppsOptions()
        var finished = row.setting("finishedAt", .number(runtime.now()))
        if let tag = last("tag") { finished = finished.setting("imageTag", .string(tag)) }
        if let image = last("image") { finished = finished.setting("imageId", .string(image)) }
        if let port = last("port").flatMap(Int.init) { finished = finished.setting("port", .number(Double(port))) }
        if let probe = last("probe") { finished = finished.setting("probe", .string(probe)) }
        let warnings = (values["warning"] ?? []).map(Self.warning)
        if !warnings.isEmpty { finished = finished.setting("warnings", .array(warnings.map(NativeRPCValue.string))) }
        var next = record.removing("pendingDeploymentId").setting("updatedAt", .number(runtime.now()))
        if outcome.code == 0, let container = last("container"), let upstream = last("upstream") {
            finished = finished.setting("status", .string("running")).setting("containerId", .string(container)).setting("upstream", .string(upstream))
                .setting("domains", .array(domains.map(NativeRPCValue.string)))
            let retired = Set(values["retired"] ?? [])
            let rows = Self.rows(record).map { retired.contains($0["containerId"].string ?? "") ? $0.setting("instanceState", .string("stopped")) : $0 }
            // Versions the recipe removed are never offered for Roll back.
            let pruned = BackendAppsDeployHistory.markingRemoved(Set(values["pruned"] ?? []), in: next.setting("deployments", .array(rows)))
            next = Self.appending(finished, to: pruned).setting("activeDeploymentId", finished["id"])
                .setting("containerId", .string(container)).setting("status", .string("running")).removing("lastError")
                .setting("domains", .array(domains.map(NativeRPCValue.string)))
            next = domains.first.map { next.setting("address", .string("https://" + $0)) } ?? next.removing("address")
            try await store.write(serverID, appID, next)
            return Self.publicDeployment(finished)
        }
        let code = last("error") ?? "deploy-failed"
        let message = BackendAppsSRV2Recipe.message(code, health: options.health, timeout: options.steps.timeoutSeconds)
        finished = finished.setting("status", .string("failed")).setting("failure", .string(code)).setting("message", .string(message))
        next = Self.appending(finished, to: next).setting("lastError", .string(message))
        if next["activeDeploymentId"].isNullish { next = next.setting("status", .string("failed")) }
        try await store.write(serverID, appID, next)
        let log = await logTail(serverID, appID, deploymentID: row["id"].string ?? "", failure: code)
        let errorCode: String
        switch outcome.code {
        case 10: errorCode = "build-failed"
        case 11, 12: errorCode = "health-failed"
        case 13, 15: errorCode = "route-failed"
        case 14: errorCode = "health-failed"
        case 16: errorCode = "cancelled"
        default: errorCode = "build-failed"
        }
        throw NativeRPCError(code: errorCode, message: message, details: Self.object([("deploymentId", row["id"]), ("failure", .string(code)), ("log", log.map(NativeRPCValue.string) ?? .missing)]))
    }

    /// An earlier deploy whose Mac went away: apply the result the server kept.
    func settle(_ serverID: String, _ appID: String, _ record: NativeRPCValue) async throws -> NativeRPCValue {
        guard let pending = record["pendingDeploymentId"].string else { return record }
        guard pending.hasPrefix(prefix + "-deploy-"), let row = Self.rows(record).first(where: { $0["id"].string == pending }) else {
            throw NativeRPCError(code: "conflict", message: "An interrupted address or deploy change needs recovery first.")
        }
        let q = BackendAppsRuntime.quote
        let path = try store.directory(appID) + "/deploys/" + pending + ".result"
        let result = try await runtime.run(serverID, "test -f \(q(path)) || exit 44; cat \(q(path)); find \(q(path)) -mmin +\(Self.staleMinutes) | grep -q . && echo stale=1", timeoutMS: 15_000, maximumBytes: 65_536)
        let values = BackendAppsSRV2Recipe.result(result.stdout)
        if let exit = values["exit"]?.last.flatMap(Int.init) {
            _ = try? await finish(serverID, appID, record: record, row: row, outcome: (exit, values), domains: (record["domains"].elements ?? []).compactMap(\.string), router: .init(mode: .unknown, owner: ""))
            return try await store.read(serverID, appID)
        }
        if result.code == 44 || values["stale"] != nil {
            // A deploy that died with its server: remove what it had half made first.
            if values["stale"] != nil { _ = try? await runtime.run(serverID, "sh \(q(try store.directory(appID) + "/recipe.sh")) recover \(q(pending))", timeoutMS: 300_000, maximumBytes: 4096) }
            // Its recipe has stopped, so the source it downloaded can go now.
            if pending.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil {
                await removeWork(serverID, try store.directory(appID) + "/" + prefix + "-builds/" + pending)
            }
            let failed = row.setting("status", .string("failed")).setting("failure", .string("interrupted")).setting("finishedAt", .number(runtime.now()))
            let next = Self.appending(failed, to: record).removing("pendingDeploymentId")
            try await store.write(serverID, appID, next)
            return next
        }
        throw Self.stillRunning(row, now: runtime.now())
    }

    /// A running recipe touches its result file every 30 seconds; one left alone this
    /// long belongs to a deploy that died (or never started) with its server.
    static let staleMinutes = 10

    /// The refusal while a deploy runs: which deploy, and since when.
    static func stillRunning(_ row: NativeRPCValue, now: Double) -> NativeRPCError {
        let minutes = row["createdAt"].number.map { Int(max(0, now - $0) / 60_000) }
        let since = minutes.map { $0 < 1 ? "less than a minute ago" : $0 == 1 ? "1 minute ago" : "\($0) minutes ago" }
        let commit = row["commit"].string.map { " (version " + String($0.prefix(7)) + ")" } ?? ""
        return NativeRPCError(code: "busy", message: "A deploy\(commit) started \(since ?? "earlier") is still running on the server. Try again when it finishes.",
                              details: object([("deploymentId", row["id"]), ("startedAt", row["createdAt"])]))
    }

    /// Whether the app's pending deploy is still running on the server: its result
    /// file exists, has no exit line yet and is still being touched.
    /// Throws the same refusal `settle` gives.
    static func refuseWhileDeploying(runtime: BackendAppsRuntime, store: BackendAppsStore, _ serverID: String, _ appID: String, record: NativeRPCValue) async throws {
        guard let pending = record["pendingDeploymentId"].string, pending.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { return }
        let q = BackendAppsRuntime.quote, path = try store.directory(appID) + "/deploys/" + pending + ".result"
        let result = try await runtime.run(serverID, "test -f \(q(path)) || exit 44; grep -q '^exit=' \(q(path)) && exit 0; find \(q(path)) -mmin +\(staleMinutes) | grep -q . && exit 0; exit 75", timeoutMS: 15_000, maximumBytes: 1024)
        guard result.code == 75 else { return }
        throw stillRunning(rows(record).first { $0["id"].string == pending } ?? object([("id", .string(pending))]), now: runtime.now())
    }

    func checkConflicts(_ serverID: String, _ appID: String, domains: [String], admin: String? = nil) async throws {
        let address = admin.flatMap { $0.range(of: #"^[A-Za-z0-9.:\[\]-]+$"#, options: .regularExpression) != nil ? $0 : nil } ?? "127.0.0.1:2019"
        let result = try await runtime.run(serverID, "curl -fsS --noproxy '*' --max-time 5 " + BackendAppsRuntime.quote("http://" + address + "/config/apps/http/servers"), timeoutMS: 15_000, maximumBytes: 2_097_152)
        guard result.code == 0, !result.truncated, let servers = try? NativeRPCValue.parseJSON(Data(result.stdout.utf8)) else { return }
        let taken = BackendAppsSRV2Router.caddyConflicts(servers: servers, routeID: routeID(appID), hosts: domains)
        guard taken.isEmpty else { throw NativeRPCError(code: "conflict", message: "\(taken.joined(separator: ", ")) already belongs to another site on this server. Choose a different address.") }
    }

    func logTail(_ serverID: String, _ appID: String, deploymentID: String, failure: String) async -> String? {
        let suffix: String
        switch failure {
        case "build-failed": suffix = "-build.log"
        case "before-failed", "before-timeout": suffix = "-before.log"
        case "health-failed": suffix = "-app.log"
        case "after-failed": suffix = "-after.log"
        default: return nil
        }
        guard let directory = try? store.directory(appID), deploymentID.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        guard let result = try? await runtime.run(serverID, "tail -n 40 " + BackendAppsRuntime.quote(directory + "/deploys/" + deploymentID + suffix), timeoutMS: 10_000, maximumBytes: 32_768),
              result.code == 0 else { return nil }
        let secrets = (try? await variables.secrets(serverID, appID)) ?? []
        let text = String(result.stdout.filter { $0 == "\n" || $0 == "\t" || !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }.suffix(4000))
        return BackendAppsValidation.mask(text, secrets: secrets)
    }

    static func warning(_ code: String) -> String {
        if code.hasPrefix("unsaved-storage:") {
            let path = String(code.dropFirst("unsaved-storage:".count))
            return "This app keeps data in \(path), which isn't saved between deploys. Add a volume for \(path) under Storage."
        }
        switch code {
        case "traefik-unchecked-traffic": return "This app has no curl or wget, so during a deploy some visitors may reach the new version before its check finishes."
        case "old-version-cleanup": return "Your new version is running. The previous version could not be stopped and needs cleanup."
        default: return "The deploy finished with a note: \(code)."
        }
    }

    // MARK: source

    func clone(_ serverID: String, _ source: NativeRPCValue, work: String, directory: String, revision: String?) async throws -> String {
        guard let repository = source["repository"].string,
              repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Choose a GitHub repository in owner/repository form.")
        }
        if let revision { guard revision.range(of: #"^(?:[a-f0-9]{40}|[a-f0-9]{64})$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Use a full commit ID.") } }
        let branch = source["branch"].string
        if let branch { guard branch.range(of: #"^[A-Za-z0-9._/-]{1,200}$"#, options: .regularExpression) != nil, !branch.hasPrefix("-"), !branch.contains("..") else { throw NativeRPCError.invalidArguments("Choose a valid repository branch.") } }
        let token = try await runtime.githubCredential(serverID) ?? ""
        guard !token.unicodeScalars.contains(where: { $0.value < 32 }), token.utf8.count <= 65_536 else { throw BackendAppsRuntime.unavailable(NativeAppsUnavailableReason.gitHubSignInUnusable) }
        let q = BackendAppsRuntime.quote
        let git = "git -c core.hooksPath=/dev/null -c credential.helper= -c protocol.file.allow=never"
        let checkout = revision.map { git + " -C \(q(work + "/source")) fetch --depth 1 --no-tags origin \(q($0)) >/dev/null 2>&1\n" + git + " -C \(q(work + "/source")) checkout --detach \(q($0)) -- >/dev/null 2>&1" } ?? ""
        let script = """
        set -eu
        umask 077
        mkdir -p \(q(directory + "/" + prefix + "-builds"))
        chmod 700 \(q(directory + "/" + prefix + "-builds"))
        mkdir \(q(work))
        credential=\(q(work + "/.github-input")); askpass=\(q(work + "/.github-askpass"))
        trap 'rm -f "$credential" "$askpass"' EXIT
        trap 'exit 130' HUP INT TERM
        cat > "$credential"
        printf '%s\\n' '#!/bin/sh' 'case "$1" in *sername*) echo x-access-token ;; *) cat "$TD_GITHUB_INPUT" ;; esac' > "$askpass"
        chmod 700 "$askpass"
        export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS="$askpass" TD_GITHUB_INPUT="$credential"
        \(git) clone --depth 1 --single-branch \(branch.map { "--branch " + q($0) + " " } ?? "")-- \(q("https://github.com/" + repository + ".git")) \(q(work + "/source")) >/dev/null 2>&1
        \(checkout)
        git -C \(q(work + "/source")) rev-parse --verify 'HEAD^{commit}'
        """
        let commit = try await runtime.checked(serverID, script, stdin: Data(token.utf8), timeoutMS: 180_000, code: "build-failed",
                                               message: "The repository could not be downloaded. Check GitHub access and the branch.").trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.range(of: #"^(?:[a-f0-9]{40}|[a-f0-9]{64})$"#, options: .regularExpression) != nil, revision == nil || commit == revision else {
            throw NativeRPCError(code: "build-failed", message: "The repository did not supply the expected version.")
        }
        return commit
    }

    func removeWork(_ serverID: String, _ work: String) async {
        _ = try? await runtime.run(serverID, "rm -rf -- " + BackendAppsRuntime.quote(work), timeoutMS: 60_000, maximumBytes: 1024)
    }

    // MARK: record helpers (same row shape as the existing deploy history)

    static func rows(_ record: NativeRPCValue) -> [NativeRPCValue] { BackendAppsDeployHistory.rows(record) }
    static func appending(_ row: NativeRPCValue, to record: NativeRPCValue) -> NativeRPCValue { BackendAppsDeployHistory.appending(row, to: record) }
    static func publicDeployment(_ row: NativeRPCValue) -> NativeRPCValue {
        let keys: Set<String> = ["id", "imageTag", "imageId", "containerId", "upstream", "port", "domains", "status", "createdAt", "finishedAt", "commit",
                                 "rollbackOf", "requestedRevision", "instanceState", "imageRemoved", "warnings", "probe", "failure", "message"]
        return .object((row.fields ?? []).filter { keys.contains($0.key) && $0.value != .missing })
    }
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
}
