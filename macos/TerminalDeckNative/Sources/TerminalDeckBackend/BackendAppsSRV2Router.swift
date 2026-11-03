import Foundation
import TerminalDeckNativeCore

/// SRV2: works with whatever already answers on ports 80/443 (Asad 18:25,
/// "keep Coolify on the same server"). Detection is read-only. Caddy gets
/// routes by @id through its admin API; Traefik gets labels on OUR containers
/// only. Nothing here edits, restarts or replaces another tool's router.
public enum BackendAppsSRV2Router {
    public struct Facts: Codable, Sendable, Equatable {
        public var mode: NativeAppsRouterInfo.Mode
        public var owner: String
        public var caddyAdmin: String?
        public var caddyServerKey: String?
        public var traefikHTTP: String?
        public var traefikHTTPS: String?
        public var traefikResolver: String?
        public var traefikNetwork: String?
        public var detail: String?
        /// How this Caddy keeps API-added addresses across its own restarts:
        /// "resume" (saved state reloads), "caddyfile" (our import line), "json", "container", "unknown".
        public var caddyPersistence: String?
        /// The owner's Caddyfile (caddyfile mode) and our folder of address files next to it.
        public var caddyfile: String?
        public var caddySnippets: String?
        /// True when the owner's Caddyfile already has our one import line.
        public var caddyImported: Bool?
        public var caddyBinary: String?
        public var caddyVersion: String?
        public init(mode: NativeAppsRouterInfo.Mode, owner: String, caddyAdmin: String? = nil, caddyServerKey: String? = nil,
                    traefikHTTP: String? = nil, traefikHTTPS: String? = nil, traefikResolver: String? = nil, traefikNetwork: String? = nil, detail: String? = nil,
                    caddyPersistence: String? = nil, caddyfile: String? = nil, caddySnippets: String? = nil, caddyImported: Bool? = nil,
                    caddyBinary: String? = nil, caddyVersion: String? = nil) {
            self.mode = mode; self.owner = owner; self.caddyAdmin = caddyAdmin; self.caddyServerKey = caddyServerKey
            self.traefikHTTP = traefikHTTP; self.traefikHTTPS = traefikHTTPS; self.traefikResolver = traefikResolver
            self.traefikNetwork = traefikNetwork; self.detail = detail
            self.caddyPersistence = caddyPersistence; self.caddyfile = caddyfile; self.caddySnippets = caddySnippets
            self.caddyImported = caddyImported; self.caddyBinary = caddyBinary; self.caddyVersion = caddyVersion
        }
        /// The exact line the owner approves once (caddyfile mode).
        public var importLine: String? { caddySnippets.map { "import " + $0 + "/*.caddy" } }
        public var persistence: NativeAppsRouterPersistence {
            switch (mode, caddyPersistence) {
            case (.ownCaddy, _), (.caddy, "resume"?):
                return .init(mode: "resume", ready: true, note: "Caddy reloads its saved addresses when it restarts, so your apps keep their addresses.")
            case (.caddy, "caddyfile"?):
                if caddyImported == true {
                    return .init(mode: "caddyfile", ready: true, line: importLine, file: caddyfile, note: "Caddy reads Terminal Deck's address files when it starts, so your apps keep their addresses after a restart.")
                }
                return .init(mode: "caddyfile", ready: false, line: importLine, file: caddyfile,
                             note: "This server's Caddy starts from its own settings file, so it forgets your apps' addresses when it restarts. Adding one line to that file keeps them; nothing else in it changes.")
            case (.caddy, "container"?):
                return .init(mode: "other", ready: false, note: "This server's Caddy runs in a container whose settings Terminal Deck can't safely change. Your apps get their addresses back when they restart, but a Caddy restart on its own can leave them missing until then.")
            case (.caddy, _):
                return .init(mode: "other", ready: false, note: "This server's Caddy starts from a fixed settings file, so a Caddy restart can leave your apps' addresses missing until the apps restart. Terminal Deck re-adds them then.")
            default:
                return .init(mode: "not-caddy", ready: true, note: mode == .traefik ? "Addresses live on your apps' own labels, so they survive any restart." : "There are no web addresses to keep on this server.")
            }
        }
        public var info: NativeAppsRouterInfo {
            switch mode {
            case .ownCaddy:
                return .init(mode: mode, owner: "Terminal Deck", canServeAddresses: true, forceHTTPSOptional: false,
                             note: "Terminal Deck's own address manager serves these addresses with automatic HTTPS.")
            case .caddy:
                return .init(mode: mode, owner: owner, canServeAddresses: true, forceHTTPSOptional: false,
                             note: "This server's existing Caddy serves the addresses. Terminal Deck adds only its own routes and leaves the rest as it is.")
            case .traefik:
                return .init(mode: mode, owner: owner, canServeAddresses: true, forceHTTPSOptional: true,
                             note: "\(owner)'s Traefik serves the addresses. Terminal Deck only labels its own apps; \(owner)'s settings are not changed.")
            case .other:
                return .init(mode: mode, owner: owner, canServeAddresses: false, forceHTTPSOptional: false,
                             note: detail ?? "Ports 80 and 443 are used by \(owner). Apps can still run, but Terminal Deck can't give them web addresses on this server.")
            case .free:
                return .init(mode: mode, owner: "Nothing yet", canServeAddresses: false, forceHTTPSOptional: false,
                             note: "Nothing serves web addresses on this server yet. Set up the server to add Terminal Deck's address manager.")
            case .unknown:
                return .init(mode: mode, owner: "Unknown", canServeAddresses: false, forceHTTPSOptional: false,
                             note: detail ?? "Terminal Deck couldn't tell what serves web addresses on this server.")
            }
        }
    }

