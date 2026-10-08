import Foundation
import TerminalDeckNativeCore

/// Server-side builds and Docker Engine candidates. The caller authorizes writes
/// before entering this service; this type never grants itself server access.
public struct BackendAppsDeploy: Sendable {
    private let runtime: BackendAppsRuntime
    private let store: BackendAppsStore
    private let caddy: BackendAppsCaddy
    private var network: String { runtime.privateNetwork }

    public init(runtime: BackendAppsRuntime, store: BackendAppsStore, caddy: BackendAppsCaddy) {
        self.runtime = runtime; self.store = store; self.caddy = caddy
    }

    public func history(serverID: String, appID: String) async throws -> NativeRPCValue {
        _ = try BackendAppsValidation.id(appID)
        let record = try await store.read(serverID, appID)
        return .array(Self.rows(record).map(Self.publicDeployment))
    }

    public func deploy(serverID: String, appID: String, revision: String? = nil) async throws -> NativeRPCValue {
        try await perform(serverID: serverID, appID: appID, revision: revision, expectedPush: nil)
    }

    /// Rechecks the binding under the same server lock that covers the build.
    /// A disable/source change after ingress approval cannot bypass this check.
    public func deployPush(serverID: String, appID: String, push: BackendAppsVerifiedPush) async throws -> NativeRPCValue {
        try await perform(serverID: serverID, appID: appID, revision: push.revision, expectedPush: push)
    }

