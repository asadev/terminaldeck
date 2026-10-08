import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Exercises actual Apps services with injected server callbacks. File-command
/// assertions cover the requested protection/atomicity, not real Linux I/O.
/// Channel/deploy/Caddy transaction cases are added when APE exposes those APIs.
@Suite("DKT Apps contract production services with synthetic server state")
struct DKTCaddyAppsContractTests {
    @Test("every Apps write denies by default before any server I/O, even with approved payload", arguments: BackendAppsChannels.writeChannels.sorted())
    func defaultWriteAuthorization(channel: String) async throws {
        let files = DKTAppsServerFiles()
        let caddy = try DKTFakeCaddy.protectedDemo()
        let service = BackendAppsChannels(runtime: files.runtime(caddy: caddy))
        let request = BackendAppsValidation.object([
            ("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID)),
            ("approved", .bool(true)), ("confirmation", .string(DKTAppsFixtures.appName)),
            ("env", BackendAppsValidation.object([("API_TOKEN", .string(DKTAppsFixtures.dummySecret))]))
        ])
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "dkt-owner", capabilities: ["apps.read", "apps.write"])
        do {
            _ = try await service.invoke(channel, request: request, context: context)
            Issue.record("unapproved Apps write unexpectedly succeeded")
        } catch let error as NativeRPCError { #expect(error.code == "approval-required") }
        #expect(await files.invocations.isEmpty)
        #expect(caddy.requests.isEmpty)
    }

    @Test("registered read and create channels persist server state and return masked records")
    func registeredCreateAndEnvRead() async throws {
        let files = DKTAppsServerFiles()
        let docker = DKTDockerFake()
        let approval = DKTAppsApprovalRecorder()
        let service = BackendAppsChannels(runtime: files.runtime(docker: docker), authorize: { action, context in
            try context.require(BackendAppsChannels.writeChannels.contains(action.channel) ? "apps.write" : "apps.read")
            await approval.record(action)
        })
        let registry = NativeChannelRegistry()
        try await BackendAppsChannels.register(registry: registry, service: service, ownerID: "dkt-apps")
        let request = BackendAppsValidation.object([
            ("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID)),
            ("name", .string(DKTAppsFixtures.appName)), ("source", DKTAppsFixtures.appRecord()["source"]),
            ("env", BackendAppsValidation.object([("API_TOKEN", .string(DKTAppsFixtures.dummySecret))]))
        ])
        let created = try await registry.invoke("apps:create", context: context(), arguments: [request])
        #expect(created["id"].string == DKTAppsFixtures.appID)
        #expect(created["status"].string == "stopped")
        #expect(!String(decoding: try created.encodedJSON(), as: UTF8.self).contains(DKTAppsFixtures.dummySecret))
        let identity = BackendAppsValidation.object([("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID))])
        let masked = try await registry.invoke("apps:env:read", context: context(), arguments: [identity])
        #expect(masked.elements?.count == 1)
        #expect(masked.elements?.first?["value"].string == "••••••••")
        #expect(masked.elements?.first?["secret"].bool == true)
        let listed = try await registry.invoke("apps:list", context: context(), arguments: [identity])
        #expect(listed.elements?.map { $0["id"].string } == [DKTAppsFixtures.appID])
        let actions = await approval.actions
        #expect(actions.map(\.channel) == ["apps:create", "apps:env:read", "apps:list"])
        #expect(actions.allSatisfy { !$0.preview.compact.contains(DKTAppsFixtures.dummySecret) })
        #expect(docker.respond(to: .init(method: "GET", target: "/containers/td-test-app/json")).statusCode == 404)
        #expect(await files.unsupportedCommands.isEmpty)
    }

    @Test("destructive app removal rejects a wrong exact name before Docker or Caddy writes")
    func destructiveConfirmation() async throws {
        let files = DKTAppsServerFiles()
        let caddy = try DKTFakeCaddy.protectedDemo()
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID) + "/state.json"
        await files.seed(path: path, data: try DKTAppsFixtures.appRecord().encodedJSON())
        let service = BackendAppsChannels(runtime: files.runtime(caddy: caddy), authorize: { _, _ in })
        let request = BackendAppsValidation.object([
            ("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID)),
            ("confirmation", .string("wrong app name"))
        ])
        do {
            _ = try await service.invoke("apps:remove", request: request, context: context())
            Issue.record("wrong destructive confirmation unexpectedly accepted")
        } catch let error as NativeRPCError { #expect(error.code == "confirmation-required") }
        #expect(caddy.requests.isEmpty)
        #expect(await files.invocations.allSatisfy { $0.stdin == nil && $0.script.contains("cat -- ") })
    }

    @Test("signed webhook dependency cannot be bypassed by enabling auto deploy")
    func autoDeployUnavailable() async throws {
        let files = DKTAppsServerFiles()
        let service = BackendAppsChannels(runtime: files.runtime(), authorize: { _, _ in })
        let request = BackendAppsValidation.object([
            ("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID)), ("enabled", .bool(true))
        ])
        do {
            _ = try await service.invoke("apps:auto-deploy:apply", request: request, context: context())
            Issue.record("unwired auto deploy unexpectedly enabled")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await files.invocations.isEmpty)
    }

    @Test("production Caddy swap and remove preserve protected demo config through Unix API")
    func productionCaddyRouteLifecycle() async throws {
        let files = DKTAppsServerFiles()
        let caddy = try DKTFakeCaddy.protectedDemo(strictAdminHost: true)
        try caddy.start()
        defer { caddy.stop() }
        let before = try caddy.configSnapshot()
        let protectedBefore = caddy.respond(to: .init(method: "GET", target: "/id/" + DKTFakeCaddy.protectedDemoRouteID,
                                                      headers: ["Host": "localhost:2019"])).body
        let runtime = files.runtime(caddy: caddy, viaUnixSocket: true, resourcePrefix: "td-test", caddyServerKey: "terminaldeck")
        let addresses = BackendAppsCaddy(runtime: runtime)
        let domains = ["td-test-app.192.0.2.5.sslip.io"]
        try await addresses.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                                 domains: domains, upstream: "172.18.0.2", port: 8080)
        try await addresses.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                                 domains: domains, upstream: "172.18.0.3", port: 8080)
        let active = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, target: "/id/" + DKTAppsRollbackFixture.routeID,
                                                   headers: ["Host": "localhost:2019"])
        #expect(try DKTCaddyJSON(data: active.body).value(at: ["handle", "0", "upstreams", "0", "dial"]) == .string("172.18.0.3:8080"))
        let protectedAfter = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, target: "/id/" + DKTFakeCaddy.protectedDemoRouteID,
                                                           headers: ["Host": "localhost:2019"])
        #expect(protectedAfter.body == protectedBefore)
        try await addresses.remove(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID)
        #expect(try caddy.configSnapshot() == before)
        #expect(caddy.requests.filter { $0.method != "GET" }.map(\.method) == ["PUT", "PATCH", "DELETE"])
        #expect(caddy.requests.allSatisfy { $0.target != "/load" && !($0.method != "GET" && $0.target == "/config/") })
        #expect(await files.lockPaths().isEmpty)
        #expect(await files.unsupportedCommands.isEmpty)
    }

    @Test("production Caddy failure retains prior route and releases its global lock")
    func productionCaddyFailure() async throws {
        let files = DKTAppsServerFiles()
        let caddy = try DKTFakeCaddy.protectedDemo()
        let service = BackendAppsCaddy(runtime: files.runtime(caddy: caddy, resourcePrefix: "td-test", caddyServerKey: "terminaldeck"))
        let domains = ["td-test-app.192.0.2.5.sslip.io"]
        try await service.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                               domains: domains, upstream: "172.18.0.2", port: 8080)
        let before = try caddy.configSnapshot()
        caddy.failNext(method: "PATCH", path: "/id/" + DKTAppsRollbackFixture.routeID, statusCode: 400,
                       message: DKTAppsFixtures.dummySecret)
        do {
            try await service.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                                   domains: domains, upstream: "172.18.0.3", port: 8080)
            Issue.record("failed route unexpectedly activated")
        } catch let error as NativeRPCError {
            #expect(error.code == "route-failed")
            #expect(!error.message.contains(DKTAppsFixtures.dummySecret))
        }
        #expect(try caddy.configSnapshot() == before)
        #expect(await files.lockPaths().isEmpty)
    }

    @Test("active Caddy mutation with failed autosave restores the earlier durable route")
    func caddyAutosaveFailureCompensates() async throws {
        let files = DKTAppsServerFiles()
        let caddy = try DKTFakeCaddy.protectedDemo()
        let service = BackendAppsCaddy(runtime: files.runtime(caddy: caddy, resourcePrefix: "td-test", caddyServerKey: "terminaldeck"))
        let domains = ["td-test-app.192.0.2.5.sslip.io"]
        try await service.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                               domains: domains, upstream: "172.18.0.2", port: 8080)
        let before = try caddy.configSnapshot()
        caddy.suppressNextAutosave()
        do {
            try await service.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                                   domains: domains, upstream: "172.18.0.3", port: 8080)
            Issue.record("route with failed autosave unexpectedly succeeded")
        } catch let error as NativeRPCError { #expect(error.code == "route-failed") }
        #expect(try caddy.configSnapshot() == before)
        #expect(try caddy.persistedSnapshot() == before)
        #expect(await files.lockPaths().isEmpty)
    }

