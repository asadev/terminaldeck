import Foundation
import TerminalDeckNativeCore

/// One owner-approved setup over the existing SSH connection, and its exact
/// undo. Idempotent: running it again upgrades the helper set in place.
/// It never installs a second router and never changes another tool's files.
public enum BackendAppsServerSetup {
    static let jqVersion = "1.7.1"
    static let jqChecksums = [
        "x86_64": ("jq-linux-amd64", "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"),
        "aarch64": ("jq-linux-arm64", "4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5")
    ]

    /// Plain-words list of exactly what will be installed, plus why it can't be.
    public static func plan(_ facts: BackendAppsServerFacts, layout: BackendAppsServerLayout, ipv4: String?) -> NativeRPCValue {
        var steps: [(String, String)] = []
        var blocked: String?
        if !facts.supported { blocked = "This server needs Linux with systemd on a 64-bit Intel/AMD or ARM processor." }
        else if !facts.administrator { blocked = "Setup needs administrator access (root, or sudo without a password). Terminals and the Docker view keep working without it." }
        if facts.docker == nil { steps.append(("Install Docker", "Docker's official installer from \(BackendDockerInstall.source).")) }
        switch facts.router {
        case .none: steps.append(("Start the address manager", "Caddy (official \(layout.caddyImage) image) as the container \(layout.caddyContainer) on ports 80 and 443, with automatic HTTPS."))
        case .ours: steps.append(("Keep the address manager", "Terminal Deck's Caddy is already running."))
        case .caddy: steps.append(("Use the existing Caddy", "Nothing is installed or restarted. Only Terminal Deck's own addresses are added through its private admin address."))
        case .traefik: steps.append(("Use the existing Traefik", "Nothing is installed or restarted. Terminal Deck's apps join the \(facts.traefik?.network ?? "router") network with their own labels."))
        case .other: steps.append(("No address manager", facts.routerSummary))
        }
        steps.append(("Install the helper set v\(BackendAppsServerLayout.version)", "Small scripts in \(layout.opt) (alerts, checks, cleanup, scheduled jobs, server-side deploys) and jq \(jqVersion) (official build, checksum checked)."))
        steps.append(("Turn on unattended duties", "systemd: \(layout.unit("watch.service")) (alerts), \(layout.unit("check.timer")) (every 5 minutes), \(layout.unit("cleanup.timer")) (weekly), \(layout.unit("hook.socket")) (deploy endpoint, private port \(layout.hookPort))."))
        if let ipv4, [.none, .ours, .caddy, .traefik].contains(facts.router) {
            steps.append(("Deploy endpoint address", "https://\(layout.hooksHost(ipv4: ipv4)) for GitHub pushes and deploy links."))
        }
        steps.append(("Settings folder", "\(layout.etc), readable only by the administrator. Alert passwords and tokens stay there."))
        return BackendAppsValidation.object([
            ("steps", .array(steps.map { BackendAppsValidation.object([("title", .string($0.0)), ("detail", .string($0.1))]) })),
            ("blockedReason", blocked.map(NativeRPCValue.string) ?? .null),
            ("router", .string(facts.router.rawValue)), ("routerSummary", .string(facts.routerSummary)),
            ("version", .string(BackendAppsServerLayout.version)), ("upgrade", .bool(facts.installed != nil)),
            ("removable", .string("Remove Terminal Deck from this server undoes all of this. Your apps, their data and backups stay."))
        ])
    }

    /// Helper-only facts (addresses for the deploy endpoint). The router lives
    /// in ONE record shared with SRV2: `<stateRoot>/router.json` (routerRecord).
    public static func serverRecord(_ facts: BackendAppsServerFacts, layout: BackendAppsServerLayout, ipv4: String?, now: Double) throws -> Data {
        try BackendAppsValidation.object([
            ("version", .string(BackendAppsServerLayout.version)), ("publicIPv4", ipv4.map(NativeRPCValue.string) ?? .null),
            ("hooksHost", ipv4.map { .string(layout.hooksHost(ipv4: $0)) } ?? .null), ("updatedAt", .number(now))
        ]).encodedJSON()
    }

