import Foundation
import TerminalDeckNativeCore

/// The Mac's remote control for the server-side duties. It owns no timer,
/// stream, process or cache: each call is one SSH command through the same
/// injected Apps runtime, and the server keeps working with the Mac off.
public actor BackendAppsServerService {
    public let layout: BackendAppsServerLayout
    private let runtime: BackendAppsRuntime

    public init(runtime: BackendAppsRuntime, fsRoot: String = "") throws {
        self.runtime = runtime
        self.layout = try BackendAppsServerLayout(runtime: runtime, fsRoot: fsRoot)
    }

    // MARK: setup

    public func probe(_ serverID: String) async throws -> BackendAppsServerFacts {
        let result = try await runtime.run(serverID, BackendAppsServerProbe.script(layout), timeoutMS: 30_000, maximumBytes: 2_000_000)
        guard result.code == 0, !result.truncated else { throw BackendAppsRuntime.unavailable("The server could not be checked. Check the connection.") }
        return BackendAppsServerProbe.parse(result.stdout)
    }

    private func ipv4(_ serverID: String, _ facts: BackendAppsServerFacts) async -> String? {
        let saved = (try? await runtime.serverAddresses(serverID)) ?? []
        return saved.first(where: BackendAppsServerFacts.isPublicIPv4) ?? facts.publicIPv4
    }

    public func status(serverID: String) async throws -> NativeRPCValue {
        let facts = try await probe(serverID)
        var value = facts.value
        if facts.installed != nil, facts.administrator {
            let script = prelude + """
            st() { systemctl is-active "$1" 2>/dev/null || true; }
            "$J" -n --arg watch "$(st \(q(layout.unit("watch.service"))))" --arg checks "$(st \(q(layout.unit("check.timer"))))" \\
              --arg cleanup "$(st \(q(layout.unit("cleanup.timer"))))" --arg endpoint "$(st \(q(layout.unit("hook.socket"))))" \\
              --slurpfile server "$ETC/server.json" '{watch:$watch,checks:$checks,cleanup:$cleanup,endpoint:$endpoint,hooksHost:($server[0].hooksHost // null)}'
            """
            value = value.setting("duties", try await json(serverID, script))
        }
        return value
    }

    public func plan(serverID: String) async throws -> NativeRPCValue {
        let facts = try await probe(serverID)
        return BackendAppsServerSetup.plan(facts, layout: layout, ipv4: await ipv4(serverID, facts))
    }

    public func install(serverID: String) async throws -> NativeRPCValue {
        let facts = try await probe(serverID)
        guard facts.supported else { throw BackendAppsServerSetup.installFailure(72) }
        guard facts.administrator else {
            throw NativeRPCError(code: "unavailable", message: "Setup needs administrator access: connect as root or as a user with passwordless sudo. Terminals and the Docker view keep working without it.")
        }
        let ip = await ipv4(serverID, facts)
        let payload = try BackendAppsServerSetup.install(facts, layout: layout, ipv4: ip, now: runtime.now())
        let result = try await runtime.run(serverID, BackendAppsServerSetup.bootstrap, stdin: Data(payload.utf8), timeoutMS: 1_200_000, maximumBytes: 65_536)
        guard result.code == 0, !result.truncated, result.stdout.contains("installed=" + BackendAppsServerLayout.version) else {
            throw BackendAppsServerSetup.installFailure(result.code)
        }
        return BackendAppsValidation.object([("installed", .bool(true)), ("version", .string(BackendAppsServerLayout.version)),
                                             ("router", .string(facts.router.rawValue)), ("routerSummary", .string(facts.routerSummary)),
                                             ("hooksHost", ip.map { .string(layout.hooksHost(ipv4: $0)) } ?? .null)])
    }

    public func remove(serverID: String, addressManager: Bool, importUndo: NativeAppsRouterPersistence.OwnedImport? = nil) async throws -> NativeRPCValue {
        // First the Caddy import line Terminal Deck added (SRV2, receipt-checked); a
        // failure stops here with everything kept, so the person can retry.
        var undone: NativeRPCValue?
        if let importUndo { undone = try await BackendAppsSRV2CaddyKeep.undo(runtime: runtime, serverID: serverID, expected: importUndo) }
        let result = try await runtime.run(serverID, BackendAppsServerSetup.bootstrap, stdin: Data(BackendAppsServerSetup.remove(layout, addressManager: addressManager).utf8), timeoutMS: 300_000, maximumBytes: 65_536)
        guard result.code == 0, !result.truncated, result.stdout.contains("removed=1") else {
            throw NativeRPCError(code: "unavailable", message: result.code == 72 ? "Removing needs administrator access." : "Terminal Deck could not be fully removed from this server. Run remove again.")
        }
        var value = BackendAppsValidation.object([("removed", .bool(true)), ("appsKept", .bool(true))])
        if result.stdout.contains("addressManager=kept-in-use") { value = value.setting("addressManager", .string("kept: apps still use it")) }
        if result.stdout.contains("addressManager=removed") { value = value.setting("addressManager", .string("removed")) }
        if result.stdout.contains("hooksRoute=kept") { value = value.setting("warning", .string("The deploy endpoint address could not be removed from the address manager.")) }
        if let undone { value = value.setting("importUndo", undone) }
        return value
    }

    // MARK: alerts

    public func alertsRead(serverID: String) async throws -> NativeRPCValue {
        BackendAppsServerSettings.publicAlerts(try await json(serverID, prelude + "\"$J\" \(q(BackendAppsServerSettings.alertsMaskFilter)) \"$ETC/alerts.json\""))
    }

    public func alertsSave(serverID: String, request: NativeRPCValue) async throws -> NativeRPCValue {
        let settings = try BackendAppsServerSettings.alerts(request)
        let script = prelude + """
        w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
        cat > "$w/in.json"
        "$J" --slurpfile old "$ETC/alerts.json" \(q(BackendAppsServerSettings.alertsMergeFilter)) "$w/in.json" > "$w/new.json"
        "$J" -e \(q(BackendAppsServerSettings.alertsCompleteFilter)) "$w/new.json" >/dev/null || exit 65
        install -m 0600 "$w/new.json" "$ETC/alerts.json.new" && mv -f "$ETC/alerts.json.new" "$ETC/alerts.json"
        "$J" \(q(BackendAppsServerSettings.alertsMaskFilter)) "$ETC/alerts.json"
        """
        return BackendAppsServerSettings.publicAlerts(try await json(serverID, script, stdin: try settings.encodedJSON(),
            refusal: "A new Telegram or Receiver channel needs its token before it can be saved."))
    }

    public func alertsTest(serverID: String) async throws -> NativeRPCValue {
        try await json(serverID, prelude + "\"$OPT/bin/td-notify\" --test", timeoutMS: 120_000)
    }

    public func alertsHistory(serverID: String, limit: Int) async throws -> NativeRPCValue {
        let count = max(1, min(limit, 200))
        return try await json(serverID, prelude + "f=\"$DATA/alerts/history.jsonl\"; if [ -f \"$f\" ]; then tail -n \(count) \"$f\" | \"$J\" -s 'reverse'; else echo '[]'; fi")
    }

    // MARK: cleanup

    public func cleanupRead(serverID: String) async throws -> NativeRPCValue {
        try await json(serverID, prelude + """
        last=$(cat "$DATA/cleanup-last.json" 2>/dev/null || echo null); preview=$(cat "$DATA/cleanup-preview.json" 2>/dev/null || echo null)
        next=$(systemctl show -p NextElapseUSecRealtime --value \(q(layout.unit("cleanup.timer"))) 2>/dev/null || true)
        "$J" -n --slurpfile s "$ETC/cleanup.json" --argjson last "$last" --argjson preview "$preview" --arg next "$next" \\
          '{settings:$s[0], last:$last, preview:$preview, nextRun:(if $next == "" then null else $next end), labelOnly:true}'
        """)
    }

    public func cleanupSave(serverID: String, request: NativeRPCValue) async throws -> NativeRPCValue {
        let settings = try BackendAppsServerSettings.cleanup(request)
        let schedule = settings["schedule"].string!
        let timer = BackendAppsServerScripts.coreUnits(layout, cleanupSchedule: schedule, traefikGateway: nil).first { $0.name == layout.unit("cleanup.timer") }!.text
        let payload = try BackendAppsValidation.object([("settings", settings), ("timer", .string(timer))]).encodedJSON()
        _ = try await json(serverID, prelude + """
        w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
        cat > "$w/in.json"
        systemd-analyze calendar "$("$J" -r '.settings.schedule' "$w/in.json")" >/dev/null 2>&1 || exit 65
        u="$UNITS/\(layout.unit("cleanup.timer"))"
        [ ! -e "$u" ] || grep -qF "$MARK" "$u" || exit 76
        "$J" '.settings' "$w/in.json" > "$w/s.json"; install -m 0600 "$w/s.json" "$ETC/cleanup.json"
        "$J" -r '.timer' "$w/in.json" > "$w/t"; install -m 0644 "$w/t" "$u"
        systemctl daemon-reload
        if [ "$("$J" -r '.settings.enabled' "$w/in.json")" = true ]; then systemctl enable --now \(q(layout.unit("cleanup.timer"))) >/dev/null 2>&1; systemctl restart \(q(layout.unit("cleanup.timer")))
        else systemctl disable --now \(q(layout.unit("cleanup.timer"))) >/dev/null 2>&1; fi
        echo '{"ok":true}'
        """, stdin: payload, refusal: "That schedule is not a valid systemd calendar time.")
        return try await cleanupRead(serverID: serverID)
    }

    public func cleanupRun(serverID: String, dryRun: Bool) async throws -> NativeRPCValue {
        try await json(serverID, prelude + "\"$OPT/bin/td-cleanup\"" + (dryRun ? " --dry-run" : ""), timeoutMS: 1_800_000)
    }

    // MARK: scheduled jobs

    public func jobsList(serverID: String, appID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        return try await json(serverID, prelude + """
        d="$STATE/\(app)/jobs"
        [ -d "$d" ] || { echo '[]'; exit 0; }
        for f in "$d"/*.json; do
          [ -f "$f" ] || continue
          case "$f" in *.last.json) continue ;; esac
          id=$(basename "$f" .json)
          last=$(cat "$d/$id.last.json" 2>/dev/null || echo null)
          next=$(systemctl show -p NextElapseUSecRealtime --value "\(layout.prefix)-\(app)_job_$id.timer" 2>/dev/null || true)
          "$J" -c --argjson last "$last" --arg next "$next" '. + {last:$last, nextRun:(if $next == "" then null else $next end)}' "$f"
        done | "$J" -s .
        """)
    }

    public func jobSave(serverID: String, appID: String, request: NativeRPCValue) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        let job = try BackendAppsServerSettings.job(request)
        let id = job["id"].string!
        let units = BackendAppsServerScripts.jobUnits(layout, app: app, job: id, schedule: job["schedule"].string!)
        let unit = layout.jobUnit(app: app, job: id)
        let payload = try BackendAppsValidation.object([("job", job), ("service", .string(units.service)), ("timer", .string(units.timer))]).encodedJSON()
        _ = try await json(serverID, prelude + """
        dir="$STATE/\(app)"
        [ -f "$dir/state.json" ] && [ ! -L "$dir" ] || exit 44
        w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
        cat > "$w/in.json"
        systemd-analyze calendar "$("$J" -r '.job.schedule' "$w/in.json")" >/dev/null 2>&1 || exit 65
        for k in service timer; do f="$UNITS/\(unit).$k"; [ ! -e "$f" ] || grep -qF "$MARK" "$f" || exit 76; done
        install -d -m 0700 "$dir/jobs"
        "$J" '.job' "$w/in.json" > "$w/job.json"; install -m 0600 "$w/job.json" "$dir/jobs/\(id).json"
        "$J" -r '.service' "$w/in.json" > "$w/s"; install -m 0644 "$w/s" "$UNITS/\(unit).service"
        "$J" -r '.timer' "$w/in.json" > "$w/t"; install -m 0644 "$w/t" "$UNITS/\(unit).timer"
        systemctl daemon-reload
        if [ "$("$J" -r '.job.enabled' "$w/in.json")" = true ]; then systemctl enable --now "\(unit).timer" >/dev/null 2>&1; systemctl restart "\(unit).timer"; systemctl is-active --quiet "\(unit).timer" || exit 77
        else systemctl disable --now "\(unit).timer" >/dev/null 2>&1 || true; fi
        echo '{"ok":true}'
        """, stdin: payload, refusal: "That schedule is not a valid systemd calendar time.")
        return try await jobsList(serverID: serverID, appID: app)
    }

    public func jobRemove(serverID: String, appID: String, jobID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID), id = try BackendAppsValidation.id(jobID)
        let unit = layout.jobUnit(app: app, job: id)
        _ = try await json(serverID, prelude + """
        systemctl disable --now "\(unit).timer" >/dev/null 2>&1 || true
        for k in service timer; do f="$UNITS/\(unit).$k"; if [ -f "$f" ] && grep -qF "$MARK" "$f"; then rm -f "$f"; fi; done
        systemctl daemon-reload
        rm -f "$STATE/\(app)/jobs/\(id).json" "$STATE/\(app)/jobs/\(id).last.json" "$STATE/\(app)/jobs/\(id).log"
        echo '{"ok":true}'
        """)
        return try await jobsList(serverID: serverID, appID: app)
    }

    public func jobRun(serverID: String, appID: String, jobID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID), id = try BackendAppsValidation.id(jobID)
        return try await json(serverID, prelude + """
        [ -f "$STATE/\(app)/jobs/\(id).json" ] || exit 44
        systemctl start --no-block "\(layout.jobUnit(app: app, job: id)).service" || exit 77
        echo '{"started":true}'
        """)
    }

    public func jobLog(serverID: String, appID: String, jobID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID), id = try BackendAppsValidation.id(jobID)
        return try await maskedLog(serverID, app: app, file: "$STATE/\(app)/jobs/\(id).log", extra: "last=$(cat \"$STATE/\(app)/jobs/\(id).last.json\" 2>/dev/null || echo null)", extraKey: "last")
    }

    // MARK: automatic deploys

    public func autoDeployRead(serverID: String, appID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        return try await json(serverID, prelude + """
        a="$ETC/apps/\(app)"
        host=$("$J" -r '.hooksHost // ""' "$ETC/server.json")
        "$J" -n --arg host "$host" --arg app \(q(app)) \\
          --argjson enabled "$("$J" -r '.enabled // false' "$a/autodeploy.json" 2>/dev/null || echo false)" \\
          --argjson secret "$([ -f "$a/hook-secret" ] && echo true || echo false)" \\
          --argjson link "$([ -f "$a/deploy-token.sha256" ] && echo true || echo false)" \\
          --arg key "$(cat "$a/deploy_key.pub" 2>/dev/null || true)" \\
          '{enabled:$enabled, hasWebhookSecret:$secret, hasDeployLink:$link,
            webhookUrl:(if $host == "" then null else "https://" + $host + "/hooks/github/" + $app end),
            deployLinkUrl:(if $host == "" then null else "https://" + $host + "/deploy/" + $app end),
            deployKey:(if $key == "" then null else $key end)}'
        """)
    }

    /// Turning it on creates a webhook secret (and, on request, a read-only
    /// deploy key whose private half never leaves the server).
    public func autoDeployApply(serverID: String, appID: String, enabled: Bool, deployKey: Bool) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        let secret = BackendAppsServerSettings.randomHex()
        _ = try await json(serverID, prelude + """
        "$J" -e '.kind == "app" and .source.kind == "github"' "$STATE/\(app)/state.json" >/dev/null 2>&1 || exit 44
        [ -n "$("$J" -r '.hooksHost // ""' "$ETC/server.json")" ] || exit 66
        a="$ETC/apps/\(app)"; install -d -m 0700 "$a"
        secret=$(cat)
        [ -f "$a/hook-secret" ] || { printf '%s' "$secret" > "$a/hook-secret.new"; chmod 600 "$a/hook-secret.new"; mv -f "$a/hook-secret.new" "$a/hook-secret"; }
        if \(deployKey ? "true" : "false") && [ ! -f "$a/deploy_key" ]; then ssh-keygen -q -t ed25519 -N '' -C \(q("terminaldeck-" + app)) -f "$a/deploy_key" >/dev/null || exit 77; fi
        "$J" -n --argjson e \(enabled ? "true" : "false") --argjson t "$(date +%s)" '{enabled:$e, updatedAt:$t}' > "$a/autodeploy.json.new"
        chmod 600 "$a/autodeploy.json.new"; mv -f "$a/autodeploy.json.new" "$a/autodeploy.json"
        echo '{"ok":true}'
        """, stdin: Data(secret.utf8))
        return try await autoDeployRead(serverID: serverID, appID: app)
    }

    /// Native window only: the secret to paste into GitHub's webhook settings.
    public func autoDeployReveal(serverID: String, appID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        return try await json(serverID, prelude + """
        a="$ETC/apps/\(app)"; [ -f "$a/hook-secret" ] || exit 44
        host=$("$J" -r '.hooksHost // ""' "$ETC/server.json")
        "$J" -n --rawfile s "$a/hook-secret" --arg u "https://$host/hooks/github/\(app)" '{webhookUrl:$u, secret:$s, contentType:"application/json", events:["push"]}'
        """)
    }

    /// Native window only: a new CI deploy link. The server keeps only its hash.
    public func deployLinkRotate(serverID: String, appID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        let token = BackendAppsServerSettings.randomToken()
        let value = try await json(serverID, prelude + """
        [ -f "$STATE/\(app)/state.json" ] || exit 44
        a="$ETC/apps/\(app)"; install -d -m 0700 "$a"
        cat | sha256sum | cut -c1-64 > "$a/deploy-token.sha256.new"; chmod 600 "$a/deploy-token.sha256.new"; mv -f "$a/deploy-token.sha256.new" "$a/deploy-token.sha256"
        host=$("$J" -r '.hooksHost // ""' "$ETC/server.json")
        "$J" -n --arg u "https://$host/deploy/\(app)" '{url:$u}'
        """, stdin: Data(token.utf8))
        return value.setting("token", .string(token))
            .setting("usage", .string("POST to the address with the header \"Authorization: Bearer <token>\". Add ?revision=<commit> to deploy one exact commit."))
    }

    public func deployRun(serverID: String, appID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        return try await json(serverID, prelude + """
        [ -f "$STATE/\(app)/state.json" ] || exit 44
        install -d -m 0700 "$DATA/deploy-queue"
        "$J" -nc --argjson at "$(date +%s)" '{trigger:"server", requestedAt:$at}' > "$DATA/deploy-queue/\(app).json"
        systemctl start --no-block "\(layout.unit("deploy@"))\(app).service" || exit 77
        echo '{"started":true}'
        """)
    }

    public func deployLog(serverID: String, appID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        return try await maskedLog(serverID, app: app, file: "$DATA/deploys/\(app).log",
                                   extra: "last=$(systemctl is-active \"\(layout.unit("deploy@"))\(app).service\" 2>/dev/null | \"$J\" -R . || echo null)", extraKey: "running")
    }

    /// Call after an app is removed: its job timers, deploy secrets and queue go.
    /// Never touches the app's data or backups. Safe when nothing was set up.
    public func forgetApp(serverID: String, appID: String) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        return try await json(serverID, prelude + """
        for f in "$UNITS"/\(layout.prefix)-\(app)_job_*.timer; do
          [ -f "$f" ] && grep -qF "$MARK" "$f" || continue
          u=$(basename "$f" .timer); systemctl disable --now "$u.timer" >/dev/null 2>&1 || true
          grep -qF "$MARK" "$UNITS/$u.service" 2>/dev/null && rm -f "$UNITS/$u.service"; rm -f "$f"
        done
        systemctl daemon-reload
        rm -rf -- "$ETC/apps/\(app)" "$DATA/deploy-queue/\(app).json" "$DATA/deploys/\(app).log"
        echo '{"forgotten":true}'
        """)
    }

    // MARK: plumbing

    private nonisolated func q(_ text: String) -> String { BackendAppsRuntime.quote(text) }

    private var prelude: String {
        "set -eu\numask 077\nOPT=\(q(layout.opt)); ETC=\(q(layout.etc)); DATA=\(q(layout.data)); STATE=\(q(layout.state)); UNITS=\(q(layout.units)); MARK=\(q(BackendAppsServerLayout.marker))\n"
            + "J=\"${TD_JQ:-$OPT/bin/jq}\"; [ -x \"$J\" ] && [ -f \"$OPT/VERSION\" ] || exit 43\n"
    }

    private func maskedLog(_ serverID: String, app: String, file: String, extra: String, extraKey: String) async throws -> NativeRPCValue {
        let value = try await json(serverID, prelude + """
        \(extra)
        log=$(tail -c 65536 "\(file)" 2>/dev/null || true)
        env=$(cat "$STATE/\(app)/.env" 2>/dev/null || true)
        "$J" -n --arg log "$log" --arg env "$env" --argjson extra "${last:-null}" '{log:$log, env:($env | split("\\n")), extra:$extra}'
        """, maximumBytes: 1_048_576)
        // Only the secret settings are hidden (#571): "KEY=value" lines, judged by name and value.
        let secrets = BackendAppsValidation.secretValues((value["env"].elements ?? []).compactMap { line -> (key: String, value: String)? in
            guard let text = line.string, let equal = text.firstIndex(of: "=") else { return nil }
            return (String(text[..<equal]), String(text[text.index(after: equal)...]))
        })
        return BackendAppsValidation.object([
            ("log", .string(BackendAppsValidation.mask(value["log"].string ?? "", secrets: secrets))), (extraKey, value["extra"])
        ])
    }

    private func json(_ serverID: String, _ script: String, stdin: Data? = nil, timeoutMS: Int = 60_000, maximumBytes: Int = 2_000_000,
                      refusal: String = "The server refused that setting.") async throws -> NativeRPCValue {
        let result = try await runtime.run(serverID, BackendAppsServerSetup.asRoot(script), stdin: stdin, timeoutMS: timeoutMS, maximumBytes: maximumBytes)
        guard result.code == 0, !result.truncated else {
            switch result.code {
            case 43: throw NativeRPCError(code: "not-installed", message: "Set up this server for Apps first. It installs the small helper set that runs these duties.")
            case 44: throw NativeRPCError(code: "not-found", message: "That app or item is not saved on this server.")
            case 65: throw NativeRPCError.invalidArguments(refusal)
            case 66: throw NativeRPCError(code: "unavailable", message: "This server has no public address for the deploy endpoint yet. Run setup again after it has one.")
            case 76: throw NativeRPCError(code: "conflict", message: "A file with a Terminal Deck name exists but was not made by Terminal Deck. Nothing was changed.")
            case 1 where result.stderr.contains("sudo"): throw NativeRPCError(code: "unavailable", message: "This needs administrator access (root or passwordless sudo).")
            default: throw NativeRPCError(code: "unavailable", message: "The server could not complete this action.")
            }
        }
        do { return try BackendAppsValidation.json(Data(result.stdout.utf8)) }
        catch { throw NativeRPCError(code: "unavailable", message: "The server replied with unreadable data.") }
    }
}