    @Test("another app's hostname cannot be claimed and no route write occurs")
    func productionDomainOwnershipConflict() async throws {
        let files = DKTAppsServerFiles()
        let caddy = try DKTFakeCaddy.protectedDemo()
        let before = try caddy.configSnapshot()
        let service = BackendAppsCaddy(runtime: files.runtime(caddy: caddy, resourcePrefix: "td-test", caddyServerKey: "terminaldeck"))
        do {
            try await service.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                                   domains: [DKTFakeCaddy.protectedDemoRouteID], upstream: "172.18.0.3", port: 8080)
            Issue.record("another app's hostname unexpectedly claimed")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(try caddy.configSnapshot() == before)
        #expect(caddy.requests.allSatisfy { $0.method == "GET" })
        #expect(await files.lockPaths().isEmpty)
    }

    @Test("an exposed Caddy admin listener is refused before app route mutation")
    func productionRejectsExposedAdmin() async throws {
        let original = try DKTFakeCaddy.protectedDemo().configuration
            .changing(method: "PATCH", path: ["admin", "listen"], payload: .string("0.0.0.0:2019"))
        let caddy = try DKTFakeCaddy(initialConfig: original.encoded())
        let files = DKTAppsServerFiles()
        let service = BackendAppsCaddy(runtime: files.runtime(caddy: caddy, resourcePrefix: "td-test", caddyServerKey: "terminaldeck"))
        do {
            try await service.swap(serverID: DKTAppsFixtures.serverID, appID: DKTAppsFixtures.appID,
                                   domains: ["td-test-app.192.0.2.5.sslip.io"], upstream: "172.18.0.3", port: 8080)
            Issue.record("exposed admin endpoint unexpectedly accepted")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(caddy.configuration == original)
        #expect(caddy.requests.allSatisfy { $0.method == "GET" })
        #expect(await files.lockPaths().isEmpty)
    }

    @Test("registered rollback checks candidate health, writes intent, swaps route, then saves state")
    func rollbackTransaction() async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        let protectedBefore = try DKTUnixHTTPClient.request(socketPath: fixture.caddy.socketPath,
                                                            target: "/id/" + DKTFakeCaddy.protectedDemoRouteID,
                                                            headers: ["Host": "localhost:2019"]).body
        let result = try await fixture.rollback()
        #expect(result["status"].string == "running")
        #expect(result["rollbackOf"].string == DKTAppsRollbackFixture.retainedDeploymentID)
        #expect(result["imageId"].string == DKTAppsRollbackFixture.retainedImageID)
        #expect(!result.compact.contains(DKTAppsFixtures.dummySecret))
        let current = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(current["activeDeploymentId"] == result["id"])
        #expect(current["pendingDeploymentId"].isNullish)
        let candidate = try #require(result["containerId"].string)
        let events = await fixture.files.boundaryEvents
        let health = try #require(events.firstIndex(of: "docker:GET /containers/" + candidate + "/json"))
        let statePath = try BackendAppsStore.directory(DKTAppsFixtures.appID) + "/state.json"
        let intent = try #require(events.firstIndex(of: "state-write:" + statePath))
        let route = try #require(events.firstIndex(of: "caddy:PATCH /id/" + DKTAppsRollbackFixture.routeID))
        let commit = try #require(events.indices.first { $0 > route && events[$0] == "state-write:" + statePath })
        #expect(health < intent && intent < route && route < commit)
        // The previous service stays alive until both routing and app state
        // are durable. It may retire afterward; its immutable image remains.
        let priorMutations = events.enumerated().filter { _, event in
            event.hasPrefix("docker:POST /containers/" + DKTAppsRollbackFixture.oldContainerID + "/stop")
                || event.hasPrefix("docker:DELETE /containers/" + DKTAppsRollbackFixture.oldContainerID)
        }
        #expect(priorMutations.allSatisfy { $0.offset > commit })
        #expect(fixture.docker.requests.allSatisfy { !($0.method == "DELETE" && $0.enginePath.hasPrefix("/images/")) })
        let create = try #require(fixture.docker.requests.first { $0.path == "/containers/create" })
        let payload = try NativeRPCValue.parseJSON(create.body)
        #expect(payload["Image"].string == DKTAppsRollbackFixture.retainedImageID)
        #expect(payload["HostConfig"]["PortBindings"].fields?.isEmpty == true)
        #expect(payload["HostConfig"]["NetworkMode"].string == DKTAppsRollbackFixture.network)
        #expect(payload["HostConfig"]["Mounts"].elements?.isEmpty == true)
        #expect(try DKTUnixHTTPClient.request(socketPath: fixture.caddy.socketPath,
                                             target: "/id/" + DKTFakeCaddy.protectedDemoRouteID,
                                             headers: ["Host": "localhost:2019"]).body == protectedBefore)
        #expect(await fixture.files.lockPaths().isEmpty)
        #expect(await fixture.files.unsupportedCommands.isEmpty)
    }

    @Test("rollback unhealthy candidate never changes old route or old app state")
    func rollbackHealthFailure() async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        fixture.docker.setResponse(method: "GET", target: "/containers/" + DKTAppsRollbackFixture.firstCandidateID + "/json",
                                   response: .json([
                                    "State": ["Running": true, "Health": ["Status": "unhealthy"]],
                                    "NetworkSettings": ["Networks": [DKTAppsRollbackFixture.network: ["IPAddress": "172.18.0.3"]]]
                                   ] as [String: Any]))
        do { _ = try await fixture.rollback(); Issue.record("unhealthy rollback unexpectedly succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "health-failed") }
        #expect(try fixture.caddy.configSnapshot() == fixture.caddyBefore)
        #expect(try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) == fixture.originalRecord)
        #expect(fixture.caddy.requests.allSatisfy { $0.method != "PATCH" })
        #expect(fixture.docker.requests.contains { $0.method == "DELETE" && $0.path == "/containers/" + DKTAppsRollbackFixture.firstCandidateID })
        #expect(await fixture.files.lockPaths().isEmpty)
    }

    @Test("rejected route swap compensates and keeps the old deployment active")
    func rollbackRouteFailure() async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        fixture.caddy.failNext(method: "PATCH", path: "/id/" + DKTAppsRollbackFixture.routeID, statusCode: 500,
                               message: DKTAppsFixtures.dummySecret)
        do { _ = try await fixture.rollback(); Issue.record("rejected route rollback unexpectedly succeeded") }
        catch let error as NativeRPCError {
            #expect(error.code == "route-failed")
            #expect(!error.message.contains(DKTAppsFixtures.dummySecret))
        }
        #expect(try fixture.caddy.configSnapshot() == fixture.caddyBefore)
        let current = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(current["activeDeploymentId"] == fixture.originalRecord["activeDeploymentId"])
        #expect(current["pendingDeploymentId"].isNullish)
        #expect(fixture.caddy.requests.filter { $0.method == "PATCH" }.count >= 2)
        #expect(fixture.docker.requests.contains { $0.method == "DELETE" && $0.path == "/containers/" + DKTAppsRollbackFixture.firstCandidateID })
        #expect(await fixture.files.lockPaths().isEmpty)
    }

    @Test("failed post-swap state commit restores old route before removing candidate")
    func rollbackStateFailure() async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID) + "/state.json"
        await fixture.files.failNextWrite(path: path, afterSuccessfulWrites: 1)
        do { _ = try await fixture.rollback(); Issue.record("failed state commit rollback unexpectedly succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "state-failed") }
        #expect(try fixture.caddy.configSnapshot() == fixture.caddyBefore)
        let current = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(current["activeDeploymentId"] == fixture.originalRecord["activeDeploymentId"])
        #expect(current["pendingDeploymentId"].isNullish)
        let events = await fixture.files.boundaryEvents
        let compensation = try #require(events.lastIndex(of: "caddy:PATCH /id/" + DKTAppsRollbackFixture.routeID))
        let cleanup = try #require(events.firstIndex(of: "docker:DELETE /containers/" + DKTAppsRollbackFixture.firstCandidateID + "?force=true&v=false"))
        #expect(compensation < cleanup)
        #expect(fixture.docker.requests.allSatisfy { !$0.path.hasPrefix("/volumes/") && !$0.path.hasPrefix("/images/") || $0.method == "GET" })
        #expect(await fixture.files.lockPaths().isEmpty)
    }

    @Test("failed compensation retains both app versions and a durable recovery marker")
    func rollbackCompensationFailure() async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID) + "/state.json"
        await fixture.files.failNextWrite(path: path, afterSuccessfulWrites: 1)
        fixture.caddy.failNext(method: "PATCH", path: "/id/" + DKTAppsRollbackFixture.routeID,
                               statusCode: 500, afterMatchingRequests: 1)
        do { _ = try await fixture.rollback(); Issue.record("failed compensation unexpectedly returned success") }
        catch let error as NativeRPCError { #expect(error.code == "state-failed") }
        let current = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(!current["pendingDeploymentId"].isNullish)
        #expect(current["activeDeploymentId"] == fixture.originalRecord["activeDeploymentId"])
        #expect(fixture.docker.requests.allSatisfy { $0.method != "DELETE" })
        let candidate = try DKTUnixHTTPClient.request(socketPath: fixture.docker.socketPath,
                                                      target: "/containers/" + DKTAppsRollbackFixture.firstCandidateID + "/json")
        #expect(try NativeRPCValue.parseJSON(candidate.body)["State"]["Running"].bool == true)
        let request = BackendAppsValidation.object([("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID))])
        do {
            _ = try await fixture.service.invoke("apps:deploy", request: request, context: context())
            Issue.record("next deploy ignored a pending recovery marker")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(await fixture.files.lockPaths().isEmpty)
    }

    @Test("retained tag image mismatch rejects rollback before creating a candidate")
    func rollbackImmutableImageGuard() async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        let tag = "td-test-" + DKTAppsFixtures.appID + ":" + DKTAppsRollbackFixture.retainedDeploymentID
        let encoded = try #require(tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        fixture.docker.setResponse(method: "GET", target: "/images/" + encoded + "/json",
                                   response: .json(["Id": "sha256:" + String(repeating: "e", count: 64)]))
        do { _ = try await fixture.rollback(); Issue.record("mutated retained image unexpectedly activated") }
        catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(fixture.docker.requests.allSatisfy { $0.method == "GET" })
        #expect(try fixture.caddy.configSnapshot() == fixture.caddyBefore)
        #expect(try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) == fixture.originalRecord)
    }

    @Test("confirmed removal finds deployment labels, removes managed services and keeps unrelated fixtures")
    func removesActualDeploymentLabels() async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        let deployment = try await fixture.rollback()
        let candidate = try #require(deployment["containerId"].string)
        let request = BackendAppsValidation.object([
            ("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID)),
            ("confirmation", .string(DKTAppsFixtures.appName))
        ])
        let result = try await fixture.service.invoke("apps:remove", request: request, context: context())
        #expect(result["removed"].bool == true)
        for id in [candidate, DKTAppsRollbackFixture.oldContainerID] {
            #expect(try DKTUnixHTTPClient.request(socketPath: fixture.docker.socketPath, target: "/containers/" + id + "/json").statusCode == 404)
        }
        #expect(try DKTUnixHTTPClient.request(socketPath: fixture.docker.socketPath,
                                             target: "/containers/" + DKTDockerFake.containerID + "/json").statusCode == 200)
        #expect(fixture.docker.requests.allSatisfy { !($0.method == "DELETE" && ($0.path.hasPrefix("/volumes/") || $0.path.hasPrefix("/images/"))) })
        #expect(await fixture.files.lockPaths().isEmpty)
        #expect(await fixture.files.unsupportedCommands.isEmpty)
    }

    @Test("fresh deploy clone/build failure preserves old serving route before candidate creation", arguments: ["clone", "build"])
    func freshDeployFailureBeforeCandidate(stage: String) async throws {
        let fixture = try await DKTAppsRollbackFixture.make()
        defer { fixture.stop() }
        if stage == "clone" {
            await fixture.files.replyToScript(containing: "git -c core.hooksPath=/dev/null", code: 1,
                                               stderr: DKTAppsFixtures.dummySecret)
        } else {
            // A synthetic revision moves the production decision tree to its
            // build failure. No GitHub clone or successful build is claimed.
            await fixture.files.replyToScript(containing: "git -c core.hooksPath=/dev/null",
                                               stdout: String(repeating: "d", count: 40) + "\n")
            await fixture.files.replyToScript(containing: "docker build ", code: 1,
                                               stderr: DKTAppsFixtures.dummySecret)
        }
        let registry = NativeChannelRegistry()
        try await BackendAppsChannels.register(registry: registry, service: fixture.service, ownerID: "dkt-apps")
        let request = BackendAppsValidation.object([
            ("serverId", .string(DKTAppsFixtures.serverID)), ("appId", .string(DKTAppsFixtures.appID))
        ])
        do {
            _ = try await registry.invoke("apps:deploy", context: context(), arguments: [request])
            Issue.record("failed fresh deploy unexpectedly succeeded")
        } catch let error as NativeRPCError {
            #expect(error.code == "build-failed")
            #expect(!error.message.contains(DKTAppsFixtures.dummySecret))
        }
        #expect(fixture.docker.requests.isEmpty)
        #expect(try fixture.caddy.configSnapshot() == fixture.caddyBefore)
        let current = try await fixture.store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(current["activeDeploymentId"] == fixture.originalRecord["activeDeploymentId"])
        #expect(current["status"].string == "running")
        #expect(current["pendingDeploymentId"].isNullish)
        #expect(current["deployments"].elements?.first?["status"].string == "failed")
        #expect(await fixture.files.lockPaths().isEmpty)
        #expect(await fixture.files.unsupportedCommands.isEmpty)
    }

    @Test("saved app state survives constructing another Mac-side store")
    func serverAuthoritativeState() async throws {
        let files = DKTAppsServerFiles()
        let firstStore = BackendAppsStore(runtime: files.runtime())
        let original = DKTAppsFixtures.appRecord()
        try await firstStore.write(DKTAppsFixtures.serverID, DKTAppsFixtures.appID, original)
        let secondStore = BackendAppsStore(runtime: files.runtime())
        #expect(try await secondStore.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) == original)
        #expect(try await secondStore.list(DKTAppsFixtures.serverID) == [original])
        let requested = await files.invocations
        #expect(requested.contains { $0.stdin != nil && $0.script.contains("chmod 600 -- ") && $0.script.contains("chmod 700 -- ") && $0.script.contains("sync -f ") })
        #expect(await files.unsupportedCommands.isEmpty)
    }

    @Test("failed atomic state save preserves the earlier record and masks stderr")
    func failedStateSavePreservesRecord() async throws {
        let files = DKTAppsServerFiles()
        let store = BackendAppsStore(runtime: files.runtime())
        let old = DKTAppsFixtures.appRecord()
        try await store.write(DKTAppsFixtures.serverID, DKTAppsFixtures.appID, old)
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID) + "/state.json"
        await files.failNextWrite(path: path)
        do {
            try await store.write(DKTAppsFixtures.serverID, DKTAppsFixtures.appID,
                                  DKTAppsFixtures.appRecord(activeDeploymentID: "dkt-candidate"))
            Issue.record("state save unexpectedly succeeded")
        } catch let error as NativeRPCError {
            #expect(error.code == "state-failed")
            #expect(!error.message.contains("DKT_DUMMY_SECRET_WRITE_FAILURE"))
        }
        #expect(try await store.read(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) == old)
    }

    @Test("environment values use protected stdin and survive as server state only")
    func protectedEnvironmentStorage() async throws {
        let files = DKTAppsServerFiles()
        let store = BackendAppsStore(runtime: files.runtime())
        let environment = ["API_TOKEN": DKTAppsFixtures.dummySecret, "DATABASE_PASSWORD": DKTAppsFixtures.dummyPassword]
        try await store.applyEnvironment(DKTAppsFixtures.serverID, DKTAppsFixtures.appID, environment)
        let restored = try await BackendAppsStore(runtime: files.runtime())
            .environment(DKTAppsFixtures.serverID, DKTAppsFixtures.appID)
        #expect(restored == environment)
        let requests = await files.invocations
        let secretWrites = requests.filter { $0.stdin != nil }
        #expect(secretWrites.count == 1)
        #expect(requests.allSatisfy { !$0.script.contains(DKTAppsFixtures.dummySecret) && !$0.script.contains(DKTAppsFixtures.dummyPassword) })
        #expect(secretWrites.first?.script.contains("chmod 600 -- ") == true)
    }

    @Test("invalid env and app IDs reject before server I/O")
    func unsafeInputsFailBeforeServer() async throws {
        let files = DKTAppsServerFiles()
        let store = BackendAppsStore(runtime: files.runtime())
        do {
            try await store.applyEnvironment(DKTAppsFixtures.serverID, DKTAppsFixtures.appID, ["API_TOKEN": "first\nsecond"])
            Issue.record("multiline setting unexpectedly accepted")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        do {
            _ = try await store.read(DKTAppsFixtures.serverID, "../../outside")
            Issue.record("invalid app ID unexpectedly accepted")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(await files.invocations.isEmpty)
    }

    @Test("failed and cancelled operations release the shared server app lock")
    func releaseLockOnFailureAndCancellation() async throws {
        let files = DKTAppsServerFiles()
        let store = BackendAppsStore(runtime: files.runtime())
        do {
            let _: Bool = try await store.withLock(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) {
                throw NativeRPCError(code: "health-failed", message: "Synthetic health failed")
            }
            Issue.record("failing locked body unexpectedly returned")
        } catch let error as NativeRPCError { #expect(error.code == "health-failed") }
        #expect(await files.lockPaths().isEmpty)
        do {
            let _: Bool = try await store.withLock(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) {
                throw CancellationError()
            }
            Issue.record("cancelled locked body unexpectedly returned")
        } catch is CancellationError { }
        #expect(await files.lockPaths().isEmpty)
        #expect(await files.unsupportedCommands.isEmpty)
    }

    @Test("another Mac's existing lock fails busy without running the action")
    func sharedLockConflict() async throws {
        let files = DKTAppsServerFiles()
        let path = try BackendAppsStore.directory(DKTAppsFixtures.appID) + "/.lock"
        _ = try await files.execute(serverID: DKTAppsFixtures.serverID,
                                    command: "mkdir -- '" + path + "'", stdin: nil,
                                    timeoutMS: 1000, maximumBytes: 1024)
        let store = BackendAppsStore(runtime: files.runtime())
        do {
            let _: Bool = try await store.withLock(DKTAppsFixtures.serverID, DKTAppsFixtures.appID) {
                Issue.record("action ran while another Mac held the app lock")
                return true
            }
            Issue.record("busy lock unexpectedly accepted")
        } catch let error as NativeRPCError { #expect(error.code == "busy") }
        #expect(await files.lockPaths() == [path])
    }

    @Test("public records omit nested env values and upload credentials")
    func publicRecordsHideSecrets() throws {
        let record = DKTAppsFixtures.appRecord()
            .setting("env", BackendAppsValidation.object([("API_TOKEN", .string(DKTAppsFixtures.dummySecret))]))
            .setting("source", BackendAppsValidation.object([
                ("repository", .string("fixture/synthetic-app")), ("token", .string(DKTAppsFixtures.dummySecret))
            ]))
            .setting("backupPolicy", BackendAppsValidation.object([
                ("schedule", .string("daily")), ("retention", .number(7)),
                ("upload", BackendAppsValidation.object([
                    ("bucket", .string("dkt-synthetic-bucket")), ("accessKey", .string(DKTAppsFixtures.dummySecret)),
                    ("secretKey", .string(DKTAppsFixtures.dummyPassword))
                ]))
            ]))
        let result = BackendAppsStore.publicRecord(record)
        let text = String(decoding: try result.encodedJSON(), as: UTF8.self)
        #expect(!text.contains(DKTAppsFixtures.dummySecret))
        #expect(!text.contains(DKTAppsFixtures.dummyPassword))
        #expect(result["env"].isNullish)
        #expect(result["source"]["repository"].string == "fixture/synthetic-app")
        #expect(result["backupPolicy"]["upload"]["bucket"].string == "dkt-synthetic-bucket")
    }

    @Test("missing Docker, Caddy and log dependencies return unavailable")
    func absentFeaturesFailClosed() async throws {
        let runtime = DKTAppsServerFiles().runtime()
        do {
            _ = try await runtime.docker(DKTAppsFixtures.serverID, "GET", "/containers/json", nil)
            Issue.record("missing Docker dependency returned success")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        do {
            _ = try await runtime.caddy(DKTAppsFixtures.serverID, "GET", "/config/", nil)
            Issue.record("missing Caddy dependency returned success")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        do {
            _ = try await runtime.watchLogs(DKTAppsFixtures.serverID, "dkt-container") { _ in }
            Issue.record("missing log dependency returned success")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
    }

    @Test("database candidates publish no ports and use named data volumes", arguments: ["postgres", "mysql", "redis", "mongodb"])
    func databasePrivatePayload(kind: String) throws {
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: nil)
        let labels = BackendAppsValidation.object([("io.terminaldeck.app", .string(DKTAppsFixtures.appID))])
        let environment = spec.environment(password: DKTAppsFixtures.dummyPassword)
        let body = spec.container(appID: DKTAppsFixtures.appID, volume: "td-test-data", environment: environment,
                                  labels: labels, network: "td-test-private", prefix: "td-test")
        #expect(body["HostConfig"]["PortBindings"].fields?.isEmpty == true)
        #expect(body["HostConfig"]["NetworkMode"].string == "td-test-private")
        #expect(body["HostConfig"]["Privileged"].bool != true)
        #expect(body["HostConfig"]["Mounts"].elements?.first?["Type"].string == "volume")
        #expect(body["HostConfig"]["Mounts"].elements?.first?["Source"].string == "td-test-data")
        #expect(!(body["Cmd"].elements ?? []).compactMap(\.string).joined(separator: " ").contains(DKTAppsFixtures.dummyPassword))
    }

    @Test("log masking removes stored secrets, authorization and password forms")
    func masksUntrustedLogs() {
        let raw = "\(DKTAppsFixtures.dummySecret) Authorization: Bearer dummy-bearer password=\(DKTAppsFixtures.dummyPassword) https://dummy-user:dummy-password@example.invalid/"
        let text = BackendAppsValidation.mask(raw, secrets: [DKTAppsFixtures.dummySecret, DKTAppsFixtures.dummyPassword])
        for secret in [DKTAppsFixtures.dummySecret, DKTAppsFixtures.dummyPassword, "dummy-bearer", "dummy-password"] {
            #expect(!text.contains(secret))
        }
    }

    private func context() -> NativeRPCContext {
        .init(caller: .nativeApp, ownerID: "dkt-owner", capabilities: ["apps.read", "apps.write"])
    }
}

private actor DKTAppsApprovalRecorder {
    private(set) var actions: [BackendAppsAction] = []
    func record(_ action: BackendAppsAction) { actions.append(action) }
}
