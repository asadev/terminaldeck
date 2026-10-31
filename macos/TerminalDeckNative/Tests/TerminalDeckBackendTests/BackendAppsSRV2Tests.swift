import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// SRV2: app options, variables, password hashing, router adapter, deploy
/// recipe, deployer and channels — all against an in-memory fake server.
/// READY SRV2 options/pipeline gate; unfinished persistence/screens use separate WIP tests.
class BackendAppsSRV2TestCase: XCTestCase, @unchecked Sendable {
}

final class BackendAppsSRV2BcryptTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testPiTablesMatchBlowfish() {
        let tables = BackendAppsSRV2Bcrypt.tables
        XCTAssertEqual(tables.p[0], 0x243F6A88)
        XCTAssertEqual(tables.p[1], 0x85A308D3)
        XCTAssertEqual(tables.p[17], 0x8979FB1B)
        XCTAssertEqual(tables.s[0], 0xD1310BA6)
        XCTAssertEqual(tables.s[1023], 0x3AC372E6)
    }

    func testKnownVectors() {
        // OpenBSD / John the Ripper reference hashes.
        let vectors = [("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"),
                       ("U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"),
                       ("U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a"),
                       ("", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy")]
        for (password, hash) in vectors { XCTAssertTrue(BackendAppsSRV2Bcrypt.verify(password, hash: hash), "vector \(password)") }
        XCTAssertFalse(BackendAppsSRV2Bcrypt.verify("U*U ", hash: vectors[0].1))
    }

    func testFreshHashVerifiesAndHasModernPrefix() throws {
        let hash = try BackendAppsSRV2Bcrypt.hash("correct horse", cost: 5)
        XCTAssertTrue(hash.hasPrefix("$2b$05$"))
        XCTAssertTrue(NativeAppsOptions.isBcrypt(hash))
        XCTAssertTrue(BackendAppsSRV2Bcrypt.verify("correct horse", hash: hash))
        XCTAssertFalse(BackendAppsSRV2Bcrypt.verify("correct horsE", hash: hash))
        XCTAssertNotEqual(hash, try BackendAppsSRV2Bcrypt.hash("correct horse", cost: 5), "salt must differ")
    }
}

final class BackendAppsSRV2OptionsTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testPartialJSONGetsDefaults() throws {
        let options = try NativeAppsOptions.from(try NativeRPCValue.parseJSON(Data(#"{"health":{"path":"/up"},"web":{"compression":false}}"#.utf8)))
        XCTAssertEqual(options.health.path, "/up")
        XCTAssertEqual(options.health.retries, 3)
        XCTAssertFalse(options.web.compression)
        XCTAssertTrue(options.web.forceHTTPS)
        XCTAssertEqual(options.version, 1)
        XCTAssertNoThrow(try options.validate())
    }

    func testValidationRejectsUnsafeValues() {
        func rejects(_ change: (inout NativeAppsOptions) -> Void, _ file: StaticString = #filePath, _ line: UInt = #line) {
            var options = NativeAppsOptions(); change(&options)
            XCTAssertThrowsError(try options.validate(), file: file, line: line)
        }
        rejects { $0.build.baseDirectory = "../outside" }
        rejects { $0.build.dockerfile = "/etc/Dockerfile" }
        rejects { $0.build.target = "bad target" }
        rejects { $0.health.path = "health" }
        rejects { $0.health.path = "/a b" }
        rejects { $0.health.expectedStatus = 99 }
        rejects { $0.health.retries = 0 }
        rejects { $0.steps.timeoutSeconds = 5 }
        rejects { $0.web.password = .init(username: "has:colon", password: "longenough") }
        rejects { $0.web.password = .init(username: "ok", password: "short") }
        rejects { $0.storage = [.init(kind: .folder, path: "/data", source: "/etc/ssl")] }
        rejects { $0.storage = [.init(kind: .folder, path: "/data", source: "/data/coolify/proxy")] }
        rejects { $0.storage = [.init(kind: .folder, path: "/data", source: "/srv")] }
        rejects { $0.storage = [.init(kind: .volume, path: "/proc/x", source: "data")] }
        rejects { $0.storage = [.init(kind: .volume, path: "/data", source: "Bad Name")] }
        rejects { $0.storage = [.init(kind: .volume, path: "/data", source: "a"), .init(kind: .volume, path: "/data", source: "b")] }
        rejects { $0.storage = [.init(kind: .file, path: "/app/", content: "x")] }
        var fine = NativeAppsOptions()
        fine.storage = [.init(kind: .folder, path: "/uploads", source: "/srv/site/uploads"), .init(kind: .volume, path: "/data", source: "data"),
                        .init(kind: .file, path: "/app/config.json", content: "{}")]
        fine.web.password = .init(username: "staging", password: "longenough")
        XCTAssertNoThrow(try fine.validate())
    }

    func testPublicFormDropsHashAndPassword() throws {
        var options = NativeAppsOptions()
        options.web.password = .init(username: "staging", hash: "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", password: "plain-text")
        let text = String(decoding: try options.publicForm.value().encodedJSON(), as: UTF8.self)
        XCTAssertTrue(text.contains("staging"))
        XCTAssertFalse(text.contains("$2b$"))
        XCTAssertFalse(text.contains("plain-text"))
        XCTAssertTrue(options.summaryLines.contains("Password protected"))
    }
}

final class BackendAppsSRV2VariablesTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testEncodingRoundTrips() {
        for value in ["plain", "a=b \"q\" \\ x", "line one\nline two\n", "tab\there", "td-json:literal", "é ü 中", "-----BEGIN KEY-----\nabc\n-----END KEY-----"] {
            let stored = BackendAppsSRV2Variables.encode(value)
            XCTAssertFalse(stored.contains("\n"))
            XCTAssertEqual(BackendAppsSRV2Variables.decode(stored), value)
        }
        XCTAssertEqual(BackendAppsSRV2Variables.encode("plain"), "plain")
        XCTAssertTrue(BackendAppsSRV2Variables.encode("a\nb").hasPrefix("td-json:"))
    }

    func testReservedBuildNames() {
        for key in ["PATH", "LD_PRELOAD", "DOCKER_HOST", "BUILDKIT_PROGRESS", "TD_SOURCE", "IFS", "GIT_DIR"] { XCTAssertTrue(NativeAppsVariable.reservedForBuild(key), key) }
        for key in ["NODE_ENV", "NEXT_PUBLIC_URL", "API_TOKEN"] { XCTAssertFalse(NativeAppsVariable.reservedForBuild(key), key) }
    }

    func testPatchKeepsValuesMasksLockedAndRejectsUnsafe() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web")
        await fake.put("/var/lib/td-test-apps/td-test-web/.env", "OLD=keep\n")
        let store = BackendAppsStore(runtime: fake.runtime())
        let variables = BackendAppsSRV2Variables(store: store)
        let rows = try await variables.patch("srv", "td-test-web", changes: [
            .init(key: "CERT", value: "-----BEGIN-----\nabc\n-----END-----", locked: true),
            .init(key: "NODE_ENV", value: "production", build: true, run: true, locked: false)
        ], remove: [])
        XCTAssertEqual(rows.map(\.key), ["CERT", "NODE_ENV", "OLD"])
        XCTAssertEqual(rows.first { $0.key == "CERT" }?.value, NativeAppsVariable.mask)
        XCTAssertEqual(rows.first { $0.key == "CERT" }?.multiline, true)
        XCTAssertEqual(rows.first { $0.key == "NODE_ENV" }?.value, "production")
        XCTAssertEqual(rows.first { $0.key == "OLD" }?.value, NativeAppsVariable.mask)
        let env = await fake.text("/var/lib/td-test-apps/td-test-web/.env") ?? ""
        XCTAssertTrue(env.contains("OLD=keep\n"))
        XCTAssertTrue(env.contains("CERT=td-json:-----BEGIN-----\\nabc\\n-----END-----\n"))
        // Flags-only change keeps the saved value.
        _ = try await variables.patch("srv", "td-test-web", changes: [.init(key: "OLD", build: true)], remove: [])
        let after = await fake.text("/var/lib/td-test-apps/td-test-web/.env") ?? ""
        XCTAssertTrue(after.contains("OLD=keep\n"))
        let keys = try await variables.keys("srv", "td-test-web")
        XCTAssertEqual(keys.build, ["NODE_ENV", "OLD"])
        XCTAssertEqual(keys.run, ["CERT", "NODE_ENV", "OLD"])
        do { _ = try await variables.patch("srv", "td-test-web", changes: [.init(key: "CERT", build: true)], remove: []); XCTFail("multi-line build value accepted") }
        catch let error as NativeRPCError { XCTAssertTrue(error.message.contains("one line")) }
        do { _ = try await variables.patch("srv", "td-test-web", changes: [.init(key: "X", value: NativeAppsVariable.mask)], remove: []); XCTFail("mask accepted") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        do { _ = try await variables.patch("srv", "td-test-web", changes: [.init(key: "PATH", value: "/x", build: true)], remove: []); XCTFail("reserved build name accepted") }
        catch let error as NativeRPCError { XCTAssertTrue(error.message.contains("build tools")) }
        let removed = try await variables.patch("srv", "td-test-web", changes: [], remove: ["OLD"])
        XCTAssertFalse(removed.contains { $0.key == "OLD" })
    }
}

final class BackendAppsSRV2DefinitionTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testApplyHashesPasswordSavesFilesAndKeepsHash() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web")
        let runtime = fake.runtime()
        let definition = BackendAppsSRV2Definition(store: BackendAppsStore(runtime: runtime), runtime: runtime)
        var options = NativeAppsOptions()
        options.web.password = .init(username: "staging", password: "longenough")
        options.storage = [.init(kind: .file, path: "/app/config.json", content: "{\"a\":1}")]
        let first = try await definition.apply("srv", "td-test-web", options, hasher: { "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW" + String($0.count).prefix(0) })
        XCTAssertEqual(first.options.web.password?.hash, "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW")
        XCTAssertNil(first.options.web.password?.password)
        let fileID = try XCTUnwrap(first.options.storage.first?.source)
        XCTAssertTrue(fileID.hasPrefix("f-"))
        let saved = await fake.text("/var/lib/td-test-apps/td-test-web/files/" + fileID)
        XCTAssertEqual(saved, "{\"a\":1}")
        let state = await fake.text("/var/lib/td-test-apps/td-test-web/state.json") ?? ""
        XCTAssertFalse(state.contains("longenough"), "plain password must never be saved")
        XCTAssertFalse(state.contains("{\\\"a\\\":1}"), "file text lives in files/, not the record")
        // Same user, no new password: the saved hash stays; file text read back.
        var again = try await definition.read("srv", "td-test-web")
        XCTAssertEqual(again.storage.first?.content, "{\"a\":1}")
        again.web.password = .init(username: "staging")
        again.health.path = "/health"
        let second = try await definition.apply("srv", "td-test-web", again, hasher: { _ in XCTFail("must not rehash"); return "" })
        XCTAssertEqual(second.options.web.password?.hash, first.options.web.password?.hash)
        XCTAssertEqual(second.options.health.path, "/health")
        let prunes = await fake.commands.filter { $0.contains("-name 'f-*'") }
        XCTAssertTrue(prunes.last?.contains("! -name '" + fileID + "'") == true)
        // A new user name without a password is refused.
        again.web.password = .init(username: "other")
        do { _ = try await definition.apply("srv", "td-test-web", again); XCTFail("password-less user accepted") }
        catch let error as NativeRPCError { XCTAssertTrue(error.message.contains("Enter a password")) }
    }
}

