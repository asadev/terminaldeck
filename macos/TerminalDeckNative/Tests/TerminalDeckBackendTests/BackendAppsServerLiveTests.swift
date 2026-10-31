import CryptoKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// SRV1 live check on the App Review demo box ONLY, under Asad's rules: every
/// object is td-test-*, the existing Caddy route stays untouched, and the
/// inventory after equals the inventory before. Opt-in, never in a gate:
/// TD_WIP=SRV1 TD_SRV1_LIVE=terminaldeck-server swift test --filter BackendAppsServerLiveTests
@Suite("SRV1 live check on terminaldeck-server", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["TD_WIP"]?.contains("SRV1") == true
                && ProcessInfo.processInfo.environment["TD_SRV1_LIVE"] == "terminaldeck-server"))
struct BackendAppsServerLiveTests {
    static let host = "terminaldeck-server", ip = "178.105.239.176", app = "td-test-srv1"
    static let hooks = "td-test-hooks.178-105-239-176.sslip.io", appHost = "td-test-srv1.178-105-239-176.sslip.io"

    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func add(_ text: String) { lock.lock(); lines.append("[\(ISO8601DateFormatter().string(from: Date()))] " + text); lock.unlock() }
        func save() { if let path = ProcessInfo.processInfo.environment["TD_SRV1_LIVE_LOG"] { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) } }
    }

    @discardableResult
    static func ssh(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 600) throws -> (code: Int32, out: String, err: String) {
        precondition(host == "terminaldeck-server", "SRV1 live checks run only on the demo box")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command]
        let out = Pipe(), input = Pipe()
        let errURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("srv1-live-err-" + UUID().uuidString)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = out; process.standardError = errHandle; process.standardInput = input
        try process.run()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); killer.cancel(); try errHandle.close()
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: errURL)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), err)
    }

    static func runtime() -> BackendAppsRuntime {
        BackendAppsRuntime(execute: { _, command, stdin, timeoutMS, _ in
            let result = try Self.ssh(command, stdin: stdin, timeout: Double(timeoutMS) / 1000)
            return BackendServersRunResult(code: Int(result.code), stdout: result.out, stderr: result.err)
        }, serverAddresses: { _ in [Self.ip] }, privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps")
    }

    static let inventoryScript = #"""
    set +e
    echo "== containers"; docker ps -a --format '{{.Names}} {{.Image}}' | sort
    echo "== images"; docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' | sort
    echo "== volumes"; docker volume ls -q | sort
    echo "== networks"; docker network ls --format '{{.Name}}' | sort
    echo "== units"; ls /etc/systemd/system | sort
    echo "== loaded-td-test-units"; systemctl list-units --all --plain --no-legend 'td-test*' | awk '{print $1}' | sort
    echo "== opt"; ls /opt | sort
    echo "== etc-td"; ls /etc | grep -E 'td-test|terminaldeck' | sort
    echo "== var-lib"; ls /var/lib | sort
    echo "== caddy-config-sha256"; curl -s http://127.0.0.1:2019/config/ | sha256sum | cut -c1-64
    echo "== caddy-route-ids"; curl -s http://127.0.0.1:2019/config/ | grep -o '"@id":"[^"]*"' | sort
    echo "== caddy-certs"; ls /var/lib/caddy/.local/share/caddy/certificates/*/ 2>/dev/null | sort
    echo "== tmp-td-test"; ls /tmp | grep td-test | sort
    """#

    static func inventory() throws -> String {
        let result = try ssh(inventoryScript, timeout: 60)
        return result.out
    }

    static func waitFor(_ seconds: Int, _ log: Log, _ what: String, _ check: () throws -> Bool) throws -> Bool {
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < end {
            if try check() { log.add("ok: \(what)"); return true }
            Thread.sleep(forTimeInterval: 5)
        }
        log.add("TIMEOUT: \(what)"); return false
    }

    @Test func installAlertCleanupJobAutoDeployRemove() async throws {
        let log = Log()
        defer { log.save() }
        let before = try Self.inventory()
        log.add("BEFORE inventory:\n" + before)
        let leftovers = before.split(separator: "\n").filter { !$0.hasPrefix("==") && $0.contains("td-test") }
        #expect(leftovers.isEmpty, "clean slate required (another live run may be active): \(leftovers)")
        guard leftovers.isEmpty else { return }
        let cacheBefore = try Self.ssh("docker buildx du --verbose 2>/dev/null | awk '/^ID:/{print $2}' | sort", timeout: 60).out
        let networkExisted = before.contains("\ntd-test-apps\n")

        let service = try BackendAppsServerService(runtime: Self.runtime())
        let channels = BackendAppsServerChannels(service: service, authorize: { _, _ in })
        let native = NativeRPCContext(caller: .nativeApp, ownerID: "srv1-live")
        func call(_ channel: String, _ fields: [(String, NativeRPCValue)] = []) async throws -> NativeRPCValue {
            try await channels.invoke(channel, request: BackendAppsValidation.object([("serverId", .string(Self.host))] + fields), context: native)
        }
        let appField: (String, NativeRPCValue) = ("appId", .string(Self.app))
        var failure: Error?
        do {
            // 1. Status: the existing Caddy must be recognised; nothing installed.
            let status = try await call("apps:server:status")
            log.add("status: " + status.compact)
            #expect(status["router"].string == "caddy" && status["installedVersion"] == .null)
            let plan = try await call("apps:server:setup:plan")
            log.add("plan: " + plan.compact)

            // 2. One-click setup (td-test layout), no second router.
            let installed = try await call("apps:server:setup:install")
            log.add("install: " + installed.compact)
            let duties = try await call("apps:server:status")
            log.add("duties: " + duties["duties"].compact)
            #expect(duties["duties"]["watch"].string == "active" && duties["duties"]["endpoint"].string == "active")
            #expect(try Self.ssh("curl -s http://127.0.0.1:47229/health").out == #"{"ok":true}"#)

            // 3. Alert fires: a labelled td-test container restarting in a loop -> webhook.
            let base = """
            set -eu
            d=/var/lib/td-test-terminaldeck-server/td-test-img; rm -rf "$d"; mkdir -p "$d/bin" "$d/www"
            cp /bin/busybox "$d/bin/busybox"; for c in sh httpd echo date sleep cat ls env; do ln -sf busybox "$d/bin/$c"; done
            echo 'td-test srv1 base' > "$d/www/index.html"
            tar -C "$d" -c . | docker import -c 'ENV PATH=/bin' - td-test-srv1-base:1 >/dev/null
            rm -rf "$d"
            docker network inspect td-test-apps >/dev/null 2>&1 || docker network create --label io.terminaldeck.managed=true td-test-apps >/dev/null
            """
            let made = try Self.ssh(base)
            log.add("base image: code \(made.code) \(made.err)")
            try Self.ssh("nohup sh -c \"printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok' | timeout 120 nc -l -q 2 127.0.0.1 18099 > /var/lib/td-test-terminaldeck-server/td-test-alert.out\" >/dev/null 2>&1 &")
            let saved = try await call("apps:server:alerts:save", [("channels", .array([BackendAppsValidation.object([
                ("id", .string("td-test-hook")), ("kind", .string("webhook")), ("url", .string("http://127.0.0.1:18099/td-test-alert"))])]))])
            log.add("alerts saved: " + saved.compact)
            try Self.ssh("docker run -d --name td-test-srv1-crash --label io.terminaldeck.managed=true --label io.terminaldeck.app=td-test-srv1 --restart on-failure:5 td-test-srv1-base:1 sh -c 'exit 3' >/dev/null")
            let alerted = try Self.waitFor(90, log, "webhook received the restart-loop alert") {
                try Self.ssh("cat /var/lib/td-test-terminaldeck-server/td-test-alert.out 2>/dev/null").out.contains("keeps restarting")
            }
            #expect(alerted)
            log.add("alert request: " + (try Self.ssh("head -c 900 /var/lib/td-test-terminaldeck-server/td-test-alert.out").out))
            log.add("alert history: " + (try await call("apps:server:alerts:history", [("limit", .number(5))])).compact)
            try Self.ssh("docker rm -f td-test-srv1-crash >/dev/null 2>&1; rm -f /var/lib/td-test-terminaldeck-server/td-test-alert.out")

            // 4. Cleanup dry-run lists only our labelled leftovers; then the real run.
            try Self.ssh("""
            set -eu; d=$(mktemp -d /tmp/td-test-srv1.XXXXXX); mkdir "$d/x"; echo 1 > "$d/x/one"
            tar -C "$d/x" -c . | docker import -c 'LABEL io.terminaldeck.managed=true' -c 'LABEL io.terminaldeck.app=td-test-srv1' - td-test-srv1-tmp:1 >/dev/null
            echo 2 > "$d/x/one"; tar -C "$d/x" -c . | docker import -c 'LABEL io.terminaldeck.managed=true' -c 'LABEL io.terminaldeck.app=td-test-srv1' - td-test-srv1-tmp:1 >/dev/null
            rm -rf "$d"
            """)
            let dangling = try Self.ssh("docker images -q --no-trunc --filter dangling=true --filter label=io.terminaldeck.app=td-test-srv1").out.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = try await call("apps:server:cleanup:preview")
            log.add("cleanup preview: " + preview.compact)
            let ids = (preview["items"].elements ?? []).compactMap { $0["id"].string }
            #expect(ids == [dangling], "dry run lists exactly our dangling image")
            let imagesBefore = try Self.ssh("docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -v td-test | sort").out
            let cleaned = try await call("apps:server:cleanup:run")
            log.add("cleanup run: " + cleaned.compact)
            #expect(try Self.ssh("docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -v td-test | sort").out == imagesBefore, "foreign images untouched")
            #expect(try Self.ssh("docker image inspect \(dangling) >/dev/null 2>&1; echo $?").out.hasPrefix("1"))

            // 5. A scheduled job runs inside the app on its own (systemd timer).
            let manual = try Self.ssh("docker run -d --name td-test-srv1-manual --label io.terminaldeck.managed=true --label io.terminaldeck.app=td-test-srv1 --network td-test-apps td-test-srv1-base:1 httpd -f -p 8080 -h /www").out.trimmingCharacters(in: .whitespacesAndNewlines)
            let state = #"{"id":"td-test-srv1","name":"td-test-srv1","kind":"app","status":"running","containerId":"\#(manual)","source":{"kind":"github","repository":"td-test/srv1","branch":"main","build":"dockerfile","port":8080},"deployments":[]}"#
            try Self.ssh("set -eu; install -d -m 0700 /var/lib/td-test-apps /var/lib/td-test-apps/td-test-srv1; cat > /var/lib/td-test-apps/td-test-srv1/state.json; chmod 600 /var/lib/td-test-apps/td-test-srv1/state.json", stdin: Data(state.utf8))
            let job = try await call("apps:server:jobs:save", [appField, ("jobId", .string("tick")), ("name", .string("Tick")), ("schedule", .string("*:*:00")), ("command", .string("echo td-test-job-ok; date"))])
            log.add("job saved: " + job.compact)
            let ran = try Self.waitFor(180, log, "timer ran the job") {
                try Self.ssh("cat /var/lib/td-test-apps/td-test-srv1/jobs/tick.last.json 2>/dev/null").out.replacingOccurrences(of: " ", with: "").contains("\"ok\":true")
            }
            #expect(ran)
            let jobLog = try await call("apps:server:jobs:log", [appField, ("jobId", .string("tick"))])
            log.add("job log: " + jobLog.compact)
            #expect(jobLog["log"].string?.contains("td-test-job-ok") == true)

            // 6. Auto-deploy through the server endpoint behind Caddy (CI link, then a signed push).
            let auto = try await call("apps:server:autodeploy:apply", [appField, ("enabled", .bool(true))])
            log.add("autodeploy: " + auto.compact)
            try Self.ssh("""
            set -eu
            r=/var/lib/td-test-apps/td-test-srv1/td-test-src.git; w=$(mktemp -d /tmp/td-test-srv1-src.XXXXXX)
            git init -q --bare -b main "$r"
            git -C "$w" init -q -b main
            printf 'FROM td-test-srv1-base:1\\nCOPY www /www\\nEXPOSE 8080\\nCMD ["httpd","-f","-p","8080","-h","/www"]\\n' > "$w/Dockerfile"
            mkdir "$w/www"; echo 'td-test srv1 v1' > "$w/www/index.html"
            git -C "$w" add -A; git -C "$w" -c user.name=td-test -c user.email=td-test@example.invalid commit -q -m v1
            git -C "$w" push -q "$r" main; rm -rf "$w"
            printf 'file://%s\\n' "$r" > /etc/td-test-terminaldeck/apps/td-test-srv1/source-url; chmod 600 /etc/td-test-terminaldeck/apps/td-test-srv1/source-url
            """)
            let link = try await call("apps:server:autodeploy:link", [appField])
            let token = link["token"].string ?? ""
            log.add("deploy link: " + (link["url"].string ?? "?") + " (token masked)")
            var via = "public HTTPS"
            var accepted = false
            for _ in 0..<12 where !accepted {
                let r = try Self.curlLocal(["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "15", "-X", "POST", "-H", "Authorization: Bearer \(token)", "https://\(Self.hooks)/deploy/\(Self.app)"])
                accepted = r == "202"
                if !accepted { try await Task.sleep(for: .seconds(5)) }
            }
            if !accepted {
                via = "on-server through Caddy (-k; certificate not issued yet)"
                accepted = try Self.ssh("curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve \(Self.hooks):443:127.0.0.1 -X POST -H 'Authorization: Bearer \(token)' https://\(Self.hooks)/deploy/\(Self.app)").out == "202"
            }
            log.add("deploy link accepted=\(accepted) via \(via)")
            #expect(accepted)
            let live1 = try Self.waitFor(300, log, "link deploy went live") {
                try Self.ssh("grep -q 'is live' /var/lib/td-test-terminaldeck-server/deploys/td-test-srv1.log 2>/dev/null && echo yes").out.contains("yes")
            }
            #expect(live1)
            log.add("deploy log 1: " + (try await call("apps:server:deploy:log", [appField])).compact)

            let commit = try Self.ssh("""
            set -eu
            r=/var/lib/td-test-apps/td-test-srv1/td-test-src.git; w=$(mktemp -d /tmp/td-test-srv1-src.XXXXXX)
            git clone -q "$r" "$w/c" 2>/dev/null; echo 'td-test srv1 v2' > "$w/c/www/index.html"
            git -C "$w/c" -c user.name=td-test -c user.email=td-test@example.invalid commit -q -am v2; git -C "$w/c" push -q origin main
            git -C "$w/c" rev-parse HEAD; rm -rf "$w"
            """).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = try await call("apps:server:autodeploy:reveal", [appField])["secret"].string ?? ""
            let body = #"{"ref":"refs/heads/main","after":"\#(commit)","repository":{"full_name":"td-test/srv1","default_branch":"main"}}"#
            let signature = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: Data(secret.utf8))).map { String(format: "%02x", $0) }.joined()
            let pushed = try Self.ssh("curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve \(Self.hooks):443:127.0.0.1 -X POST -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' -H 'X-GitHub-Delivery: td-test-\(UUID().uuidString.lowercased())' -H 'X-Hub-Signature-256: sha256=\(signature)' --data-binary @- https://\(Self.hooks)/hooks/github/\(Self.app)", stdin: Data(body.utf8)).out
            log.add("signed push answered \(pushed)")
            #expect(pushed == "202")
            let live2 = try Self.waitFor(300, log, "push deploy went live with the pushed commit") {
                let text = try Self.ssh("cat /var/lib/td-test-terminaldeck-server/deploys/td-test-srv1.log 2>/dev/null; cat /var/lib/td-test-apps/td-test-srv1/state.json").out
                return text.contains("is live") && text.contains(commit)
            }
            #expect(live2)
            let page = try Self.ssh("curl -sk --max-time 10 --resolve \(Self.appHost):443:127.0.0.1 https://\(Self.appHost)/").out
            log.add("app answers: " + page)
            #expect(page.contains("td-test srv1 v2"))
            log.add("state after deploys: " + (try Self.ssh("cat /var/lib/td-test-apps/td-test-srv1/state.json").out))

            // 7. Remove Terminal Deck from the server (td-test layout).
            _ = try await call("apps:server:jobs:remove", [appField, ("jobId", .string("tick"))])
            let removed = try await call("apps:server:setup:remove", [("confirmation", .string(Self.host))])
            log.add("remove: " + removed.compact)
            #expect(removed["removed"].bool == true)
        } catch { failure = error; log.add("FAILED: \(error)") }

        // Harness cleanup of everything the run itself created (always runs).
        let newCache = try Self.ssh("docker buildx du --verbose 2>/dev/null | awk '/^ID:/{print $2}' | sort", timeout: 60).out
            .split(separator: "\n").filter { !cacheBefore.split(separator: "\n").contains($0) }
        let cleanup = """
        set +e
        curl -s -o /dev/null -X DELETE http://127.0.0.1:2019/id/td-test-td-test-srv1
        curl -s -o /dev/null -X DELETE http://127.0.0.1:2019/id/td-test--hooks
        systemctl disable --now td-test-terminaldeck-watch.service td-test-terminaldeck-check.timer td-test-terminaldeck-cleanup.timer td-test-terminaldeck-hook.socket td-test-td-test-srv1_job_tick.timer >/dev/null 2>&1
        rm -f /etc/systemd/system/td-test-terminaldeck-* /etc/systemd/system/td-test-td-test-srv1_job_*; systemctl daemon-reload; systemctl reset-failed >/dev/null 2>&1
        for c in $(docker ps -a --format '{{.Names}}' | grep -E '^td-test-(td-test-)?srv1-'); do docker rm -f "$c" >/dev/null; done
        for i in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^td-test-(td-test-)?srv1[-:]'); do docker rmi "$i" >/dev/null; done
        for i in $(docker images -q --filter label=io.terminaldeck.app=td-test-srv1); do docker rmi "$i" >/dev/null; done
        \(networkExisted ? "" : "[ -z \"$(docker network inspect -f '{{range .Containers}}x{{end}}' td-test-apps 2>/dev/null)\" ] && docker network rm td-test-apps >/dev/null 2>&1")
        \(newCache.map { "docker builder prune -f --filter id=\($0) >/dev/null 2>&1" }.joined(separator: "\n"))
        rm -rf /var/lib/td-test-apps/td-test-srv1; rm -f /var/lib/td-test-apps/router.json; rmdir /var/lib/td-test-apps 2>/dev/null; rm -rf /var/lib/td-test-caddy-lock /opt/td-test-terminaldeck /etc/td-test-terminaldeck /var/lib/td-test-terminaldeck-server /tmp/td-test-srv1*
        rm -rf /var/lib/caddy/.local/share/caddy/certificates/*/td-test-srv1.* /var/lib/caddy/.local/share/caddy/certificates/*/td-test-hooks.*; sleep 20; rm -rf /var/lib/caddy/.local/share/caddy/certificates/*/td-test-srv1.* /var/lib/caddy/.local/share/caddy/certificates/*/td-test-hooks.*
        """
        log.add("harness cleanup removed \(newCache.count) build-cache records created by this run")
        _ = try Self.ssh(cleanup, timeout: 300)
        let after = try Self.inventory()
        log.add("AFTER inventory:\n" + after)
        #expect(after == before, "inventory after must equal before")
        log.add(after == before ? "PASS: inventory after == before" : "MISMATCH: inventory changed")
        if let failure { throw failure }
    }

    /// Calls the public endpoint from this Mac (the real internet path).
    static func curlLocal(_ args: [String]) throws -> String {
        let process = Process(); let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = args
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