    private func perform(serverID: String, appID: String, revision: String?, expectedPush: BackendAppsVerifiedPush?) async throws -> NativeRPCValue {
        _ = try BackendAppsValidation.id(appID)
        let approvedRevision: String?
        if let revision {
            guard revision.range(of: #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#, options: .regularExpression) != nil else {
                throw NativeRPCError.invalidArguments("The approved GitHub revision must be a complete 40 or 64 character commit ID.")
            }
            approvedRevision = revision.lowercased()
        } else { approvedRevision = nil }
        return try await store.withLock(serverID, appID) {
            let original = try await store.read(serverID, appID)
            guard original["kind"].string == "app" else {
                throw NativeRPCError.invalidArguments("Only apps can deploy from a repository.")
            }
            try Self.requireSettled(original)
            guard try Self.cleanupIDs(original).count < Self.maximumPendingCleanup else {
                throw NativeRPCError(code: "busy", message: "Earlier app versions need cleanup before another deploy. Inspect this app's cleanup warnings.")
            }
            try validateResourceNames()
            let source = original["source"]
            if let push = expectedPush {
                guard original["autoDeploy"].bool == true, original["pendingAutoDeploy"].isNullish,
                      source["kind"].string == "github", source["repository"].string == push.repository,
                      let branch = source["branch"].string, "refs/heads/" + branch == push.ref,
                      approvedRevision == push.revision else {
                    throw NativeRPCError(code: "conflict", message: "This app's automatic deploy binding changed after push approval. Nothing was built or switched.")
                }
            }
            guard approvedRevision == nil || source["kind"].string == "github" else {
                throw NativeRPCError.invalidArguments("Exact repository revisions apply only to GitHub apps.")
            }
            let isTemplate = source["kind"].string == "template"
            if isTemplate, original["activeDeploymentId"].string != nil {
                throw BackendAppsRuntime.unavailable("Updating this app needs a safe maintenance window for its saved data. That path is not connected yet.")
            }
            let deploymentID = runtime.resourcePrefix + "-deploy-" + UUID().uuidString.lowercased()
            let imageTag = imageRepository(appID) + ":" + deploymentID
            let directory = try store.directory(appID)
            let work = directory + "/" + runtime.resourcePrefix + "-builds/" + deploymentID
            if !isTemplate, let transaction = try currentRecovery(serverID: serverID, appID: appID) {
                _ = try await transaction.register(.removeAppWorkDirectory(path: work))
            }
            var row = Self.deployment(id: deploymentID, tag: imageTag, at: runtime.now())
                .setting("requestedRevision", approvedRevision.map(NativeRPCValue.string) ?? .missing)
            try await store.write(serverID, appID, Self.appending(row, to: original))
            do {
                var plan: BackendAppsDeployPlan
                let commit: String
                if isTemplate {
                    plan = try await templatePlan(serverID: serverID, appID: appID, source: source, tag: imageTag)
                    commit = "template:" + (try BackendAppsDataTemplates.validatedEntry(source)).id
                } else {
                    let github = try BackendAppsDeploySource(source)
                    commit = try await clone(serverID: serverID, source: github, work: work, directory: directory, revision: approvedRevision)
                    plan = try await buildPlan(serverID: serverID, source: github, work: work)
                    try await build(serverID: serverID, appID: appID, plan: plan, work: work, tag: imageTag)
                }
                let image = try await inspectImage(serverID: serverID, image: imageTag)
                guard let imageID = image["Id"].string, imageID.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                    throw NativeRPCError(code: "build-failed", message: "The server did not retain the built app.")
                }
                if !isTemplate {
                    guard image["Config"]["Volumes"].isNullish || image["Config"]["Volumes"].fields?.isEmpty == true else {
                        throw BackendAppsRuntime.unavailable("This app needs saved storage. A managed storage mapping must be added before it can deploy safely.")
                    }
                    if source["port"].isNullish, plan.mode == .dockerfile {
                        let ports = (image["Config"]["ExposedPorts"].fields ?? []).map(\.key).filter { $0.hasSuffix("/tcp") }
                        guard ports.count == 1, let port = Int(ports[0].dropLast(4)), (1...65_535).contains(port) else {
                            throw BackendAppsRuntime.unavailable("Choose the app's listening port before deploying. Its build file does not name one web port.")
                        }
                        plan = plan.withPort(port)
                    }
                } else {
                    try BackendAppsDataTemplatePlanner.validateStorage(image: image, source: source)
                }
                row = row.setting("commit", .string(commit)).setting("imageId", .string(imageID))
                let finished = try await activate(serverID: serverID, appID: appID, original: original, row: row, plan: plan, image: imageID)
                var result = finished
                if !isTemplate, !(await removeBuildDirectory(serverID: serverID, work: work)) {
                    let warnings = (result["warnings"].elements ?? []) + [.string("Your app is running. Its temporary build files need cleanup; inspect the saved transaction result.")]
                    result = result.setting("warnings", .array(warnings)).setting("workCleanupNeeded", .bool(true))
                }
                return Self.publicDeployment(result)
            } catch {
                // A serving candidate is retained if route compensation failed.
                // Failed builds never stop or remove the previous app.
                let failureCode = (error as? NativeRPCError)?.code
                var finalFailure = Self.safe(error)
                if runtime.recovery != nil, failureCode != "state-failed", failureCode != "route-failed" {
                    do { try await restoreAppRecord(serverID: serverID, appID: appID, fallback: original) }
                    catch { finalFailure = NativeRPCError(code: "state-failed", message: "The deploy did not finish and its captured app state could not be restored. Inspect its saved recovery notes.") }
                } else if failureCode != "state-failed", failureCode != "route-failed" {
                    let current = try? await store.read(serverID, appID)
                    if current?["pendingDeploymentId"].isNullish != false {
                        let failed = row.setting("status", .string("failed")).setting("finishedAt", .number(runtime.now()))
                        try? await store.write(serverID, appID, Self.appending(failed, to: original))
                    }
                }
                if !isTemplate, !(await removeBuildDirectory(serverID: serverID, work: work)) {
                    finalFailure = NativeRPCError(code: "state-failed", message: "The deploy did not finish and its temporary files could not be cleaned up. Inspect its saved recovery notes before retrying.")
                }
                throw finalFailure
            }
        }
    }

    public func rollback(serverID: String, appID: String, deploymentID: String) async throws -> NativeRPCValue {
        _ = try BackendAppsValidation.id(appID)
        _ = try BackendAppsValidation.identifier(deploymentID)
        return try await store.withLock(serverID, appID) {
            let original = try await store.read(serverID, appID)
            try Self.requireSettled(original)
            guard try Self.cleanupIDs(original).count < Self.maximumPendingCleanup else { throw NativeRPCError(code: "busy", message: "Earlier app versions need cleanup before a rollback.") }
            try validateResourceNames()
            guard original["source"]["kind"].string != "template" else {
                throw BackendAppsRuntime.unavailable("Rolling this app back needs a safe maintenance window for its saved data. That path is not connected yet.")
            }
            guard let retained = Self.rows(original).first(where: { $0["id"].string == deploymentID && $0["status"].string == "running" }),
                  let tag = retained["imageTag"].string, let imageID = retained["imageId"].string,
                  tag.hasPrefix(imageRepository(appID) + ":"),
                  imageID.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw NativeRPCError(code: "not-found", message: "That successful deploy is no longer available to roll back to.")
            }
            let image = try await inspectImage(serverID: serverID, image: tag)
            guard image["Id"].string == imageID else {
                throw NativeRPCError(code: "conflict", message: "The retained app version has changed. Rollback was stopped.")
            }
            let port = try Self.port(retained["port"])
            _ = try BackendAppsValidation.identifier(String(tag.split(separator: ":").last ?? ""))
            let row = Self.deployment(id: runtime.resourcePrefix + "-deploy-" + UUID().uuidString.lowercased(), tag: tag, at: runtime.now())
                .setting("imageId", .string(imageID)).setting("rollbackOf", .string(deploymentID))
                .setting("commit", retained["commit"])
            // A rollback is a new deploy, retaining the immutable source tag.
            // Runtime settings use today's protected environment; data is untouched.
            let plan = BackendAppsDeployPlan(mode: .dockerfile, context: ".", dockerfile: "Dockerfile", port: port,
                                             command: retained["command"], entrypoint: retained["entrypoint"], environment: [:])
            return Self.publicDeployment(try await activate(serverID: serverID, appID: appID, original: original, row: row, plan: plan, image: imageID))
        }
    }

    private func activate(serverID: String, appID: String, original: NativeRPCValue, row: NativeRPCValue,
                          plan: BackendAppsDeployPlan, image: String) async throws -> NativeRPCValue {
        let previous = try Self.active(original)
        let transaction = try currentRecovery(serverID: serverID, appID: appID)
        let candidateRecovery = try await transaction?.register(.removeCreatedContainers)
        var pendingCleanup = try Self.cleanupIDs(original)
        if let id = previous?["containerId"].string {
            _ = try BackendAppsValidation.identifier(id)
            if !pendingCleanup.contains(id) { pendingCleanup.append(id) }
        }
        guard pendingCleanup.count <= Self.maximumPendingCleanup else { throw NativeRPCError(code: "busy", message: "Earlier app versions need cleanup before another deploy.") }
        var environment = plan.environment
        for (key, value) in try await store.environment(serverID, appID) { environment[key] = value }
        if environment["PORT"] == nil { environment["PORT"] = String(plan.port) }
        try await ensureNetwork(serverID: serverID)
        let name = "\(runtime.resourcePrefix)-\(appID)-\(row["id"].string!)"
        var labels = Self.object([("io.terminaldeck.managed", .string("true")), ("io.terminaldeck.app", .string(appID)), ("io.terminaldeck.deployment", row["id"])])
        if let transaction { labels = labels.setting("io.terminaldeck.transaction", .string(transaction.scope.ownerToken)) }
        let body = Self.object([
            ("Image", .string(image)), ("Env", .array(environment.keys.sorted().map { .string("\($0)=\(environment[$0]!)") })),
            ("Labels", labels),
            ("HostConfig", Self.object([("NetworkMode", .string(network)), ("PortBindings", Self.object([])),
                                         ("Mounts", .array(plan.mounts)),
                                         ("RestartPolicy", Self.object([("Name", .string("unless-stopped"))]))])),
            ("NetworkingConfig", Self.object([("EndpointsConfig", Self.object([(network, Self.object([]))]))]))
        ]).setting("Cmd", plan.command).setting("Entrypoint", plan.entrypoint)
        var createdID: String?
        var didRoute = false
        var mustRetainCandidate = false
        do {
            let response = try await request(serverID, "POST", "/containers/create?name=\(name)", body, code: "build-failed")
            guard let candidate = response["Id"].string, candidate.range(of: #"^[a-f0-9]{12,64}$"#, options: .regularExpression) != nil else {
                throw NativeRPCError(code: "build-failed", message: "The server did not create the next app version.")
            }
            createdID = candidate
            _ = try await request(serverID, "POST", "/containers/\(candidate)/start", code: "build-failed")
            let upstream = try await healthy(serverID: serverID, candidate: candidate, port: plan.port)
            let domains = try await domains(serverID: serverID, appID: appID, record: original)
            let prepared = row.setting("containerId", .string(candidate)).setting("upstream", .string(upstream))
                .setting("port", .number(Double(plan.port))).setting("domains", .array(domains.map(NativeRPCValue.string)))
                .setting("command", plan.command).setting("entrypoint", plan.entrypoint).setting("status", .string("ready"))
            let intent = Self.appending(prepared, to: original).setting("pendingDeploymentId", row["id"])
            // The intent is durable before Caddy changes. An interrupted operation
            // blocks another deployment until its route is explicitly recovered.
            try await store.write(serverID, appID, intent)
            let routeRecovery: BackendAppsRecoveryHandle?
            if let transaction {
                routeRecovery = try await transaction.register(.restoreCaddyRoute(routeID: transaction.scope.caddyRouteID, collectionPath: transaction.scope.routeCollectionPath))
            } else { routeRecovery = nil }
            do {
                try await caddy.swap(serverID: serverID, appID: appID, domains: domains, upstream: upstream, port: plan.port)
                didRoute = true
            } catch {
                if (error as? NativeRPCError)?.details["routeUncertain"].bool == true {
                    mustRetainCandidate = true
                    throw NativeRPCError(code: "route-failed", message: "The app address needs recovery. Both app versions were retained.",
                                         details: BackendAppsValidation.object([("routeUncertain", .bool(true))]))
                }
                // An I/O error can mean Caddy accepted a swap but its response was
                // lost; always compensate, even when swap did not return success.
                do {
                    if (error as? NativeRPCError)?.details["routeRecovered"].bool != true {
                        try await compensate(serverID: serverID, appID: appID, previous: previous, transaction: transaction, routeRecovery: routeRecovery)
                    }
                }
                catch {
                    mustRetainCandidate = true
                    throw NativeRPCError(code: "route-failed", message: "The app address needs recovery. Both app versions were retained.")
                }
                do { try await restoreAppRecord(serverID: serverID, appID: appID, fallback: Self.appending(prepared.setting("status", .string("failed")), to: original)) }
                catch {
                    mustRetainCandidate = true
                    throw NativeRPCError(code: "state-failed", message: "The previous app address was restored, but the saved deploy needs recovery. Both versions were retained.")
                }
                throw NativeRPCError(code: "route-failed", message: "The app address could not be updated. The previous app was kept.")
            }
            let finished = prepared.setting("status", .string("running")).setting("finishedAt", .number(runtime.now()))
            let committed = Self.appending(finished, to: original).setting("activeDeploymentId", row["id"])
                .setting("containerId", .string(candidate)).setting("status", .string("running"))
                .setting("address", .string("https://" + domains[0])).setting("domains", .array(domains.map(NativeRPCValue.string)))
                .setting("cleanupNeededContainers", .array(pendingCleanup.map(NativeRPCValue.string)))
                .setting("updatedAt", .number(runtime.now())).removing("pendingDeploymentId")
            do { try await store.write(serverID, appID, committed) }
            catch {
                do { try await compensate(serverID: serverID, appID: appID, previous: previous, transaction: transaction, routeRecovery: routeRecovery); didRoute = false }
                catch {
                    mustRetainCandidate = true
                    throw NativeRPCError(code: "state-failed", message: "The app address needs recovery after a save failure. Both versions were retained.")
                }
                do { try await restoreAppRecord(serverID: serverID, appID: appID, fallback: Self.appending(finished.setting("status", .string("failed")), to: original)) }
                catch {
                    mustRetainCandidate = true
                    throw NativeRPCError(code: "state-failed", message: "The previous app address was restored, but the saved deploy needs recovery. Both versions were retained.")
                }
                throw NativeRPCError(code: "state-failed", message: "The deploy could not be saved. The previous app was kept.")
            }
            // Only now can the prior instance retire. Its immutable image and
            // history remain available; failure here never undoes this deploy.
            return await Task { await retirePrevious(serverID: serverID, appID: appID, previous: previous, committed: committed, deployment: finished) }.value
        } catch {
            if !didRoute && !mustRetainCandidate {
                if !(await removeCandidate(serverID: serverID, candidate: createdID, transaction: transaction, recovery: candidateRecovery)) {
                    throw NativeRPCError(code: "state-failed", message: "The deploy failed and its candidate could not be cleaned up. Keep the saved recovery notes and inspect this app before retrying.", details: Self.object([("cleanupPending", .bool(true))]))
                }
            }
            throw Self.safe(error)
        }
    }

    private func clone(serverID: String, source: BackendAppsDeploySource, work: String, directory: String, revision: String?) async throws -> String {
        let token = try await runtime.githubCredential(serverID)
        guard token?.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) != true,
              (token?.utf8.count ?? 0) <= 65_536 else {
            throw BackendAppsRuntime.unavailable("The GitHub connection could not supply a usable sign-in.")
        }
        let q = BackendAppsRuntime.quote
        let branch = source.branch.map { "--branch " + q($0) + " " } ?? ""
        let marker: String
        if let transaction = BackendAppsRecoveryContext.current {
            marker = "printf '%s' " + q(transaction.scope.ownerToken) + " > " + q(work + "/.recovery-owner") + "\nchmod 600 " + q(work + "/.recovery-owner")
        } else { marker = "" }
        let checkout: String
        if let revision {
            // Fetch that object even when --depth 1 cloned a newer branch head.
            // Askpass stays protected and active for the authenticated fetch.
            let git = "git -C " + q(work + "/source") + " -c core.hooksPath=/dev/null -c credential.helper= -c protocol.file.allow=never "
            checkout = git + "fetch --depth 1 --no-tags origin " + q(revision) + " >/dev/null 2>&1\n"
                + git + "checkout --detach " + q(revision) + " -- >/dev/null 2>&1"
        } else { checkout = "" }
        let script = """
        set -eu
        umask 077
        test -d \(q(directory)) && test ! -L \(q(directory))
        test ! -L \(q(directory + "/" + runtime.resourcePrefix + "-builds"))
        mkdir -p \(q(directory + "/" + runtime.resourcePrefix + "-builds"))
        chmod 700 \(q(directory + "/" + runtime.resourcePrefix + "-builds"))
        mkdir \(q(work))
        \(marker)
        credential=\(q(work + "/.github-input"))
        askpass=\(q(work + "/.github-askpass"))
        trap 'rm -f "$credential" "$askpass"' EXIT
        trap 'exit 130' HUP INT TERM
        cat > "$credential"
        chmod 600 "$credential"
        cat > "$askpass" <<'TERMINALDECK_ASKPASS'
        #!/bin/sh
        case "$1" in
          *Username*|*username*) printf '%s\\n' 'x-access-token' ;;
          *) cat "$TD_GITHUB_INPUT" ;;
        esac
        TERMINALDECK_ASKPASS
        chmod 700 "$askpass"
        export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        export GIT_ASKPASS="$askpass" TD_GITHUB_INPUT="$credential"
        git -c core.hooksPath=/dev/null -c credential.helper= -c protocol.file.allow=never clone --depth 1 --single-branch \(branch)-- \(q("https://github.com/" + source.repository + ".git")) \(q(work + "/source")) >/dev/null 2>&1
        \(checkout)
        git -C \(q(work + "/source")) -c core.hooksPath=/dev/null rev-parse --verify 'HEAD^{commit}'
        """
        let commit = try await runtime.checked(serverID, script, stdin: Data((token ?? "").utf8), timeoutMS: 180_000,
                                               code: "build-failed", message: revision == nil ? "The repository could not be downloaded. Check GitHub access and the branch." : "The approved revision could not be downloaded. Check GitHub access; the server must allow a shallow fetch of that exact revision.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.range(of: #"^(?:[a-f0-9]{40}|[a-f0-9]{64})$"#, options: .regularExpression) != nil else {
            throw NativeRPCError(code: "build-failed", message: "The repository did not supply a valid revision.")
        }
        guard revision == nil || commit == revision else {
            throw NativeRPCError(code: "build-failed", message: "The downloaded revision does not match the approved push. Nothing was built or switched.")
        }
        return commit
    }

    private func buildPlan(serverID: String, source: BackendAppsDeploySource, work: String) async throws -> BackendAppsDeployPlan {
        if source.build == "compose" {
            let path: String
            if let file = source.composeFile { path = try Self.relative(file) }
            else {
                let script = "set -eu\nfor candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml compose.json; do\n"
                    + "if test -f " + BackendAppsRuntime.quote(work + "/source") + "/\"$candidate\"; then printf '%s' \"$candidate\"; exit 0; fi\ndone\nexit 44"
                path = try await runtime.checked(serverID, script, code: "build-failed", message: "No compose file was found in the repository. Choose its compose file in app settings.")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml", "compose.json"].contains(path) else {
                    throw NativeRPCError(code: "build-failed", message: "The app's compose file could not be verified.")
                }
            }
            let text = try await runtime.checked(serverID, Self.readSource(work: work, path: path),
                                                  code: "build-failed", message: "The app's compose file could not be read.")
            let json = try BackendAppsComposeYAML.parse(text)
            return try BackendAppsDeployPlan.compose(json, service: source.service, port: source.port)
        }
        let dockerfile = try Self.relative(source.dockerfile ?? "Dockerfile")
        if source.build == "dockerfile" {
            return .init(mode: .dockerfile, context: ".", dockerfile: dockerfile, port: source.port ?? 3000)
        }
        let result = try await runtime.run(serverID, "set -eu\n" + Self.sourcePathGuard(work: work, path: dockerfile) + "\ntest -f " + BackendAppsRuntime.quote(work + "/source/" + dockerfile))
        guard !result.truncated else { throw NativeRPCError(code: "build-failed", message: "The server could not inspect the repository.") }
        if result.code == 0 { return .init(mode: .dockerfile, context: ".", dockerfile: dockerfile, port: source.port ?? 3000) }
        guard result.code == 1 else { throw NativeRPCError(code: "build-failed", message: "The app build path could not be verified.") }
        return .init(mode: .railpack, context: ".", dockerfile: "Dockerfile", port: source.port ?? 3000)
    }

    private func build(serverID: String, appID: String, plan: BackendAppsDeployPlan, work: String, tag: String) async throws {
        let q = BackendAppsRuntime.quote
        let root = work + "/source"
        let guardScript = Self.sourcePathGuard(work: work, path: plan.context)
        let script: String
        switch plan.mode {
        case .dockerfile:
            script = "set -eu\n" + guardScript + "\n" + Self.sourcePathGuard(work: work, path: plan.context + "/" + plan.dockerfile)
                + "\ndocker build --label io.terminaldeck.managed=true --label " + q("io.terminaldeck.app=" + appID)
                + " --tag " + q(tag) + " --file " + q(root + "/" + plan.context + "/" + plan.dockerfile) + " " + q(root + "/" + plan.context) + " >/dev/null 2>&1"
        case .railpack:
            // Official CLI uses --name and an already configured BuildKit host.
            // We deliberately do not install/start a privileged builder.
            _ = try await runtime.checked(serverID, "command -v railpack >/dev/null 2>&1 && test -n \"${BUILDKIT_HOST:-}\"", code: "unavailable",
                                           message: "Automatic builds need Railpack and a configured BuildKit builder on this server.")
            script = "set -eu\n" + guardScript + "\nrailpack build --name " + q(tag) + " " + q(root) + " >/dev/null 2>&1"
        }
        _ = try await runtime.checked(serverID, script, timeoutMS: 900_000, code: "build-failed", message: "The app could not be built. Check its build file and dependencies.")
        if plan.mode == .railpack { try await labelImage(serverID: serverID, appID: appID, source: tag, tag: tag) }
    }

    private func ensureNetwork(serverID: String) async throws {
        let response = try await runtime.docker(serverID, "GET", "/networks/\(network)", nil)
        if response.status == 404 {
            _ = try await request(serverID, "POST", "/networks/create", Self.object([
                ("Name", .string(network)), ("Driver", .string("bridge")), ("CheckDuplicate", .bool(true)),
                ("Labels", Self.object([("io.terminaldeck.managed", .string("true"))]))
            ]), code: "build-failed")
        } else if !response.ok {
            throw BackendAppsRuntime.unavailable("The app's private connection could not be checked.")
        }
        let details = try await request(serverID, "GET", "/networks/\(network)", code: "build-failed")
        guard details["Driver"].string == "bridge", details["Labels"]["io.terminaldeck.managed"].string == "true",
              details["Scope"].string == "local" else {
            throw NativeRPCError(code: "conflict", message: "The app network is already used by something this app does not manage.")
        }
    }

    private func inspectImage(serverID: String, image: String) async throws -> NativeRPCValue {
        let encoded = image.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try await request(serverID, "GET", "/images/\(encoded)/json", code: "build-failed")
    }

    private func healthy(serverID: String, candidate: String, port: Int) async throws -> String {
        for attempt in 0..<60 {
            try Task.checkCancellation()
            let inspect = try await request(serverID, "GET", "/containers/\(candidate)/json", code: "health-failed")
            guard inspect["State"]["Running"].bool == true else {
                throw NativeRPCError(code: "health-failed", message: "The next app version stopped before it was ready.")
            }
            let ip = inspect["NetworkSettings"]["Networks"][network]["IPAddress"].string ?? ""
            guard Self.privateIPv4(ip) else { throw NativeRPCError(code: "health-failed", message: "The next app version has no private address.") }
            let health = inspect["State"]["Health"]["Status"].string
            if health == "healthy" { return ip }
            if health == "unhealthy" { throw NativeRPCError(code: "health-failed", message: "The next app version did not pass its health check.") }
            if health == nil {
                let probe = try await runtime.run(serverID, "command -v curl >/dev/null 2>&1 || exit 127\ncurl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 3 "
                                                  + BackendAppsRuntime.quote("http://\(ip):\(port)/") + " >/dev/null 2>&1", timeoutMS: 5_000, maximumBytes: 1024)
                if probe.code == 0, !probe.truncated { return ip }
                if probe.code == 127 { throw BackendAppsRuntime.unavailable("The server needs curl to check apps without a built-in health check.") }
            }
            if attempt < 59 { try await Task.sleep(for: .seconds(1)) }
        }
        throw NativeRPCError(code: "health-failed", message: "The next app version was not ready in time. The previous app was kept.")
    }

    private func domains(serverID: String, appID: String, record: NativeRPCValue) async throws -> [String] {
        if let values = record["domains"].elements, !values.isEmpty {
            return try values.map { try $0.requireString("App address", nonempty: true) }
        }
        return [try await caddy.defaultDomain(serverID: serverID, appID: appID)]
    }

    private func restoreRoute(serverID: String, appID: String, previous: NativeRPCValue?) async throws {
        if let previous {
            let domains = try previous["domains"].requireArray("Previous addresses").map { try $0.requireString("Previous address", nonempty: true) }
            guard !domains.isEmpty, let ip = previous["upstream"].string, Self.privateIPv4(ip) else {
                throw NativeRPCError(code: "route-failed", message: "The previous app address cannot be recovered automatically.")
            }
            try await caddy.swap(serverID: serverID, appID: appID, domains: domains, upstream: ip, port: try Self.port(previous["port"]))
        } else { try await caddy.remove(serverID: serverID, appID: appID) }
    }

    private func compensate(serverID: String, appID: String, previous: NativeRPCValue?, transaction: BackendAppsRecoveryTransaction?, routeRecovery: BackendAppsRecoveryHandle?) async throws {
        // Compensation must finish even when the request owner disconnected.
        // Unstructured Tasks inherit the approved call's TaskLocal authority,
        // while starting with an independent cancellation state.
        if let transaction, let routeRecovery {
            let outcome = try await Task { try await transaction.perform(routeRecovery) }.value
            guard outcome.completed else { throw NativeRPCError(code: "route-failed", message: "The captured app address could not be recovered. Keep both versions for inspection.") }
            return
        }
        guard runtime.recovery == nil else { throw NativeRPCError(code: "route-failed", message: "The app has no usable captured address recovery step.") }
        try await Task { try await restoreRoute(serverID: serverID, appID: appID, previous: previous) }.value
    }

    private func imageRepository(_ appID: String) -> String {
        runtime.resourcePrefix == "terminaldeck" ? "terminaldeck/" + appID : runtime.resourcePrefix + "-" + appID
    }

    private func validateResourceNames() throws {
        _ = try BackendAppsValidation.id(runtime.resourcePrefix)
        _ = try BackendAppsValidation.identifier(network)
    }

    private func templatePlan(serverID: String, appID: String, source: NativeRPCValue, tag: String) async throws -> BackendAppsDeployPlan {
        return try await BackendAppsDataTemplatePlanner(runtime: runtime)
            .plan(serverID: serverID, appID: appID, source: source, tag: tag)
    }

    private func labelImage(serverID: String, appID: String, source: String, tag: String) async throws {
        let image = try await inspectImage(serverID: serverID, image: source)
        guard let id = image["Id"].string, id.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw NativeRPCError(code: "build-failed", message: "The app's source version could not be verified.")
        }
        let q = BackendAppsRuntime.quote
        _ = try await runtime.checked(serverID, "docker build --network none --label io.terminaldeck.managed=true --label "
                                       + q("io.terminaldeck.app=" + appID) + " --tag " + q(tag) + " - >/dev/null 2>&1",
                                       stdin: Data(("FROM " + id + "\n").utf8), timeoutMS: 300_000,
                                       code: "build-failed", message: "The app version could not be retained safely.")
    }

    private func removeCandidate(serverID: String, candidate: String?, transaction: BackendAppsRecoveryTransaction?, recovery: BackendAppsRecoveryHandle?) async -> Bool {
        if let transaction, let recovery {
            return await Task { do { return try await transaction.perform(recovery).completed } catch { return false } }.value
        }
        guard runtime.recovery == nil, let candidate else { return false }
        return await Task {
            do { let response = try await runtime.docker(serverID, "DELETE", "/containers/\(candidate)?force=true&v=false", nil); return response.ok || response.status == 404 }
            catch { return false }
        }.value
    }

    private func retirePrevious(serverID: String, appID: String, previous: NativeRPCValue?, committed: NativeRPCValue,
                                deployment: NativeRPCValue) async -> NativeRPCValue {
        var pending = (committed["cleanupNeededContainers"].elements ?? []).compactMap(\.string)
        var retiredID: String?
        var warnings: [String] = []
        if let previous, let id = previous["containerId"].string {
            do {
                guard id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil, id != deployment["containerId"].string else { throw NativeRPCError(code: "conflict", message: "The prior app version needs inspection.") }
                let inspected = try await runtime.docker(serverID, "GET", "/containers/\(id)/json", nil)
                if inspected.status == 404 { retiredID = id }
                else {
                    guard inspected.ok else { throw BackendAppsRuntime.unavailable("The previous version could not be checked.") }
                    let details = try inspected.value()
                    guard Self.owns(details, appID: appID), details["Id"].string == id, let running = details["State"]["Running"].bool else { throw NativeRPCError(code: "conflict", message: "The previous version is not owned by this app.") }
                    if running {
                        let stopped = try await runtime.docker(serverID, "POST", "/containers/\(id)/stop?t=10", nil)
                        guard stopped.ok || stopped.status == 304 else { throw BackendAppsRuntime.unavailable("The previous version could not be stopped.") }
                        let checked = try await runtime.docker(serverID, "GET", "/containers/\(id)/json", nil)
                        if checked.status != 404 {
                            guard checked.ok else { throw BackendAppsRuntime.unavailable("The previous version could not be checked.") }
                            let value = try checked.value()
                            guard Self.owns(value, appID: appID), value["Id"].string == id, value["State"]["Running"].bool == false else { throw BackendAppsRuntime.unavailable("The previous version has not stopped yet.") }
                        }
                    }
                    retiredID = id
                }
            } catch {
                // Never expose transport output, stop an unowned instance, or
                // compensate a durable successful deployment for cleanup.
                warnings.append("Your new app is running. The previous version could not be stopped safely and needs cleanup.")
            }
        }
        if let retiredID { pending.removeAll { $0 == retiredID } }
        if !pending.isEmpty, warnings.isEmpty { warnings.append("Your new app is running. Earlier app versions still need cleanup.") }
        var result = deployment.setting("cleanupNeeded", .bool(!pending.isEmpty))
            .setting("cleanupNeededIds", .array(pending.map(NativeRPCValue.string))).setting("warnings", .array(warnings.map(NativeRPCValue.string)))
        var saved = Self.appending(result, to: committed).setting("cleanupNeededContainers", .array(pending.map(NativeRPCValue.string)))
        if let retiredID {
            saved = saved.setting("deployments", .array(Self.rows(saved).map { $0["containerId"].string == retiredID ? $0.setting("instanceState", .string("stopped")) : $0 }))
        }
        do { try await store.write(serverID, appID, saved) }
        catch {
            warnings.append("Your new app is running. Its cleanup result could not be saved; inspect the previous versions before the next deploy.")
            result = result.setting("warnings", .array(warnings.map(NativeRPCValue.string))).setting("cleanupStateSaved", .bool(false))
        }
        return result
    }
    private func removeBuildDirectory(serverID: String, work: String) async -> Bool {
        if runtime.recovery != nil {
            guard let transaction = BackendAppsRecoveryContext.current, transaction.scope.serverID == serverID,
                  let handle = await transaction.registered(.removeAppWorkDirectory(path: work)) else { return false }
            return await Task { do { return try await transaction.perform(handle).completed } catch { return false } }.value
        }
        return await Task {
            do { let result = try await runtime.run(serverID, "rm -rf -- " + BackendAppsRuntime.quote(work), timeoutMS: 30_000, maximumBytes: 1024); return result.code == 0 && !result.truncated }
            catch { return false }
        }.value
    }

    private func currentRecovery(serverID: String, appID: String) throws -> BackendAppsRecoveryTransaction? {
        guard runtime.recovery != nil else { return nil }
        guard let transaction = BackendAppsRecoveryContext.current, transaction.scope.serverID == serverID, transaction.scope.appID == appID,
              transaction.scope.stateRoot == store.stateRoot, transaction.scope.resourcePrefix == runtime.resourcePrefix,
              transaction.scope.privateNetwork == runtime.privateNetwork else {
            throw NativeRPCError(code: "access-denied", message: "This deploy needs its own approved app recovery transaction.")
        }
        return transaction
    }

    private func restoreAppRecord(serverID: String, appID: String, fallback: NativeRPCValue) async throws {
        if runtime.recovery != nil {
            let path = try store.directory(appID) + "/state.json"
            let recovered = try await Task { try await store.recoverFile(serverID, path: path) }.value
            guard recovered else { throw NativeRPCError(code: "state-failed", message: "The captured app state could not be recovered. Inspect its transaction notes before retrying.") }
            return
        }
        try await store.write(serverID, appID, fallback)
    }
    private func request(_ serverID: String, _ method: String, _ path: String, _ value: NativeRPCValue? = nil, code: String) async throws -> NativeRPCValue {
        let response: BackendAppsHTTPResponse
        do { response = try await runtime.docker(serverID, method, path, try value?.encodedJSON()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendAppsRuntime.unavailable("The app's private server connection did not finish.") }
        guard response.ok else { throw NativeRPCError(code: code, message: "The server could not complete this app action.") }
        if response.body.isEmpty { return .null }
        return try response.value()
    }

    private static func requireSettled(_ record: NativeRPCValue) throws {
        guard record["pendingDeploymentId"].isNullish else {
            throw NativeRPCError(code: "conflict", message: "An interrupted deploy needs its app address recovered before another deploy.")
        }
    }
    private static func active(_ record: NativeRPCValue) throws -> NativeRPCValue? {
        guard let id = record["activeDeploymentId"].string else { return nil }
        guard let previous = rows(record).first(where: { $0["id"].string == id }),
              previous["containerId"].string != nil, privateIPv4(previous["upstream"].string ?? ""),
              previous["domains"].elements?.isEmpty == false else {
            throw NativeRPCError(code: "state-failed", message: "The previous app's recovery details are missing.")
        }
        _ = try port(previous["port"])
        return previous
    }
    private static func deployment(id: String, tag: String, at: Double) -> NativeRPCValue {
        object([("id", .string(id)), ("imageTag", .string(tag)), ("status", .string("building")), ("createdAt", .number(at))])
    }
    private static func rows(_ record: NativeRPCValue) -> [NativeRPCValue] { record["deployments"].elements ?? [] }
    private static func publicDeployment(_ row: NativeRPCValue) -> NativeRPCValue {
        let keys: Set<String> = ["id", "imageTag", "imageId", "containerId", "upstream", "port", "domains", "status", "createdAt", "finishedAt", "commit", "rollbackOf", "requestedRevision", "instanceState", "warnings", "cleanupNeeded", "cleanupNeededIds", "cleanupStateSaved", "workCleanupNeeded"]
        return .object((row.fields ?? []).filter { keys.contains($0.key) })
    }
    private static func appending(_ row: NativeRPCValue, to record: NativeRPCValue) -> NativeRPCValue {
        record.setting("deployments", .array([row] + rows(record).filter { $0["id"] != row["id"] }))
    }
    private static func object(_ values: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendAppsValidation.object(values) }
    private static func safe(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        return error as? NativeRPCError ?? NativeRPCError(code: "build-failed", message: "The app deploy could not finish. The previous version was kept.")
    }
    private static let maximumPendingCleanup = 8
    private static func cleanupIDs(_ record: NativeRPCValue) throws -> [String] {
        if record["cleanupNeededContainers"].isNullish { return [] }
        guard let rows = record["cleanupNeededContainers"].elements, rows.count <= maximumPendingCleanup else { throw NativeRPCError(code: "state-failed", message: "The app's cleanup record needs inspection.") }
        let ids = try rows.map { try BackendAppsValidation.identifier($0.requireString("Previous app version", nonempty: true)) }
        guard Set(ids).count == ids.count else { throw NativeRPCError(code: "state-failed", message: "The app's cleanup record needs inspection.") }
        return ids
    }
    private static func owns(_ inspection: NativeRPCValue, appID: String) -> Bool {
        inspection["Config"]["Labels"]["io.terminaldeck.app"].string == appID && inspection["Config"]["Labels"]["io.terminaldeck.managed"].string == "true"
    }
    static func port(_ value: NativeRPCValue) throws -> Int {
        guard let number = value.number, number.rounded() == number, (1...65535).contains(number) else {
            throw NativeRPCError.invalidArguments("Choose the app's listening port between 1 and 65535.")
        }
        return Int(number)
    }
    static func relative(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 512, !value.hasPrefix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }),
            !value.contains(":"),
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != ".." }) else {
            throw NativeRPCError.invalidArguments("Build files must use a path inside the repository.")
        }
        return value
    }
    static func privateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> Int? in
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = Int(part), (0...255).contains(byte), String(byte) == part else { return nil }
            return byte
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
    }
    private static func sourcePathGuard(work: String, path: String) -> String {
        let q = BackendAppsRuntime.quote
        return "root=$(realpath -- " + q(work + "/source") + ")\nresolved=$(realpath -m -- " + q(work + "/source/" + path)
            + ")\ncase \"$resolved\" in \"$root\"|\"$root\"/*) ;; *) exit 65 ;; esac"
    }
    private static func readSource(work: String, path: String) -> String {
        "set -eu\n" + sourcePathGuard(work: work, path: path) + "\ncat -- " + BackendAppsRuntime.quote(work + "/source/" + path)
    }
}