    /// The router decision as `<stateRoot>/router.json`, in the JSON shape of
    /// SRV2's `BackendAppsSRV2Router.Facts` (DESIGN SRV1+SRV2). The file format is
    /// the seam; no Swift type is shared, so neither lane's build depends on the other.
    public static func routerRecord(_ facts: BackendAppsServerFacts) throws -> Data {
        var fields: [(String, NativeRPCValue)]
        switch facts.router {
        case .none, .ours:
            fields = [("mode", .string("own-caddy")), ("owner", .string("Terminal Deck")), ("caddyAdmin", .string("127.0.0.1:2019")), ("caddyServerKey", .string("terminaldeck"))]
        case .caddy:
            fields = [("mode", .string("caddy")), ("owner", .string(facts.routerName.isEmpty ? "Caddy" : facts.routerName)), ("caddyAdmin", .string("127.0.0.1:2019"))]
            if let key = facts.caddyServerKey { fields.append(("caddyServerKey", .string(key))) }
        case .traefik:
            let traefik = facts.traefik
            fields = [("mode", .string("traefik")), ("owner", .string(traefik?.coolify == true ? "Coolify" : (traefik?.container ?? "Traefik")))]
            if let traefik {
                fields += [("traefikHTTP", .string(traefik.httpEntry)), ("traefikHTTPS", .string(traefik.httpsEntry)), ("traefikNetwork", .string(traefik.network))]
                if let resolver = traefik.resolver { fields.append(("traefikResolver", .string(resolver))) }
            }
        case .other:
            fields = [("mode", .string("other")), ("owner", .string(facts.routerName.isEmpty ? "another program" : facts.routerName)), ("detail", .string(facts.routerSummary))]
        }
        return try BackendAppsValidation.object(fields).encodedJSON()
    }

