import Foundation
import TerminalDeckNativeCore

/// Where Terminal Deck's own server helpers live (SRV1). Every name derives
/// from the Apps runtime prefix, so the live harness's `td-test` layout never
/// touches production names. `fsRoot` exists only for hermetic local tests.
public struct BackendAppsServerLayout: Sendable, Equatable {
    public static let version = "1"
    public static let marker = "# Managed by Terminal Deck server helpers"
    /// The ownership labels the Apps engine already puts on everything it creates.
    public static let managedLabel = "io.terminaldeck.managed"
    public static let appLabel = "io.terminaldeck.app"
    public let prefix: String, stateRoot: String, network: String, fsRoot: String

    public init(prefix: String = "terminaldeck", stateRoot: String = BackendAppsStore.root,
                network: String = "terminaldeck-apps", fsRoot: String = "") throws {
        guard prefix.range(of: #"\A[a-z][a-z0-9-]{0,23}\z"#, options: .regularExpression) != nil,
              stateRoot == BackendAppsStore.root || stateRoot == "/var/lib/" + prefix + "-apps",
              network.range(of: #"\A[a-z][a-z0-9_.-]{0,62}\z"#, options: .regularExpression) != nil,
              fsRoot.isEmpty || fsRoot.range(of: #"\A/[A-Za-z0-9/_.-]{1,512}\z"#, options: .regularExpression) != nil,
              !fsRoot.contains("..") else {
            throw NativeRPCError.invalidArguments("The server helper layout is invalid.")
        }
        self.prefix = prefix; self.stateRoot = stateRoot; self.network = network; self.fsRoot = fsRoot
    }
    public init(runtime: BackendAppsRuntime, fsRoot: String = "") throws {
        try self.init(prefix: runtime.resourcePrefix, stateRoot: runtime.stateRoot, network: runtime.privateNetwork, fsRoot: fsRoot)
    }

    public var isTest: Bool { prefix != "terminaldeck" }
    /// `terminaldeck` in production, `td-test-terminaldeck` for live tests.
    public var base: String { isTest ? prefix + "-terminaldeck" : "terminaldeck" }
    public var opt: String { fsRoot + "/opt/" + base }
    public var bin: String { opt + "/bin" }
    public var etc: String { fsRoot + "/etc/" + base }
    public var data: String { fsRoot + "/var/lib/" + base + "-server" }
    public var state: String { fsRoot + stateRoot }
    public var units: String { fsRoot + "/etc/systemd/system" }
    public var hookPort: Int { isTest ? 47_229 : 47_219 }
    public var caddyContainer: String { base + "-caddy" }
    /// Same folders as APE's host install, so its default autosave path holds.
    public var ourCaddyRoot: String { isTest ? data + "/caddy" : fsRoot + "/var/lib/caddy/terminaldeck" }
    public var caddyImage: String { "caddy:2" }
    public var hooksForwarder: String { base + "-hooks" }
    /// An app ID cannot start with a dash, so this never equals an app route.
    public var hooksRouteID: String { prefix + "--hooks" }
    /// APE's Caddy configuration lock, shared so both writers serialise.
    public var caddyLock: String { fsRoot + "/var/lib/" + prefix + "-caddy-lock" }
    public func unit(_ name: String) -> String { base + "-" + name }
    public func jobUnit(app: String, job: String) -> String { prefix + "-" + app + "_job_" + job }
    public func imageRepository(_ app: String) -> String { isTest ? prefix + "-" + app : "terminaldeck/" + app }
    public func hooksHost(ipv4: String) -> String {
        isTest ? prefix + "-hooks." + ipv4.replacingOccurrences(of: ".", with: "-") + ".sslip.io"
               : "hooks.terminaldeck." + ipv4 + ".sslip.io"
    }
    public func defaultDomain(app: String, ipv4: String) -> String {
        isTest ? (app.hasPrefix(prefix + "-") ? app : prefix + "-" + app) + "." + ipv4.replacingOccurrences(of: ".", with: "-") + ".sslip.io"
               : app + "." + ipv4 + ".sslip.io"
    }
    public var helperNames: [String] { ["td-lib.sh", "td-notify", "td-watch", "td-check", "td-cleanup", "td-job", "td-deploy", "td-hook"] }
    public var coreUnitNames: [String] {
        [unit("watch.service"), unit("check.service"), unit("check.timer"), unit("cleanup.service"), unit("cleanup.timer"),
         unit("hook.socket"), unit("hook@.service"), unit("deploy@.service")]
    }
}

/// What 80/443 already belong to. Terminal Deck never installs a second router.
public enum BackendAppsServerRouter: String, Sendable, Equatable {
    case none, ours, caddy, traefik, other
}

public struct BackendAppsServerTraefik: Sendable, Equatable {
    public let container: String, network: String, httpEntry: String, httpsEntry: String, resolver: String?, coolify: Bool
}

/// One read-only look at the server. Nothing here changes the server.
public struct BackendAppsServerFacts: Sendable, Equatable {
    public var uid = -1, sudo = false, systemd = false
    public var os = "unknown", arch = "unknown", hostname = ""
    public var docker: String?
    public var installed: String?
    public var router: BackendAppsServerRouter = .none
    public var routerName = ""
    public var caddyServerKey: String?
    public var caddyPersists = true
    public var caddyAutosave: String?
    public var traefik: BackendAppsServerTraefik?
    public var ipv4: [String] = []
    public var diskPercent: Int?
    public var memoryMB: Int?
    public var administrator: Bool { uid == 0 || sudo }
    public var supported: Bool { systemd && ["x86_64", "aarch64", "arm64"].contains(arch) }
    public var publicIPv4: String? { ipv4.first(where: BackendAppsServerFacts.isPublicIPv4) }

    public var value: NativeRPCValue {
        var fields: [(String, NativeRPCValue)] = [
            ("hostname", .string(hostname)), ("administrator", .bool(administrator)), ("needsSudo", .bool(uid != 0 && sudo)),
            ("systemd", .bool(systemd)), ("os", .string(os)), ("arch", .string(arch)), ("supported", .bool(supported)),
            ("docker", docker.map(NativeRPCValue.string) ?? .null), ("installedVersion", installed.map(NativeRPCValue.string) ?? .null),
            ("helperVersion", .string(BackendAppsServerLayout.version)),
            ("router", .string(router.rawValue)), ("routerName", .string(routerName)),
            ("routerSummary", .string(routerSummary)), ("publicIPv4", publicIPv4.map(NativeRPCValue.string) ?? .null),
            ("diskPercent", diskPercent.map { .number(Double($0)) } ?? .null), ("memoryMB", memoryMB.map { .number(Double($0)) } ?? .null)
        ]
        if router == .caddy { fields.append(("caddyKeepsApiRoutes", .bool(caddyPersists))) }
        if let traefik { fields.append(("traefik", BackendAppsValidation.object([("container", .string(traefik.container)), ("network", .string(traefik.network)), ("coolify", .bool(traefik.coolify))]))) }
        return BackendAppsValidation.object(fields)
    }

    public var routerSummary: String {
        switch router {
        case .none: return "Ports 80 and 443 are free. Terminal Deck will start its own address manager (Caddy) there."
        case .ours: return "Terminal Deck's own address manager (Caddy) already serves ports 80 and 443."
        case .caddy: return "An existing Caddy serves ports 80 and 443. Terminal Deck adds only its own addresses to it and never changes the rest."
            + (caddyPersists ? "" : " Note: this Caddy reloads its own file on restart, so Terminal Deck's addresses must be re-applied after a Caddy restart.")
        case .traefik: return (traefik?.coolify == true ? "Coolify's" : "An existing") + " Traefik serves ports 80 and 443. Terminal Deck uses it through labels on its own apps and never changes Traefik."
        case .other: return "\(routerName.isEmpty ? "Another program" : routerName) uses ports 80 and 443. Terminal Deck cannot add web addresses through it, so it installs no address manager. Terminals, Docker and scheduled duties still work."
        }
    }

    static func isPublicIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }), String(parts.map(String.init).joined(separator: ".")) == text else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
        case (172, 16...31), (100, 64...127): return false
        default: return parts[0] < 224
        }
    }
}

