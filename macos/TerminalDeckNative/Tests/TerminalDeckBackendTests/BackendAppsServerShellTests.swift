import CryptoKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Runs the generated server helpers for real (POSIX sh) against fake docker,
/// systemctl and curl, in a private folder. Nothing touches this Mac's Docker
/// or any server. READY SRV1 gate; live-server test remains separately opt-in.
@Suite("SRV1 server helpers behave on a fake server", .serialized)
struct BackendAppsServerShellTests {
    /// A private fake server: generated helpers in <root>/opt/terminaldeck/bin,
    /// fake tools in <root>/fake, their state and call logs in <root>/fake/state.
    struct Sandbox {
        let root: URL, layout: BackendAppsServerLayout
        var fake: URL { root.appendingPathComponent("fake") }
        var state: URL { fake.appendingPathComponent("state") }

        init(prefix: String = "terminaldeck") throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("srv1-" + UUID().uuidString.prefix(8).lowercased())
            layout = prefix == "terminaldeck" ? try BackendAppsServerLayout(fsRoot: root.path)
                : try BackendAppsServerLayout(prefix: prefix, stateRoot: "/var/lib/" + prefix + "-apps", network: prefix + "-apps", fsRoot: root.path)
            for dir in [layout.bin, layout.etc + "/apps", layout.data, layout.state, layout.units, state.path + "/root", fake.path] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let helpers: [(String, String)] = [
                ("td-lib.sh", BackendAppsServerScripts.library(layout)), ("td-notify", BackendAppsServerScripts.notify(layout)),
                ("td-watch", BackendAppsServerScripts.watch(layout)), ("td-check", BackendAppsServerScripts.check(layout)),
                ("td-cleanup", BackendAppsServerScripts.cleanup(layout)), ("td-job", BackendAppsServerScripts.job(layout)),
                ("td-deploy", BackendAppsServerDeployScript.deploy(layout)), ("td-hook", BackendAppsServerDeployScript.hook(layout))
            ]
            for (name, text) in helpers { try write(layout.bin + "/" + name, text, mode: 0o755) }
            try write(layout.opt + "/VERSION", "1\n")
            for (name, text) in Self.fakes { try write(fake.path + "/" + name, text, mode: 0o755) }
            for file in ["images.txt", "containers.txt", "events.txt", "docker.log", "systemctl.log", "curl.argv", "curl.config", "notify.log"] {
                try write(state.path + "/" + file, "")
            }
            if let dump = ProcessInfo.processInfo.environment["TD_SRV1_SCRIPT_DIR"] {
                for (name, text) in helpers { try? text.write(toFile: dump + "/" + name, atomically: true, encoding: .utf8) }
            }
        }

        func write(_ path: String, _ text: String, mode: Int = 0o644) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        func log(_ name: String) -> String { read(state.path + "/" + name) }