final class BackendAppsSRV2RouterTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    /// The shared record SRV1's server probe writes (its `routerRecord` shape).
    static let coolifyRecord = #"{"mode":"traefik","owner":"Coolify","traefikHTTP":"http","traefikHTTPS":"https","traefikNetwork":"coolify","traefikResolver":"letsencrypt"}"#
    static func facts(_ json: String) -> BackendAppsSRV2Router.Facts? { BackendAppsSRV2Router.record(Data(json.utf8)) }

    func testSharedRouterRecordFromServerSetup() throws {
        let coolify = try XCTUnwrap(Self.facts(Self.coolifyRecord))
        XCTAssertEqual(coolify.mode, .traefik)
        XCTAssertEqual(coolify.owner, "Coolify")
        XCTAssertEqual(coolify.traefikNetwork, "coolify")
        XCTAssertTrue(coolify.info.canServeAddresses)
        XCTAssertTrue(coolify.info.note.contains("not changed"))
        let existing = try XCTUnwrap(Self.facts(#"{"mode":"caddy","owner":"Caddy","caddyAdmin":"127.0.0.1:2019","caddyServerKey":"srv0"}"#))
        XCTAssertEqual(existing.mode, .caddy); XCTAssertEqual(existing.caddyServerKey, "srv0"); XCTAssertFalse(existing.info.forceHTTPSOptional)
        XCTAssertEqual(Self.facts(#"{"mode":"own-caddy","owner":"Terminal Deck","caddyAdmin":"127.0.0.1:2019","caddyServerKey":"terminaldeck"}"#)?.mode, .ownCaddy)
        let other = try XCTUnwrap(Self.facts(#"{"mode":"other","owner":"nginx","detail":"Ports 80 and 443 are used by nginx."}"#))
        XCTAssertFalse(other.info.canServeAddresses)
        XCTAssertNil(BackendAppsSRV2Router.record(nil))
        XCTAssertNil(BackendAppsSRV2Router.record(Data("not json".utf8)))
        XCTAssertFalse(BackendAppsSRV2Router.notSetUp.info.canServeAddresses)
    }

    func testMissingRecordUsesTheInjectedServerProbeOnly() async throws {
        let fake = SRV2FakeServer()
        await fake.remove("/var/lib/td-test-apps/router.json")
        let runtime = fake.runtime()
        let without = BackendAppsSRV2Deployer(runtime: runtime, store: BackendAppsStore(runtime: runtime))
        let unset = try await without.resolvedFacts("srv", nil)
        XCTAssertEqual(unset.mode, .unknown)
        let probed = BackendAppsSRV2Deployer(runtime: runtime, store: BackendAppsStore(runtime: runtime), routerProbe: { _ in Self.facts(Self.coolifyRecord) })
        let facts = try await probed.resolvedFacts("srv", nil)
        XCTAssertEqual(facts.mode, .traefik)
        let saved = await fake.text("/var/lib/td-test-apps/router.json")
        XCTAssertNil(saved, "SRV2 never writes the shared record")
    }

    func testAddressPlanAndCaddyRoutes() throws {
        let plan = BackendAppsSRV2Router.plan(domains: ["example.com", "www.example.com", "api.example.com"], redirect: .toApex)
        XCTAssertEqual(plan.serve, ["example.com", "api.example.com"])
        XCTAssertEqual(plan.redirects.map { $0.from + ">" + $0.to }, ["www.example.com>example.com"])
        XCTAssertEqual(BackendAppsSRV2Router.plan(domains: ["example.com"], redirect: .toWWW).serve, ["example.com"], "a pair needs both names listed")
        var web = NativeAppsOptions.Web()
        web.password = .init(username: "staging", hash: "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW")
        let routes = BackendAppsSRV2Router.caddyRoutes(routeID: "td-test-web", plan: plan, web: web)
        XCTAssertEqual(routes.map { $0["@id"].string }, ["td-test-web", "td-test-web-redirect"])
        let handlers = routes[0]["handle"].elements ?? []
        XCTAssertEqual(handlers.map { $0["handler"].string }, ["authentication", "encode", "reverse_proxy"])
        let account = handlers[0]["providers"]["http_basic"]["accounts"].elements?.first
        XCTAssertEqual(account?["username"].string, "staging")
        XCTAssertEqual(account?["password"].string.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }, web.password?.hash)
        XCTAssertEqual(handlers[2]["upstreams"].elements?.first?["dial"].string, BackendAppsSRV2Router.upstreamPlaceholder)
        let redirect = routes[1]["handle"].elements?.first?["routes"].elements?.first
        XCTAssertEqual(redirect?["handle"].elements?.first?["status_code"].number, 308)
        XCTAssertEqual(redirect?["handle"].elements?.first?["headers"]["Location"].elements?.first?.string, "{http.request.scheme}://example.com{http.request.uri}")
        web.password = nil; web.compression = false
        let plain = BackendAppsSRV2Router.caddyRoutes(routeID: "td-test-web", plan: .init(serve: ["a.example.com"], redirects: []), web: web)
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain[0]["handle"].elements?.map { $0["handler"].string }, ["reverse_proxy"])
    }

    func testConflictsIgnoreOwnRoutes() throws {
        let servers = try NativeRPCValue.parseJSON(Data(#"{"srv0":{"routes":[{"match":[{"host":["178-105-239-176.sslip.io"]}]},{"@id":"td-test-web","match":[{"host":["web.example.com"]}]},{"@id":"td-test-web-redirect","match":[{"host":["www.web.example.com"]}]},{"match":[{"host":["*.taken.com"]}]}]}}"#.utf8))
        XCTAssertEqual(BackendAppsSRV2Router.caddyConflicts(servers: servers, routeID: "td-test-web", hosts: ["web.example.com", "www.web.example.com"]), [])
        XCTAssertEqual(BackendAppsSRV2Router.caddyConflicts(servers: servers, routeID: "td-test-web", hosts: ["178-105-239-176.sslip.io", "a.taken.com", "b.c.taken.com"]), ["178-105-239-176.sslip.io", "a.taken.com"])
    }

    func testTraefikLabels() throws {
        let facts = BackendAppsSRV2Router.Facts(mode: .traefik, owner: "Coolify", traefikHTTP: "http", traefikHTTPS: "https", traefikResolver: "letsencrypt", traefikNetwork: "coolify")
        var web = NativeAppsOptions.Web(redirect: .toWWW)
        web.password = .init(username: "staging", hash: "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW")
        let plan = BackendAppsSRV2Router.plan(domains: ["example.com", "www.example.com"], redirect: .toWWW)
        let labels = Dictionary(BackendAppsSRV2Router.traefikLabels(prefix: "terminaldeck", appID: "web", plan: plan, web: web, facts: facts), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(labels["traefik.enable"], "true")
        XCTAssertEqual(labels["traefik.docker.network"], "coolify")
        let key = try XCTUnwrap(labels.keys.first { $0.hasPrefix("traefik.http.services.") }?.split(separator: ".")[3]).description
        XCTAssertTrue(key.hasPrefix("terminaldeck-web-"))
        XCTAssertEqual(labels["traefik.http.routers.\(key)-https.rule"], "Host(`www.example.com`)")
        XCTAssertEqual(labels["traefik.http.routers.\(key)-https.entrypoints"], "https")
        XCTAssertEqual(labels["traefik.http.routers.\(key)-https.tls.certresolver"], "letsencrypt")
        XCTAssertEqual(labels["traefik.http.routers.\(key)-https.middlewares"], "\(key)-auth,\(key)-gzip")
        XCTAssertEqual(labels["traefik.http.routers.\(key)-http.middlewares"], "\(key)-https")
        XCTAssertEqual(labels["traefik.http.middlewares.\(key)-https.redirectscheme.scheme"], "https")
        XCTAssertEqual(labels["traefik.http.middlewares.\(key)-auth.basicauth.users"], "staging:" + (web.password?.hash ?? ""))
        XCTAssertEqual(labels["traefik.http.routers.\(key)-canonical-https.rule"], "Host(`example.com`)")
        XCTAssertEqual(labels["traefik.http.middlewares.\(key)-canonical.redirectregex.replacement"], "https://www.${2}${3}")
        XCTAssertEqual(labels["traefik.http.services.\(key).loadbalancer.server.port"], BackendAppsSRV2Router.portPlaceholder)
        // Different settings, different names: an old and a new version never clash.
        web.compression = false
        let other = BackendAppsSRV2Router.traefikLabels(prefix: "terminaldeck", appID: "web", plan: plan, web: web, facts: facts)
        XCTAssertFalse(other.contains { $0.0.contains(key + "-") })
        XCTAssertTrue(BackendAppsSRV2Router.traefikLabels(prefix: "terminaldeck", appID: "web", plan: plan, web: web, facts: .init(mode: .caddy, owner: "Caddy")).isEmpty)
    }
}

final class BackendAppsSRV2RecipeTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    static func input(_ facts: BackendAppsSRV2Router.Facts = .init(mode: .caddy, owner: "Caddy", caddyAdmin: "127.0.0.1:2019", caddyServerKey: "srv0"),
                      change: (inout NativeAppsOptions) -> Void = { _ in }) -> BackendAppsSRV2Recipe.Input {
        var options = NativeAppsOptions()
        options.build = .init(baseDirectory: "web", dockerfile: "Dockerfile.prod", target: "runtime", noCache: true)
        options.steps = .init(beforeDeploy: "echo 'migrate' && ./migrate up", afterDeploy: "echo done", timeoutSeconds: 120)
        options.health = .init(path: "/health?full=1", expectedStatus: 200, intervalSeconds: 2, timeoutSeconds: 2, retries: 3, startPeriodSeconds: 4)
        options.web = .init(redirect: .toApex, forceHTTPS: true, compression: true, password: .init(username: "staging", hash: "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"))
        options.storage = [.init(kind: .volume, path: "/data", source: "data"), .init(kind: .file, path: "/app/config.json", source: "f-0123456789abcdef", readOnly: true),
                           .init(kind: .folder, path: "/uploads", source: "/srv/td-test/uploads")]
        change(&options)
        return .init(appID: "td-test-web", prefix: "td-test", appDirectory: "/var/lib/td-test-apps/td-test-web", network: "td-test-apps",
                     imageRepository: "td-test-td-test-web", port: 8080, options: options, domains: ["web.example.com", "www.web.example.com"],
                     facts: facts, buildKeys: ["NODE_ENV"], runKeys: ["NODE_ENV", "SECRET"], routeID: "td-test-td-test-web")
    }

    func variable(_ recipe: String, _ name: String) -> String? {
        guard let line = recipe.split(separator: "\n").first(where: { $0.hasPrefix(name + "=") }) else { return nil }
        let raw = String(line.dropFirst(name.count + 1))
        guard raw.hasPrefix("'") else { return raw }
        return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    func testRenderedRecipeIsValidShellAndJSON() throws {
        let recipe = try BackendAppsSRV2Recipe.render(Self.input())
        // POSIX syntax check with the system shell.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("srv2-recipe-\(UUID().uuidString).sh")
        try recipe.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-n", url.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let appStatic = try XCTUnwrap(variable(recipe, "TD_APP_STATIC")).replacingOccurrences(of: "__TD_DEPLOYMENT__", with: "d1").replacingOccurrences(of: "__TD_PORT__", with: "8080")
        let hc = try XCTUnwrap(variable(recipe, "TD_HC_CURL")).replacingOccurrences(of: "__TD_PORT__", with: "8080")
        let body = try NativeRPCValue.parseJSON(Data(("{\"Image\":\"sha256:x\",\"Env\":[]" + appStatic + "," + hc + "}").utf8))
        XCTAssertEqual(body["Labels"]["dev.terminaldeck.app"].string, "td-test-web")
        XCTAssertEqual(body["Labels"]["managed-by"].string, "terminaldeck")
        XCTAssertEqual(body["Labels"]["dev.terminaldeck.deployment"].string, "d1")
        XCTAssertEqual(body["Labels"]["io.terminaldeck.app"].string, "td-test-web")
        XCTAssertEqual(body["Labels"]["dev.terminaldeck.role"].string, "app")
        XCTAssertEqual(body["HostConfig"]["NetworkMode"].string, "td-test-apps")
        XCTAssertNil(body["HostConfig"]["PortBindings"].fields?.first, "no public ports")
        let mounts = body["HostConfig"]["Mounts"].elements ?? []
        XCTAssertEqual(mounts.map { $0["Type"].string }, ["volume", "bind", "bind"])
        XCTAssertEqual(mounts[0]["Source"].string, "td-test-td-test-web-data")
        XCTAssertEqual(mounts[0]["VolumeOptions"]["Labels"]["managed-by"].string, "terminaldeck")
        XCTAssertEqual(mounts[1]["Source"].string, "/var/lib/td-test-apps/td-test-web/files/f-0123456789abcdef")
        XCTAssertEqual(mounts[1]["ReadOnly"].bool, true)
        XCTAssertEqual(mounts[2]["Source"].string, "/srv/td-test/uploads")
        XCTAssertEqual(body["Healthcheck"]["Retries"].number, 3)
        XCTAssertEqual(body["Healthcheck"]["StartPeriod"].number, 4_000_000_000)
        XCTAssertTrue(body["Healthcheck"]["Test"].elements?.last?.string?.contains("http://127.0.0.1:8080/health?full=1") == true)
        let oneOff = try XCTUnwrap(variable(recipe, "TD_ONEOFF_STATIC")).replacingOccurrences(of: "__TD_DEPLOYMENT__", with: "d1")
        let before = try NativeRPCValue.parseJSON(Data(("{\"Image\":\"x\",\"Env\":[]" + oneOff + ",\"Entrypoint\":[\"/bin/sh\",\"-c\"],\"Cmd\":[" + (variable(recipe, "TD_BEFORE_JSON") ?? "") + "]}").utf8))
        XCTAssertEqual(before["Cmd"].elements?.first?.string, "echo 'migrate' && ./migrate up")
        XCTAssertEqual(before["Labels"]["dev.terminaldeck.role"].string, "before")
        XCTAssertTrue(before["Labels"].fields?.contains { $0.key.hasPrefix("traefik.") } == false)
        XCTAssertNil(before["HostConfig"]["RestartPolicy"].fields)
        let route = try NativeRPCValue.parseJSON(Data(try XCTUnwrap(variable(recipe, "TD_ROUTE_1")).utf8))
        XCTAssertEqual(route["@id"].string, "td-test-td-test-web")
        XCTAssertEqual(route["match"].elements?.first?["host"].elements?.compactMap(\.string), ["web.example.com"])
        XCTAssertEqual(variable(recipe, "TD_ROUTE_IDS"), "td-test-td-test-web td-test-td-test-web-redirect")
        XCTAssertEqual(variable(recipe, "TD_DOCKERFILE"), "web/Dockerfile.prod")
        XCTAssertEqual(variable(recipe, "TD_TARGET"), "runtime")
        XCTAssertEqual(variable(recipe, "TD_NOCACHE"), "1")
        XCTAssertEqual(variable(recipe, "TD_BUILD_KEYS"), " NODE_ENV ")
        XCTAssertEqual(variable(recipe, "TD_RUN_KEYS"), " NODE_ENV SECRET ")
        XCTAssertEqual(variable(recipe, "TD_FILES"), "f-0123456789abcdef")
    }

    func testRecipeNeverTouchesForeignResources() throws {
        let facts = try XCTUnwrap(BackendAppsSRV2RouterTests.facts(BackendAppsSRV2RouterTests.coolifyRecord))
        let recipe = try BackendAppsSRV2Recipe.render(Self.input(facts))
        XCTAssertEqual(variable(recipe, "TD_ROUTER"), "traefik")
        XCTAssertEqual(variable(recipe, "TD_TRAEFIK_NET"), "coolify")
        XCTAssertEqual(variable(recipe, "TD_ROUTE_IDS"), "", "Traefik mode never calls a router API")
        for banned in ["system prune", "image prune", "volume prune", "docker restart", "docker kill", "docker rm -f", "docker network rm", "docker network disconnect", "--force-recreate", "/traefik", "dynamic/", "caddy reload", "systemctl"] {
            XCTAssertFalse(recipe.contains(banned), banned)
        }
        // Every stop/remove/rmi acts only on ids found through our own labels.
        let lines = recipe.split(separator: "\n").map(String.init)
        for line in lines where line.contains("docker stop") || line.contains("docker rm ") || line.contains("docker rmi") {
            XCTAssertTrue(line.contains("$td_old") || line.contains("$td_image"), line)
        }
        XCTAssertTrue(recipe.contains("for td_old in $(docker ps -q --no-trunc --filter \"label=io.terminaldeck.app=$TD_APP\" --filter label=io.terminaldeck.managed=true)"))
        XCTAssertTrue(recipe.contains("--filter \"label=dev.terminaldeck.app=$TD_APP\" --filter label=managed-by=terminaldeck"))
        XCTAssertTrue(recipe.contains("docker network connect \"$TD_TRAEFIK_NET\" \"$td_new\""), "only our new container joins Traefik's network")
        let labels = try XCTUnwrap(variable(recipe, "TD_APP_STATIC"))
        XCTAssertTrue(labels.contains("traefik.http.routers.td-test-td-test-web-"))
        XCTAssertTrue(labels.contains("$2b$05$CCCC"), "the password hash rides on our own label only")
    }

    func testRenderRefusesUnsafeInputs() {
        var input = Self.input(); input.buildKeys = ["LD_PRELOAD"]
        XCTAssertThrowsError(try BackendAppsSRV2Recipe.render(input))
        XCTAssertThrowsError(try BackendAppsSRV2Recipe.render(Self.input { $0.web.forceHTTPS = false }), "Caddy here always forces https")
        input = Self.input(); input.appDirectory = "/var/lib/td-test-apps/../etc"
        XCTAssertThrowsError(try BackendAppsSRV2Recipe.render(input))
        input = Self.input(); input.domains = ["www.web.example.com", "web.example.com"]; input.options.web.redirect = .toWWW
        XCTAssertNoThrow(try BackendAppsSRV2Recipe.render(input))
    }

    func testResultParsingAndMessages() {
        let values = BackendAppsSRV2Recipe.result("recipe=1\nwarning=a\nwarning=b\nerror=health-failed\nexit=12\n")
        XCTAssertEqual(values["warning"], ["a", "b"])
        XCTAssertEqual(values["exit"], ["12"])
        XCTAssertTrue(BackendAppsSRV2Recipe.message("health-failed", health: .init(path: "/up")).contains("/up"))
        XCTAssertTrue(BackendAppsSRV2Recipe.message("after-failed").contains("put back"))
        XCTAssertTrue(BackendAppsSRV2Recipe.message("before-failed").contains("still running"))
    }
}

final class BackendAppsSRV2DeployerTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func runtime(_ fake: SRV2FakeServer) -> BackendAppsRuntime { fake.runtime(addresses: ["178.105.239.176"]) }

    func testSuccessfulDeployRecordsActiveVersionAndAddress() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        await fake.setRecipeResult("recipe=1\ntag=td-test-td-test-web:x\nimage=sha256:\(String(repeating: "a", count: 64))\nport=8080\ncontainer=\(String(repeating: "b", count: 64))\nprobe=docker\nupstream=10.0.9.2\nwarning=unsaved-storage:/var/data\nstatus=running\nexit=0\n", exit: 0)
        let deployer = BackendAppsSRV2Deployer(runtime: runtime(fake), store: BackendAppsStore(runtime: runtime(fake)))
        let row = try await deployer.deploy(serverID: "srv", appID: "td-test-web", source: .prepared(path: "/var/lib/td-test-apps/td-test-web/td-test-builds/src"))
        XCTAssertEqual(row["status"].string, "running")
        XCTAssertEqual(row["probe"].string, "docker")
        XCTAssertTrue(row["warnings"].elements?.first?.string?.contains("/var/data") == true)
        let record = try await BackendAppsStore(runtime: runtime(fake)).read("srv", "td-test-web")
        XCTAssertEqual(record["activeDeploymentId"], row["id"])
        XCTAssertEqual(record["containerId"].string, String(repeating: "b", count: 64))
        XCTAssertEqual(record["address"].string, "https://td-test-web.178-105-239-176.sslip.io")
        XCTAssertTrue(record["pendingDeploymentId"].isNullish)
        let recipe = await fake.text("/var/lib/td-test-apps/td-test-web/recipe.sh") ?? ""
        XCTAssertTrue(recipe.contains("TD_CADDY_SERVER='srv0'"))
        let run = await fake.commands.first { $0.contains("recipe.sh") && $0.contains(" deploy ") } ?? ""
        XCTAssertTrue(run.contains("nohup env TD_DEPLOYMENT="))
        XCTAssertTrue(run.contains("TD_SOURCE="))
    }

    func testFailedHealthCheckKeepsThePreviousVersion() async throws {
        let fake = SRV2FakeServer()
        let previous = BackendAppsValidation.object([("id", .string("td-test-deploy-old")), ("status", .string("running")), ("containerId", .string(String(repeating: "c", count: 64))),
                                                     ("upstream", .string("10.0.9.1")), ("port", .number(8080)), ("imageTag", .string("td-test-td-test-web:old")),
                                                     ("domains", .array([.string("td-test-web.178-105-239-176.sslip.io")]))])
        await fake.seedApp("td-test-web", port: 8080, extra: [("activeDeploymentId", .string("td-test-deploy-old")), ("containerId", .string(String(repeating: "c", count: 64))),
                                                             ("status", .string("running")), ("deployments", .array([previous]))])
        await fake.setRecipeResult("recipe=1\nimage=sha256:\(String(repeating: "a", count: 64))\nport=8080\ncontainer=\(String(repeating: "d", count: 64))\nerror=health-failed\nexit=12\n", exit: 12)
        await fake.put("/var/lib/td-test-apps/td-test-web/deploys/LOG", "")
        let deployer = BackendAppsSRV2Deployer(runtime: runtime(fake), store: BackendAppsStore(runtime: runtime(fake)))
        do { _ = try await deployer.deploy(serverID: "srv", appID: "td-test-web", source: .prepared(path: "/var/lib/td-test-apps/td-test-web/td-test-builds/src")); XCTFail("failed health check reported success") }
        catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "health-failed")
            XCTAssertTrue(error.message.contains("previous version is still running"))
            XCTAssertEqual(error.details["failure"].string, "health-failed")
        }
        let record = try await BackendAppsStore(runtime: runtime(fake)).read("srv", "td-test-web")
        XCTAssertEqual(record["activeDeploymentId"].string, "td-test-deploy-old")
        XCTAssertEqual(record["containerId"].string, String(repeating: "c", count: 64))
        XCTAssertEqual(record["status"].string, "running")
        XCTAssertEqual(record["deployments"].elements?.first?["status"].string, "failed")
        XCTAssertTrue(record["pendingDeploymentId"].isNullish)
    }

    func testInterruptedDeploySettlesFromTheServerResult() async throws {
        let fake = SRV2FakeServer()
        let pending = BackendAppsValidation.object([("id", .string("td-test-deploy-pending")), ("status", .string("deploying")), ("createdAt", .number(1))])
        await fake.seedApp("td-test-web", port: 8080, extra: [("pendingDeploymentId", .string("td-test-deploy-pending")), ("deployments", .array([pending]))])
        await fake.put("/var/lib/td-test-apps/td-test-web/deploys/td-test-deploy-pending.result",
                       "image=sha256:\(String(repeating: "a", count: 64))\nport=8080\ncontainer=\(String(repeating: "e", count: 64))\nupstream=10.0.9.5\nexit=0\n")
        await fake.setRecipeResult("error=build-failed\nexit=10\n", exit: 10)
        let deployer = BackendAppsSRV2Deployer(runtime: runtime(fake), store: BackendAppsStore(runtime: runtime(fake)))
        _ = try? await deployer.deploy(serverID: "srv", appID: "td-test-web", source: .prepared(path: "/var/lib/td-test-apps/td-test-web/td-test-builds/src"))
        let record = try await BackendAppsStore(runtime: runtime(fake)).read("srv", "td-test-web")
        XCTAssertEqual(record["activeDeploymentId"].string, "td-test-deploy-pending", "the finished earlier deploy is recorded")
        XCTAssertEqual(record["containerId"].string, String(repeating: "e", count: 64))
    }

    /// U87 (#591): the server removes the downloaded source only once the recipe stopped,
    /// never the Mac after a dropped connection; a deploy that died loses it when settled.
    func testDownloadedSourceGoesOnlyAfterTheRecipeStops() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        let deployer = BackendAppsSRV2Deployer(runtime: runtime(fake), store: BackendAppsStore(runtime: runtime(fake)))
        let work = "/var/lib/td-test-apps/td-test-web/td-test-builds/td-test-deploy-x"
        _ = try await deployer.run("srv", "td-test-web", deploymentID: "td-test-deploy-x", environment: [("TD_DEPLOYMENT", "td-test-deploy-x")], cleanup: work)
        let run = await fake.commands.last ?? ""
        let hangup = try XCTUnwrap(run.range(of: "trap '' HUP;")), recipe = try XCTUnwrap(run.range(of: "recipe.sh' deploy "))
        let removal = try XCTUnwrap(run.range(of: "rm -rf -- '\(work)';")), output = try XCTUnwrap(run.range(of: "cat '"))
        XCTAssertTrue(hangup.lowerBound < recipe.lowerBound && recipe.lowerBound < removal.lowerBound && removal.lowerBound < output.lowerBound,
                      "nothing is printed until the recipe stopped and its source is gone, so a dropped connection can't cut in")

        let pending = BackendAppsValidation.object([("id", .string("td-test-deploy-gone")), ("status", .string("deploying")), ("createdAt", .number(1))])
        await fake.seedApp("td-test-web", port: 8080, extra: [("pendingDeploymentId", .string("td-test-deploy-gone")), ("deployments", .array([pending]))])
        await fake.setRecipeResult("error=build-failed\nexit=10\n", exit: 10)
        _ = try? await deployer.deploy(serverID: "srv", appID: "td-test-web", source: .prepared(path: "/var/lib/td-test-apps/td-test-web/td-test-builds/src"))
        let record = try await BackendAppsStore(runtime: runtime(fake)).read("srv", "td-test-web")
        XCTAssertEqual(BackendAppsDeployHistory.rows(record).first { $0["id"].string == "td-test-deploy-gone" }?["failure"].string, "interrupted")
        let commands = await fake.commands
        XCTAssertTrue(commands.contains("rm -rf -- '/var/lib/td-test-apps/td-test-web/td-test-builds/td-test-deploy-gone'"))
    }

    /// U55 (#66): the app's lock is held only to start and to record a deploy. A change
    /// saved while the recipe runs goes ahead and is kept; a second deploy (and removal)
    /// is refused naming the running deploy and since when.
    func testOtherChangesGoAheadWhileADeployRuns() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        await fake.setRecipeResult("recipe=1\nimage=sha256:\(String(repeating: "a", count: 64))\nport=8080\ncontainer=\(String(repeating: "b", count: 64))\nupstream=10.0.9.2\nexit=0\n", exit: 0)
        let store = BackendAppsStore(runtime: runtime(fake)), app = "td-test-web"
        let deployer = BackendAppsSRV2Deployer(runtime: runtime(fake), store: store)
        let source = BackendAppsSRV2Deployer.Source.prepared(path: "/var/lib/td-test-apps/td-test-web/td-test-builds/src")
        let rt = runtime(fake)
        await fake.setDuringRecipe {
            var said: [String] = []
            do {
                _ = try await store.withLock("srv", app) {
                    let record = try await store.read("srv", app)
                    try await store.write("srv", app, record.setting("envKeys", .array([.string("FIXED")])))
                    return true
                }
                said.append("change saved")
            } catch { said.append("change refused: \(error)") }
            do { _ = try await deployer.deploy(serverID: "srv", appID: app, source: source); said.append("second deploy ran") }
            catch let error as NativeRPCError { said.append("second: " + error.code + ": " + error.message) }
            catch { said.append("second: \(error)") }
            do {
                try await BackendAppsSRV2Deployer.refuseWhileDeploying(runtime: rt, store: store, "srv", app, record: try await store.read("srv", app))
                said.append("removal allowed")
            } catch let error as NativeRPCError { said.append("removal: " + error.code) }
            catch { said.append("removal: \(error)") }
            return said.joined(separator: "\n")
        }
        let row = try await deployer.deploy(serverID: "srv", appID: app, source: source)
        let said = await fake.duringRecipeAnswer ?? ""
        XCTAssertTrue(said.contains("change saved"), said)
        XCTAssertTrue(said.contains("second: busy: A deploy started less than a minute ago is still running on the server."), said)
        XCTAssertTrue(said.contains("removal: busy"), said)
        let record = try await store.read("srv", app)
        XCTAssertEqual(record["envKeys"].elements?.first?.string, "FIXED", "the change saved during the deploy is kept")
        XCTAssertEqual(record["activeDeploymentId"], row["id"])
        XCTAssertTrue(record["pendingDeploymentId"].isNullish)
        let commands = await fake.commands
        let run = try XCTUnwrap(commands.firstIndex { $0.contains("recipe.sh' deploy ") })
        XCTAssertNotNil(commands[..<run].lastIndex { $0.contains("rmdir --") }, "the lock is released before the recipe runs")
        XCTAssertTrue(commands.contains { $0.contains(": > '/var/lib/td-test-apps/td-test-web/deploys/\(row["id"].string ?? "")" + ".result'") })
        // A finished result: nothing runs, so removal may go ahead.
        await fake.put("/var/lib/td-test-apps/td-test-web/deploys/\(row["id"].string ?? "").result", "exit=0\n")
        try await BackendAppsSRV2Deployer.refuseWhileDeploying(runtime: rt, store: store, "srv", app, record: record.setting("pendingDeploymentId", row["id"]))
    }

    /// U2 (#2, #65, #67, #579): one history rule for every writer: newest first, one cap,
    /// and a version the recipe removed is never offered for Roll back.
    func testHistoryIsNewestFirstCappedAndMarksVersionsTheRecipeRemoved() async throws {
        let fake = SRV2FakeServer()
        let gone = "sha256:" + String(repeating: "1", count: 64)
        func row(_ n: Int) -> NativeRPCValue {
            var pairs: [(String, NativeRPCValue)] = [("id", .string("td-test-deploy-\(n)")), ("status", .string("running")), ("createdAt", .number(Double(n) * 1000)),
                                                     ("imageTag", .string("td-test-td-test-web:\(n)"))]
            if n == 59 { pairs.append(("imageId", .string(gone))) }
            return BackendAppsValidation.object(pairs)
        }
        // Server pushes added their rows oldest first; the running version is the oldest row.
        await fake.seedApp("td-test-web", port: 8080, extra: [("activeDeploymentId", .string("td-test-deploy-1")), ("deployments", .array((1...60).map(row)))])
        await fake.seedApp("td-test-api", port: 8080, extra: [("deployments", .array([row(1), row(2)]))])
        await fake.setRecipeResult("recipe=1\nimage=sha256:\(String(repeating: "a", count: 64))\nport=8080\ncontainer=\(String(repeating: "b", count: 64))\nupstream=10.0.9.2\npruned=\(gone)\nexit=0\n", exit: 0)
        let store = BackendAppsStore(runtime: runtime(fake))
        let deployer = BackendAppsSRV2Deployer(runtime: runtime(fake), store: store)
        let new = try await deployer.deploy(serverID: "srv", appID: "td-test-web", source: .prepared(path: "/var/lib/td-test-apps/td-test-web/td-test-builds/src"))
        let saved = try await store.read("srv", "td-test-web")["deployments"].elements ?? []
        XCTAssertEqual(saved.first?["id"], new["id"], "the newest deploy is the top row")
        let times = saved.compactMap { $0["createdAt"].number }
        XCTAssertEqual(times, times.sorted(by: >))
        XCTAssertEqual(saved.count, BackendAppsDeployHistory.limit + 1, "one cap, plus the version that was running")
        XCTAssertTrue(saved.contains { $0["id"].string == "td-test-deploy-1" })
        let pruned = saved.first { $0["id"].string == "td-test-deploy-59" } ?? .null
        XCTAssertEqual(pruned["imageRemoved"].bool, true)
        XCTAssertFalse(BackendAppsDeployHistory.canRollBack(pruned))
        XCTAssertTrue(BackendAppsDeployHistory.canRollBack(saved.first { $0["id"].string == "td-test-deploy-60" } ?? .null))
        // The Deployments list reads one order, whoever wrote the rows.
        let engine = BackendAppsDeploy(runtime: runtime(fake), store: store, caddy: BackendAppsCaddy(runtime: runtime(fake)))
        let history = try await engine.history(serverID: "srv", appID: "td-test-web")
        XCTAssertEqual(history.elements?.first?["id"], new["id"])
        XCTAssertEqual(history.elements?.first { $0["id"].string == "td-test-deploy-59" }?["imageRemoved"].bool, true)
        let unsorted = try await engine.history(serverID: "srv", appID: "td-test-api")
        XCTAssertEqual(unsorted.elements?.compactMap { $0["id"].string }, ["td-test-deploy-2", "td-test-deploy-1"])
    }
}

