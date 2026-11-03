import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// SRV2: renders an app's deploy recipe, a plain POSIX sh file saved in the
/// app's protected server folder. It is the ONE place a deploy's steps live,
/// so a deploy runs the same whether the Mac or the server starts it:
/// build → before → create → health → route → after → retire.
/// Callers hold the app lock. Exit codes: 0 ok, 10 build, 11 before,
/// 12 health/start, 13 route (old kept), 14 after (old put back), 15 uncertain.
public enum BackendAppsSRV2Recipe {
    public static let version = 1

    public struct Input: Sendable {
        public var appID: String
        public var prefix: String
        public var appDirectory: String
        public var network: String
        public var imageRepository: String
        public var port: Int?
        public var options: NativeAppsOptions
        public var domains: [String]
        public var facts: BackendAppsSRV2Router.Facts
        public var buildKeys: [String]
        public var runKeys: [String]
        public var routeID: String
        public var keepImages: Int
        public init(appID: String, prefix: String, appDirectory: String, network: String, imageRepository: String, port: Int?,
                    options: NativeAppsOptions, domains: [String], facts: BackendAppsSRV2Router.Facts, buildKeys: [String], runKeys: [String],
                    routeID: String, keepImages: Int = 5) {
            self.appID = appID; self.prefix = prefix; self.appDirectory = appDirectory; self.network = network
            self.imageRepository = imageRepository; self.port = port; self.options = options; self.domains = domains; self.facts = facts
            self.buildKeys = buildKeys; self.runKeys = runKeys; self.routeID = routeID; self.keepImages = keepImages
        }
    }

    public enum Router: String, Sendable { case caddy, traefik, none }
    public static func router(_ facts: BackendAppsSRV2Router.Facts) -> Router {
        switch facts.mode {
        case .ownCaddy, .caddy: return facts.caddyServerKey == nil ? .none : .caddy
        case .traefik: return .traefik
        default: return .none
        }
    }