        @discardableResult
        func run(_ helper: String, _ args: [String] = [], stdin: Data? = nil, env: [String: String] = [:]) throws -> (code: Int32, out: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [layout.bin + "/" + helper] + args
            process.environment = ["PATH": fake.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "TD_JQ": "/usr/bin/jq", "FAKE_STATE": state.path, "HOME": root.path, "LC_ALL": "C"]
                .merging(env) { $1 }
            let output = Pipe(), input = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = input
            try process.run()
            if let stdin { input.fileHandleForWriting.write(stdin) }
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        /// Stand-in for the library's HMAC, run through the real shell function.
        func shellHMAC(key: String, data: String) throws -> String {
            try write(root.path + "/k", key); try write(root.path + "/d", data)
            try write(layout.bin + "/hmac-probe", ". '\(layout.bin)/td-lib.sh'\ntd_hmac_sha256 '\(root.path)/k' '\(root.path)/d'\n", mode: 0o755)
            return try run("hmac-probe").out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static let fakes: [(String, String)] = [
            ("docker", #"""
            #!/bin/sh
            F="$FAKE_STATE"
            echo "$*" >> "$F/docker.log"
            field() { awk -F'\t' -v id="$1" -v n="$2" '$1 == id {print $n}' "$3"; }
            case "$1" in
              info) echo "$F/root" ;;
              ps) awk -F'\t' 'NF {print $1}' "$F/containers.txt" ;;
              events) cat "$F/events.txt" ;;
              exec) printf '%s\n' "${FAKE_EXEC_OUT:-}"; exit "${FAKE_EXEC_CODE:-0}" ;;
              inspect)
                fmt=$3; id=$4
                awk -F'\t' -v id="$id" '$1 == id {f=1} END {exit !f}' "$F/containers.txt" || exit 1
                case "$fmt" in
                  *State.Running*) field "$id" 5 "$F/containers.txt" ;;
                  *State.Status*) echo running ;;
                  *io.terminaldeck.app*io.terminaldeck.managed*) printf '%s|%s\n' "$(field "$id" 3 "$F/containers.txt")" "$(field "$id" 4 "$F/containers.txt")" ;;
                  *.Image*) field "$id" 2 "$F/containers.txt" ;;
                  *) echo ;;
                esac ;;
              image)
                case "$2" in
                  ls)
                    case "$*" in
                      *dangling=true*label=io.terminaldeck.managed=true*) awk -F'\t' '$2 == "true" && $4 == "1" {print $1}' "$F/images.txt" ;;
                      *label=io.terminaldeck.managed=true*) awk -F'\t' '$2 == "true" {print $1}' "$F/images.txt" ;;
                      *) awk -F'\t' 'NF {print $1}' "$F/images.txt" ;;
                    esac ;;
                  inspect)
                    fmt=$4; id=$5
                    awk -F'\t' -v id="$id" '$1 == id {f=1} END {exit !f}' "$F/images.txt" || exit 1
                    case "$fmt" in
                      *io.terminaldeck.managed*) field "$id" 2 "$F/images.txt" | sed 's/^-$//' ;;
                      *io.terminaldeck.app*) field "$id" 3 "$F/images.txt" | sed 's/^-$//' ;;
                      *Size*) field "$id" 5 "$F/images.txt" ;;
                      *) echo ;;
                    esac ;;
                  rm)
                    id=$3
                    if awk -F'\t' -v id="$id" '$2 == id {found=1} END {exit !found}' "$F/containers.txt"; then echo "conflict: in use" >&2; exit 1; fi
                    awk -F'\t' -v id="$id" '$1 != id' "$F/images.txt" > "$F/images.new" && mv "$F/images.new" "$F/images.txt" ;;
                esac ;;
              *) : ;;
            esac
            exit 0
            """#),
            ("systemctl", #"""
            #!/bin/sh
            echo "$*" >> "$FAKE_STATE/systemctl.log"
            case "$1" in is-active) echo active ;; show) echo ;; esac
            exit 0
            """#),
            ("curl", #"""
            #!/bin/sh
            echo "$*" >> "$FAKE_STATE/curl.argv"
            case " $* " in *" -K - "*) cat >> "$FAKE_STATE/curl.config"; echo "----" >> "$FAKE_STATE/curl.config" ;; esac
            exit 0
            """#),
            ("timeout", #"""
            #!/bin/sh
            while :; do case "$1" in -*) shift ;; *) break ;; esac; done
            shift
            "$@"
            """#),
            ("hostname", "#!/bin/sh\necho fakebox\n")
        ]
    }

    static func hmac(_ key: String, _ data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(key.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    @Test func shellHmacMatchesGitHubsDocumentedExample() throws {
        let box = try Sandbox()
        // https://docs.github.com/webhooks/using-webhooks/validating-webhook-deliveries (test values)
        #expect(try box.shellHMAC(key: "It's a Secret to Everybody", data: "Hello, World!") == "757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17")
        let long = String(repeating: "k", count: 100)
        #expect(try box.shellHMAC(key: long, data: "{\"a\":1}\n") == Self.hmac(long, Data("{\"a\":1}\n".utf8)))
    }

    /// Asad 18:25: a server that also runs Coolify. Cleanup removes only our
    /// labelled leftovers; Traefik, Coolify's apps and its rollback images stay.
    @Test func cleanupBesideCoolifyChangesNothingForeign() throws {
        let box = try Sandbox()
        let foreign = [
            "sha256:aaa1\t-\t-\t0\t100\t# traefik (coolify-proxy)",
            "sha256:aaa2\t-\t-\t1\t200\t# coolify rollback, dangling",
            "sha256:aaa3\t-\t-\t0\t300\t# coolify app"
        ].map { $0.components(separatedBy: "\t#")[0] }
        let ours = ["sha256:bbb1\ttrue\tweb\t1\t400", "sha256:bbb2\ttrue\tweb\t0\t500", "sha256:bbb3\ttrue\tweb\t0\t600", "sha256:bbb4\ttrue\tweb\t0\t700"]
        try box.write(box.state.path + "/images.txt", (foreign + ours).joined(separator: "\n") + "\n")
        try box.write(box.state.path + "/containers.txt", "c1\tsha256:aaa1\t-\t-\ttrue\nc2\tsha256:aaa3\t-\t-\ttrue\nc3\tsha256:bbb4\tweb\ttrue\ttrue\n")
        // Mac deploys keep the newest row first (U2, #2).
        try box.write(box.layout.state + "/web/state.json", #"{"id":"web","name":"web","kind":"app","deployments":[{"id":"d4","imageId":"sha256:bbb4","createdAt":4000},{"id":"d3","imageId":"sha256:bbb3","createdAt":3000},{"id":"d2","imageId":"sha256:bbb2","createdAt":2000}]}"#)

        let preview = try box.run("td-cleanup", ["--dry-run"])
        let dry = try NativeRPCValue.parseJSON(Data(preview.out.utf8))
        #expect(dry["dryRun"].bool == true)
        #expect((dry["items"].elements ?? []).map { $0["id"].string ?? "" } == ["sha256:bbb1"])
        #expect(!box.log("docker.log").contains("image rm"))

        _ = try box.run("td-cleanup")
        var images = box.log("images.txt")
        for line in foreign { #expect(images.contains(line), "foreign image changed: \(line)") }
        #expect(!images.contains("sha256:bbb1") && images.contains("sha256:bbb2") && images.contains("sha256:bbb3"))

        try box.write(box.layout.etc + "/cleanup.json", #"{"removeOldVersions":true,"keepVersions":2}"#)
        _ = try box.run("td-cleanup")
        images = box.log("images.txt")
        for line in foreign { #expect(images.contains(line)) }
        #expect(!images.contains("sha256:bbb2"), "older version beyond keepVersions goes")
        #expect(images.contains("sha256:bbb3"), "the recent version stays though it is not the last row")
        #expect(images.contains("sha256:bbb4"), "the running version stays")
        let rows = try NativeRPCValue.parseJSON(Data(box.read(box.layout.state + "/web/state.json").utf8))["deployments"].elements ?? []
        #expect(rows.map { $0["imageRemoved"].bool == true } == [false, false, true], "only the removed version loses Roll back")
        #expect(!FileManager.default.fileExists(atPath: box.layout.state + "/web/.lock"))
        let calls = box.log("docker.log")
        for banned in ["system prune", "image prune", "volume prune", "container prune", "builder prune", "image rm sha256:aaa"] {
            #expect(!calls.contains(banned), "\(banned)")
        }
        #expect(box.read(box.layout.data + "/cleanup-last.json").contains("\"removed\""))
    }

    /// U2 (#2): the 5-minute check alerts on the newest deploy by time, not on the last row.
    @Test func checkAlertsOnlyWhenTheNewestDeployFailed() throws {
        let box = try Sandbox()
        try box.write(box.layout.bin + "/td-notify", "#!/bin/sh\necho \"$*\" >> \"$FAKE_STATE/notify.log\"\n", mode: 0o755)
        try box.write(box.layout.etc + "/alerts.json", #"{"thresholds":{"diskPercent":101}}"#)
        try box.write(box.layout.state + "/web/state.json", #"{"id":"web","kind":"app","deployments":[{"id":"d2","status":"running","createdAt":2000},{"id":"d1","status":"failed","createdAt":1000}]}"#)
        _ = try box.run("td-check")
        #expect(!box.log("notify.log").contains("deployfail:web"), "an old failure under a newer success is not an alert")
        try box.write(box.layout.state + "/web/state.json", #"{"id":"web","kind":"app","deployments":[{"id":"d3","status":"failed","createdAt":3000},{"id":"d2","status":"running","createdAt":2000}]}"#)
        _ = try box.run("td-check")
        #expect(box.log("notify.log").contains("deployfail:web:d3"))
    }

    @Test func hookDeploysOnlySignedPushesForTheSavedBranch() throws {
        let box = try Sandbox()
        try box.write(box.layout.state + "/web/state.json", #"{"id":"web","name":"web","kind":"app","source":{"kind":"github","repository":"Acme/Web","branch":"main"}}"#)
        try box.write(box.layout.etc + "/apps/web/autodeploy.json", #"{"enabled":true}"#)
        let secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        try box.write(box.layout.etc + "/apps/web/hook-secret", secret)
        let revision = String(repeating: "a1", count: 20)
        func request(_ body: String, signature: String?, delivery: String, event: String = "push", path: String = "/hooks/github/web") -> Data {
            var head = "POST \(path) HTTP/1.1\r\nHost: hooks.example\r\nX-GitHub-Event: \(event)\r\nX-GitHub-Delivery: \(delivery)\r\nContent-Type: application/json\r\n"
            if let signature { head += "X-Hub-Signature-256: sha256=\(signature)\r\n" }
            return Data((head + "Content-Length: \(body.utf8.count)\r\n\r\n" + body).utf8)
        }
        let push = #"{"ref":"refs/heads/main","after":"\#(revision)","repository":{"full_name":"acme/web","default_branch":"main"}}"#
        let queue = box.layout.data + "/deploy-queue/web.json"

        let forged = try box.run("td-hook", stdin: request(push, signature: String(repeating: "0", count: 64), delivery: "11111111-aaaa"))
        #expect(forged.out.hasPrefix("HTTP/1.1 401"))
        #expect(!FileManager.default.fileExists(atPath: queue))

        let good = try box.run("td-hook", stdin: request(push, signature: Self.hmac(secret, Data(push.utf8)), delivery: "22222222-bbbb"))
        #expect(good.out.hasPrefix("HTTP/1.1 202"))
        #expect(box.read(queue).contains(revision) && box.read(queue).contains("\"push\""))
        #expect(box.log("systemctl.log").contains("start --no-block terminaldeck-deploy@web.service"))

        try FileManager.default.removeItem(atPath: queue)
        let replay = try box.run("td-hook", stdin: request(push, signature: Self.hmac(secret, Data(push.utf8)), delivery: "22222222-bbbb"))
        #expect(replay.out.contains("duplicate") && !FileManager.default.fileExists(atPath: queue))

        let other = #"{"ref":"refs/heads/dev","after":"\#(revision)","repository":{"full_name":"acme/web"}}"#
        let branch = try box.run("td-hook", stdin: request(other, signature: Self.hmac(secret, Data(other.utf8)), delivery: "33333333-cccc"))
        #expect(branch.out.contains("ignored") && !FileManager.default.fileExists(atPath: queue))

        let token = "abcdefghijklmnopqrstuvwxyz012345"
        try box.write(box.layout.etc + "/apps/web/deploy-token.sha256", SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined())
        let wrong = try box.run("td-hook", stdin: Data("POST /deploy/web HTTP/1.1\r\nAuthorization: Bearer \(String(repeating: "x", count: 32))\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(wrong.out.hasPrefix("HTTP/1.1 401") && !FileManager.default.fileExists(atPath: queue))
        let inAddress = try box.run("td-hook", stdin: Data("POST /deploy/web?token=\(token) HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(inAddress.out.hasPrefix("HTTP/1.1 401") && !FileManager.default.fileExists(atPath: queue), "the key is taken from the header only (U87, #592)")
        let link = try box.run("td-hook", stdin: Data("POST /deploy/web HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(link.out.hasPrefix("HTTP/1.1 202") && box.read(queue).contains("\"link\""))

        try box.write(box.layout.etc + "/apps/web/autodeploy.json", #"{"enabled":false}"#)
        try FileManager.default.removeItem(atPath: queue)
        let off = try box.run("td-hook", stdin: Data("POST /deploy/web HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(off.out.hasPrefix("HTTP/1.1 404") && !FileManager.default.fileExists(atPath: queue))
        let duplicate = try box.run("td-hook", stdin: Data("POST /deploy/web HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 5\r\n\r\n".utf8))
        #expect(duplicate.out.hasPrefix("HTTP/1.1 400"))
    }

    @Test func notifyKeepsSecretsOffTheCommandLineAndRemindsOnlyLater() throws {
        let box = try Sandbox()
        let token = "123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef12"
        try box.write(box.layout.etc + "/alerts.json", #"{"enabled":true,"remindMinutes":60,"channels":[{"id":"phone","kind":"telegram","botToken":"\#(token)","chatId":"42"},{"id":"ops","kind":"webhook","url":"https://example.test/h","secret":"supersecretvalue"}]}"#)
        _ = try box.run("td-notify", ["disk:/", "warning", "Disk is 91% full", "The disk is full."])
        let argv = box.log("curl.argv"), config = box.log("curl.config")
        #expect(argv.split(separator: "\n").count == 2)
        #expect(!argv.contains("ABCDEFGHIJ") && !argv.contains("supersecretvalue"))
        #expect(config.contains("bot\(token)/sendMessage") && config.contains("X-Terminal-Deck-Signature: sha256="))
        #expect(!config.contains("supersecretvalue"))
        _ = try box.run("td-notify", ["disk:/", "warning", "Disk is 92% full", "Still full."])
        #expect(box.log("curl.argv").split(separator: "\n").count == 2, "same problem within the reminder window stays quiet")
        _ = try box.run("td-notify", ["--resolve", "disk:/", "Back below the limit."])
        #expect(box.log("curl.argv").split(separator: "\n").count == 4)
        #expect(box.log("curl.config").contains("Resolved: Disk is 91% full"))
        let history = box.read(box.layout.data + "/alerts/history.jsonl")
        #expect(history.contains("\"delivered\":[{\"id\":\"phone\",\"ok\":true},{\"id\":\"ops\",\"ok\":true}]") && !history.contains("ABCDEFGHIJ"))
        let test = try box.run("td-notify", ["--test"])
        #expect(test.out.contains("\"phone\"") && test.out.contains("\"ok\":true"))
    }

    @Test func watcherAlertsForOurAppsAndOptInContainersOnly() throws {
        let box = try Sandbox()
        try box.write(box.layout.bin + "/td-notify", "#!/bin/sh\necho \"$*\" >> \"$FAKE_STATE/notify.log\"\n", mode: 0o755)
        try box.write(box.layout.etc + "/alerts.json", #"{"watch":{"containers":["keep-me"]}}"#)
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64)
        try box.write(box.state.path + "/events.txt", [
            #"{"Type":"container","Action":"oom","Actor":{"ID":"\#(a)","Attributes":{"name":"terminaldeck-web-1","io.terminaldeck.managed":"true","io.terminaldeck.app":"web"}}}"#,
            #"{"Type":"container","Action":"oom","Actor":{"ID":"\#(b)","Attributes":{"name":"coolify-db","coolify.managed":"true"}}}"#,
            #"{"Type":"container","Action":"oom","Actor":{"ID":"\#(c)","Attributes":{"name":"keep-me"}}}"#,
            #"{"Type":"container","Action":"health_status: unhealthy","Actor":{"ID":"\#(a)","Attributes":{"name":"terminaldeck-web-1","io.terminaldeck.managed":"true","io.terminaldeck.app":"web"}}}"#,
            #"{"Type":"container","Action":"oom","Actor":{"ID":"\#(b)","Attributes":{"name":"evil;rm -rf /","io.terminaldeck.managed":"true","io.terminaldeck.app":"-bad"}}}"#
        ].joined(separator: "\n") + "\n")
        _ = try box.run("td-watch")
        let notes = box.log("notify.log")
        #expect(notes.contains("oom:web critical"))
        #expect(notes.contains("oom:keep-me critical"))
        #expect(notes.contains("unhealthy:web warning"))
        #expect(!notes.contains("coolify-db") && !notes.contains("evil"))
    }

    @Test func jobRunsInsideTheAppKeepsItsResultAndAlertsOnFailure() throws {
        let box = try Sandbox()
        try box.write(box.layout.bin + "/td-notify", "#!/bin/sh\necho \"$*\" >> \"$FAKE_STATE/notify.log\"\n", mode: 0o755)
        let cid = String(repeating: "c0", count: 32)
        try box.write(box.state.path + "/containers.txt", "\(cid)\tsha256:x\tweb\ttrue\ttrue\n")
        try box.write(box.layout.state + "/web/state.json", #"{"id":"web","name":"web","kind":"app","containerId":"\#(cid)"}"#)
        try box.write(box.layout.state + "/web/jobs/nightly.json", #"{"id":"nightly","name":"Nightly report","command":"php artisan report","timeoutSeconds":60,"enabled":true}"#)
        _ = try box.run("td-job", ["web", "nightly"], env: ["FAKE_EXEC_CODE": "3", "FAKE_EXEC_OUT": "boom"])
        let last = try NativeRPCValue.parseJSON(Data(box.read(box.layout.state + "/web/jobs/nightly.last.json").utf8))
        #expect(last["exitCode"].number == 3 && last["ok"].bool == false)
        #expect(box.read(box.layout.state + "/web/jobs/nightly.log").contains("boom"))
        #expect(box.log("docker.log").contains("exec \(cid) sh -c php artisan report"))
        #expect(box.log("notify.log").contains("job:web:nightly warning"))

        _ = try box.run("td-job", ["web", "nightly"], env: ["FAKE_EXEC_CODE": "0", "FAKE_EXEC_OUT": "ok"])
        #expect(box.log("notify.log").contains("--resolve job:web:nightly"))

        // A foreign container with the same ID shape is never exec'd into.
        try box.write(box.state.path + "/containers.txt", "\(cid)\tsha256:x\t-\t-\ttrue\n")
        _ = try box.run("td-job", ["web", "nightly"])
        #expect(box.log("docker.log").components(separatedBy: "exec ").count == 3)

        try box.write(box.layout.units + "/terminaldeck-gone_job_nightly.timer", BackendAppsServerLayout.marker + " v1\n")
        _ = try box.run("td-job", ["gone", "nightly"])
        #expect(box.log("systemctl.log").contains("disable --now terminaldeck-gone_job_nightly.timer"))
    }

    /// A td-test app whose source is a local repository, with a stand-in recipe that
    /// records what it was asked (deploy, or recover an earlier deploy).
    static func recipeApp(_ box: Sandbox, state: String) throws -> (dir: String, head: String) {
        try box.write(box.layout.bin + "/td-notify", "#!/bin/sh\necho \"$*\" >> \"$FAKE_STATE/notify.log\"\n", mode: 0o755)
        let dir = box.layout.state + "/td-test-web"
        try box.write(dir + "/state.json", state)
        try box.write(box.layout.etc + "/server.json", #"{"publicIPv4":"203.0.113.9"}"#)
        let repo = dir + "/src.git", work = box.root.path + "/w"
        func git(_ args: [String]) throws -> String {
            let process = Process(); let out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = args
            process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": box.root.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = out; process.standardError = FileHandle.nullDevice
            try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "--bare", "-b", "main", repo])
        _ = try git(["init", "-q", "-b", "main", work])
        try box.write(work + "/Dockerfile", "FROM scratch\n")
        _ = try git(["-C", work, "add", "-A"])
        _ = try git(["-C", work, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "one"])
        _ = try git(["-C", work, "push", "-q", repo, "main"])
        try box.write(box.layout.etc + "/apps/td-test-web/source-url", "file://" + repo + "\n")
        try box.write(dir + "/recipe.sh", #"""
        #!/bin/sh
        d=$(cd "$(dirname "$0")" && pwd); mkdir -p "$d/deploys"
        if [ "$1" = recover ]; then echo "$2" >> "$d/recovered.seen"; printf 'error=interrupted\nexit=16\n' >> "$d/deploys/$2.result"; exit 0; fi
        r="$d/deploys/$TD_DEPLOYMENT.result"
        [ -f "$TD_SOURCE/Dockerfile" ] || { printf 'error=source-missing\nexit=10\n' > "$r"; exit 10; }
        printf '%s' "$TD_PREVIOUS" > "$d/previous.seen"
        if [ "${FAKE_RECIPE_EXIT:-0}" = 0 ]; then
          printf 'tag=td-test-td-test-web:%s\nimage=sha256:%s\nport=8080\ncontainer=newc\nupstream=172.18.0.9\nprobe=server\nretired=oldc\npruned=sha256:old\nexit=0\n' "$TD_DEPLOYMENT" 0000000000000000000000000000000000000000000000000000000000000000 > "$r"
          exit 0
        fi
        printf 'error=health-failed\nexit=12\n' > "$r"; exit 12
        """#, mode: 0o700)
        return (dir, try git(["-C", work, "rev-parse", "HEAD"]))
    }

    /// DESIGN SRV1+SRV2: the server-side deploy clones, then hands the steps to
    /// the app's recipe and records the result exactly like the Mac deployer.
    @Test func serverDeployRunsTheAppRecipeAndRecordsTheResult() throws {
        let box = try Sandbox(prefix: "td-test")
        let (dir, head) = try Self.recipeApp(box, state: #"{"id":"td-test-web","name":"web","kind":"app","containerId":"oldc","activeDeploymentId":"d0","source":{"kind":"github","repository":"td-test/web","branch":"main","build":"dockerfile"},"deployments":[{"id":"d0","containerId":"oldc","imageId":"sha256:old","status":"running"}]}"#)

        let ok = try box.run("td-deploy", ["td-test-web"])
        #expect(ok.code == 0 && ok.out.contains("\"recipe\":true"))
        var state = try NativeRPCValue.parseJSON(Data(box.read(dir + "/state.json").utf8))
        let row = state["deployments"].elements?.first ?? .null
        #expect(state["containerId"].string == "newc" && state["activeDeploymentId"] == row["id"])
        #expect(row["status"].string == "running" && row["commit"].string == head && row["port"].number == 8080)
        #expect(state["deployments"].elements?.last?["instanceState"].string == "stopped")
        #expect(state["deployments"].elements?.last?["imageRemoved"].bool == true, "a version the recipe removed loses Roll back")
        #expect(state["pendingDeploymentId"] == .missing)
        #expect(state["address"].string == "https://td-test-web.203-0-113-9.sslip.io")
        #expect(box.read(dir + "/previous.seen") == "oldc")
        #expect(!FileManager.default.fileExists(atPath: dir + "/.lock"))

        let failed = try box.run("td-deploy", ["td-test-web"], env: ["FAKE_RECIPE_EXIT": "1"])
        #expect(failed.code == 1)
        state = try NativeRPCValue.parseJSON(Data(box.read(dir + "/state.json").utf8))
        #expect(state["deployments"].elements?.first?["failure"].string == "health-failed", "server deploys add the newest row first (U2, #67)")
        #expect(state["containerId"].string == "newc" && state["lastError"].string != nil && state["pendingDeploymentId"] == .missing)
        #expect(box.log("notify.log").contains("deployfail:td-test-web"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/.lock"))
        let builds = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/td-test-builds")) ?? []
        #expect(builds.isEmpty, "build folders are removed after each run")
    }

    /// U87 (#572): a deploy left unfinished (the server restarted mid-recipe, or the Mac went
    /// away) is recorded by the next server-side deploy instead of refusing every later push.
    @Test func serverDeploySettlesAnEarlierUnfinishedDeployFirst() throws {
        let box = try Sandbox(prefix: "td-test")
        let source = #""source":{"kind":"github","repository":"td-test/web","branch":"main","build":"dockerfile"}"#
        let (dir, _) = try Self.recipeApp(box, state: #"{"id":"td-test-web","name":"web","kind":"app","containerId":"oldc","activeDeploymentId":"d0","pendingDeploymentId":"td-test-deploy-done",\#(source),"deployments":[{"id":"td-test-deploy-done","status":"deploying","createdAt":2000},{"id":"d0","containerId":"oldc","status":"running","createdAt":1000}]}"#)
        try box.write(dir + "/deploys/td-test-deploy-done.result", "image=sha256:\(String(repeating: "1", count: 64))\ncontainer=donec\nupstream=172.18.0.5\nexit=0\n")
        let first = try box.run("td-deploy", ["td-test-web"])
        #expect(first.code == 0)
        var state = try NativeRPCValue.parseJSON(Data(box.read(dir + "/state.json").utf8))
        var rows = state["deployments"].elements ?? []
        #expect(rows.first { $0["id"].string == "td-test-deploy-done" }?["status"].string == "running", "the finished earlier deploy is recorded")
        #expect(box.read(dir + "/previous.seen") == "donec", "the new deploy replaces the version the earlier one started")
        #expect(state["containerId"].string == "newc" && state["pendingDeploymentId"] == .missing)

        // Died with the server: its result went quiet long ago and has no exit line.
        try box.write(dir + "/state.json", #"{"id":"td-test-web","name":"web","kind":"app","containerId":"newc","activeDeploymentId":"d0","pendingDeploymentId":"td-test-deploy-gone",\#(source),"deployments":[{"id":"td-test-deploy-gone","status":"deploying","createdAt":3000},{"id":"d0","containerId":"newc","status":"running","createdAt":1000}]}"#)
        try box.write(dir + "/deploys/td-test-deploy-gone.result", "recipe=1\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 60)], ofItemAtPath: dir + "/deploys/td-test-deploy-gone.result")
        try box.write(dir + "/td-test-builds/td-test-deploy-gone/source/Dockerfile", "FROM scratch\n")
        let second = try box.run("td-deploy", ["td-test-web"])
        #expect(second.code == 0, "the push after a restart deploys instead of asking for recovery")
        state = try NativeRPCValue.parseJSON(Data(box.read(dir + "/state.json").utf8))
        rows = state["deployments"].elements ?? []
        #expect(rows.first { $0["id"].string == "td-test-deploy-gone" }?["failure"].string == "interrupted")
        #expect(box.read(dir + "/recovered.seen") == "td-test-deploy-gone\n", "what it half made is cleaned up first")
        #expect(!FileManager.default.fileExists(atPath: dir + "/td-test-builds/td-test-deploy-gone"))
        #expect(state["pendingDeploymentId"] == .missing && state["activeDeploymentId"] == rows.first?["id"])
        #expect(!FileManager.default.fileExists(atPath: dir + "/.lock"))
    }

    /// U87 (#580): the app's recipe is the only deploy path. Without one the server
    /// deploy stops before it downloads or builds anything.
    @Test func serverDeployRunsOnlyTheAppsRecipe() throws {
        let box = try Sandbox(prefix: "td-test")
        let (dir, _) = try Self.recipeApp(box, state: #"{"id":"td-test-web","name":"web","kind":"app","source":{"kind":"github","repository":"td-test/web","branch":"main","build":"dockerfile"}}"#)
        try FileManager.default.removeItem(atPath: dir + "/recipe.sh")
        let result = try box.run("td-deploy", ["td-test-web"])
        #expect(result.code == 1 && result.out.contains("Deploy this app once from Terminal Deck on your Mac first."))
        let state = try NativeRPCValue.parseJSON(Data(box.read(dir + "/state.json").utf8))
        #expect(state["deployments"] == .missing, "no deploy row is started")
        #expect(!FileManager.default.fileExists(atPath: dir + "/td-test-builds"), "nothing is downloaded")
        #expect(!box.log("docker.log").contains("build"), "nothing is built outside the recipe")
    }
}