final class BackendAppsSRV2ChannelsTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testWritesAskBeforeAnyServerCallAndPreviewsHideValues() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web")
        let seen = SRV2Box()
        let channels = BackendAppsSRV2Channels(runtime: fake.runtime(), authorize: { action, _ in
            await seen.add(action.preview)
            throw NativeRPCError(code: "approval-required", message: "no")
        })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "test")
        let before = await fake.commands.count
        let request = BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("td-test-web")),
                                                    ("set", .array([BackendAppsValidation.object([("key", .string("TOKEN")), ("value", .string("super-secret-value"))])]))])
        do { _ = try await channels.invoke("apps:variables:patch", request: request, context: context); XCTFail("write ran without approval") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        var options = NativeAppsOptions(); options.web.password = .init(username: "staging", password: "plain-password-1")
        let apply = BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("td-test-web")), ("options", try options.value())])
        do { _ = try await channels.invoke("apps:options:apply", request: apply, context: context); XCTFail("write ran without approval") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        let after = await fake.commands.count
        XCTAssertEqual(before, after, "no server I/O before approval")
        let previews = await seen.values.map { String(decoding: (try? $0.encodedJSON()) ?? Data(), as: UTF8.self) }.joined()
        XCTAssertTrue(previews.contains("TOKEN"))
        XCTAssertTrue(previews.contains("Sets a new password"))
        XCTAssertFalse(previews.contains("super-secret-value"))
        XCTAssertFalse(previews.contains("plain-password-1"))
    }

    func testComposeAppsUseTheEarlierEngine() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", build: "compose")
        let channels = BackendAppsSRV2Channels(runtime: fake.runtime(), authorize: { _, _ in }, fallback: { channel, _, _ in .string("fallback:" + channel) })
        let value = try await channels.invoke("apps:deploy", request: BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("td-test-web"))]), context: NativeRPCContext(caller: .nativeApp, ownerID: "t"))
        XCTAssertEqual(value.string, "fallback:apps:deploy")
    }

    func testOptionsRoundTripThroughChannels() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        let channels = BackendAppsSRV2Channels(runtime: fake.runtime(addresses: ["178.105.239.176"]), authorize: { _, _ in })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "t")
        var options = NativeAppsOptions(); options.health.path = "/up"; options.steps.beforeDeploy = "true"
        let saved = try await channels.invoke("apps:options:apply", request: BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("td-test-web")), ("options", try options.value())]), context: context)
        XCTAssertEqual(saved["options"]["health"]["path"].string, "/up")
        XCTAssertTrue(saved["note"].string?.contains("next deploy") == true)
        let read = try await channels.invoke("apps:options:read", request: BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("td-test-web"))]), context: context)
        XCTAssertEqual(read["options"]["steps"]["beforeDeploy"].string, "true")
        let recipe = await fake.text("/var/lib/td-test-apps/td-test-web/recipe.sh") ?? ""
        XCTAssertTrue(recipe.contains("TD_HEALTH_PATH='/up'"), "saving options rewrites the recipe")
    }
}