    public static func render(_ input: Input) throws -> String {
        let q = BackendAppsRuntime.quote
        let options = input.options
        try options.validate()
        for (label, value) in [("app", input.appID), ("prefix", input.prefix)] {
            guard value.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("The recipe's \(label) name is invalid.") }
        }
        guard input.network.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$"#, options: .regularExpression) != nil,
              input.imageRepository.range(of: #"^[a-z0-9][a-z0-9/_.-]{0,127}$"#, options: .regularExpression) != nil,
              input.appDirectory.hasPrefix("/"), input.appDirectory.range(of: #"^[A-Za-z0-9/_.-]+$"#, options: .regularExpression) != nil,
              !input.appDirectory.contains(".."), input.routeID.range(of: #"^[a-z][a-z0-9-]{0,95}$"#, options: .regularExpression) != nil,
              (1...50).contains(input.keepImages) else { throw NativeRPCError.invalidArguments("The recipe's server names are invalid.") }
        if let port = input.port { guard (1...65_535).contains(port) else { throw NativeRPCError.invalidArguments("Choose the app's listening port between 1 and 65535.") } }
        for key in input.buildKeys + input.runKeys { guard NativeAppsVariable.validKey(key) else { throw NativeRPCError.invalidArguments("A variable name is invalid.") } }
        for key in input.buildKeys { guard !NativeAppsVariable.reservedForBuild(key) else { throw NativeRPCError.invalidArguments("\(key) can't be used during the build.") } }

        let router = router(input.facts)
        let plan = BackendAppsSRV2Router.plan(domains: input.domains, redirect: options.web.redirect)
        if router != .none, plan.serve.isEmpty { throw NativeRPCError.invalidArguments("Add at least one address that isn't only a redirect.") }
        if !options.web.forceHTTPS, !input.facts.info.forceHTTPSOptional { throw NativeRPCError.invalidArguments("This server's address manager always sends visitors to https. Turn \"Force https\" back on.") }

        // Labels: ours on everything; Traefik's only on the app version itself.
        let base: [(String, String)] = [("dev.terminaldeck.app", input.appID), ("managed-by", "terminaldeck"), ("dev.terminaldeck.deployment", "__TD_DEPLOYMENT__"),
                                        ("io.terminaldeck.managed", "true"), ("io.terminaldeck.app", input.appID), ("io.terminaldeck.deployment", "__TD_DEPLOYMENT__")]
        let traefik = router == .traefik ? BackendAppsSRV2Router.traefikLabels(prefix: input.prefix, appID: input.appID, plan: plan, web: options.web, facts: input.facts) : []
        let appLabels = base + [("dev.terminaldeck.port", BackendAppsSRV2Router.portPlaceholder)] + traefik
        func labelsJSON(_ pairs: [(String, String)]) throws -> String { try pairs.map { try json(.string($0.0)) + ":" + json(.string($0.1)) }.joined(separator: ",") }

        // Storage: named volumes (labelled), saved single files, server folders.
        var mounts: [NativeRPCValue] = [], files: [String] = [], folders: [String] = []
        for mount in options.storage {
            switch mount.kind {
            case .volume:
                mounts.append(obj([("Type", .string("volume")), ("Source", .string(input.prefix + "-" + input.appID + "-" + mount.source)), ("Target", .string(mount.path)),
                                   ("ReadOnly", .bool(mount.readOnly)), ("VolumeOptions", obj([("Labels", obj([("dev.terminaldeck.app", .string(input.appID)), ("managed-by", .string("terminaldeck"))]))]))]))
            case .file:
                guard mount.source.range(of: #"^f-[a-f0-9]{16}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("A saved file is missing. Save the app's storage again.") }
                files.append(mount.source)
                mounts.append(obj([("Type", .string("bind")), ("Source", .string(input.appDirectory + "/files/" + mount.source)), ("Target", .string(mount.path)), ("ReadOnly", .bool(mount.readOnly))]))
            case .folder:
                try NativeAppsOptions.serverFolder(mount.source)
                folders.append(mount.source)
                mounts.append(obj([("Type", .string("bind")), ("Source", .string(mount.source)), ("Target", .string(mount.path)), ("ReadOnly", .bool(mount.readOnly))]))
            }
        }
        let health = options.health
        let seconds: (Int) -> NativeRPCValue = { .number(Double($0) * 1_000_000_000) }
        let codeTest = health.expectedStatus.map { "[ \"$c\" = \"\($0)\" ]" } ?? "[ \"$c\" -ge 200 ] && [ \"$c\" -lt 400 ]"
        let url = "http://127.0.0.1:" + BackendAppsSRV2Router.portPlaceholder + health.path
        let curlTest = "c=$(curl -s -o /dev/null -w '%{http_code}' --max-time \(health.timeoutSeconds) '\(url)') ; \(codeTest)"
        let wgetTest = health.expectedStatus.map { "wget -q -S -O /dev/null -T \(health.timeoutSeconds) '\(url)' 2>&1 | grep -q 'HTTP/[0-9.]* \($0)'" }
            ?? "wget -q -O /dev/null -T \(health.timeoutSeconds) '\(url)'"
        func healthcheck(_ test: String) throws -> String {
            try "\"Healthcheck\":" + json(obj([("Test", .array([.string("CMD-SHELL"), .string(test)])), ("Interval", seconds(health.intervalSeconds)),
                                                ("Timeout", seconds(health.timeoutSeconds)), ("Retries", .number(Double(health.retries))),
                                                ("StartPeriod", seconds(health.startPeriodSeconds))]))
        }
        let restart = "\"RestartPolicy\":{\"Name\":\"unless-stopped\"}"
        let mountsJSON = try json(.array(mounts))
        let netJSON = try json(.string(input.network))
        let appStatic = ",\"Labels\":{" + (try labelsJSON(appLabels + [("dev.terminaldeck.role", "app")])) + "},\"HostConfig\":{\"NetworkMode\":" + netJSON
            + ",\"Mounts\":" + mountsJSON + "," + restart + "},\"NetworkingConfig\":{\"EndpointsConfig\":{" + netJSON + ":{}}}"
        let oneOffStatic = ",\"Labels\":{" + (try labelsJSON(base + [("dev.terminaldeck.role", "before")])) + "},\"HostConfig\":{\"NetworkMode\":" + netJSON
            + ",\"Mounts\":" + mountsJSON + "},\"NetworkingConfig\":{\"EndpointsConfig\":{" + netJSON + ":{}}}"

        var routes: [String] = [], routeIDs: [String] = []
        if router == .caddy {
            for route in BackendAppsSRV2Router.caddyRoutes(routeID: input.routeID, plan: plan, web: options.web) {
                routes.append(try json(route)); routeIDs.append(route["@id"].string ?? "")
            }
        }
        let allRouteIDs = [input.routeID, input.routeID + "-redirect"]
        // Caddyfile mode: the same addresses also go to our own imported file.
        let keep = router == .caddy && input.facts.caddyPersistence == "caddyfile"
        if keep {
            guard let folder = input.facts.caddySnippets, folder.hasPrefix("/"), !folder.contains(".."),
                  folder.range(of: #"^[A-Za-z0-9/_.@+-]+$"#, options: .regularExpression) != nil,
                  (input.facts.caddyBinary ?? "/usr/bin/caddy").range(of: #"^/[A-Za-z0-9/_.+-]+$"#, options: .regularExpression) != nil else {
                throw NativeRPCError.invalidArguments("The address manager's settings folder is invalid.")
            }
        }
        let staleIDs = router == .caddy ? allRouteIDs.filter { !routeIDs.contains($0) } : []
        let dockerfile = (options.build.baseDirectory.isEmpty ? "" : options.build.baseDirectory + "/") + (options.build.dockerfile.isEmpty ? "Dockerfile" : options.build.dockerfile)
        let covered = options.storage.map(\.path)
        func steps(_ command: String) throws -> String { command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try json(.string(command)) }

        var header: [String] = [
            "#!/bin/sh",
            "# Terminal Deck app recipe v\(version) for \(input.appID). Generated by Terminal Deck; it rewrites this file.",
            "# Usage: sh recipe.sh deploy|ensure-route|apply-route|persist-route|unroute|recover <deployment> (the caller holds the app lock; a deploy runs without it).",
            "set -u", "umask 077", "LC_ALL=C; export LC_ALL",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH",
            "TD_RECIPE_VERSION=\(version)",
            "TD_APP=" + q(input.appID), "TD_PREFIX=" + q(input.prefix), "TD_DIR=" + q(input.appDirectory), "TD_NET=" + q(input.network),
            "TD_REPO=" + q(input.imageRepository), "TD_PORT_SET=" + q(input.port.map(String.init) ?? ""),
            "TD_BUILD_KEYS=" + q(" " + input.buildKeys.joined(separator: " ") + " "), "TD_RUN_KEYS=" + q(" " + input.runKeys.joined(separator: " ") + " "),
            "TD_BASE=" + q(options.build.baseDirectory), "TD_DOCKERFILE=" + q(dockerfile), "TD_TARGET=" + q(options.build.target),
            "TD_NOCACHE=" + (options.build.noCache ? "1" : "0"),
            "TD_BEFORE_JSON=" + q(try steps(options.steps.beforeDeploy)), "TD_AFTER_JSON=" + q(try steps(options.steps.afterDeploy)),
            "TD_STEP_TIMEOUT=\(options.steps.timeoutSeconds)",
            "TD_HEALTH=" + (health.enabled ? "1" : "0"), "TD_HEALTH_PATH=" + q(health.path), "TD_HEALTH_CODE=" + q(health.expectedStatus.map(String.init) ?? ""),
            "TD_HEALTH_INTERVAL=\(health.intervalSeconds)", "TD_HEALTH_TIMEOUT=\(health.timeoutSeconds)",
            "TD_HEALTH_RETRIES=\(health.retries)", "TD_HEALTH_START=\(health.startPeriodSeconds)",
            "TD_HC_CURL=" + q(try healthcheck(curlTest)), "TD_HC_WGET=" + q(try healthcheck(wgetTest)),
            "TD_APP_STATIC=" + q(appStatic), "TD_ONEOFF_STATIC=" + q(oneOffStatic),
            "TD_ROUTER=" + router.rawValue,
            "TD_CADDY_ADMIN=" + q(input.facts.caddyAdmin ?? "127.0.0.1:2019"), "TD_CADDY_SERVER=" + q(input.facts.caddyServerKey ?? ""),
            "TD_ROUTE_IDS=" + q(routeIDs.joined(separator: " ")), "TD_ROUTE_STALE=" + q(staleIDs.joined(separator: " ")),
            "TD_ALL_ROUTE_IDS=" + q(allRouteIDs.joined(separator: " ")),
            "TD_TRAEFIK_NET=" + q(input.facts.traefikNetwork ?? ""),
            "TD_ROUTE_MAIN=" + q(input.routeID),
            "TD_CADDY_KEEP=" + (keep ? "caddyfile" : "''"), "TD_CADDY_SNIPPETS=" + q(keep ? input.facts.caddySnippets ?? "" : ""),
            "TD_CADDY_BIN=" + q(input.facts.caddyBinary ?? "/usr/bin/caddy"),
            "TD_CADDY_FILE_BODY=" + q(keep ? BackendAppsSRV2Router.caddyfileSites(routeID: input.routeID, appID: input.appID, plan: plan, web: options.web, caddyVersion: input.facts.caddyVersion) : ""),
            "TD_FILES=" + q(files.joined(separator: " ")), "TD_FOLDERS=" + q(folders.joined(separator: " ")),
            "TD_COVERED=" + q(" " + covered.joined(separator: " ") + " "),
            "TD_KEEP_IMAGES=\(input.keepImages)"
        ]
        for (index, route) in routes.enumerated() { header.append("TD_ROUTE_\(index + 1)=" + q(route)) }
        return header.joined(separator: "\n") + "\n" + body
    }

    /// The fixed part of every recipe. Values above are data; nothing here is per app.
    static let body = #"""
    TD_TMP=''
    TD_RESULT=/dev/null
    TD_CODE=000
    TD_PROBE=server
    TD_HC=''
    TD_IP=''
    td_out() { printf '%s=%s\n' "$1" "$2" >> "$TD_RESULT"; }
    td_fail() { td_out error "$2"; td_out exit "$1"; exit "$1"; }
    td_tmp() {
      TD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/td-recipe.XXXXXX") || exit 1
      trap 'rm -rf "$TD_TMP"' EXIT
      trap 'exit 130' HUP INT TERM
    }
    td_api() {
      if [ $# -ge 3 ]; then
        TD_CODE=$(curl -sS --noproxy '*' --max-time "${TD_API_TIMEOUT:-60}" --unix-socket /var/run/docker.sock -o "$TD_TMP/api.out" -w '%{http_code}' -X "$1" -H 'Content-Type: application/json' --data-binary @"$3" "http://localhost$2" 2>/dev/null) || TD_CODE=000
      else
        TD_CODE=$(curl -sS --noproxy '*' --max-time "${TD_API_TIMEOUT:-60}" --unix-socket /var/run/docker.sock -o "$TD_TMP/api.out" -w '%{http_code}' -X "$1" "http://localhost$2" 2>/dev/null) || TD_CODE=000
      fi
    }
    td_caddy() {
      if [ $# -ge 3 ]; then
        TD_CODE=$(curl -sS --noproxy '*' --max-time 20 -o "$TD_TMP/caddy.out" -w '%{http_code}' -X "$1" -H 'Content-Type: application/json' --data-binary @"$3" "http://$TD_CADDY_ADMIN$2" 2>/dev/null) || TD_CODE=000
      else
        TD_CODE=$(curl -sS --noproxy '*' --max-time 20 -o "$TD_TMP/caddy.out" -w '%{http_code}' -X "$1" "http://$TD_CADDY_ADMIN$2" 2>/dev/null) || TD_CODE=000
      fi
    }
    td_id_from() { sed -n 's/.*"Id":"\([a-f0-9]\{64\}\)".*/\1/p' "$1" | head -n 1; }
    td_env_json() {
      if [ -f "$TD_DIR/.env" ]; then
        awk -v keys="$TD_RUN_KEYS" -v port="$TD_PORT" '
          function esc(s,   out, i, c) { out = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\") out = out "\\\\"; else if (c == "\"") out = out "\\\""; else out = out c } return out }
          BEGIN { printf "["; n = 0; hasport = 0 }
          { i = index($0, "="); if (i < 2) next; k = substr($0, 1, i - 1); v = substr($0, i + 1)
            if (index(keys, " " k " ") == 0) next
            if (substr(v, 1, 8) == "td-json:") v = substr(v, 9); else v = esc(v)
            if (k == "PORT") hasport = 1
            printf "%s\"%s=%s\"", (n++ ? "," : ""), k, v }
          END { if (!hasport) printf "%s\"PORT=%s\"", (n++ ? "," : ""), port; printf "]" }' "$TD_DIR/.env"
      else
        printf '["PORT=%s"]' "$TD_PORT"
      fi
    }
    td_remove() { [ -n "${1:-}" ] && td_api DELETE "/containers/$1?force=true&v=true"; return 0; }
    td_create() {
      td_role=$1; td_image=$2; td_name=$3
      if [ "$td_role" = app ]; then td_static=$TD_APP_STATIC; else td_static=$TD_ONEOFF_STATIC; fi
      {
        printf '%s' "$td_static" | sed -e "s/__TD_DEPLOYMENT__/$TD_DEPLOYMENT/g" -e "s/__TD_PORT__/$TD_PORT/g"
        if [ "$td_role" = app ] && [ -n "$TD_HC" ]; then printf ',%s' "$TD_HC" | sed -e "s/__TD_PORT__/$TD_PORT/g"; fi
        if [ "$td_role" = before ]; then printf ',"Entrypoint":["/bin/sh","-c"],"Cmd":[%s]' "$TD_BEFORE_JSON"; fi
        printf '}'
      } > "$TD_TMP/static-$td_role.json"
      { printf '{"Image":"%s","Env":' "$td_image"; td_env_json; cat "$TD_TMP/static-$td_role.json"; } > "$TD_TMP/create-$td_role.json"
      td_api POST "/containers/create?name=$td_name" "$TD_TMP/create-$td_role.json"
      [ "$TD_CODE" = 201 ] || return 1
      TD_CREATED=$(td_id_from "$TD_TMP/api.out")
      [ -n "$TD_CREATED" ]
    }
    td_network() {
      if docker network inspect "$TD_NET" >/dev/null 2>&1; then
        td_owner=$(docker network inspect -f '{{index .Labels "io.terminaldeck.managed"}}|{{index .Labels "managed-by"}}' "$TD_NET" 2>/dev/null) || return 1
        case "$td_owner" in true\|*|*\|terminaldeck) return 0 ;; *) return 1 ;; esac
      fi
      docker network create --driver bridge --label io.terminaldeck.managed=true --label managed-by=terminaldeck "$TD_NET" >/dev/null 2>&1
    }
    td_build() {
      td_src=$1; td_tag=$2
      td_root=$(realpath -- "$td_src") || return 1
      td_ctx=$(realpath -m -- "$td_src/$TD_BASE") || return 1
      td_df=$(realpath -m -- "$td_src/$TD_DOCKERFILE") || return 1
      case "$td_ctx" in "$td_root"|"$td_root"/*) ;; *) return 1 ;; esac
      case "$td_df" in "$td_root"/*) ;; *) return 1 ;; esac
      [ -d "$td_ctx" ] && [ -f "$td_df" ] || return 1
      (
        set --
        if [ -n "$TD_TARGET" ]; then set -- "$@" --target "$TD_TARGET"; fi
        if [ "$TD_NOCACHE" = 1 ]; then set -- "$@" --no-cache; fi
        if [ -f "$TD_DIR/.env" ]; then
          while IFS= read -r td_line || [ -n "$td_line" ]; do
            td_k=${td_line%%=*}; td_v=${td_line#*=}
            case "$TD_BUILD_KEYS" in *" $td_k "*) ;; *) continue ;; esac
            case "$td_v" in td-json:*) continue ;; esac
            export "$td_k=$td_v"; set -- "$@" --build-arg "$td_k"
          done < "$TD_DIR/.env"
        fi
        exec docker build --label "dev.terminaldeck.app=$TD_APP" --label managed-by=terminaldeck --label io.terminaldeck.managed=true --label "io.terminaldeck.app=$TD_APP" --tag "$td_tag" --file "$td_df" "$@" "$td_ctx"
      ) > "$TD_DIR/deploys/$TD_DEPLOYMENT-build.log" 2>&1
    }
    td_before() {
      [ -n "$TD_BEFORE_JSON" ] || return 0
      td_create before "$1" "$TD_PREFIX-$TD_APP-before-$TD_DEPLOYMENT" || td_fail 11 before-create
      td_one=$TD_CREATED
      td_api POST "/containers/$td_one/start"
      if [ "$TD_CODE" != 204 ]; then td_remove "$td_one"; td_fail 11 before-start; fi
      TD_API_TIMEOUT=$TD_STEP_TIMEOUT td_api POST "/containers/$td_one/wait"
      td_wait=$TD_CODE
      td_status=$(sed -n 's/.*"StatusCode":\([0-9]*\).*/\1/p' "$TD_TMP/api.out" | head -n 1)
      docker logs --tail 400 "$td_one" > "$TD_DIR/deploys/$TD_DEPLOYMENT-before.log" 2>&1
      td_remove "$td_one"
      [ "$td_wait" = 200 ] || td_fail 11 before-timeout
      [ "$td_status" = 0 ] || td_fail 11 before-failed
    }
    td_probe_tool() {
      TD_PROBE=server; TD_HC=''
      if [ "$TD_HEALTH" != 1 ]; then TD_PROBE=none; return 0; fi
      td_tool=$(docker run --rm --network none --entrypoint /bin/sh --label managed-by=terminaldeck --label "dev.terminaldeck.app=$TD_APP" --label dev.terminaldeck.role=probe "$1" -c 'command -v curl || command -v wget' 2>/dev/null) || td_tool=''
      case "$td_tool" in
        *curl*) TD_PROBE=docker; TD_HC=$TD_HC_CURL ;;
        *wget*) TD_PROBE=docker; TD_HC=$TD_HC_WGET ;;
      esac
      return 0
    }
    td_code_ok() {
      if [ -n "$TD_HEALTH_CODE" ]; then [ "$1" = "$TD_HEALTH_CODE" ]; else [ "$1" -ge 200 ] 2>/dev/null && [ "$1" -lt 400 ]; fi
    }
    td_health() {
      td_start=$(date +%s); td_failures=0
      td_deadline=$((td_start + TD_HEALTH_START + TD_HEALTH_RETRIES * (TD_HEALTH_INTERVAL + TD_HEALTH_TIMEOUT) + 30))
      while :; do
        td_state=$(docker inspect -f "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{with index .NetworkSettings.Networks \"$TD_NET\"}}{{.IPAddress}}{{end}}" "$1" 2>/dev/null) || return 1
        td_status=${td_state%%|*}; td_rest=${td_state#*|}; td_hs=${td_rest%%|*}; TD_IP=${td_rest#*|}
        [ "$td_status" = running ] || return 1
        td_now=$(date +%s)
        [ "$td_now" -lt "$td_deadline" ] || return 1
        if [ "$TD_PROBE" = docker ]; then
          case "$td_hs" in healthy) return 0 ;; unhealthy) return 1 ;; esac
          sleep 1; continue
        fi
        if [ "$TD_HEALTH" != 1 ]; then
          if [ $((td_now - td_start)) -ge "$TD_HEALTH_START" ] && [ -n "$TD_IP" ]; then return 0; fi
          sleep 1; continue
        fi
        if [ -n "$TD_IP" ]; then
          td_c=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --connect-timeout "$TD_HEALTH_TIMEOUT" --max-time "$TD_HEALTH_TIMEOUT" "http://$TD_IP:$TD_PORT$TD_HEALTH_PATH" 2>/dev/null) || td_c=000
          if td_code_ok "$td_c"; then return 0; fi
        fi
        if [ $((td_now - td_start)) -ge "$TD_HEALTH_START" ]; then
          td_failures=$((td_failures + 1))
          [ "$td_failures" -lt "$TD_HEALTH_RETRIES" ] || return 1
        fi
        sleep "$TD_HEALTH_INTERVAL"
      done
    }
    td_route_put() {
      td_caddy GET "/id/$1"
      if [ "$TD_CODE" = 200 ]; then
        td_caddy PATCH "/id/$1" "$2"
      else
        td_caddy PUT "/config/apps/http/servers/$TD_CADDY_SERVER/routes/0" "$2"
        # An empty route list has no index 0 to insert before: append instead.
        if [ "$TD_CODE" != 200 ]; then td_caddy POST "/config/apps/http/servers/$TD_CADDY_SERVER/routes" "$2"; fi
      fi
      [ "$TD_CODE" = 200 ] || return 1
      td_caddy GET "/id/$1"
      [ "$TD_CODE" = 200 ]
    }
    td_route_save() {
      for td_rid in $TD_ALL_ROUTE_IDS; do
        rm -f "$TD_TMP/prev-$td_rid.json"
        td_caddy GET "/id/$td_rid"
        if [ "$TD_CODE" = 200 ]; then cp "$TD_TMP/caddy.out" "$TD_TMP/prev-$td_rid.json"; fi
      done
    }
    td_route_apply() {
      td_i=0
      for td_rid in $TD_ROUTE_IDS; do
        td_i=$((td_i + 1))
        eval "td_body=\$TD_ROUTE_$td_i"
        printf '%s' "$td_body" | sed "s/__TD_UPSTREAM__/$1/g" > "$TD_TMP/route-$td_rid.json"
        td_route_put "$td_rid" "$TD_TMP/route-$td_rid.json" || return 1
      done
      for td_rid in $TD_ROUTE_STALE; do
        td_caddy GET "/id/$td_rid"
        if [ "$TD_CODE" = 200 ]; then td_caddy DELETE "/id/$td_rid"; [ "$TD_CODE" = 200 ] || return 1; fi
      done
      return 0
    }
    td_route_restore() {
      td_ok=0
      for td_rid in $TD_ALL_ROUTE_IDS; do
        if [ -f "$TD_TMP/prev-$td_rid.json" ]; then
          td_route_put "$td_rid" "$TD_TMP/prev-$td_rid.json" || td_ok=1
        else
          td_caddy GET "/id/$td_rid"
          if [ "$TD_CODE" = 200 ]; then td_caddy DELETE "/id/$td_rid"; [ "$TD_CODE" = 200 ] || td_ok=1; fi
        fi
      done
      return $td_ok
    }
    td_keep_file() { printf '%s/%s.caddy' "$TD_CADDY_SNIPPETS" "$TD_ROUTE_MAIN"; }
    td_persist() {
      [ "$TD_CADDY_KEEP" = caddyfile ] && [ -n "$TD_CADDY_SNIPPETS" ] && [ -d "$TD_CADDY_SNIPPETS" ] || return 0
      td_pf=$(td_keep_file); td_pt="$TD_CADDY_SNIPPETS/.$TD_ROUTE_MAIN.caddy.tmp"
      if ! printf '%s' "$TD_CADDY_FILE_BODY" | sed "s/__TD_UPSTREAM__/$1/g" > "$td_pt"; then rm -f "$td_pt"; td_out warning keep-address-failed; return 0; fi
      if [ -x "$TD_CADDY_BIN" ] && ! "$TD_CADDY_BIN" adapt --adapter caddyfile --config "$td_pt" >/dev/null 2>&1; then rm -f "$td_pt"; td_out warning keep-address-failed; return 0; fi
      chmod 640 "$td_pt"; chgrp caddy "$td_pt" 2>/dev/null || chmod 644 "$td_pt"
      mv -f "$td_pt" "$td_pf" || { rm -f "$td_pt"; td_out warning keep-address-failed; }
      return 0
    }
    td_keep_save() {
      rm -f "$TD_TMP/keep.prev" "$TD_TMP/keep.none"
      [ "$TD_CADDY_KEEP" = caddyfile ] && [ -d "$TD_CADDY_SNIPPETS" ] || return 0
      if [ -f "$(td_keep_file)" ]; then cp -p "$(td_keep_file)" "$TD_TMP/keep.prev"; else : > "$TD_TMP/keep.none"; fi
    }
    td_keep_restore() {
      if [ -f "$TD_TMP/keep.prev" ]; then cp -p "$TD_TMP/keep.prev" "$(td_keep_file).tmp" && mv -f "$(td_keep_file).tmp" "$(td_keep_file)"
      elif [ -f "$TD_TMP/keep.none" ]; then rm -f "$(td_keep_file)"; fi
      return 0
    }
    td_after() {
      [ -n "$TD_AFTER_JSON" ] || return 0
      printf '{"AttachStdout":true,"AttachStderr":true,"Tty":true,"Cmd":["/bin/sh","-c",%s]}' "$TD_AFTER_JSON" > "$TD_TMP/exec.json"
      td_api POST "/containers/$1/exec" "$TD_TMP/exec.json"
      [ "$TD_CODE" = 201 ] || return 1
      td_exec=$(td_id_from "$TD_TMP/api.out")
      [ -n "$td_exec" ] || return 1
      printf '{"Detach":false,"Tty":true}' > "$TD_TMP/exec-start.json"
      TD_API_TIMEOUT=$TD_STEP_TIMEOUT td_api POST "/exec/$td_exec/start" "$TD_TMP/exec-start.json"
      td_started=$TD_CODE
      tail -c 65536 "$TD_TMP/api.out" > "$TD_DIR/deploys/$TD_DEPLOYMENT-after.log" 2>/dev/null
      [ "$td_started" = 200 ] || return 1
      td_api GET "/exec/$td_exec/json"
      [ "$(sed -n 's/.*"ExitCode":\([0-9-]*\).*/\1/p' "$TD_TMP/api.out" | head -n 1)" = 0 ]
    }
    td_retire() {
      for td_old in $(docker ps -q --no-trunc --filter "label=io.terminaldeck.app=$TD_APP" --filter label=io.terminaldeck.managed=true); do
        [ "$td_old" = "$1" ] && continue
        td_role=$(docker inspect -f '{{index .Config.Labels "dev.terminaldeck.role"}}' "$td_old" 2>/dev/null) || continue
        case "$td_role" in before|probe) continue ;; esac
        if docker stop -t 10 "$td_old" >/dev/null 2>&1 && docker rm "$td_old" >/dev/null 2>&1; then td_out retired "$td_old"; else td_out warning old-version-cleanup; fi
      done
    }
    td_keep_images() {
      td_n=0
      for td_image in $(docker images -q --no-trunc --filter "label=dev.terminaldeck.app=$TD_APP" --filter label=managed-by=terminaldeck | awk '!seen[$0]++'); do
        td_n=$((td_n + 1))
        [ "$td_n" -le "$TD_KEEP_IMAGES" ] && continue
        if docker rmi "$td_image" >/dev/null 2>&1; then td_out pruned "$td_image"; fi
      done
      find "$TD_DIR/deploys" -type f -mtime +30 -delete 2>/dev/null || true
    }
    td_running() {
      td_found=$(docker ps -q --no-trunc --filter "label=io.terminaldeck.app=$TD_APP" --filter label=dev.terminaldeck.role=app | head -n 1)
      [ -n "$td_found" ] || td_found=$(docker ps -q --no-trunc --filter "label=io.terminaldeck.app=$TD_APP" --filter label=io.terminaldeck.managed=true | head -n 1)
      printf '%s' "$td_found"
    }
    td_deploy() {
      case "${TD_DEPLOYMENT:-}" in ''|*[!a-z0-9-]*) echo 'error=deployment-id'; exit 10 ;; esac
      td_tmp
      mkdir -p "$TD_DIR/deploys" && chmod 700 "$TD_DIR/deploys" || exit 10
      TD_RESULT="$TD_DIR/deploys/$TD_DEPLOYMENT.result"
      : > "$TD_RESULT"
      td_out recipe "$TD_RECIPE_VERSION"
      # Keep the result file fresh while this deploy runs (it holds no app lock), so
      # nothing mistakes a long build for a deploy that died with its server.
      ( while kill -0 $$ 2>/dev/null; do touch "$TD_RESULT" 2>/dev/null; sleep 30; done ) >/dev/null 2>&1 &
      [ -S /var/run/docker.sock ] || td_fail 10 docker-unavailable
      td_network || td_fail 10 network
      if [ -n "${TD_IMAGE:-}" ]; then
        case "$TD_IMAGE" in "$TD_REPO":*) ;; *) td_fail 10 image-not-owned ;; esac
        td_tag=$TD_IMAGE
      else
        [ -d "${TD_SOURCE:-}" ] || td_fail 10 source-missing
        td_tag="$TD_REPO:$TD_DEPLOYMENT"
        td_build "$TD_SOURCE" "$td_tag" || td_fail 10 build-failed
      fi
      td_image=$(docker image inspect -f '{{.Id}}' "$td_tag" 2>/dev/null) || td_fail 10 build-missing
      td_out tag "$td_tag"; td_out image "$td_image"
      TD_PORT=$TD_PORT_SET
      if [ -z "$TD_PORT" ]; then
        td_ports=$(docker image inspect -f '{{range $p, $v := .Config.ExposedPorts}}{{$p}} {{end}}' "$td_image" 2>/dev/null)
        set -- $td_ports
        if [ $# -eq 1 ]; then case "$1" in */tcp) TD_PORT=${1%/tcp} ;; esac; fi
      fi
      case "$TD_PORT" in ''|*[!0-9]*) td_fail 10 port-unknown ;; esac
      td_out port "$TD_PORT"
      for td_v in $(docker image inspect -f '{{range $p, $v := .Config.Volumes}}{{$p}} {{end}}' "$td_image" 2>/dev/null); do
        case "$TD_COVERED" in *" $td_v "*) ;; *) td_out warning "unsaved-storage:$td_v" ;; esac
      done
      for td_f in $TD_FILES; do
        [ -f "$TD_DIR/files/$td_f" ] && [ ! -L "$TD_DIR/files/$td_f" ] || td_fail 10 file-missing
        chmod 644 "$TD_DIR/files/$td_f" || td_fail 10 file-missing
      done
      for td_d in $TD_FOLDERS; do
        [ -e "$td_d" ] && continue
        (umask 022; mkdir -p -- "$td_d") || td_fail 10 folder
        # With Docker's user remapping the app's root is a different server user: give it the new folder.
        if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=userns'; then
          td_uid=$(awk -F: '$1=="dockremap"{print $2; exit}' /etc/subuid 2>/dev/null); td_gid=$(awk -F: '$1=="dockremap"{print $2; exit}' /etc/subgid 2>/dev/null)
          if [ -n "$td_uid" ]; then chown "$td_uid:${td_gid:-$td_uid}" "$td_d" || td_fail 10 folder; fi
        fi
      done
      if [ -z "${TD_IMAGE:-}" ]; then td_before "$td_image"; fi
      td_probe_tool "$td_image"
      td_create app "$td_image" "$TD_PREFIX-$TD_APP-$TD_DEPLOYMENT" || td_fail 12 create-failed
      td_new=$TD_CREATED
      td_out container "$td_new"
      if [ "$TD_ROUTER" = traefik ]; then
        docker network connect "$TD_TRAEFIK_NET" "$td_new" >/dev/null 2>&1 || { td_remove "$td_new"; td_fail 13 router-network; }
        [ "$TD_PROBE" = docker ] || td_out warning traefik-unchecked-traffic
      fi
      td_api POST "/containers/$td_new/start"
      if [ "$TD_CODE" != 204 ]; then td_remove "$td_new"; td_fail 12 start-failed; fi
      if ! td_health "$td_new"; then
        docker logs --tail 200 "$td_new" > "$TD_DIR/deploys/$TD_DEPLOYMENT-app.log" 2>&1
        td_remove "$td_new"
        td_fail 12 health-failed
      fi
      td_out probe "$TD_PROBE"
      td_out upstream "$TD_IP"
      if [ "$TD_ROUTER" = caddy ]; then
        td_route_save
        td_keep_save
        if ! td_route_apply "$TD_IP:$TD_PORT"; then
          if td_route_restore; then td_remove "$td_new"; td_fail 13 route-failed; fi
          td_fail 15 route-uncertain
        fi
        td_persist "$TD_IP:$TD_PORT"
      fi
      if ! td_after "$td_new"; then
        if [ "$TD_ROUTER" = caddy ]; then td_route_restore || td_fail 15 after-route-uncertain; td_keep_restore; fi
        td_remove "$td_new"
        td_fail 14 after-failed
      fi
      td_retire "$td_new"
      td_keep_images
      td_out status running
      td_out exit 0
    }
    td_route_now() {
      [ "$TD_ROUTER" = caddy ] || { echo "route=unchanged"; return 0; }
      td_tmp
      td_new=$(td_running)
      [ -n "$td_new" ] || { echo "route=no-running-version"; return 0; }
      td_ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$TD_NET\"}}{{.IPAddress}}{{end}}" "$td_new" 2>/dev/null)
      td_port=$(docker inspect -f '{{index .Config.Labels "dev.terminaldeck.port"}}' "$td_new" 2>/dev/null)
      case "$td_port" in ''|*[!0-9]*) td_port=$TD_PORT_SET ;; esac
      case "$td_ip" in ''|*[!0-9.]*) echo "error=no-private-address"; exit 13 ;; esac
      case "$td_port" in ''|*[!0-9]*) echo "error=port-unknown"; exit 13 ;; esac
      if [ "$1" = check ]; then
        td_caddy GET "/id/$TD_ROUTE_MAIN"
        if [ "$TD_CODE" = 200 ] && grep -q "\"dial\":\"$td_ip:$td_port\"" "$TD_TMP/caddy.out"; then td_persist "$td_ip:$td_port"; echo "route=ok"; return 0; fi
      fi
      if [ "$1" = keep ]; then td_persist "$td_ip:$td_port"; echo "route=kept"; return 0; fi
      td_route_save
      if td_route_apply "$td_ip:$td_port"; then td_persist "$td_ip:$td_port"; echo "route=applied"; return 0; fi
      td_route_restore || { echo "error=route-uncertain"; exit 15; }
      echo "error=route-failed"; exit 13
    }
    td_unroute() {
      [ "$TD_ROUTER" = caddy ] || { echo "route=unchanged"; return 0; }
      td_tmp
      for td_rid in $TD_ALL_ROUTE_IDS; do
        td_caddy GET "/id/$td_rid"
        if [ "$TD_CODE" = 200 ]; then td_caddy DELETE "/id/$td_rid"; [ "$TD_CODE" = 200 ] || { echo "error=route-failed"; exit 13; }; fi
      done
      if [ "$TD_CADDY_KEEP" = caddyfile ] && [ -n "$TD_CADDY_SNIPPETS" ]; then rm -f "$(td_keep_file)"; fi
      echo "route=removed"
    }
    td_recover() {
      case "${1:-}" in ''|*[!a-z0-9-]*) echo error=usage; exit 2 ;; esac
      TD_DEPLOYMENT=$1
      R="$TD_DIR/deploys/$1.result"
      if [ -f "$R" ] && grep -q '^exit=' "$R"; then echo recover=finished; return 0; fi
      td_tmp
      mkdir -p "$TD_DIR/deploys" && chmod 700 "$TD_DIR/deploys"
      TD_RESULT=$R
      for td_c in $(docker ps -aq --no-trunc --filter "label=dev.terminaldeck.deployment=$1" --filter "label=dev.terminaldeck.app=$TD_APP" 2>/dev/null); do
        td_role=$(docker inspect -f '{{index .Config.Labels "dev.terminaldeck.role"}}' "$td_c" 2>/dev/null)
        if [ "$td_role" = app ]; then
          td_others=$(docker ps -q --no-trunc --filter "label=io.terminaldeck.app=$TD_APP" --filter label=io.terminaldeck.managed=true 2>/dev/null | grep -v -x -- "$td_c")
          if [ -z "$td_others" ]; then td_out warning interrupted-kept-new; continue; fi
        fi
        td_remove "$td_c"
      done
      if [ "$TD_ROUTER" = caddy ]; then ( td_route_now force ) >/dev/null 2>&1 || td_out warning route; fi
      td_out error interrupted
      td_out exit 16
      echo recover=done
    }
    case "${1:-}" in
      deploy) td_deploy ;;
      recover) td_recover "${2:-}" ;;
      ensure-route) td_route_now check ;;
      apply-route) td_route_now force ;;
      persist-route) td_route_now keep ;;
      unroute) td_unroute ;;
      *) echo "error=usage"; exit 2 ;;
    esac
    """#

    // MARK: helpers

    public static func json(_ value: NativeRPCValue) throws -> String {
        if let text = value.string {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(text), as: UTF8.self)
        }
        return String(decoding: try value.encodedJSON(), as: UTF8.self)
    }
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func obj(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }

    /// Parses the recipe's `key=value` result lines (repeated keys keep every value).
    public static func result(_ text: String) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            guard let equal = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equal]), default: []].append(String(line[line.index(after: equal)...]))
        }
        return values
    }

    /// Plain words for each failure code the recipe can report.
    public static func message(_ code: String, health: NativeAppsOptions.Health? = nil, timeout: Int? = nil) -> String {
        switch code {
        case "build-failed": return "The app could not be built. Check its build file and the build settings. The previous version is still running."
        case "source-missing": return "The app's source could not be found on the server. Nothing was changed."
        case "port-unknown": return "Choose the app's listening port: its build file doesn't name exactly one."
        case "file-missing": return "A saved storage file is missing on the server. Save the app's storage again."
        case "folder": return "A server folder for the app's storage could not be created."
        case "docker-unavailable": return "Docker is not running on this server."
        case "network": return "The app network is used by something Terminal Deck doesn't manage."
        case "image-not-owned", "build-missing": return "That app version is no longer kept on the server."
        case "before-failed": return "The before-deploy command failed. The previous version is still running."
        case "before-timeout": return "The before-deploy command took longer than \(timeout ?? 600) seconds. The previous version is still running."
        case "before-create", "before-start": return "The before-deploy command could not start (it needs /bin/sh in the app). The previous version is still running."
        case "create-failed", "start-failed": return "The new version could not start. The previous version is still running."
        case "health-failed":
            let path = health?.path ?? "/"
            return health?.enabled == false ? "The new version stopped soon after starting. The previous version is still running."
                : "The new version didn't pass its health check (\(path)). The previous version is still running."
        case "route-failed", "router-network": return "The address couldn't be switched to the new version. The previous version is still running."
        case "after-failed": return "The after-deploy command failed, so the previous version was put back."
        case "route-uncertain", "after-route-uncertain": return "The address switch couldn't be confirmed. Both versions were kept; check the app's address."
        case "interrupted": return "The deploy was interrupted before it finished and was undone on the server. The previous version is still running."
        default: return "The deploy could not finish. The previous version is still running."
        }
    }
}