struct BackendAppsDeploySource: Sendable {
    let repository: String, build: String
    let branch: String?
    let port: Int?
    let dockerfile: String?, composeFile: String?, service: String?
    init(_ value: NativeRPCValue) throws {
        let allowed: Set<String> = ["kind", "repository", "branch", "build", "port", "dockerfile", "composeFile", "service"]
        guard let fields = value.fields, fields.allSatisfy({ allowed.contains($0.key) }) else {
            throw NativeRPCError.invalidArguments("The repository source contains unsupported settings.")
        }
        for key in ["branch", "build", "dockerfile", "composeFile", "service"] {
            guard value[key].isNullish || value[key].string != nil else {
                throw NativeRPCError.invalidArguments("Repository build options must use plain text.")
            }
        }
        guard value["kind"].string == "github", let repository = value["repository"].string,
              repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil,
              !repository.hasSuffix("/.."), !repository.hasSuffix("/.") else {
            throw NativeRPCError.invalidArguments("Choose a GitHub repository in owner/repository form.")
        }
        let branch = value["branch"].string
        if let branch {
            guard !branch.isEmpty, branch.utf8.count <= 255, !branch.hasPrefix("-"),
                  !branch.contains(".."), !branch.contains("@{"), !branch.contains("\\"),
                  branch.range(of: #"[\s\x00-\x1f\x7f~^:?*\[]"#, options: .regularExpression) == nil else {
                throw NativeRPCError.invalidArguments("Choose a valid repository branch.")
            }
        }
        let build = value["build"].string ?? "auto"
        guard ["auto", "dockerfile", "compose"].contains(build) else { throw NativeRPCError.invalidArguments("Choose a supported app build method.") }
        self.repository = repository; self.branch = branch; self.build = build
        self.port = value["port"].isNullish ? nil : try BackendAppsDeploy.port(value["port"])
        self.dockerfile = value["dockerfile"].string; self.composeFile = value["composeFile"].string; self.service = value["service"].string
        if let dockerfile { _ = try BackendAppsDeploy.relative(dockerfile) }
        if let composeFile { _ = try BackendAppsDeploy.relative(composeFile) }
        if let service { _ = try BackendAppsValidation.identifier(service) }
    }
}