final class BackendAppsSRV2MCPTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testToolsMapToChannelsAndOnlyChangesNeedApproval() {
        let specs = BackendAppsSRV2MCP.specs()
        XCTAssertEqual(Set(specs.map(\.id)), ["apps.options.read", "apps.options.apply", "apps.variables.read", "apps.variables.patch", "apps.router.read",
                                              "apps.router.persist.plan", "apps.router.persist.apply"])
        for spec in specs {
            XCTAssertEqual(spec.channel, "apps:" + spec.id.dropFirst(5).replacingOccurrences(of: ".", with: ":"))
            XCTAssertEqual(spec.write, BackendAppsSRV2Channels.writeChannels.contains(spec.channel), spec.id)
            XCTAssertTrue(BackendAppsSRV2Channels.readChannels.union(BackendAppsSRV2Channels.writeChannels).contains(spec.channel))
        }
        XCTAssertTrue(BackendAppsSRV2MCP.handles("apps_options_apply"))
        XCTAssertFalse(BackendAppsSRV2MCP.handles("apps.deploy"))
    }

    func testValidationAndSummariesNeverLeakValues() throws {
        let patch = BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("web")),
                                                  ("set", .array([BackendAppsValidation.object([("key", .string("TOKEN")), ("value", .string("very-secret-1")), ("locked", .bool(true))])])),
                                                  ("remove", .array([.string("OLD")]))])
        XCTAssertNoThrow(try BackendAppsSRV2MCP.validate(tool: "apps.variables.patch", arguments: patch))
        let sentence = try XCTUnwrap(BackendAppsSRV2MCP.summary(tool: "apps.variables.patch", arguments: patch))
        XCTAssertTrue(sentence.contains("TOKEN") && sentence.contains("OLD"))
        XCTAssertFalse(sentence.contains("very-secret-1"))
        XCTAssertThrowsError(try BackendAppsSRV2MCP.validate(tool: "apps.variables.patch", arguments: patch.setting("extra", .bool(true))), "unknown fields refused")
        XCTAssertThrowsError(try BackendAppsSRV2MCP.validate(tool: "apps.variables.patch", arguments: patch.setting("set", .array([BackendAppsValidation.object([("key", .string("X")), ("value", .string(NativeAppsVariable.mask))])]))), "masked value refused")
        var options = NativeAppsOptions(); options.web.password = .init(username: "staging", password: "plain-password-9")
        let apply = BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("web")), ("options", try options.value())])
        XCTAssertNoThrow(try BackendAppsSRV2MCP.validate(tool: "apps.options.apply", arguments: apply))
        let applySentence = try XCTUnwrap(BackendAppsSRV2MCP.summary(tool: "apps.options.apply", arguments: apply))
        XCTAssertTrue(applySentence.contains("Sets a new password"))
        XCTAssertFalse(applySentence.contains("plain-password-9"))
        options.storage = [.init(kind: .folder, path: "/data", source: "/etc")]
        XCTAssertThrowsError(try BackendAppsSRV2MCP.validate(tool: "apps.options.apply", arguments: apply.setting("options", try options.value())))
        XCTAssertThrowsError(try BackendAppsSRV2MCP.validate(tool: "apps.options.read", arguments: BackendAppsValidation.object([("serverId", .string("srv")), ("appId", .string("Bad_ID"))])))
    }
}