    // MARK: the router record (ONE detection: SRV1's server probe writes <stateRoot>/router.json)

    /// Facts from the shared router record, or nil when the server isn't set up yet.
    public static func record(_ data: Data?) -> Facts? {
        guard let data, let facts = try? JSONDecoder().decode(Facts.self, from: data) else { return nil }
        return facts
    }
    public static let notSetUp = Facts(mode: .unknown, owner: "Unknown", detail: "Terminal Deck hasn't checked this server's web addresses yet. Open Server setup to check.")

    /// Read-only: finds the Caddy process that owns the admin port, then how it starts.
    public static func persistenceScript(adminPort: Int) -> String {
        """
        set -u
        pid=$(ss -ltnpH "sport = :\(adminPort)" 2>/dev/null | sed -n 's/.*pid=\\([0-9]*\\).*/\\1/p' | head -n 1)
        [ -n "$pid" ] || { echo caddy_pid=; exit 0; }
        echo "caddy_pid=$pid"
        printf 'caddy_args='; tr '\\000' '\\n' < /proc/$pid/cmdline | base64 | tr -d '\\n'; echo
        echo "caddy_cwd=$(readlink /proc/$pid/cwd)"
        exe=$(readlink /proc/$pid/exe); echo "caddy_exe=$exe"
        if [ "$(readlink /proc/$pid/root)" = / ]; then echo caddy_host=1; echo "caddy_version=$("$exe" version 2>/dev/null | head -n 1)"; fi
        """
    }

