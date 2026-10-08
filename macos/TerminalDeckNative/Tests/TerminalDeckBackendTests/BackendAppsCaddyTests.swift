import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Apps address manager: private transport, isolated routes and durable swaps")
struct BackendAppsCaddyTests {
    @Test func failedReplacementKeepsPreviousAppAndOtherRoutes() async throws {
        let old = BackendAppsCaddyFake.route("terminaldeck-site", host: "site.example.com", dial: "172.18.0.2:8080")
        let other = BackendAppsCaddyFake.route("terminaldeck-other", host: "other.example.com", dial: "172.18.0.3:3000")
        let fake = BackendAppsCaddyFake(routes: [old, other], rejectNextMutation: true)
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        await #expect(throws: NativeRPCError.self) {
            try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
        }
        let state = await fake.snapshot()
        #expect(state.routes == [old, other])
        #expect(state.requests.last == "PATCH /id/terminaldeck-site")
        #expect(!state.locked)
    }

    @Test func addingAndRemovingOneRoutePreservesOthersAndNeverLoadsWholeConfig() async throws {
        let other = BackendAppsCaddyFake.route("terminaldeck-other", host: "other.example.com", dial: "172.18.0.3:3000")
        let fake = BackendAppsCaddyFake(routes: [other])
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
        let added = await fake.snapshot()
        #expect(added.routes.last == other)
        #expect(added.routes.count == 2)
        #expect(added.routes.first?["@id"].string == "terminaldeck-site")
        try await service.remove(serverID: "server-one", appID: "site")
        let removed = await fake.snapshot()
        #expect(removed.routes == [other])
        #expect(removed.requests.contains("DELETE /id/terminaldeck-site"))
        #expect(!removed.requests.contains { $0.contains("/load") || $0 == "POST /config/" || $0 == "PATCH /config/" })
    }

    @Test func duplicateDomainFailsBeforeMutation() async throws {
        let other = BackendAppsCaddyFake.route("terminaldeck-other", host: "site.example.com", dial: "172.18.0.3:3000")
        let fake = BackendAppsCaddyFake(routes: [other])
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        do {
            try await service.swap(serverID: "server-one", appID: "site", domains: ["SITE.EXAMPLE.COM"], upstream: "172.18.0.4", port: 8080)
            Issue.record("A duplicate address was accepted.")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        let state = await fake.snapshot()
        #expect(state.routes == [other])
        #expect(state.requests == ["GET /config/"])
        #expect(!state.locked)
    }

    @Test func serverLockPreventsAnyConfigReadWhileAnotherMacIsChangingRoutes() async throws {
        let fake = BackendAppsCaddyFake(locked: true)
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        do {
            try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
            Issue.record("A held server lock was ignored.")
        } catch let error as NativeRPCError { #expect(error.code == "busy") }
        let state = await fake.snapshot()
        #expect(state.requests.isEmpty)
        #expect(state.locked)
    }

    @Test func wildcardOwnedByAnotherAppCannotBeShadowed() async throws {
        let wildcard = BackendAppsCaddyFake.route("terminaldeck-other", host: "*.example.com", dial: "172.18.0.3:3000")
        let fake = BackendAppsCaddyFake(routes: [wildcard])
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        do {
            try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
            Issue.record("An address owned by another app was shadowed.")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect((await fake.snapshot()).routes == [wildcard])
    }

    @Test func invalidPublicUpstreamsPortsAndDomainSyntaxDoNoServerIO() async throws {
        let fake = BackendAppsCaddyFake()
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        for upstream in ["127.0.0.1", "203.0.113.9", "app-container", "172.18.0.4;touch /tmp/no", "172.018.0.4"] {
            await #expect(throws: NativeRPCError.self) { try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: upstream, port: 8080) }
        }
        await #expect(throws: NativeRPCError.self) { try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 0) }
        for domain in ["https://example.com", "example.com:443", "*.example.com", "app.local", "example.com/path", "example.com\n", "example..com", "-a.example.com", "127.0.0.1"] {
            #expect(throws: NativeRPCError.self) { _ = try BackendAppsCaddy.hostname(domain) }
        }
        let state = await fake.snapshot()
        #expect(state.commands.isEmpty && state.requests.isEmpty)
    }

    @Test func staleAAAARejectsAnOtherwiseMatchingDomain() async throws {
        let fake = BackendAppsCaddyFake()
        let service = BackendAppsCaddy(runtime: await fake.runtime(addresses: ["203.0.113.9", "2001:db8::9"], dns: ["203.0.113.9", "2001:db8::10"]))
        let check = try await service.check(serverID: "server-one", domain: "site.example.com")
        #expect(check["pointsHere"].bool == false)
        #expect(check["instructions"].string?.contains("Remove A or AAAA records") == true)
        #expect((await fake.snapshot()).commands.isEmpty)
    }

    @Test func ipv6SpellingIsComparedByAddressAndDNSReadDoesNotInstall() async throws {
        let fake = BackendAppsCaddyFake()
        let service = BackendAppsCaddy(runtime: await fake.runtime(addresses: ["2001:db8::9"], dns: ["2001:0DB8:0:0:0:0:0:9"]))
        let check = try await service.check(serverID: "server-one", domain: "SITE.EXAMPLE.COM")
        #expect(check["pointsHere"].bool == true)
        #expect(check["domain"].string == "site.example.com")
        let state = await fake.snapshot()
        #expect(state.commands.isEmpty && state.requests.isEmpty)
    }

    @Test func defaultAddressNeedsPublicIPv4AndUsesApprovedTestNamespace() async throws {
        let fake = BackendAppsCaddyFake()
        let production = BackendAppsCaddy(runtime: await fake.runtime(addresses: ["10.0.0.1", "203.0.113.9"]))
        #expect(try await production.defaultDomain(serverID: "server-one", appID: "site") == "site.203.0.113.9.sslip.io")
        let test = BackendAppsCaddy(runtime: await fake.runtime(addresses: ["178.105.239.176"], prefix: "td-test", existingServer: "srv0"))
        #expect(try await test.defaultDomain(serverID: "server-one", appID: "site") == "td-test-site.178-105-239-176.sslip.io")
        #expect(try await test.defaultDomain(serverID: "server-one", appID: "td-test-site") == "td-test-site.178-105-239-176.sslip.io")
        let ipv6Only = BackendAppsCaddy(runtime: await fake.runtime(addresses: ["2001:db8::9"]))
        await #expect(throws: NativeRPCError.self) { _ = try await ipv6Only.defaultDomain(serverID: "server-one", appID: "site") }
    }

    @Test func installationPlanIsReadOnlyAndUsesDurablePrivateService() async throws {
        let fake = BackendAppsCaddyFake()
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        let plan = service.plan()
        let command = try #require(plan["commands"].elements?.first?.string)
        #expect(plan["adminAddress"].string == "127.0.0.1:2019")
        #expect(command.contains("run --resume --config"))
        #expect(command.contains("\"listen\":\"127.0.0.1:2019\""))
        #expect(command.contains("config\":{\"persist\":true}"))
        #expect(command.contains("https://dl.cloudsmith.io/public/caddy/stable/"))
        #expect(command.contains("if command -v caddy >/dev/null 2>&1; then exit 73; fi"))
        #expect((await fake.snapshot()).commands.isEmpty)
    }

    @Test func installSuccessRequiresHealthyPrivateCaddyResponse() async throws {
        let fake = BackendAppsCaddyFake(exposeAdmin: true)
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        await #expect(throws: NativeRPCError.self) { _ = try await service.install(serverID: "server-one") }
        let state = await fake.snapshot()
        #expect(state.requests == ["GET /config/"])
    }

    @Test func existingCaddyAndLiveTestConnectionsNeverRunInstaller() async throws {
        let fake = BackendAppsCaddyFake()
        let service = BackendAppsCaddy(runtime: await fake.runtime(prefix: "td-test", existingServer: "srv0"))
        await #expect(throws: NativeRPCError.self) { _ = try await service.install(serverID: "server-one") }
        #expect((await fake.snapshot()).commands.isEmpty)
    }

    @Test func liveNamespaceAddsAndRemovesOnlyOwnedRoutesKeepingExistingDemoRoute() async throws {
        let demo = BackendAppsCaddyFake.route("app-review-demo", host: "178-105-239-176.sslip.io", dial: "127.0.0.1:8080")
        let fake = BackendAppsCaddyFake(routes: [demo], serverKey: "srv0")
        let service = BackendAppsCaddy(runtime: await fake.runtime(prefix: "td-test", existingServer: "srv0"))
        try await service.swap(serverID: "server-one", appID: "site", domains: ["td-test-site.178-105-239-176.sslip.io"], upstream: "172.18.0.4", port: 8080)
        try await service.remove(serverID: "server-one", appID: "site")
        let state = await fake.snapshot()
        #expect(state.routes == [demo])
        #expect(state.requests.contains("DELETE /id/td-test-site"))
        #expect(state.commands.filter { !$0.contains("cat ") }.allSatisfy { $0.contains("td-test-caddy-lock") })
    }

    @Test func appIDsAlreadyContainingNamespacePrefixKeepDistinctRouteTargets() async throws {
        let fake = BackendAppsCaddyFake()
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
        try await service.swap(serverID: "server-one", appID: "terminaldeck-site", domains: ["second.example.com"], upstream: "172.18.0.5", port: 8080)
        let added = await fake.snapshot()
        #expect(Set(added.routes.compactMap { $0["@id"].string }) == ["terminaldeck-site", "terminaldeck-terminaldeck-site"])
        try await service.remove(serverID: "server-one", appID: "terminaldeck-site")
        let remaining = await fake.snapshot()
        #expect(remaining.routes.count == 1)
        #expect(remaining.routes.first?["@id"].string == "terminaldeck-site")
    }

    @Test func autosaveFailureCompensatesToPreviousRouteBeforeReportingFailure() async throws {
        let old = BackendAppsCaddyFake.route("terminaldeck-site", host: "site.example.com", dial: "172.18.0.2:8080")
        let fake = BackendAppsCaddyFake(routes: [old], skipNextAutosave: true)
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        do {
            try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
            Issue.record("An unsaved route was marked durable.")
        } catch let error as NativeRPCError {
            #expect(error.code == "route-failed")
            #expect(error.details["routeUncertain"].bool != true)
        }
        let state = await fake.snapshot()
        #expect(state.routes == [old])
        #expect(state.requests.filter { $0 == "PATCH /id/terminaldeck-site" }.count == 2)
        #expect(!state.locked)
    }

    @Test func failedCompensationMarksRoutingUncertainSoDeployKeepsBothInstances() async throws {
        let old = BackendAppsCaddyFake.route("terminaldeck-site", host: "site.example.com", dial: "172.18.0.2:8080")
        let fake = BackendAppsCaddyFake(routes: [old], skipNextAutosave: true, rejectCompensation: true)
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        do {
            try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
            Issue.record("An unverified compensation was accepted.")
        } catch let error as NativeRPCError {
            #expect(error.code == "route-failed")
            #expect(error.details["routeUncertain"].bool == true)
            #expect(!error.message.contains("untrusted-secret-build-output"))
        }
        #expect(!(await fake.snapshot()).locked)
    }

    @Test func compensationAndLockReleaseRetainExistingConnectionRPCIdentity() async throws {
        let old = BackendAppsCaddyFake.route("terminaldeck-site", host: "site.example.com", dial: "172.18.0.2:8080")
        let fake = BackendAppsCaddyFake(routes: [old], rejectNextMutation: true, requireRPCIdentity: true)
        let service = BackendAppsCaddy(runtime: await fake.runtime())
        try await BackendAppsCaddyTestContext.$rpcIdentity.withValue("owner-one") {
            do {
                try await service.swap(serverID: "server-one", appID: "site", domains: ["site.example.com"], upstream: "172.18.0.4", port: 8080)
                Issue.record("A rejected address change was accepted.")
            } catch let error as NativeRPCError {
                #expect(error.details["routeUncertain"].bool != true)
            }
        }
        let state = await fake.snapshot()
        #expect(!state.locked)
        #expect(state.routes == [old])
        #expect(state.requests.filter { $0 == "PATCH /id/terminaldeck-site" }.count == 2)
    }
}

private enum BackendAppsCaddyTestContext {
    @TaskLocal static var rpcIdentity: String?
}

/// A Swift actor models only Caddy's documented atomic config requests. It
/// preserves a route when a reload is rejected and independently records
/// tunnel paths/lock operations. It never opens a socket or starts a process.
private actor BackendAppsCaddyFake {
    struct Snapshot: Sendable {
        let routes: [NativeRPCValue]
        let requests: [String]
        let commands: [String]
        let locked: Bool
    }
    private var routes: [NativeRPCValue]
    private var savedRoutes: [NativeRPCValue]
    private var requests: [String] = []
    private var commands: [String] = []
    private var locked: Bool
    private var rejectNextMutation: Bool
    private let serverKey: String
    private let exposeAdmin: Bool
    private var skipNextAutosave: Bool
    private let rejectCompensation: Bool
    private var mutationCount = 0
    private let requireRPCIdentity: Bool

    init(routes: [NativeRPCValue] = [], locked: Bool = false, rejectNextMutation: Bool = false, serverKey: String = "terminaldeck", exposeAdmin: Bool = false, skipNextAutosave: Bool = false, rejectCompensation: Bool = false, requireRPCIdentity: Bool = false) {
        self.routes = routes; self.savedRoutes = routes; self.locked = locked; self.rejectNextMutation = rejectNextMutation
        self.serverKey = serverKey; self.exposeAdmin = exposeAdmin
        self.skipNextAutosave = skipNextAutosave; self.rejectCompensation = rejectCompensation
        self.requireRPCIdentity = requireRPCIdentity
    }

    func runtime(addresses: [String] = ["203.0.113.9"], dns: [String] = ["203.0.113.9"], prefix: String = "terminaldeck", existingServer: String? = nil) -> BackendAppsRuntime {
        BackendAppsRuntime(
            execute: { _, command, _, _, _ in try await self.execute(command) },
            caddy: { _, method, path, body in try await self.http(method, path, body) },
            serverAddresses: { _ in addresses }, resolveDNS: { _ in dns },
            resourcePrefix: prefix, caddyServerKey: existingServer
        )
    }

    func snapshot() -> Snapshot { .init(routes: routes, requests: requests, commands: commands, locked: locked) }

    private func execute(_ command: String) throws -> BackendServersRunResult {
        try requireContext()
        commands.append(command)
        if command.contains("cat ") && !command.contains("td_service=") {
            return .init(code: 0, stdout: configuration(savedRoutes).compact)
        }
        if command.contains("td_service=") { return .init(code: 0, stdout: "") }
        if command.contains("mkdir ") {
            if locked { return .init(code: 73, stdout: "") }
            locked = true
        } else if command.contains("rmdir ") { locked = false }
        return .init(code: 0, stdout: "")
    }

    private func http(_ method: String, _ path: String, _ body: Data?) throws -> BackendAppsHTTPResponse {
        try requireContext()
        requests.append(method + " " + path)
        if method == "GET", path == "/config/" {
            return .init(status: 200, body: try configuration(routes).encodedJSON())
        }
        mutationCount += 1
        if rejectNextMutation { rejectNextMutation = false; return .init(status: 400, body: Data(#"{"error":"untrusted-secret-build-output"}"#.utf8)) }
        if rejectCompensation && mutationCount > 1 { return .init(status: 500) }
        if method == "PUT", path == "/config/apps/http/servers/" + serverKey + "/routes/0", let body {
            routes.insert(try NativeRPCValue.parseJSON(body), at: 0)
            save()
            return .init(status: 200)
        }
        if path.hasPrefix("/id/"), let index = routes.firstIndex(where: { $0["@id"].string == String(path.dropFirst(4)) }) {
            if method == "PATCH", let body { routes[index] = try NativeRPCValue.parseJSON(body); save(); return .init(status: 200) }
            if method == "DELETE" { routes.remove(at: index); save(); return .init(status: 200) }
        }
        return .init(status: 404)
    }

    private func save() {
        if skipNextAutosave { skipNextAutosave = false } else { savedRoutes = routes }
    }

    private func requireContext() throws {
        if requireRPCIdentity && BackendAppsCaddyTestContext.rpcIdentity != "owner-one" {
            throw NativeRPCError(code: "access-denied", message: "The existing RPC connection identity is missing.")
        }
    }

    private func configuration(_ rows: [NativeRPCValue]) -> NativeRPCValue {
        let server = BackendAppsValidation.object([("@id", .string("td-app-server")), ("listen", .array([.string(":443")])), ("routes", .array(rows))])
        return BackendAppsValidation.object([
            ("admin", BackendAppsValidation.object([("listen", .string(exposeAdmin ? "0.0.0.0:2019" : "127.0.0.1:2019")), ("config", BackendAppsValidation.object([("persist", .bool(true))]))])),
            ("apps", BackendAppsValidation.object([("http", BackendAppsValidation.object([("servers", BackendAppsValidation.object([(serverKey, server)]))]))]))
        ])
    }

    static func route(_ id: String, host: String, dial: String) -> NativeRPCValue {
        BackendAppsValidation.object([
            ("@id", .string(id)),
            ("match", .array([BackendAppsValidation.object([("host", .array([.string(host)]))])])),
            ("handle", .array([BackendAppsValidation.object([("handler", .string("reverse_proxy")), ("upstreams", .array([BackendAppsValidation.object([("dial", .string(dial))])]))])])),
            ("terminal", .bool(true))
        ])
    }
}
