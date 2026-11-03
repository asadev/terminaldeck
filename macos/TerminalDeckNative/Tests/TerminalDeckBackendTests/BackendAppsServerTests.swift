import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// SRV1 (server-side setup + unattended duties). READY SRV1 gate; live-server test remains separately opt-in.
@Suite("SRV1 server setup, router coexistence, settings and channels")
struct BackendAppsServerTests {
    actor Calls { var commands: [String] = []; func add(_ c: String) { commands.append(c) } }

    static func runtime(_ calls: Calls, stdout: String = "{}", code: Int = 0) -> BackendAppsRuntime {
        BackendAppsRuntime(execute: { _, command, _, _, _ in
            await calls.add(command)
            return BackendServersRunResult(code: code, stdout: stdout)
        })
    }
    static func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    static let coolifyTraefik = #"""
    [{"Name":"/coolify-proxy","Config":{"Image":"traefik:v3.1","Labels":{"coolify.managed":"true","coolify.proxy":"true"},
      "Cmd":["--ping=true","--entrypoints.http.address=:80","--entrypoints.https.address=:443","--providers.docker=true",
             "--providers.docker.exposedbydefault=false","--certificatesresolvers.letsencrypt.acme.httpchallenge=true"]},
      "NetworkSettings":{"Networks":{"coolify":{"IPAddress":"10.0.1.2"}}}}]
    """#
    static let existingCaddy = #"{"apps":{"http":{"servers":{"srv0":{"listen":[":443"],"routes":[{"match":[{"host":["demo.example"]}],"terminal":true}]}}}}}"#

    @Test func probeFindsFreePortsAsNoRouter() {
        let facts = BackendAppsServerProbe.parse("uid=0\nsystemd=1\nos=ubuntu\narch=x86_64\nhostname=box\ndocker=29.1.3\nipv4=10.0.0.5\nipv4=203.0.113.9\n")
        #expect(facts.router == .none)
        #expect(facts.administrator && facts.supported)
        #expect(facts.publicIPv4 == "203.0.113.9")
    }

    @Test func probeUsesExistingHostCaddyByItsHttpsServerKey() {
        let output = "uid=0\nsystemd=1\narch=x86_64\nlisten=LISTEN 0 4096 *:443 *:* users:((\"caddy\",pid=776685,fd=7))\ncaddyconfig=\(Self.b64(Self.existingCaddy))\ncaddyresume=0\n"
        let facts = BackendAppsServerProbe.parse(output)
        #expect(facts.router == .caddy)
        #expect(facts.caddyServerKey == "srv0")
        #expect(facts.caddyPersists == false)
        #expect(facts.routerSummary.contains("never changes the rest"))
    }

    @Test func probeRecognisesCoolifyTraefikAndNeverPlansASecondRouter() throws {
        let output = "uid=1000\nsudo=1\nsystemd=1\narch=aarch64\nlisten=LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:((\"docker-proxy\",pid=1,fd=4))\npublisher=\(Self.b64(Self.coolifyTraefik))\n"
        let facts = BackendAppsServerProbe.parse(output)
        #expect(facts.router == .traefik)
        #expect(facts.traefik == BackendAppsServerTraefik(container: "coolify-proxy", network: "coolify", httpEntry: "http", httpsEntry: "https", resolver: "letsencrypt", coolify: true))
        let layout = try BackendAppsServerLayout()
        let plan = BackendAppsServerSetup.plan(facts, layout: layout, ipv4: "203.0.113.9")
        let titles = (plan["steps"].elements ?? []).compactMap { $0["title"].string }
        #expect(titles.contains("Use the existing Traefik"))
        #expect(!titles.contains("Start the address manager"))
        let payload = try BackendAppsServerSetup.install(facts, layout: layout, ipv4: "203.0.113.9", now: 1)
        #expect(!payload.contains("caddy run --resume"))
        #expect(payload.contains("--network 'coolify'"))
        #expect(payload.contains("traefik.http.routers.terminaldeck--hooks.rule=Host(`hooks.terminaldeck.203.0.113.9.sslip.io`)"))
        #expect(payload.contains("traefik.http.routers.terminaldeck--hooks.tls.certresolver=letsencrypt"))
        let record = try NativeRPCValue.parseJSON(BackendAppsServerSetup.routerRecord(facts))
        #expect(record["mode"].string == "traefik" && record["traefikNetwork"].string == "coolify" && record["traefikHTTPS"].string == "https" && record["owner"].string == "Coolify")
        // The other tool's router is only named in our own settings record, never in a command.
        let mentions = payload.split(separator: "\n").filter { $0.contains("coolify-proxy") }
        #expect(mentions.allSatisfy { $0.hasPrefix("printf '%s\\n'") })
    }

    @Test func probeLeavesOtherWebServersAlone() throws {
        let facts = BackendAppsServerProbe.parse("uid=0\nsystemd=1\narch=x86_64\nlisten=LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:((\"nginx\",pid=9,fd=6))\n")
        #expect(facts.router == .other && facts.routerName == "nginx")
        let payload = try BackendAppsServerSetup.install(facts, layout: try BackendAppsServerLayout(), ipv4: "203.0.113.9", now: 1)
        #expect(!payload.contains("docker run -d --name 'terminaldeck-caddy'"))
        #expect(!payload.contains("2019/config/apps/http/servers"))
    }

    @Test func installUsesExistingCaddyByIdOnlyAndOursWhenPortsAreFree() throws {
        let layout = try BackendAppsServerLayout()
        var caddy = BackendAppsServerFacts(); caddy.uid = 0; caddy.systemd = true; caddy.arch = "x86_64"; caddy.router = .caddy; caddy.caddyServerKey = "srv0"
        let existing = try BackendAppsServerSetup.install(caddy, layout: layout, ipv4: "203.0.113.9", now: 1)
        #expect(existing.contains("http://127.0.0.1:2019/config/apps/http/servers/srv0/routes/0"))
        #expect(existing.contains("/id/terminaldeck--hooks"))
        #expect(!existing.contains("caddy run --resume"))
        #expect(!existing.contains("POST /load") && !existing.contains("2019/load"))
        var free = caddy; free.router = .none; free.caddyServerKey = nil
        let ours = try BackendAppsServerSetup.install(free, layout: layout, ipv4: "203.0.113.9", now: 1)
        #expect(ours.contains("docker run -d --name 'terminaldeck-caddy' --label io.terminaldeck.managed=true"))
        #expect(ours.contains("/var/lib/caddy/terminaldeck/config"))
        for text in [existing, ours] {
            #expect(!text.contains("system prune"))
            #expect(!text.contains("image prune"))
            #expect(!text.contains("volume prune"))
            #expect(!text.contains("container prune"))
        }
    }

    @Test func cleanupScriptIsLabelScopedAndOptInForSharedThings() throws {
        let script = BackendAppsServerScripts.cleanup(try BackendAppsServerLayout())
        #expect(!script.contains("system prune") && !script.contains("image prune") && !script.contains("volume prune"))
        #expect(script.contains(#"--filter dangling=true --filter "label=$TD_LABEL""#))
        #expect(script.contains(#"if [ "$cache" = true ]; then"#))
        #expect(script.contains("docker builder prune -f --filter until=168h"))
        // U121 (#581): Docker keeps one build cache for the whole server, and the option says so.
        let tools = BackendAppsServerTools.definitions()
        for channel in ["apps:server:cleanup:save", "apps:server:cleanup:run", "apps:server:cleanup:read"] {
            #expect(tools.first { $0.channel == channel }?.description.contains("every tool's week-old build cache") == true, "\(channel)")
        }
    }

    @Test func removeTouchesOnlyMarkedFilesAndKeepsApps() throws {
        let layout = try BackendAppsServerLayout(prefix: "td-test", stateRoot: "/var/lib/td-test-apps", network: "td-test-apps")
        let script = BackendAppsServerSetup.remove(layout, addressManager: false)
        #expect(script.contains(#"grep -qF "$MARK""#))
        #expect(!script.contains("/var/lib/td-test-apps"))
        #expect(script.contains("/opt/td-test-terminaldeck"))
        #expect(!script.contains("rm -rf -- \"/\""))
        #expect(!script.contains("-backup."))
    }

    @Test func testLayoutNamesEverythingTdTest() throws {
        let layout = try BackendAppsServerLayout(prefix: "td-test", stateRoot: "/var/lib/td-test-apps", network: "td-test-apps")
        for name in [layout.base, layout.caddyContainer, layout.hooksForwarder, layout.hooksRouteID, layout.jobUnit(app: "web", job: "n")] + layout.coreUnitNames {
            #expect(name.hasPrefix("td-test"), "\(name)")
        }
        #expect(layout.opt == "/opt/td-test-terminaldeck" && layout.data == "/var/lib/td-test-terminaldeck-server")
        #expect(layout.hooksHost(ipv4: "178.105.239.176") == "td-test-hooks.178-105-239-176.sslip.io")
        #expect(throws: NativeRPCError.self) { try BackendAppsServerLayout(prefix: "td-test", stateRoot: "/var/lib/terminaldeck/other") }
    }

    @Test func alertSettingsValidateAndNeverEchoSecrets() throws {
        let saved = try BackendAppsServerSettings.alerts(.object([
            .init("channels", .array([
                .object([.init("id", .string("phone")), .init("kind", .string("telegram")), .init("botToken", .string(BackendAppsServerSettings.mask)), .init("chatId", .string("42"))]),
                .object([.init("id", .string("ops")), .init("kind", .string("webhook")), .init("url", .string("https://example.test/h")), .init("secret", .string("supersecretvalue"))])
            ])),
            .init("thresholds", .object([.init("diskPercent", .number(90))])),
            .init("watch", .object([.init("containers", .array([.string("coolify-db")]))]))
        ]))
        #expect(saved["channels"].elements?[0].has("botToken") == false, "A mask must keep the saved token, not replace it")
        #expect(saved["thresholds"]["diskPercent"].number == 90)
        #expect(throws: NativeRPCError.self) {
            try BackendAppsServerSettings.alerts(.object([.init("channels", .array([.object([.init("id", .string("x")), .init("kind", .string("webhook")), .init("url", .string("http://example.test"))])]))]))
        }
        #expect(throws: NativeRPCError.self) {
            try BackendAppsServerSettings.alerts(.object([.init("channels", .array([.object([.init("id", .string("x")), .init("kind", .string("telegram")), .init("botToken", .string("nope")), .init("chatId", .string("1"))])]))]))
        }
        let masked = BackendAppsServerSettings.publicAlerts(.object([.init("channels", .array([.object([.init("id", .string("ops")), .init("kind", .string("webhook")), .init("secret", .string("set"))])]))]))
        #expect(masked["channels"].elements?[0]["secret"].string == BackendAppsServerSettings.mask)
        #expect(masked["channels"].elements?[0]["hasSecret"].bool == true)
    }

    @Test func jobsAndCleanupSettingsAreBounded() throws {
        let job = try BackendAppsServerSettings.job(.object([.init("jobId", .string("nightly")), .init("schedule", .string("*-*-* 02:30:00")), .init("command", .string("php artisan schedule:run"))]))
        #expect(job["timeoutSeconds"].number == 600 && job["enabled"].bool == true)
        #expect(throws: NativeRPCError.self) { try BackendAppsServerSettings.job(.object([.init("jobId", .string("x")), .init("schedule", .string("daily; rm -rf /")), .init("command", .string("true"))])) }
        #expect(throws: NativeRPCError.self) { try BackendAppsServerSettings.job(.object([.init("jobId", .string("x")), .init("schedule", .string("daily")), .init("command", .string("a\nb"))])) }
        let cleanup = try BackendAppsServerSettings.cleanup(.object([]))
        #expect(cleanup["removeOldVersions"].bool == false && cleanup["buildCache"].bool == false && cleanup["unnamedStorage"].bool == false)
        let units = BackendAppsServerScripts.jobUnits(try BackendAppsServerLayout(), app: "web", job: "nightly", schedule: "daily")
        #expect(units.timer.contains("OnCalendar=daily") && units.service.contains("td-job web nightly"))
    }

    @Test func writesNeedApprovalBeforeAnyServerIO() async throws {
        let calls = Calls()
        let channels = BackendAppsServerChannels(service: try BackendAppsServerService(runtime: Self.runtime(calls)))
        let native = NativeRPCContext(caller: .nativeApp, ownerID: "window")
        for channel in BackendAppsServerChannels.writeChannels.sorted() {
            var request = NativeRPCValue.object([.init("serverId", .string("s1"))])
            if BackendAppsServerChannels.needsApp(channel) { request = request.setting("appId", .string("web")) }
            if channel.hasSuffix(":remove") && channel.contains("setup") { request = request.setting("confirmation", .string("s1")) }
            if channel.contains(":jobs:") { request = request.setting("jobId", .string("nightly")) }
            if channel.hasSuffix("jobs:save") { request = request.setting("schedule", .string("daily")).setting("command", .string("true")) }
            if channel.hasSuffix("autodeploy:apply") { request = request.setting("enabled", .bool(true)) }
            await #expect(throws: NativeRPCError.self, "\(channel)") { _ = try await channels.invoke(channel, request: request, context: native) }
        }
        #expect(await calls.commands.isEmpty)
    }

    @Test func secretChannelsAreNativeWindowOnlyAndHaveNoTool() async throws {
        let calls = Calls()
        let channels = BackendAppsServerChannels(service: try BackendAppsServerService(runtime: Self.runtime(calls)), authorize: { _, _ in })
        let ai = NativeRPCContext(caller: .internalEngine, ownerID: "agent")
        for channel in BackendAppsServerChannels.nativeOnlyChannels {
            do { _ = try await channels.invoke(channel, request: .object([.init("serverId", .string("s1")), .init("appId", .string("web"))]), context: ai); Issue.record("\(channel) ran for an agent") }
            catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        #expect(await calls.commands.isEmpty)
        let tools = BackendAppsServerTools.definitions().map(\.channel)
        #expect(Set(tools).isDisjoint(with: BackendAppsServerChannels.nativeOnlyChannels))
        #expect(Set(tools).isSubset(of: BackendAppsServerChannels.invokeChannels))
        for definition in BackendAppsServerTools.definitions() {
            #expect((definition.tier == .read) == BackendAppsServerChannels.readChannels.contains(definition.channel), "\(definition.id)")
            _ = try definition.specification()
        }
    }

    @Test func approvalPreviewCarriesNoSecrets() async throws {
        actor Seen { var previews: [String] = []; func add(_ p: String) { previews.append(p) } }
        let seen = Seen(), calls = Calls()
        let channels = BackendAppsServerChannels(service: try BackendAppsServerService(runtime: Self.runtime(calls)), authorize: { action, _ in
            await seen.add(action.preview.compact)
            throw NativeRPCError(code: "approval-denied", message: "no")
        })
        let request = NativeRPCValue.object([.init("serverId", .string("s1")), .init("channels", .array([
            .object([.init("id", .string("phone")), .init("kind", .string("telegram")), .init("botToken", .string("123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef12")), .init("chatId", .string("42"))])
        ]))])
        await #expect(throws: NativeRPCError.self) { _ = try await channels.invoke("apps:server:alerts:save", request: request, context: NativeRPCContext(caller: .nativeApp, ownerID: "w")) }
        let preview = await seen.previews.joined()
        #expect(preview.contains("telegram") && !preview.contains("ABCDEFGHIJ"))
        #expect(await calls.commands.isEmpty)
    }

    /// U87 (#580): server-started deploys run only the app's recipe, so turning automatic
    /// deploys on (or Deploy on the server) writes it first; a failure there changes nothing.
    @Test func serverDeploysArePreparedBeforeTheyAreTurnedOn() async throws {
        actor Prepared { var apps: [String] = []; func add(_ app: String) { apps.append(app) } }
        let calls = Calls(), prepared = Prepared()
        let channels = BackendAppsServerChannels(service: try BackendAppsServerService(runtime: Self.runtime(calls)), authorize: { _, _ in },
                                                 prepareDeploys: { server, app in await prepared.add(server + "/" + app) })
        let native = NativeRPCContext(caller: .nativeApp, ownerID: "w")
        let request = NativeRPCValue.object([.init("serverId", .string("s1")), .init("appId", .string("web"))])
        _ = try await channels.invoke("apps:server:autodeploy:apply", request: request.setting("enabled", .bool(false)), context: native)
        #expect(await prepared.apps.isEmpty, "turning them off needs no recipe")
        _ = try await channels.invoke("apps:server:autodeploy:apply", request: request.setting("enabled", .bool(true)), context: native)
        _ = try await channels.invoke("apps:server:deploy:run", request: request, context: native)
        #expect(await prepared.apps == ["s1/web", "s1/web"])

        let untouched = Calls()
        let failing = BackendAppsServerChannels(service: try BackendAppsServerService(runtime: Self.runtime(untouched)), authorize: { _, _ in },
                                                prepareDeploys: { _, _ in throw NativeRPCError(code: "state-failed", message: "no recipe") })
        await #expect(throws: NativeRPCError.self) { _ = try await failing.invoke("apps:server:autodeploy:apply", request: request.setting("enabled", .bool(true)), context: native) }
        #expect(await untouched.commands.isEmpty, "automatic deploys stay off when the recipe could not be written")
    }

    @Test func statusRunsOnlyTheReadOnlyProbeWhenNotInstalled() async throws {
        let calls = Calls()
        let service = try BackendAppsServerService(runtime: Self.runtime(calls, stdout: "uid=0\nsystemd=1\narch=x86_64\n"))
        let status = try await service.status(serverID: "s1")
        #expect(status["router"].string == "none" && status["installedVersion"] == .null)
        let commands = await calls.commands
        #expect(commands.count == 1)
        for word in ["docker run", "systemctl enable", "install -m", "rm -", "mkdir", "curl -X", "PATCH", "PUT"] {
            #expect(!commands[0].contains(word), "probe must not change the server: \(word)")
        }
    }
}