    /// How a host Caddy starts: `--resume`, a Caddyfile, a JSON file, or unknown.
    public static func persistence(output: String, prefix: String) -> (mode: String, caddyfile: String?, binary: String?, version: String?) {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") { if let equal = line.firstIndex(of: "=") { values[String(line[..<equal])] = String(line[line.index(after: equal)...]) } }
        guard let pid = values["caddy_pid"], !pid.isEmpty else { return ("unknown", nil, nil, nil) }
        guard values["caddy_host"] == "1" else { return ("container", nil, nil, nil) }
        let args = values["caddy_args"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) } ?? []
        let binary = values["caddy_exe"], version = values["caddy_version"]
        if args.contains("--resume") || args.contains("-resume") { return ("resume", nil, binary, version) }
        func value(_ names: [String]) -> String? {
            for (index, argument) in args.enumerated() {
                for name in names {
                    if argument == name, index + 1 < args.count { return args[index + 1] }
                    if argument.hasPrefix(name + "=") { return String(argument.dropFirst(name.count + 1)) }
                }
            }
            return nil
        }
        let adapter = value(["--adapter", "-adapter"])
        var config = value(["--config", "-config", "-c"]) ?? "Caddyfile"
        if !config.hasPrefix("/") { config = (values["caddy_cwd"] ?? "/") + "/" + config }
        let name = (config as NSString).lastPathComponent.lowercased()
        let isCaddyfile = adapter == "caddyfile" || (adapter == nil && (name.hasPrefix("caddyfile") || name.hasSuffix(".caddyfile")))
        if isCaddyfile, config.range(of: #"^/[A-Za-z0-9/_.@+-]+$"#, options: .regularExpression) != nil, !config.contains("/../") {
            return ("caddyfile", (config as NSString).standardizingPath, binary, version)
        }
        return (name.hasSuffix(".json") || adapter == "json" ? "json" : "unknown", nil, binary, version)
    }

    public static func withPersistence(_ facts: Facts, runtime: BackendAppsRuntime, serverID: String, prefix: String) async throws -> Facts {
        var next = facts
        let port = Int(facts.caddyAdmin?.split(separator: ":").last ?? "") ?? 2019
        let probe = try await runtime.run(serverID, persistenceScript(adminPort: port), timeoutMS: 15_000, maximumBytes: 65_536)
        let found = persistence(output: probe.code == 0 ? probe.stdout : "", prefix: prefix)
        next.caddyPersistence = found.mode; next.caddyBinary = found.binary; next.caddyVersion = found.version
        if found.mode == "caddyfile", let file = found.caddyfile {
            let folder = (file as NSString).deletingLastPathComponent + "/" + prefix
            next.caddyfile = file; next.caddySnippets = folder
            let q = BackendAppsRuntime.quote
            let check = try await runtime.run(serverID, "test -f \(q(file)) || exit 44; grep -qxF \(q("import " + folder + "/*.caddy")) \(q(file)) && test -d \(q(folder)) && echo imported=1; exit 0", timeoutMS: 15_000, maximumBytes: 1024)
            next.caddyImported = check.stdout.contains("imported=1")
        }
        return next
    }

    // MARK: addresses

    public struct AddressPlan: Sendable, Equatable {
        public var serve: [String]
        public var redirects: [(from: String, to: String)]
        public static func == (a: Self, b: Self) -> Bool { a.serve == b.serve && a.redirects.map { $0.from + ">" + $0.to } == b.redirects.map { $0.from + ">" + $0.to } }
    }

    /// The www/apex redirect applies to pairs where both names are listed; the
    /// other addresses are served as they are.
    public static func plan(domains: [String], redirect: NativeAppsOptions.Redirect) -> AddressPlan {
        var serve: [String] = [], redirects: [(from: String, to: String)] = []
        let listed = Set(domains)
        for domain in domains {
            let isWWW = domain.hasPrefix("www.")
            let partner = isWWW ? String(domain.dropFirst(4)) : "www." + domain
            if redirect == .toApex, isWWW, listed.contains(partner) { redirects.append((domain, partner)); continue }
            if redirect == .toWWW, !isWWW, listed.contains(partner) { redirects.append((domain, partner)); continue }
            serve.append(domain)
        }
        return .init(serve: serve, redirects: redirects)
    }

    // MARK: Caddy (routes by @id, never a whole-config write)

    public static let upstreamPlaceholder = "__TD_UPSTREAM__"

    /// Main route + optional redirect route, ids `<routeID>` and `<routeID>-redirect`.
    public static func caddyRoutes(routeID: String, plan: AddressPlan, web: NativeAppsOptions.Web) -> [NativeRPCValue] {
        var handlers: [NativeRPCValue] = []
        if let password = web.password, let hash = password.hash {
            handlers.append(object([("handler", .string("authentication")), ("providers", object([("http_basic", object([
                ("accounts", .array([object([("username", .string(password.username)), ("password", .string(Data(hash.utf8).base64EncodedString()))])])),
                ("hash", object([("algorithm", .string("bcrypt"))])), ("hash_cache", object([])), ("realm", .string("restricted"))
            ]))]))]))
        }
        if web.compression {
            handlers.append(object([("handler", .string("encode")), ("encodings", object([("gzip", object([])), ("zstd", object([]))])),
                                    ("prefer", .array([.string("zstd"), .string("gzip")]))]))
        }
        handlers.append(object([("handler", .string("reverse_proxy")), ("upstreams", .array([object([("dial", .string(upstreamPlaceholder))])]))]))
        var routes = [object([("@id", .string(routeID)), ("match", .array([object([("host", .array(plan.serve.map(NativeRPCValue.string)))])])),
                              ("handle", .array(handlers)), ("terminal", .bool(true))])]
        if !plan.redirects.isEmpty {
            let inner = plan.redirects.map { pair in
                object([("match", .array([object([("host", .array([.string(pair.from)]))])])),
                        ("handle", .array([object([("handler", .string("static_response")), ("status_code", .number(308)),
                                                   ("headers", object([("Location", .array([.string("{http.request.scheme}://" + pair.to + "{http.request.uri}")]))]))])]))])
            }
            routes.append(object([("@id", .string(routeID + "-redirect")),
                                  ("match", .array([object([("host", .array(plan.redirects.map { .string($0.from) }))])])),
                                  ("handle", .array([object([("handler", .string("subroute")), ("routes", .array(inner))])])),
                                  ("terminal", .bool(true))]))
        }
        return routes
    }

    /// Hosts already claimed by a route we don't own. Our ids start with routeID.
    public static func caddyConflicts(servers: NativeRPCValue, routeID: String, hosts: [String]) -> [String] {
        let wanted = Set(hosts.map { $0.lowercased() })
        var claimed = Set<String>()
        func visit(_ route: NativeRPCValue) {
            if let id = route["@id"].string, id == routeID || id.hasPrefix(routeID + "-") { return }
            // Our own address file (Caddyfile mode) marks its sites with this variable.
            if route.compact.contains("\"td_owner\":\"" + routeID + "\"") { return }
            for match in route["match"].elements ?? [] {
                for host in (match["host"].elements ?? []).compactMap(\.string) {
                    let lower = host.lowercased()
                    for want in wanted where lower == want || lower == "*" || (lower.hasPrefix("*.") && want.hasSuffix(String(lower.dropFirst())) && want.split(separator: ".").count == lower.split(separator: ".").count) {
                        claimed.insert(want)
                    }
                }
            }
        }
        for server in servers.fields ?? [] { for route in server.value["routes"].elements ?? [] { visit(route) } }
        return claimed.sorted()
    }

    // MARK: Caddyfile address file (kept across Caddy restarts in caddyfile mode)

    /// The same addresses as `caddyRoutes`, as Caddyfile site blocks for our own
    /// imported file. Each site carries `vars td_owner <routeID>` so it is
    /// recognised as ours after Caddy rebuilds its config from the Caddyfile.
    public static func caddyfileSites(routeID: String, appID: String, plan: AddressPlan, web: NativeAppsOptions.Web, caddyVersion: String?) -> String {
        let modern: Bool = {
            guard let version = caddyVersion, let match = version.range(of: #"v?2\.(\d+)"#, options: .regularExpression) else { return false }
            return (Int(version[match].split(separator: ".")[1]) ?? 0) >= 8
        }()
        var text = "# Terminal Deck app \(appID): its addresses. Generated; Terminal Deck rewrites this file.\n"
        if !plan.serve.isEmpty {
            text += plan.serve.joined(separator: ", ") + " {\n\tvars td_owner \(routeID)\n"
            if let password = web.password, let hash = password.hash {
                text += "\t\(modern ? "basic_auth" : "basicauth") {\n\t\t\(password.username) \(Data(hash.utf8).base64EncodedString())\n\t}\n"
            }
            if web.compression { text += "\tencode zstd gzip\n" }
            text += "\treverse_proxy \(upstreamPlaceholder)\n}\n"
        }
        for pair in plan.redirects {
            text += pair.from + " {\n\tvars td_owner \(routeID)\n\tredir {scheme}://\(pair.to){uri} 308\n}\n"
        }
        return text
    }

    // MARK: Traefik (labels on our container only)

    public static let portPlaceholder = "__TD_PORT__"

    /// Router/middleware names carry a short hash of the settings, so an old and
    /// a new version never declare the same name with different settings.
    public static func traefikLabels(prefix: String, appID: String, plan: AddressPlan, web: NativeAppsOptions.Web, facts: Facts) -> [(String, String)] {
        guard facts.mode == .traefik, let http = facts.traefikHTTP, let https = facts.traefikHTTPS, let network = facts.traefikNetwork else { return [] }
        let fingerprint = ([prefix, appID, http, https, facts.traefikResolver ?? "", network, web.redirect.rawValue, String(web.forceHTTPS), String(web.compression),
                            web.password?.username ?? "", web.password?.hash ?? ""] + plan.serve + plan.redirects.map { $0.from + ">" + $0.to }).joined(separator: "\n")
        let key = prefix + "-" + appID + "-" + String(BackendAppsSRV2Recipe.sha256Hex(fingerprint).prefix(8))
        func rule(_ hosts: [String]) -> String { hosts.map { "Host(`" + $0 + "`)" }.joined(separator: " || ") }
        var labels: [(String, String)] = [("traefik.enable", "true"), ("traefik.docker.network", network),
                                          ("traefik.http.services.\(key).loadbalancer.server.port", portPlaceholder)]
        var middlewares: [String] = []
        if let password = web.password, let hash = password.hash {
            labels.append(("traefik.http.middlewares.\(key)-auth.basicauth.users", password.username + ":" + hash))
            middlewares.append(key + "-auth")
        }
        if web.compression {
            labels.append(("traefik.http.middlewares.\(key)-gzip.compress", "true"))
            middlewares.append(key + "-gzip")
        }
        if web.forceHTTPS {
            labels += [("traefik.http.middlewares.\(key)-https.redirectscheme.scheme", "https"),
                       ("traefik.http.middlewares.\(key)-https.redirectscheme.permanent", "true")]
        }
        func routers(_ name: String, hosts: [String], middlewares: [String]) {
            guard !hosts.isEmpty else { return }
            labels += [("traefik.http.routers.\(name)-https.rule", rule(hosts)), ("traefik.http.routers.\(name)-https.entrypoints", https),
                       ("traefik.http.routers.\(name)-https.tls", "true"), ("traefik.http.routers.\(name)-https.service", key)]
            if let resolver = facts.traefikResolver { labels.append(("traefik.http.routers.\(name)-https.tls.certresolver", resolver)) }
            if !middlewares.isEmpty { labels.append(("traefik.http.routers.\(name)-https.middlewares", middlewares.joined(separator: ","))) }
            labels += [("traefik.http.routers.\(name)-http.rule", rule(hosts)), ("traefik.http.routers.\(name)-http.entrypoints", http),
                       ("traefik.http.routers.\(name)-http.service", key)]
            let plain = web.forceHTTPS ? [key + "-https"] : middlewares
            if !plain.isEmpty { labels.append(("traefik.http.routers.\(name)-http.middlewares", plain.joined(separator: ","))) }
        }
        routers(key, hosts: plan.serve, middlewares: middlewares)
        if !plan.redirects.isEmpty, let first = plan.redirects.first {
            let toWWW = first.to.hasPrefix("www.")
            let scheme = web.forceHTTPS ? "https" : "${1}"
            labels += [("traefik.http.middlewares.\(key)-canonical.redirectregex.regex", toWWW ? "^(https?)://([^/:]+)(.*)$" : "^(https?)://www\\.([^/:]+)(.*)$"),
                       ("traefik.http.middlewares.\(key)-canonical.redirectregex.replacement", scheme + (toWWW ? "://www.${2}${3}" : "://${2}${3}")),
                       ("traefik.http.middlewares.\(key)-canonical.redirectregex.permanent", "true")]
            routers(key + "-canonical", hosts: plan.redirects.map(\.from), middlewares: [key + "-canonical"])
            // The plain-http redirect router goes straight to the final address.
            if web.forceHTTPS, let index = labels.firstIndex(where: { $0.0 == "traefik.http.routers.\(key)-canonical-http.middlewares" }) {
                labels[index].1 = key + "-canonical"
            }
        }
        return labels
    }

    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
}