    /// The full install, sent over stdin (no argv size limit) and run as root.
    public static func install(_ facts: BackendAppsServerFacts, layout: BackendAppsServerLayout, ipv4: String?, now: Double) throws -> String {
        let q = BackendAppsRuntime.quote
        let record = String(decoding: try serverRecord(facts, layout: layout, ipv4: ipv4, now: now), as: UTF8.self)
        let router = String(decoding: try routerRecord(facts), as: UTF8.self)
        let units = BackendAppsServerScripts.coreUnits(layout, cleanupSchedule: "TD_CLEANUP_SCHEDULE", traefikGateway: facts.router == .traefik ? "TD_GATEWAY" : nil)
        let files: [(String, String, String)] = [
            ("td-lib.sh", BackendAppsServerScripts.library(layout), "0644"),
            ("td-notify", BackendAppsServerScripts.notify(layout), "0755"),
            ("td-watch", BackendAppsServerScripts.watch(layout), "0755"),
            ("td-check", BackendAppsServerScripts.check(layout), "0755"),
            ("td-cleanup", BackendAppsServerScripts.cleanup(layout), "0755"),
            ("td-job", BackendAppsServerScripts.job(layout), "0755"),
            ("td-deploy", BackendAppsServerDeployScript.deploy(layout), "0755"),
            ("td-hook", BackendAppsServerDeployScript.hook(layout), "0755")
        ]
        var script = """
        set -eu
        umask 077
        [ "$(id -u)" -eq 0 ] || exit 72
        command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || exit 72
        command -v curl >/dev/null 2>&1 || exit 71
        w=$(mktemp -d)
        trap 'rm -rf "$w"' EXIT
        OPT=\(q(layout.opt)); ETC=\(q(layout.etc)); DATA=\(q(layout.data)); UNITS=\(q(layout.units))
        MARK=\(q(BackendAppsServerLayout.marker))
        if ! command -v docker >/dev/null 2>&1; then
          ( \(BackendDockerInstall.command) ) >/dev/null 2>&1 || exit 73
        fi
        docker info >/dev/null 2>&1 || exit 74
        case "$(uname -m)" in
          x86_64) jq_asset=\(jqChecksums["x86_64"]!.0); jq_sum=\(jqChecksums["x86_64"]!.1) ;;
          aarch64|arm64) jq_asset=\(jqChecksums["aarch64"]!.0); jq_sum=\(jqChecksums["aarch64"]!.1) ;;
          *) exit 72 ;;
        esac
        install -d -m 0755 "$OPT" "$OPT/bin"
        install -d -m 0700 "$ETC" "$ETC/apps" "$DATA"
        if ! echo "$jq_sum  $OPT/bin/jq" | sha256sum -c - >/dev/null 2>&1; then
          curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$w/jq" "https://github.com/jqlang/jq/releases/download/jq-\(jqVersion)/$jq_asset" || exit 75
          echo "$jq_sum  $w/jq" | sha256sum -c - >/dev/null 2>&1 || exit 75
          install -m 0755 "$w/jq" "$OPT/bin/jq"
        fi
        JQ="$OPT/bin/jq"

        """
        for (name, text, mode) in files {
            let delimiter = "TD_SRV1_EOF_" + name.uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: ".", with: "_")
            precondition(!text.contains(delimiter))
            script += "cat > \"$w/\(name)\" <<'\(delimiter)'\n\(text)\(delimiter)\ninstall -m \(mode) \"$w/\(name)\" \"$OPT/bin/\(name)\"\n"
        }
        script += """
        printf '%s' \(q(BackendAppsServerDeployScript.githubKnownHosts)) > "$w/known"; install -m 0644 "$w/known" "$OPT/github_known_hosts"
        printf '%s\\n' \(q(BackendAppsServerLayout.version)) > "$w/version"; install -m 0644 "$w/version" "$OPT/VERSION"
        [ -f "$ETC/alerts.json" ] || printf '%s\\n' '{"enabled":true,"channels":[],"thresholds":{"diskPercent":85,"memoryPressure":20,"certDays":14},"remindMinutes":1440,"watch":{"containers":[]}}' > "$ETC/alerts.json"
        [ -f "$ETC/cleanup.json" ] || printf '%s\\n' '{"enabled":true,"schedule":"\(BackendAppsServerSettings.defaultCleanupSchedule)","removeOldVersions":false,"keepVersions":3,"buildCache":false,"unnamedStorage":false}' > "$ETC/cleanup.json"
        chmod 600 "$ETC/alerts.json" "$ETC/cleanup.json"
        printf '%s\\n' \(q(record)) > "$w/server.json"; "$JQ" -e . "$w/server.json" >/dev/null; install -m 0600 "$w/server.json" "$ETC/server.json"
        install -d -m 0700 \(q(layout.state))
        printf '%s\\n' \(q(router)) > "$w/router.json"; "$JQ" -e .mode "$w/router.json" >/dev/null; install -m 0600 "$w/router.json" \(q(layout.state + "/router.json"))
        if ! docker network inspect \(q(layout.network)) >/dev/null 2>&1; then docker network create --driver bridge --label \(BackendAppsServerLayout.managedLabel)=true \(q(layout.network)) >/dev/null; fi

        """
        script += routerSteps(facts, layout: layout)
        script += "schedule=$(\"$JQ\" -r '.schedule // \"\(BackendAppsServerSettings.defaultCleanupSchedule)\"' \"$ETC/cleanup.json\")\n"
        script += "systemd-analyze calendar \"$schedule\" >/dev/null 2>&1 || schedule=\(q(BackendAppsServerSettings.defaultCleanupSchedule))\n"
        for unit in units {
            let delimiter = "TD_SRV1_UNIT_EOF"
            script += """
            if [ -e "$UNITS/\(unit.name)" ] && ! grep -qF "$MARK" "$UNITS/\(unit.name)"; then exit 76; fi
            cat > "$w/unit" <<'\(delimiter)'
            \(unit.text)\(delimiter)
            sed -e "s|TD_CLEANUP_SCHEDULE|$schedule|" -e "s|TD_GATEWAY|${gateway:-127.0.0.1}|" "$w/unit" > "$w/unit.final"
            install -m 0644 "$w/unit.final" "$UNITS/\(unit.name)"

            """
        }
        script += """
        systemctl daemon-reload
        systemctl enable --now \(q(layout.unit("watch.service"))) \(q(layout.unit("check.timer"))) \(q(layout.unit("hook.socket"))) >/dev/null 2>&1
        systemctl restart \(q(layout.unit("watch.service"))) >/dev/null 2>&1
        if [ "$("$JQ" -r '.enabled // true' "$ETC/cleanup.json")" = true ]; then systemctl enable --now \(q(layout.unit("cleanup.timer"))) >/dev/null 2>&1; else systemctl disable --now \(q(layout.unit("cleanup.timer"))) >/dev/null 2>&1 || true; fi
        systemctl is-active --quiet \(q(layout.unit("watch.service"))) || exit 77
        systemctl is-active --quiet \(q(layout.unit("hook.socket"))) || exit 77
        n=0; until [ "$(curl -s --max-time 3 http://127.0.0.1:\(layout.hookPort)/health)" = '{"ok":true}' ]; do n=$((n + 1)); [ "$n" -lt 10 ] || exit 78; sleep 1; done

        """
        script += hooksRoute(facts, layout: layout, ipv4: ipv4)
        script += "echo installed=\(BackendAppsServerLayout.version)\n"
        return script
    }

    static func routerSteps(_ facts: BackendAppsServerFacts, layout: BackendAppsServerLayout) -> String {
        let q = BackendAppsRuntime.quote
        switch facts.router {
        case .none, .ours:
            let root = layout.ourCaddyRoot
            let bootstrap = #"{"admin":{"listen":"127.0.0.1:2019","config":{"persist":true}},"apps":{"http":{"servers":{"terminaldeck":{"@id":"td-app-server","listen":[":443"],"routes":[]}}},"tls":{"automation":{"policies":[{"issuers":[{"module":"acme","ca":"https://acme-v02.api.letsencrypt.org/directory"}]}]}}}}"#
            return """
            gateway=''
            if ! docker inspect \(q(layout.caddyContainer)) >/dev/null 2>&1; then
              curl -s --max-time 2 -o /dev/null http://127.0.0.1:2019/config/ && exit 79
              install -d -m 0700 \(q(root)) \(q(root + "/config")) \(q(root + "/data"))
              printf '%s\\n' \(q(bootstrap)) > \(q(root + "/bootstrap.json")); chmod 600 \(q(root + "/bootstrap.json"))
              docker run -d --name \(q(layout.caddyContainer)) --label \(BackendAppsServerLayout.managedLabel)=true --label io.terminaldeck.role=address-manager \\
                --restart unless-stopped --network host --userns=host -e XDG_CONFIG_HOME=/config -e XDG_DATA_HOME=/data \\
                -v \(q(root + "/config")):/config -v \(q(root + "/data")):/data -v \(q(root + "/bootstrap.json")):/etc/caddy/terminaldeck.json:ro \\
                \(layout.caddyImage) caddy run --resume --config /etc/caddy/terminaldeck.json >/dev/null || exit 80
            fi
            [ "$(docker inspect -f '{{index .Config.Labels "\(BackendAppsServerLayout.managedLabel)"}}' \(q(layout.caddyContainer)))" = true ] || exit 76
            [ "$(docker inspect -f '{{.State.Running}}' \(q(layout.caddyContainer)))" = true ] || docker start \(q(layout.caddyContainer)) >/dev/null
            n=0; until curl -s --max-time 2 -o /dev/null http://127.0.0.1:2019/config/; do n=$((n + 1)); [ "$n" -lt 20 ] || exit 80; sleep 1; done

            """
        case .traefik:
            guard let traefik = facts.traefik else { return "gateway=''\n" }
            return """
            gateway=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
            printf '%s' "$gateway" | grep -Eq '^[0-9]{1,3}(\\.[0-9]{1,3}){3}$' || exit 81
            docker network inspect \(q(traefik.network)) >/dev/null 2>&1 || exit 81

            """
        case .caddy, .other:
            return "gateway=''\n"
        }
    }

    /// The public route to the private deploy endpoint, added by id only.
    static func hooksRoute(_ facts: BackendAppsServerFacts, layout: BackendAppsServerLayout, ipv4: String?) -> String {
        let q = BackendAppsRuntime.quote
        guard let ipv4 else { return "" }
        let host = layout.hooksHost(ipv4: ipv4)
        switch facts.router {
        case .none, .ours, .caddy:
            let key = facts.router == .caddy ? (facts.caddyServerKey ?? "") : "terminaldeck"
            guard key.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil else { return "" }
            let route = #"{"@id":"\#(layout.hooksRouteID)","match":[{"host":["\#(host)"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:\#(layout.hookPort)"}]}],"terminal":true}"#
            return """
            lock=\(q(layout.caddyLock)); n=0
            until mkdir "$lock" 2>/dev/null; do n=$((n + 1)); [ "$n" -lt 60 ] || exit 82; sleep 2; done
            printf 'setup' > "$lock/owner"
            if curl -s --max-time 10 http://127.0.0.1:2019/id/\(layout.hooksRouteID) | "$JQ" -e '.["@id"]' >/dev/null 2>&1; then
              code=$(printf '%s' \(q(route)) | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X PATCH -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:2019/id/\(layout.hooksRouteID))
            else
              code=$(printf '%s' \(q(route)) | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X PUT -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:2019/config/apps/http/servers/\(key)/routes/0)
            fi
            rm -f "$lock/owner"; rmdir "$lock"
            [ "$(curl -s --max-time 10 http://127.0.0.1:2019/id/\(layout.hooksRouteID) | "$JQ" -r '.handle[0].upstreams[0].dial // ""')" = 127.0.0.1:\(layout.hookPort) ] || exit 83

            """
        case .traefik:
            guard let traefik = facts.traefik else { return "" }
            let rid = layout.hooksRouteID
            var labels = [
                "\(BackendAppsServerLayout.managedLabel)=true", "io.terminaldeck.role=deploy-endpoint", "traefik.enable=true",
                "traefik.docker.network=\(traefik.network)", "traefik.http.routers.\(rid).rule=Host(`\(host)`)",
                "traefik.http.routers.\(rid).entrypoints=\(traefik.httpsEntry)", "traefik.http.routers.\(rid).tls=true",
                "traefik.http.routers.\(rid).service=\(rid)", "traefik.http.services.\(rid).loadbalancer.server.port=8080"
            ]
            if let resolver = traefik.resolver { labels.append("traefik.http.routers.\(rid).tls.certresolver=\(resolver)") }
            return """
            if docker inspect \(q(layout.hooksForwarder)) >/dev/null 2>&1; then
              [ "$(docker inspect -f '{{index .Config.Labels "\(BackendAppsServerLayout.managedLabel)"}}' \(q(layout.hooksForwarder)))" = true ] || exit 76
              docker rm -f \(q(layout.hooksForwarder)) >/dev/null
            fi
            docker run -d --name \(q(layout.hooksForwarder)) \(labels.map { "--label " + q($0) }.joined(separator: " ")) --restart unless-stopped \\
              --network \(q(traefik.network)) --add-host "td-host:$gateway" \(layout.caddyImage) caddy reverse-proxy --from :8080 --to "td-host:\(layout.hookPort)" >/dev/null || exit 83

            """
        case .other: return ""
        }
    }

    /// Undo everything setup added. Apps, their data, backups and APD's own
    /// backup timers stay. The address manager goes only on request and only
    /// when no app address still uses it.
    public static func remove(_ layout: BackendAppsServerLayout, addressManager: Bool) -> String {
        let q = BackendAppsRuntime.quote
        let core = layout.coreUnitNames.map(q).joined(separator: " ")
        return """
        set -u
        umask 077
        [ "$(id -u)" -eq 0 ] || exit 72
        OPT=\(q(layout.opt)); ETC=\(q(layout.etc)); DATA=\(q(layout.data)); UNITS=\(q(layout.units)); MARK=\(q(BackendAppsServerLayout.marker))
        case "$OPT" in */opt/*terminaldeck) ;; *) exit 70 ;; esac
        case "$ETC" in */etc/*terminaldeck) ;; *) exit 70 ;; esac
        case "$DATA" in */var/lib/*terminaldeck-server) ;; *) exit 70 ;; esac
        systemctl disable --now \(q(layout.unit("watch.service"))) \(q(layout.unit("check.timer"))) \(q(layout.unit("cleanup.timer"))) \(q(layout.unit("hook.socket"))) >/dev/null 2>&1
        systemctl stop \(q(layout.unit("deploy@*.service"))) \(q(layout.unit("hook@*.service"))) >/dev/null 2>&1
        for f in "$UNITS"/\(layout.prefix)-*_job_*.timer; do
          [ -f "$f" ] && grep -qF "$MARK" "$f" || continue
          u=$(basename "$f" .timer)
          systemctl disable --now "$u.timer" >/dev/null 2>&1
          grep -qF "$MARK" "$UNITS/$u.service" 2>/dev/null && rm -f "$UNITS/$u.service"
          rm -f "$f"
        done
        for u in \(core); do
          [ -f "$UNITS/$u" ] && grep -qF "$MARK" "$UNITS/$u" && rm -f "$UNITS/$u"
        done
        systemctl daemon-reload
        systemctl reset-failed >/dev/null 2>&1
        JQ="$OPT/bin/jq"
        if curl -s --max-time 5 http://127.0.0.1:2019/id/\(layout.hooksRouteID) | "$JQ" -e '.["@id"]' >/dev/null 2>&1; then
          curl -s -o /dev/null --max-time 20 -X DELETE http://127.0.0.1:2019/id/\(layout.hooksRouteID)
          curl -s --max-time 5 http://127.0.0.1:2019/id/\(layout.hooksRouteID) | "$JQ" -e '.["@id"]' >/dev/null 2>&1 && echo "hooksRoute=kept"
        fi
        if [ "$(docker inspect -f '{{index .Config.Labels "\(BackendAppsServerLayout.managedLabel)"}}' \(q(layout.hooksForwarder)) 2>/dev/null)" = true ]; then docker rm -f \(q(layout.hooksForwarder)) >/dev/null 2>&1; fi
        if \(addressManager ? "true" : "false") && [ "$(docker inspect -f '{{index .Config.Labels "\(BackendAppsServerLayout.managedLabel)"}}' \(q(layout.caddyContainer)) 2>/dev/null)" = true ]; then
          left=$(curl -s --max-time 5 http://127.0.0.1:2019/config/apps/http/servers/terminaldeck/routes | "$JQ" '[.[]? | select(.["@id"] != "\(layout.hooksRouteID)")] | length' 2>/dev/null)
          if [ "${left:-1}" = 0 ]; then docker rm -f \(q(layout.caddyContainer)) >/dev/null 2>&1 && rm -rf -- \(q(layout.ourCaddyRoot)); echo addressManager=removed
          else echo addressManager=kept-in-use; fi
        fi
        rm -rf -- "$OPT" "$ETC" "$DATA"
        [ ! -e "$OPT" ] && [ ! -e "$ETC" ] && [ ! -e "$DATA" ] || exit 77
        echo removed=1
        """
    }

    /// Wraps a script so it runs as root directly or through passwordless sudo.
    public static func asRoot(_ script: String) -> String {
        let quoted = BackendAppsRuntime.quote(script)
        return "if [ \"$(id -u)\" -eq 0 ]; then exec sh -c \(quoted); else exec sudo -n sh -c \(quoted); fi"
    }

    /// The script body travels on stdin, so its size is not limited by argv.
    public static let bootstrap = #"set -eu; umask 077; d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cat > "$d/run.sh"; chmod 700 "$d"; if [ "$(id -u)" -eq 0 ]; then sh "$d/run.sh"; else sudo -n sh "$d/run.sh"; fi"#

    public static func installFailure(_ code: Int?) -> NativeRPCError {
        switch code {
        case 72: return .init(code: "unavailable", message: "Setup needs Linux with systemd and administrator access (root or passwordless sudo).")
        case 71: return .init(code: "unavailable", message: "This server needs curl before Terminal Deck can set it up.")
        case 73: return .init(code: "unavailable", message: "Docker's official installer did not finish. Check the server's internet access and try again.")
        case 74: return .init(code: "unavailable", message: "Docker is installed but not running. Start Docker on the server and try again.")
        case 75: return .init(code: "unavailable", message: "The small JSON tool (jq) could not be downloaded and checked. Check the server's internet access.")
        case 76: return .init(code: "conflict", message: "A file or container with a Terminal Deck name exists but was not made by Terminal Deck. Nothing was changed for it.")
        case 79: return .init(code: "conflict", message: "Another program already uses Caddy's private admin port 2019. Terminal Deck did not start a second address manager.")
        case 80: return .init(code: "unavailable", message: "The address manager (Caddy) could not be started.")
        case 81: return .init(code: "unavailable", message: "The existing Traefik's network could not be found. Nothing was changed.")
        case 82: return .init(code: "busy", message: "The server's addresses are being changed. Try again shortly.")
        case 83: return .init(code: "unavailable", message: "Setup finished, but the deploy endpoint address could not be added. Automatic deploys stay unavailable until setup runs again.")
        case 77, 78: return .init(code: "unavailable", message: "The helpers were installed but did not start. Run setup again or check the server's systemd logs.")
        default: return .init(code: "unavailable", message: "Setup did not finish. Nothing outside Terminal Deck's own files was changed; you can run it again.")
        }
    }
}