/// The read-only probe. It needs no jq; JSON blobs travel base64 encoded and
/// are parsed here. Every command is guarded so a missing tool is a fact.
public enum BackendAppsServerProbe {
    public static func script(_ layout: BackendAppsServerLayout) -> String {
        let q = BackendAppsRuntime.quote
        return #"""
        set +e
        u=$(id -u); echo "uid=$u"
        S=''
        if [ "$u" != 0 ]; then if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then echo sudo=1; S='sudo -n'; else echo sudo=0; fi; fi
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then echo systemd=1; else echo systemd=0; fi
        if [ -r /etc/os-release ]; then . /etc/os-release; echo "os=${ID:-unknown}"; fi
        echo "arch=$(uname -m)"
        echo "hostname=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-' | cut -c1-64)"
        if command -v docker >/dev/null 2>&1; then echo "docker=$($S docker version --format '{{.Server.Version}}' 2>/dev/null | tr -cd '0-9A-Za-z.+-' | cut -c1-32)"; fi
        if [ -f \#(q(layout.opt + "/VERSION")) ]; then echo "installed=$(tr -cd '0-9A-Za-z.-' < \#(q(layout.opt + "/VERSION")) | cut -c1-16)"; fi
        $S ss -ltnpH 2>/dev/null | awk '$4 ~ /:(80|443)$/' | head -n 8 | while IFS= read -r l; do echo "listen=$l"; done
        if command -v docker >/dev/null 2>&1; then
          state=$($S docker inspect -f '{{.State.Running}} {{index .Config.Labels "\#(BackendAppsServerLayout.managedLabel)"}}' \#(q(layout.caddyContainer)) 2>/dev/null)
          [ -n "$state" ] && echo "ourcaddy=$state"
          $S docker ps --format '{{.ID}} {{.Ports}}' 2>/dev/null | grep -E ':(80|443)->' | head -n 3 | while read -r id rest; do
            echo "publisher=$($S docker inspect "$id" 2>/dev/null | head -c 200000 | base64 | tr -d '\n')"
          done
        fi
        cfg=$(curl -s --max-time 3 http://127.0.0.1:2019/config/ 2>/dev/null | head -c 1000000 | base64 | tr -d '\n')
        [ -n "$cfg" ] && echo "caddyconfig=$cfg"
        if systemctl cat caddy.service >/dev/null 2>&1; then
          if systemctl show -p ExecStart --value caddy.service 2>/dev/null | grep -q -- '--resume'; then echo caddyresume=1; else echo caddyresume=0; fi
          home=$(getent passwd caddy 2>/dev/null | cut -d: -f6)
          [ -n "$home" ] && [ -f "$home/.config/caddy/autosave.json" ] && echo "caddyautosave=$home/.config/caddy/autosave.json"
        fi
        if command -v ip >/dev/null 2>&1; then ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print "ipv4=" a[1]}' | head -n 8; fi
        df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print "disk=" $5}'
        awk '/^MemTotal:/{print "memory=" int($2/1024)}' /proc/meminfo 2>/dev/null
        exit 0
        """#
    }

    public static func parse(_ output: String) -> BackendAppsServerFacts {
        var facts = BackendAppsServerFacts()
        var listeners: [String] = [], publishers: [NativeRPCValue] = []
        var caddyConfig: NativeRPCValue?, ourCaddy: String?
        for line in output.split(separator: "\n").prefix(400) {
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal]), value = String(line[line.index(after: equal)...])
            switch key {
            case "uid": facts.uid = Int(value) ?? -1
            case "sudo": facts.sudo = value == "1"
            case "systemd": facts.systemd = value == "1"
            case "os": facts.os = String(value.prefix(32))
            case "arch": facts.arch = String(value.prefix(16))
            case "hostname": facts.hostname = String(value.prefix(64))
            case "docker": facts.docker = value.isEmpty ? nil : String(value.prefix(32))
            case "installed": facts.installed = value.isEmpty ? nil : String(value.prefix(16))
            case "listen": listeners.append(value)
            case "ourcaddy": ourCaddy = value
            case "publisher": if let data = Data(base64Encoded: value), let parsed = try? NativeRPCValue.parseJSON(data) { publishers.append(parsed.elements?.first ?? parsed) }
            case "caddyconfig": if let data = Data(base64Encoded: value) { caddyConfig = try? NativeRPCValue.parseJSON(data) }
            case "caddyresume": facts.caddyPersists = value == "1"
            case "caddyautosave": facts.caddyAutosave = value.hasPrefix("/") && !value.contains("..") ? String(value.prefix(512)) : nil
            case "ipv4": if facts.ipv4.count < 8 { facts.ipv4.append(value) }
            case "disk": facts.diskPercent = Int(value)
            case "memory": facts.memoryMB = Int(value)
            default: continue
            }
        }
        classify(&facts, listeners: listeners, publishers: publishers, caddyConfig: caddyConfig, ourCaddy: ourCaddy)
        return facts
    }

    static func classify(_ facts: inout BackendAppsServerFacts, listeners: [String], publishers: [NativeRPCValue],
                         caddyConfig: NativeRPCValue?, ourCaddy: String?) {
        if ourCaddy == "true true" { facts.router = .ours; facts.routerName = "Terminal Deck Caddy"; return }
        let processes = listeners.compactMap { line -> String? in
            guard let start = line.range(of: "((\"") else { return nil }
            let rest = line[start.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        if listeners.isEmpty && publishers.isEmpty { facts.router = .none; return }
        if let publisher = publishers.first {
            let image = (publisher["Config"]["Image"].string ?? "").lowercased()
            let name = String((publisher["Name"].string ?? "").drop(while: { $0 == "/" }))
            facts.routerName = name.isEmpty ? image : name
            if image.contains("traefik"), let traefik = traefik(publisher, name: name) {
                facts.router = .traefik; facts.traefik = traefik; return
            }
            if image.contains("caddy"), let key = caddyKey(caddyConfig) {
                facts.router = .caddy; facts.caddyServerKey = key; facts.routerName = name; return
            }
            facts.router = .other; return
        }
        let name = processes.first ?? "another program"
        if name == "caddy", let key = caddyKey(caddyConfig) {
            facts.router = .caddy; facts.caddyServerKey = key; facts.routerName = "Caddy"; return
        }
        facts.router = .other; facts.routerName = name
    }

    /// The HTTP server listening on :443 is the one Terminal Deck adds routes to.
    static func caddyKey(_ config: NativeRPCValue?) -> String? {
        guard let config, config["admin"]["disabled"].bool != true, let servers = config["apps"]["http"]["servers"].fields else { return nil }
        let candidates = servers.filter { server in
            (server.value["listen"].elements ?? []).contains { ($0.string ?? "").hasSuffix(":443") }
        }
        guard candidates.count == 1, let key = candidates.first?.key,
              key.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil,
              candidates[0].value["routes"].isNullish || candidates[0].value["routes"].elements != nil else { return nil }
        return key
    }

    static func traefik(_ inspect: NativeRPCValue, name: String) -> BackendAppsServerTraefik? {
        let words = ((inspect["Config"]["Entrypoint"].elements ?? []) + (inspect["Config"]["Cmd"].elements ?? []) + (inspect["Args"].elements ?? [])).compactMap(\.string)
        var http: String?, https: String?, resolver: String?, network: String?
        for word in words {
            let lower = word.lowercased()
            if lower.hasPrefix("--entrypoints."), let equal = word.firstIndex(of: "=") {
                let key = word[word.index(word.startIndex, offsetBy: 14)..<equal]
                let parts = key.split(separator: ".")
                guard parts.count == 2, parts[1].lowercased() == "address" else { continue }
                let address = String(word[word.index(after: equal)...])
                if address.hasSuffix(":443") || address.hasSuffix(":443/tcp") { https = String(parts[0]) }
                if address.hasSuffix(":80") || address.hasSuffix(":80/tcp") { http = String(parts[0]) }
            } else if lower.hasPrefix("--certificatesresolvers."), resolver == nil {
                let rest = word.dropFirst(24)
                resolver = rest.split(separator: ".").first.map(String.init)
            } else if lower.hasPrefix("--providers.docker.network="), let equal = word.firstIndex(of: "=") {
                network = String(word[word.index(after: equal)...])
            }
        }
        let networks = (inspect["NetworkSettings"]["Networks"].fields ?? []).map(\.key).filter { !["bridge", "host", "none"].contains($0) }
        let chosen = network ?? (networks.count == 1 ? networks[0] : networks.first(where: { $0 == "coolify" }))
        let safe = #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\z"#
        guard let https, let http, let chosen,
              [https, http, chosen, name].allSatisfy({ $0.range(of: safe, options: .regularExpression) != nil }),
              resolver.map({ $0.range(of: safe, options: .regularExpression) != nil }) ?? true else { return nil }
        let labels = inspect["Config"]["Labels"]
        let coolify = labels["coolify.managed"].string == "true" || labels["coolify.proxy"].string == "true" || name == "coolify-proxy"
        return .init(container: name, network: chosen, httpEntry: http, httpsEntry: https, resolver: resolver, coolify: coolify)
    }
}