final class BackendAppsSRV2RouterRecordTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testSavedRouterRecordFromSetupIsUsedWithoutProbing() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        let saved = BackendAppsSRV2Router.Facts(mode: .traefik, owner: "Coolify", traefikHTTP: "http", traefikHTTPS: "https", traefikResolver: "letsencrypt", traefikNetwork: "coolify")
        await fake.put("/var/lib/td-test-apps/router.json", String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
        let runtime = fake.runtime(addresses: ["178.105.239.176"])
        let deployer = BackendAppsSRV2Deployer(runtime: runtime, store: BackendAppsStore(runtime: runtime))
        let facts = try await deployer.resolvedFacts("srv", nil)
        XCTAssertEqual(facts.mode, .traefik)
        let probes = await fake.commands.filter { $0.contains("caddy_pid=") }
        XCTAssertTrue(probes.isEmpty, "a Traefik record needs no Caddy process check")
        let record = try await BackendAppsStore(runtime: runtime).read("srv", "td-test-web")
        let written = try await deployer.writeRecipe("srv", "td-test-web", record: record, facts: facts)
        XCTAssertTrue(written.recipe.contains("TD_ROUTER=traefik"))
        XCTAssertTrue(written.recipe.contains("traefik.docker.network"))
    }
}

final class BackendAppsSRV2CaddyKeepTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    static func probe(_ args: [String], cwd: String = "/", host: Bool = true, version: String = "v2.6.2 h1:abc") -> String {
        var text = "caddy_pid=776685\ncaddy_args=" + Data(args.joined(separator: "\n").utf8).base64EncodedString() + "\ncaddy_cwd=\(cwd)\ncaddy_exe=/usr/bin/caddy\n"
        if host { text += "caddy_host=1\ncaddy_version=\(version)\n" }
        return text
    }

    func testHowCaddyStartsDecidesHowAddressesAreKept() {
        let file = BackendAppsSRV2Router.persistence(output: Self.probe(["/usr/bin/caddy", "run", "--environ", "--config", "/etc/caddy/Caddyfile"]), prefix: "terminaldeck")
        XCTAssertEqual(file.mode, "caddyfile"); XCTAssertEqual(file.caddyfile, "/etc/caddy/Caddyfile")
        XCTAssertEqual(BackendAppsSRV2Router.persistence(output: Self.probe(["caddy", "run", "--resume", "--config", "/x/bootstrap.json"]), prefix: "terminaldeck").mode, "resume")
        XCTAssertEqual(BackendAppsSRV2Router.persistence(output: Self.probe(["caddy", "run", "--config", "/etc/caddy/caddy.json"]), prefix: "terminaldeck").mode, "json")
        XCTAssertEqual(BackendAppsSRV2Router.persistence(output: Self.probe(["caddy", "run"], cwd: "/srv/site"), prefix: "terminaldeck").caddyfile, "/srv/site/Caddyfile")
        XCTAssertEqual(BackendAppsSRV2Router.persistence(output: Self.probe(["caddy", "run", "--config", "/etc/caddy/Caddyfile"], host: false), prefix: "terminaldeck").mode, "container")
        XCTAssertEqual(BackendAppsSRV2Router.persistence(output: "caddy_pid=\n", prefix: "terminaldeck").mode, "unknown")
        var facts = BackendAppsSRV2Router.Facts(mode: .caddy, owner: "Caddy", caddyAdmin: "127.0.0.1:2019", caddyServerKey: "srv0", caddyPersistence: "caddyfile",
                                                caddyfile: "/etc/caddy/Caddyfile", caddySnippets: "/etc/caddy/terminaldeck", caddyImported: false)
        XCTAssertFalse(facts.persistence.ready)
        XCTAssertEqual(facts.persistence.line, "import /etc/caddy/terminaldeck/*.caddy")
        XCTAssertEqual(facts.persistence.file, "/etc/caddy/Caddyfile")
        facts.caddyImported = true
        XCTAssertTrue(facts.persistence.ready)
        facts.caddyPersistence = "resume"
        XCTAssertTrue(facts.persistence.ready)
        XCTAssertTrue(BackendAppsSRV2Router.Facts(mode: .traefik, owner: "Coolify").persistence.ready)
    }

    func testAddressFileMatchesTheRoutesAndIsRecognisedAsOurs() throws {
        var web = NativeAppsOptions.Web(redirect: .toApex)
        web.password = .init(username: "staging", hash: "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW")
        let plan = BackendAppsSRV2Router.plan(domains: ["web.example.com", "www.web.example.com"], redirect: .toApex)
        let old = BackendAppsSRV2Router.caddyfileSites(routeID: "terminaldeck-web", appID: "web", plan: plan, web: web, caddyVersion: "v2.6.2 h1:x")
        XCTAssertTrue(old.contains("web.example.com {\n\tvars td_owner terminaldeck-web\n\tbasicauth {"))
        XCTAssertTrue(old.contains("\tencode zstd gzip\n\treverse_proxy __TD_UPSTREAM__\n}"))
        XCTAssertTrue(old.contains("www.web.example.com {\n\tvars td_owner terminaldeck-web\n\tredir {scheme}://web.example.com{uri} 308\n}"))
        XCTAssertTrue(BackendAppsSRV2Router.caddyfileSites(routeID: "terminaldeck-web", appID: "web", plan: plan, web: web, caddyVersion: "v2.8.4").contains("basic_auth {"))
        // After Caddy rebuilds its config from the Caddyfile, those sites have no @id but are still ours.
        let servers = try NativeRPCValue.parseJSON(Data(#"{"srv0":{"routes":[{"match":[{"host":["web.example.com"]}],"handle":[{"handler":"subroute","routes":[{"handle":[{"handler":"vars","td_owner":"terminaldeck-web"}]}]}]},{"match":[{"host":["other.example.com"]}],"handle":[{"handler":"subroute","routes":[{"handle":[{"handler":"vars","td_owner":"terminaldeck-other"}]}]}]}]}}"#.utf8))
        XCTAssertEqual(BackendAppsSRV2Router.caddyConflicts(servers: servers, routeID: "terminaldeck-web", hosts: ["web.example.com", "other.example.com"]), ["other.example.com"])
    }

    func testRecipeKeepsTheAddressFileOnlyInCaddyfileMode() throws {
        let facts = BackendAppsSRV2Router.Facts(mode: .caddy, owner: "Caddy", caddyAdmin: "127.0.0.1:2019", caddyServerKey: "srv0", caddyPersistence: "caddyfile",
                                                caddyfile: "/etc/caddy/Caddyfile", caddySnippets: "/etc/caddy/terminaldeck", caddyImported: true, caddyBinary: "/usr/bin/caddy", caddyVersion: "v2.6.2")
        let recipe = try BackendAppsSRV2Recipe.render(BackendAppsSRV2RecipeTests.input(facts))
        XCTAssertTrue(recipe.contains("TD_CADDY_KEEP=caddyfile"))
        XCTAssertTrue(recipe.contains("TD_CADDY_SNIPPETS='/etc/caddy/terminaldeck'"))
        XCTAssertTrue(recipe.contains("vars td_owner td-test-td-test-web"))
        XCTAssertTrue(recipe.contains("persist-route) td_route_now keep"))
        var resume = facts; resume.caddyPersistence = "resume"
        let plain = try BackendAppsSRV2Recipe.render(BackendAppsSRV2RecipeTests.input(resume))
        XCTAssertTrue(plain.contains("TD_CADDY_KEEP=''"))
        XCTAssertTrue(plain.contains("TD_CADDY_FILE_BODY=''"))
        var bad = facts; bad.caddySnippets = "/etc/caddy/../x"
        XCTAssertThrowsError(try BackendAppsSRV2Recipe.render(BackendAppsSRV2RecipeTests.input(bad)))
    }

    func testEveryRecipeAddressActionIsAccepted() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        let deployer = BackendAppsSRV2Deployer(runtime: fake.runtime(), store: BackendAppsStore(runtime: fake.runtime()))
        for action in ["ensure-route", "apply-route", "persist-route", "unroute"] {
            let result = try await deployer.route("srv", "td-test-web", action: action)
            XCTAssertFalse(result.isEmpty, action)
        }
        do { _ = try await deployer.route("srv", "td-test-web", action: "drop-everything"); XCTFail("unknown action accepted") } catch {}
    }

    func testApplyAddsOnlyTheApprovedLineAndRefusesAChangedPlan() async throws {
        let fake = SRV2FakeServer()
        let saved = BackendAppsSRV2Router.Facts(mode: .caddy, owner: "Caddy", caddyAdmin: "127.0.0.1:2019", caddyServerKey: "srv0")
        await fake.put("/var/lib/td-test-apps/router.json", String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
        await fake.setPersistenceProbe(Self.probe(["/usr/bin/caddy", "run", "--environ", "--config", "/etc/caddy/Caddyfile"]))
        let keep = BackendAppsSRV2CaddyKeep(runtime: fake.runtime(), store: BackendAppsStore(runtime: fake.runtime()))
        let plan = try await keep.plan("srv")
        XCTAssertEqual(plan.mode, "caddyfile")
        XCTAssertFalse(plan.ready)
        XCTAssertEqual(plan.line, "import /etc/caddy/td-test/*.caddy")
        do { _ = try await keep.apply("srv", file: "/etc/caddy/Caddyfile", line: "import /etc/other/*.caddy"); XCTFail("changed line accepted") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "conflict") }
        let result = try await keep.apply("srv", file: "/etc/caddy/Caddyfile", line: "import /etc/caddy/td-test/*.caddy")
        XCTAssertEqual(result["ready"].bool, true)
        let script = await fake.commands.first { $0.contains("terminaldeck-owner") && $0.contains(">> \"$file\"") } ?? ""
        XCTAssertTrue(script.contains("line='import /etc/caddy/td-test/*.caddy'"))
        XCTAssertTrue(script.contains("printf '%s\\n' \"$line\"; } >> \"$file\""), "exactly one line is appended")
        XCTAssertFalse(script.contains("reload") || script.contains("systemctl") || script.contains("restart"), "the owner's Caddy is never reloaded or restarted")
    }
}