struct BackendAppsDeployPlan: Sendable {
    enum Mode: Sendable, Equatable { case dockerfile, railpack }
    let mode: Mode
    let context: String, dockerfile: String
    let port: Int
    let command: NativeRPCValue, entrypoint: NativeRPCValue
    let environment: [String: String]
    let mounts: [NativeRPCValue]
    init(mode: Mode, context: String, dockerfile: String, port: Int, command: NativeRPCValue = .missing,
         entrypoint: NativeRPCValue = .missing, environment: [String: String] = [:], mounts: [NativeRPCValue] = []) {
        self.mode = mode; self.context = context; self.dockerfile = dockerfile; self.port = port
        self.command = command; self.entrypoint = entrypoint; self.environment = environment; self.mounts = mounts
    }
    func withPort(_ port: Int) -> Self {
        .init(mode: mode, context: context, dockerfile: dockerfile, port: port, command: command, entrypoint: entrypoint, environment: environment, mounts: mounts)
    }

    /// The bounded Swift YAML/JSON reader supplies the syntax. This separate
    /// allowlist validates behavior before building, never compose up.
    static func compose(_ value: NativeRPCValue, service: String?, port: Int?) throws -> Self {
        guard let service, !service.isEmpty, let port,
              let top = value.fields, Set(top.map(\.key)).isSubset(of: ["name", "version", "services"]),
              let services = value["services"].fields, services.count == 1, services[0].key == service,
              let fields = services[0].value.fields else {
            throw BackendAppsRuntime.unavailable("Compose needs one named web service, its listening port, and no extra resources.")
        }
        let allowed: Set<String> = ["build", "command", "entrypoint", "environment", "expose", "restart"]
        guard Set(fields.map(\.key)).isSubset(of: allowed) else {
            throw BackendAppsRuntime.unavailable("This compose app uses settings that cannot be deployed safely yet. Host access, published ports and extra services are not supported.")
        }
        let web = services[0].value
        let context: String, dockerfile: String
        if let text = web["build"].string { context = try BackendAppsDeploy.relative(text); dockerfile = "Dockerfile" }
        else {
            guard let build = web["build"].fields, Set(build.map(\.key)).isSubset(of: ["context", "dockerfile"]),
                  let text = web["build"]["context"].string else {
                throw BackendAppsRuntime.unavailable("Compose needs a local build folder and a Dockerfile. Build arguments and external build contexts are not supported yet.")
            }
            context = try BackendAppsDeploy.relative(text)
            dockerfile = try BackendAppsDeploy.relative(web["build"]["dockerfile"].string ?? "Dockerfile")
        }
        func argv(_ value: NativeRPCValue) throws -> NativeRPCValue {
            if value.isNullish { return .missing }
            guard let values = value.elements, values.count <= 256, values.allSatisfy({ ($0.string?.utf8.count ?? 65_537) <= 65_536 && $0.string?.contains("\0") == false }) else {
                throw BackendAppsRuntime.unavailable("Compose start commands must be a list of words.")
            }
            return value
        }
        let env = web["environment"].isNullish ? [:] : try BackendAppsValidation.environment(web["environment"])
        if let exposed = web["expose"].elements {
            for entry in exposed {
                let text: String
                if let string = entry.string { text = string }
                else { text = String(try BackendAppsDeploy.port(entry)) }
                guard text == String(port) || text == "\(port)/tcp" else { throw BackendAppsRuntime.unavailable("Compose may expose only the selected app port.") }
            }
        } else if !web["expose"].isNullish { throw NativeRPCError.invalidArguments("Compose app ports must be a list.") }
        if !web["restart"].isNullish {
            guard let restart = web["restart"].string, restart == "unless-stopped" || restart == "always" else {
                throw BackendAppsRuntime.unavailable("This compose restart setting is not supported yet.")
            }
        }
        return .init(mode: .dockerfile, context: context, dockerfile: dockerfile, port: port,
                     command: try argv(web["command"]), entrypoint: try argv(web["entrypoint"]), environment: env)
    }
}