/// The Caddy import line's receipt and undo, run for real (POSIX sh) in a
/// private folder: apply and undo exactly as the server would, with a fake
/// `caddy adapt`. Each failure mode keeps the owner's file and our receipt.
final class BackendAppsSRV2CaddyUndoShellTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    struct Sandbox {
        let root: String
        var caddyfile: String { root + "/etc/caddy/Caddyfile" }
        var folder: String { root + "/etc/caddy/td-test" }
        var line: String { "import " + folder + "/*.caddy" }
        var receipt: String { root + "/state/" + BackendAppsSRV2CaddyKeep.receiptName }
        var caddy: String { root + "/fake/caddy" }
        var owned: NativeAppsRouterPersistence.OwnedImport { .init(file: caddyfile, line: line, folder: folder) }

        init(caddyfile text: String = "site.example.com {\n\trespond ok\n}\n") throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("srv2-undo-" + UUID().uuidString.prefix(8).lowercased()).path
            try FileManager.default.createDirectory(atPath: base + "/etc/caddy", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: base + "/fake", withIntermediateDirectories: true)
            // The scripts compare against realpath(1); /var is a link to /private/var here.
            guard let resolved = realpath(base, nil) else { throw NativeRPCError.malformed("sandbox path") }
            root = String(cString: resolved); free(resolved)
            try text.write(toFile: caddyfile, atomically: false, encoding: .utf8)
            try "#!/bin/sh\n[ \"$1\" = adapt ] || exit 2\n[ -z \"${FAKE_CADDY_FAIL:-}\" ]\n".write(toFile: caddy, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: caddy)
        }
        func remove() { try? FileManager.default.removeItem(atPath: root) }
        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

        @discardableResult
        func sh(_ script: String, env: [String: String] = [:]) throws -> (code: Int32, out: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": root].merging(env) { $1 }
            let output = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        func apply(token: String = "0123456789abcdef0123456789abcdef", env: [String: String] = [:]) throws -> Int32 {
            let q = BackendAppsRuntime.quote
            return try sh(BackendAppsSRV2CaddyKeep.applyScript(file: q(caddyfile), line: q(line), folder: q(folder), binary: q(caddy),
                                                               receipt: q(receipt), token: q(token), namespace: q("td-test")), env: env).code
        }
        func undo(_ owned: NativeAppsRouterPersistence.OwnedImport? = nil) throws -> (code: Int32, out: String) {
            let q = BackendAppsRuntime.quote, want = owned ?? self.owned
            return try sh(BackendAppsSRV2CaddyKeep.undoScript(receipt: q(receipt), file: q(want.file), line: q(want.line), folder: q(want.folder), namespace: q("td-test")))
        }
    }

    func testApplyThenUndoRestoresTheOwnersFileByteForByte() throws {
        for original in ["site.example.com {\n\trespond ok\n}\n", "site.example.com {\n\trespond ok\n}"] {
            let box = try Sandbox(caddyfile: original); defer { box.remove() }
            XCTAssertEqual(try box.apply(), 0)
            XCTAssertEqual(box.read(box.caddyfile)?.components(separatedBy: box.line).count, 2, "exactly one line added")
            let receipt = try XCTUnwrap(box.read(box.receipt))
            XCTAssertEqual(BackendAppsSRV2CaddyKeep.parseReceipt(receipt, namespace: "td-test"), box.owned)
            try "# Terminal Deck app web: its addresses.\nweb.example.com {\n}\n".write(toFile: box.folder + "/td-test-web.caddy", atomically: false, encoding: .utf8)
            let first = try box.undo()
            XCTAssertEqual(first.code, 0, first.out)
            XCTAssertEqual(box.read(box.caddyfile), original, "the owner's file is back exactly")
            XCTAssertFalse(box.exists(box.folder), "our folder and only our files are gone")
            XCTAssertFalse(box.exists(box.receipt))
            let again = try box.undo()
            XCTAssertEqual(again.code, 0); XCTAssertTrue(again.out.contains("undo=nothing"), "idempotent")
            XCTAssertEqual(box.read(box.caddyfile), original)
        }
    }

    func testAnImportTheOwnerAlreadyHadIsNeverOursAndNeverTouched() throws {
        let box = try Sandbox(); defer { box.remove() }
        let owners = "site.example.com {\n}\nimport " + box.folder + "/*.caddy\n"
        try owners.write(toFile: box.caddyfile, atomically: false, encoding: .utf8)
        XCTAssertEqual(try box.apply(), 0)
        XCTAssertFalse(box.exists(box.receipt), "no receipt for a line we didn't add")
        XCTAssertTrue(try box.undo().out.contains("undo=nothing"))
        XCTAssertEqual(box.read(box.caddyfile), owners)
    }

    func testAChangedReceiptOrWrongExpectationRemovesNothing() throws {
        let box = try Sandbox(); defer { box.remove() }
        XCTAssertEqual(try box.apply(), 0)
        let added = box.read(box.caddyfile)
        let other = NativeAppsRouterPersistence.OwnedImport(file: box.caddyfile, line: "import /etc/other/td-test/*.caddy", folder: "/etc/other/td-test")
        XCTAssertEqual(try box.undo(other).code, 68)
        XCTAssertEqual(box.read(box.caddyfile), added); XCTAssertTrue(box.exists(box.receipt)); XCTAssertTrue(box.exists(box.folder))
        // A tampered receipt (foreign namespace) is not trusted either.
        let receipt = try XCTUnwrap(box.read(box.receipt))
        try receipt.replacingOccurrences(of: "namespace=td-test", with: "namespace=coolify").write(toFile: box.receipt, atomically: false, encoding: .utf8)
        XCTAssertEqual(try box.undo().code, 66)
        XCTAssertEqual(box.read(box.caddyfile), added)
        XCTAssertNil(BackendAppsSRV2CaddyKeep.parseReceipt(box.read(box.receipt) ?? "", namespace: "td-test"))
    }

    func testALinkedCaddyfileOrForeignFolderStopsBeforeAnyChange() throws {
        let box = try Sandbox(); defer { box.remove() }
        XCTAssertEqual(try box.apply(), 0)
        let added = try XCTUnwrap(box.read(box.caddyfile))
        // Caddyfile swapped for a link: refuse, the link target untouched.
        let target = box.root + "/elsewhere"
        try added.write(toFile: target, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: box.caddyfile)
        try FileManager.default.createSymbolicLink(atPath: box.caddyfile, withDestinationPath: target)
        XCTAssertEqual(try box.undo().code, 66)
        XCTAssertEqual(box.read(target), added); XCTAssertTrue(box.exists(box.receipt))
        try FileManager.default.removeItem(atPath: box.caddyfile)
        try added.write(toFile: box.caddyfile, atomically: false, encoding: .utf8)
        // Folder marker no longer ours: refuse before touching the Caddyfile.
        try "ffffffffffffffffffffffffffffffff\n".write(toFile: box.folder + "/.terminaldeck-owner", atomically: false, encoding: .utf8)
        XCTAssertEqual(try box.undo().code, 66)
        XCTAssertEqual(box.read(box.caddyfile), added, "nothing changed before the ownership check")
        XCTAssertTrue(box.exists(box.receipt))
    }

    func testAReadErrorNeverRewritesTheOwnersFile() throws {
        try XCTSkipIf(getuid() == 0, "root reads unreadable files")
        let box = try Sandbox(); defer { box.remove() }
        XCTAssertEqual(try box.apply(), 0)
        let added = box.read(box.caddyfile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.caddyfile)
        let result = try box.undo()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.caddyfile)
        XCTAssertEqual(result.code, 67)
        XCTAssertEqual(box.read(box.caddyfile), added); XCTAssertTrue(box.exists(box.receipt)); XCTAssertTrue(box.exists(box.folder))
    }

    func testForeignFilesAndLinksInOurFolderAreLeftAlone() throws {
        let box = try Sandbox(); defer { box.remove() }
        XCTAssertEqual(try box.apply(), 0)
        try "owner notes\n".write(toFile: box.folder + "/notes.txt", atomically: false, encoding: .utf8)
        let precious = box.root + "/precious"
        try "keep me\n".write(toFile: precious, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: box.folder + "/td-test-evil.caddy", withDestinationPath: precious)
        try "not ours\n".write(toFile: box.folder + "/td-test-other.caddy", atomically: false, encoding: .utf8)
        let result = try box.undo()
        XCTAssertEqual(result.code, 0, result.out)
        XCTAssertTrue(result.out.contains("folder=kept-other-files"))
        XCTAssertEqual(box.read(box.folder + "/notes.txt"), "owner notes\n")
        XCTAssertEqual(box.read(precious), "keep me\n")
        XCTAssertEqual(box.read(box.folder + "/td-test-other.caddy"), "not ours\n")
        XCTAssertFalse(box.exists(box.folder + "/README.caddy"))
        XCTAssertFalse(box.read(box.caddyfile)?.contains(box.line) ?? true)
        XCTAssertFalse(box.exists(box.receipt))
    }

    func testApplyRefusesAForeignFolderAndPutsTheFileBackWhenCaddyRejectsIt() throws {
        let box = try Sandbox(); defer { box.remove() }
        let original = box.read(box.caddyfile)
        try FileManager.default.createDirectory(atPath: box.folder, withIntermediateDirectories: true)
        try "someone else's\n".write(toFile: box.folder + "/theirs.caddy", atomically: false, encoding: .utf8)
        XCTAssertEqual(try box.apply(), 64)
        XCTAssertEqual(box.read(box.caddyfile), original); XCTAssertFalse(box.exists(box.receipt))
        try FileManager.default.removeItem(atPath: box.folder)
        XCTAssertEqual(try box.apply(env: ["FAKE_CADDY_FAIL": "1"]), 65)
        XCTAssertEqual(box.read(box.caddyfile), original, "put back exactly"); XCTAssertFalse(box.exists(box.receipt), "no receipt for a line that isn't there")
    }

    func testRemoveServerPreviewsTheExactLineBeforeAnyServerCall() async throws {
        let fake = SRV2FakeServer()
        let seen = SRV2Box()
        let service = try BackendAppsServerService(runtime: fake.runtime())
        let channels = BackendAppsServerChannels(service: service, authorize: { action, _ in
            await seen.add(action.preview)
            throw NativeRPCError(code: "approval-required", message: "no")
        })
        let owned = NativeAppsRouterPersistence.OwnedImport(file: "/etc/caddy/Caddyfile", line: "import /etc/caddy/td-test/*.caddy", folder: "/etc/caddy/td-test")
        let request = BackendAppsValidation.object([("serverId", .string("srv")), ("confirmation", .string("srv")),
            ("importUndo", BackendAppsValidation.object([("file", .string(owned.file)), ("line", .string(owned.line)), ("folder", .string(owned.folder))]))])
        let before = await fake.commands.count
        do { _ = try await channels.invoke("apps:server:setup:remove", request: request, context: NativeRPCContext(caller: .nativeApp, ownerID: "t", capabilities: ["apps.write"])); XCTFail("ran without approval") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        let after = await fake.commands.count
        XCTAssertEqual(before, after, "no server I/O before approval")
        let previews = await seen.values
        let preview = try XCTUnwrap(previews.first)
        XCTAssertEqual(preview["importUndo"]["line"].string, owned.line)
        XCTAssertEqual(preview["importUndo"]["file"].string, owned.file)
        XCTAssertEqual(preview["importUndo"]["folder"].string, owned.folder)
        let bad = request.setting("importUndo", BackendAppsValidation.object([("file", .string(owned.file)), ("line", .string(owned.line))]))
        do { _ = try await channels.invoke("apps:server:setup:remove", request: bad, context: NativeRPCContext(caller: .nativeApp, ownerID: "t", capabilities: ["apps.write"])); XCTFail("partial importUndo accepted") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        XCTAssertTrue(BackendAppsMCP.summary(tool: "apps.server.setup.remove", arguments: request).contains(owned.line))
    }
}

/// Server-side recovery of interrupted changes: the journal kept next to the
/// app lock, and the recovery script run for real (POSIX sh) in a sandbox.
final class BackendAppsSRV2TxnRecoveryTests: BackendAppsSRV2TestCase, @unchecked Sendable {
    func testEveryLockedChangeKeepsAJournalAndClosesItBeforeRelease() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        let store = BackendAppsStore(runtime: fake.runtime())
        _ = try await store.withLock("srv", "td-test-web") {
            try await store.writeFile("srv", path: "/var/lib/td-test-apps/td-test-web/.env", contents: Data("A=1\n".utf8))
            return true
        }
        let commands = await fake.commands
        let acquire = try XCTUnwrap(commands.firstIndex { $0.contains("mkdir -- '/var/lib/td-test-apps/td-test-web/.lock'") })
        let create = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("# td-journal create '/var/lib/td-test-apps/td-test-web/.lock' '/var/lib/td-test-apps/td-test-web/.txn'") })
        XCTAssertLessThan(acquire, create, "a fresh journal right after the lock")
        let capture = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("# td-journal capture") && $0.contains("'/var/lib/td-test-apps/td-test-web/.env'") })
        XCTAssertTrue(commands[capture].contains("cp -p -- '/var/lib/td-test-apps/td-test-web/.env' '/var/lib/td-test-apps/td-test-web/.txn/before/'"), "before-image kept")
        let write = try XCTUnwrap(commands.firstIndex { $0.contains("mv -f --") && $0.contains("/.env'") })
        XCTAssertLessThan(capture, write, "journal before the write")
        let finish = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("# td-journal finish") })
        let release = try XCTUnwrap(commands.lastIndex { $0.contains("rmdir --") })
        XCTAssertLessThan(finish, release, "the journal closes before the lock is released")
        XCTAssertTrue(commands.allSatisfy { !$0.hasPrefix("# td-journal install") || !$0.contains("A=1") }, "the helper carries no app values")
    }

    func testAStaleInterruptedChangeIsRecoveredBeforeTheNextChange() async throws {
        let fake = SRV2FakeServer()
        await fake.seedApp("td-test-web", port: 8080)
        await fake.setBusyOnce()
        let store = BackendAppsStore(runtime: fake.runtime())
        let ran = try await store.withLock("srv", "td-test-web") { true }
        XCTAssertTrue(ran)
        let commands = await fake.commands
        XCTAssertTrue(commands.contains { $0.hasPrefix("# td-journal recover") && $0.contains("sh '/var/lib/td-test-apps/.td-recover.sh' --stale-minutes 30 'td-test-web'") })
        XCTAssertEqual(commands.filter { $0.contains("mkdir -- '/var/lib/td-test-apps/td-test-web/.lock'") }.count, 2, "acquired again after recovery")
    }

    struct Box {
        let root: String
        var app: String { root + "/td-test-web" }
        init() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("srv2-txn-" + UUID().uuidString.prefix(8).lowercased()).path
            try FileManager.default.createDirectory(atPath: base + "/td-test-web/files", withIntermediateDirectories: true)
            guard let resolved = realpath(base, nil) else { throw NativeRPCError.malformed("sandbox") }
            root = String(cString: resolved); free(resolved)
            try BackendAppsSRV2TxnRecovery.script(stateRoot: root).write(toFile: root + "/" + BackendAppsSRV2TxnRecovery.scriptName, atomically: false, encoding: .utf8)
        }
        func put(_ rel: String, _ text: String) throws { try text.write(toFile: app + "/" + rel, atomically: false, encoding: .utf8) }
        func read(_ rel: String) -> String? { try? String(contentsOfFile: app + "/" + rel, encoding: .utf8) }
        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: app + "/" + rel) }
        /// A change that stopped halfway: lock + journal, files already rewritten.
        func interrupted(token: String = "11111111-2222-3333-4444-555555555555", stale: Bool = true) throws {
            try FileManager.default.createDirectory(atPath: app + "/.lock", withIntermediateDirectories: true)
            try token.write(toFile: app + "/.lock/owner", atomically: false, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: app + "/.txn/before", withIntermediateDirectories: true)
            try token.write(toFile: app + "/.txn/token", atomically: false, encoding: .utf8)
            try "state.json\n.env\nfiles/f-0123456789abcdef\n".write(toFile: app + "/.txn/paths", atomically: false, encoding: .utf8)
            try "{\"id\":\"td-test-web\",\"name\":\"before\"}".write(toFile: app + "/.txn/before/0", atomically: false, encoding: .utf8)
            try "A=before\n".write(toFile: app + "/.txn/before/1", atomically: false, encoding: .utf8)
            try "".write(toFile: app + "/.txn/lease", atomically: false, encoding: .utf8)
            try put("state.json", "{\"id\":\"td-test-web\",\"name\":\"half-changed\"}")
            try put(".env", "A=after\n")
            try put("files/f-0123456789abcdef", "new file\n")
            if stale { _ = try sh("touch -t 202001010000 '\(app)/.txn/lease' '\(app)/.lock'") }
        }
        @discardableResult
        func sh(_ script: String) throws -> (code: Int32, out: String) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
            try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        func recover(_ args: String = "") throws -> (code: Int32, out: String) { try sh("sh '\(root)/\(BackendAppsSRV2TxnRecovery.scriptName)' --stale-minutes 30 \(args)") }
        func remove() { try? FileManager.default.removeItem(atPath: root) }
    }

    func testStaleInterruptedChangeIsPutBackExactly() throws {
        let box = try Box(); defer { box.remove() }
        try box.interrupted()
        let result = try box.recover()
        XCTAssertEqual(result.code, 0, result.out)
        XCTAssertTrue(result.out.contains("recovered=td-test-web"))
        XCTAssertEqual(box.read("state.json"), "{\"id\":\"td-test-web\",\"name\":\"before\"}")
        XCTAssertEqual(box.read(".env"), "A=before\n")
        XCTAssertFalse(box.exists("files/f-0123456789abcdef"), "a file the change created is removed")
        XCTAssertFalse(box.exists(".lock")); XCTAssertFalse(box.exists(".txn"))
        XCTAssertTrue(try box.recover().out.isEmpty, "nothing left to do")
    }

    func testALiveChangeIsNeverTouched() throws {
        let box = try Box(); defer { box.remove() }
        try box.interrupted(stale: false)
        let result = try box.recover()
        XCTAssertTrue(result.out.contains("busy=td-test-web"))
        XCTAssertEqual(box.read(".env"), "A=after\n"); XCTAssertTrue(box.exists(".lock")); XCTAssertTrue(box.exists(".txn"))
    }

    func testFinishedLeftoversAndJournalLessLocksAreOnlyTidied() throws {
        let box = try Box(); defer { box.remove() }
        // A journal without a lock: the change finished; only the journal goes.
        try box.interrupted()
        try FileManager.default.removeItem(atPath: box.app + "/.lock")
        XCTAssertEqual(try box.recover().code, 0)
        XCTAssertEqual(box.read(".env"), "A=after\n", "a finished change is never undone")
        XCTAssertFalse(box.exists(".txn"))
        // A stale lock without a journal: release only.
        try FileManager.default.createDirectory(atPath: box.app + "/.lock", withIntermediateDirectories: true)
        try "someone".write(toFile: box.app + "/.lock/owner", atomically: false, encoding: .utf8)
        try box.sh("touch -t 202001010000 '\(box.app)/.lock'")
        let result = try box.recover()
        XCTAssertTrue(result.out.contains("recovered=td-test-web"))
        XCTAssertEqual(box.read(".env"), "A=after\n"); XCTAssertFalse(box.exists(".lock"))
    }

    func testADeployIsResumedNotUndoneAndBadJournalsAreRefused() throws {
        let box = try Box(); defer { box.remove() }
        try box.interrupted()
        try "td-test-deploy-abc".write(toFile: box.app + "/.txn/resume", atomically: false, encoding: .utf8)
        try "#!/bin/sh\necho \"$1 $2\" > \"$(dirname \"$0\")/recipe.called\"\n".write(toFile: box.app + "/recipe.sh", atomically: false, encoding: .utf8)
        try box.sh("touch -t 202001010000 '\(box.app)/.txn/lease'")
        XCTAssertTrue(try box.recover().out.contains("recovered=td-test-web"))
        XCTAssertEqual(box.read("recipe.called"), "recover td-test-deploy-abc\n")
        XCTAssertEqual(box.read(".env"), "A=after\n", "a deploy's settings are not rolled back; the Mac records its result")
        // A journal naming a path outside the app is refused and kept.
        try box.interrupted()
        try "../../etc/passwd\n".write(toFile: box.app + "/.txn/paths", atomically: false, encoding: .utf8)
        try box.sh("touch -t 202001010000 '\(box.app)/.txn/lease'")
        let refused = try box.recover()
        XCTAssertNotEqual(refused.code, 0)
        XCTAssertTrue(box.exists(".lock")); XCTAssertTrue(box.exists(".txn"))
        // A symlinked target is refused.
        try box.interrupted()
        try FileManager.default.removeItem(atPath: box.app + "/.env")
        try FileManager.default.createSymbolicLink(atPath: box.app + "/.env", withDestinationPath: box.root + "/outside")
        try box.sh("touch -t 202001010000 '\(box.app)/.txn/lease'")
        XCTAssertNotEqual(try box.recover().code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.root + "/outside"))
    }
}

actor SRV2Box { var values: [NativeRPCValue] = []; func add(_ value: NativeRPCValue) { values.append(value) } }

/// An in-memory server: just enough of the store's file/lock commands, the
/// router probe (an existing Caddy with server srv0) and the recipe run.
actor SRV2FakeServer {
    var files: [String: Data] = [:]
    var commands: [String] = []
    var recipeResult = "exit=0\n"
    var recipeExit = 0
    var persistenceProbe = "caddy_pid=\n"
    func setPersistenceProbe(_ text: String) { persistenceProbe = text }
    var busyOnce = false
    func setBusyOnce() { busyOnce = true }
    /// Runs once while the next `recipe.sh deploy` is "running"; its answer is kept.
    var duringRecipe: (@Sendable () async -> String)?
    var duringRecipeAnswer: String?
    func setDuringRecipe(_ hook: @escaping @Sendable () async -> String) { duringRecipe = hook }

    init() { files["/var/lib/td-test-apps/router.json"] = Data(#"{"mode":"caddy","owner":"Caddy","caddyAdmin":"127.0.0.1:2019","caddyServerKey":"srv0"}"#.utf8) }
    func put(_ path: String, _ text: String) { files[path] = Data(text.utf8) }
    func remove(_ path: String) { files[path] = nil }
    func text(_ path: String) -> String? { files[path].map { String(decoding: $0, as: UTF8.self) } }
    func setRecipeResult(_ text: String, exit: Int) { recipeResult = text; recipeExit = exit }
    func seedApp(_ id: String, port: Int? = nil, build: String = "dockerfile", extra: [(String, NativeRPCValue)] = []) {
        var source: [(String, NativeRPCValue)] = [("kind", .string("github")), ("repository", .string("asadev/demo")), ("build", .string(build))]
        if let port { source.append(("port", .number(Double(port)))) }
        var record = BackendAppsValidation.object([("id", .string(id)), ("name", .string(id)), ("kind", .string("app")), ("status", .string("stopped")), ("source", BackendAppsValidation.object(source))])
        for (key, value) in extra { record = record.setting(key, value) }
        files["/var/lib/td-test-apps/\(id)/state.json"] = try? record.encodedJSON()
    }

    nonisolated func runtime(addresses: [String] = []) -> BackendAppsRuntime {
        BackendAppsRuntime(execute: { _, command, input, _, _ in try await self.execute(command, input) },
                           serverAddresses: { _ in addresses }, resolveDNS: { _ in addresses },
                           privateNetwork: "td-test-apps", resourcePrefix: "td-test", caddyServerKey: "srv0", stateRoot: "/var/lib/td-test-apps")
    }

    static func unwrap(_ command: String) -> String {
        guard command.hasPrefix("sh -c '"), command.hasSuffix("'") else { return command }
        return String(command.dropFirst(7).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
    static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    func execute(_ command: String, _ input: Data?) async throws -> BackendServersRunResult {
        let script = Self.unwrap(command)
        commands.append(script)
        if script.contains("caddy_pid=") { return .init(code: 0, stdout: persistenceProbe) }
        if script.contains("grep -qxF") && script.contains("echo imported=1") { return .init(code: 0, stdout: "") }
        if script.contains("/config/apps/http/servers") && script.hasPrefix("curl") { return .init(code: 0, stdout: "{\"srv0\":{\"listen\":[\":443\"],\"routes\":[]}}") }
        if script.hasPrefix("# td-journal recover") { return .init(code: 0, stdout: "recovered=td-test-web\n") }
        if script.hasPrefix("# td-journal ") { return .init(code: 0, stdout: "") }
        if let lock = Self.capture(#"mkdir -- '([^']+/\.lock)'"#, script) {
            if busyOnce { busyOnce = false; return .init(code: 73, stdout: "") }
            files[lock[0] + "/owner"] = input ?? Data(); return .init(code: 0, stdout: "")
        }
        if script.contains("rmdir --") { return .init(code: 0, stdout: "") }
        if let target = Self.capture(#"mv -f -- '[^']+' '([^']+)'"#, script) { files[target[0]] = input ?? Data(); return .init(code: 0, stdout: "") }
        if script.contains("recipe.sh') deploy ") || script.contains("recipe.sh' deploy ") {
            if let hook = duringRecipe { duringRecipe = nil; duringRecipeAnswer = await hook() }
            return .init(code: 0, stdout: recipeResult + "exitcode=\(recipeExit)\n")
        }
        if let path = Self.capture(#": > '([^']+\.result)'$"#, script) { files[path[0]] = Data(); return .init(code: 0, stdout: "") }
        if let path = Self.capture(#"test -f '([^']+\.result)' \|\| exit 44; grep -q"#, script) {
            guard let data = files[path[0]] else { return .init(code: 44, stdout: "") }
            return .init(code: String(decoding: data, as: UTF8.self).contains("exit=") ? 0 : 75, stdout: "")
        }
        if script.contains("recipe.sh' ") { return .init(code: 0, stdout: "route=applied\n") }
        if script.contains("-name 'f-*'") { return .init(code: 0, stdout: "") }
        if let path = Self.capture(#"cat -- '([^']+)'$"#, script) {
            guard let data = files[path[0]] else { return .init(code: 44, stdout: "") }
            return .init(code: 0, stdout: String(decoding: data, as: UTF8.self))
        }
        if let path = Self.capture(#"test -f '([^']+\.result)' \|\| exit 44; cat"#, script) {
            guard let data = files[path[0]] else { return .init(code: 44, stdout: "") }
            return .init(code: 0, stdout: String(decoding: data, as: UTF8.self))
        }
        if script.hasPrefix("tail -n 40") || script.hasPrefix("rm -rf") { return .init(code: 0, stdout: "") }
        return .init(code: 0, stdout: "")
    }
}
