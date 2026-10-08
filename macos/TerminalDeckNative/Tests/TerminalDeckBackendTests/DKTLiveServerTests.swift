import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Skipped in normal CI. Only the owner-run live-check.sh opts into a real host.
/// This is a readiness/safety check, not a deploy/rollback/restore smoke test.
final class DKTLiveServerTests: XCTestCase {
    func testOwnerGatedReadOnlyRun() async throws {
        let configuration = try DKTLiveProbeConfiguration.load()
        let target = try DKTLiveTarget.resolve(configuration.target)
        let evidence = try DKTLiveProbeConfiguration.evidence()
        try DKTLiveLogWriter.validateWritable()
        let trace = DKTLiveCheckTrace()
        let _: Bool = try await DKTLiveRunHarness.run(target: target, evidence: evidence, inventory: {
            let label = await trace.inventoryLabel()
            await trace.append("started: " + label + " (containers, images, volumes, networks, Caddy routes/config and server folders/backups)")
            do {
                let snapshot = try DKTLiveProbeCache.shared.snapshot(configuration: configuration, refresh: true)
                for name in snapshot.sections.keys.sorted() {
                    await trace.append(label + " read: " + name + " (exit " + String(snapshot.sections[name]?.status ?? -1) + ")")
                }
                let inventory = try snapshot.inventory()
                await trace.append("passed: " + label)
                return inventory
            } catch {
                await trace.append("failed: " + label)
                throw DKTLiveProbeFailure("The full live inventory is unavailable; no raw response is logged.")
            }
        }, body: { session in
            let snapshot = try DKTLiveProbeCache.shared.snapshot(configuration: configuration)
            try await DKTLiveReadOnlyChecks.run(snapshot: snapshot, configuration: configuration, session: session, trace: trace)
            return true
        }, cleanup: { _ in /* The readiness suite only reads; it creates no objects. */ }, record: { entry in
            let checks = await trace.snapshot()
            let outcome = entry.outcome == "passed" && checks.notChecked ? "passed-with-not-checked" : entry.outcome
            try DKTLiveLogWriter.append(.init(time: entry.time, target: entry.target,
                whatRan: checks.notes + entry.whatRan.map { "authorized read: " + $0 }, before: entry.before, after: entry.after,
                cleanupPassed: entry.cleanupPassed, outcome: outcome))
        })
    }
}

private actor DKTLiveCheckTrace {
    private var inventoryCalls = 0
    private var notes: [String] = []
    private var notChecked = false
    func inventoryLabel() -> String { inventoryCalls += 1; return inventoryCalls == 1 ? "before inventory" : "after inventory" }
    func append(_ note: String, notChecked: Bool = false) { notes.append(note); self.notChecked = self.notChecked || notChecked }
    func snapshot() -> (notes: [String], notChecked: Bool) { (notes, notChecked) }
}

/// All failures throw into the single run wrapper. No XCTest assertion can leave a false "passed" live record.
private enum DKTLiveReadOnlyChecks {
    static func run(snapshot: DKTLiveProbeSnapshot, configuration: DKTLiveProbeConfiguration,
                    session: DKTLiveRunSession, trace: DKTLiveCheckTrace) async throws {
        var failed = 0
        if await check("Linux platform and read tools", channel: "docker:status", session: session, trace: trace, body: {
            try require(snapshot.success("platform").trimmingCharacters(in: .whitespacesAndNewlines) == "Linux", "The approved target is not Linux.")
            _ = try snapshot.success("tools")
        }) == false { failed += 1 }
        if await check("private Docker socket, ping and Engine version", channel: "docker:status", session: session, trace: trace, body: {
            _ = try snapshot.success("socket")
            try require(snapshot.success("ping").trimmingCharacters(in: .whitespacesAndNewlines) == "OK", "Docker's private socket did not answer its ping.")
            let version = try snapshot.object("version")
            try require(version["ApiVersion"] as? String != nil && version["Os"] as? String == "linux", "Docker did not report a Linux Engine/API version.")
        }) == false { failed += 1 }
        if await check("no public Docker/Caddy control listeners", channel: "docker:status", session: session, trace: trace, body: {
            for row in try snapshot.success("listeners").split(separator: "\n") {
                let fields = row.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 4 else { throw DKTLiveProbeFailure("Listener output could not be checked safely.") }
                let endpoint = String(fields[3])
                guard let colon = endpoint.lastIndex(of: ":"), let port = Int(endpoint[endpoint.index(after: colon)...]) else {
                    throw DKTLiveProbeFailure("Listener address format is unavailable.")
                }
                guard [2375, 2376, 2019].contains(port) else { continue }
                let host = String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                try require(DKTLiveProbe.isLoopback(host), "A Docker or Caddy control port is bound beyond loopback.")
            }
        }) == false { failed += 1 }
        if await check("loopback Caddy admin and private managed-app ports", channel: "apps:caddy:plan", session: session, trace: trace, body: {
            let config = try snapshot.object("caddy")
            let admin = config["admin"] as? [String: Any] ?? [:]
            try require(admin["disabled"] as? Bool != true, "The tunneled Caddy admin is disabled.")
            if let address = admin["listen"] as? String {
                try require(["localhost:2019", "127.0.0.1:2019", "[::1]:2019"].contains(address) || address.hasPrefix("unix/"), "Caddy admin is not private.")
            }
            for container in try snapshot.array("containers") {
                let labels = container["Labels"] as? [String: String] ?? [:]
                let names = container["Names"] as? [String] ?? []
                let managed = labels.keys.contains { $0.hasPrefix("terminaldeck.") || $0.hasPrefix("ae.terminaldeck.") || $0.hasPrefix("io.terminaldeck.") }
                    || names.contains { $0.hasPrefix("/terminaldeck-") || $0.hasPrefix("/td-test-") }
                guard managed else { continue }
                for binding in container["Ports"] as? [[String: Any]] ?? [] {
                    try require(binding["PublicPort"] == nil, "A managed app/database publishes a host port.")
                }
            }
        }) == false { failed += 1 }
        if snapshot.sections["state"]?.status == 0,
           snapshot.sections["state"]?.body.trimmingCharacters(in: .whitespacesAndNewlines) == "MISSING" {
            await trace.append("not checked: app-state permissions (the server Apps folder does not exist; no folder was created)", notChecked: true)
        } else if await check("0700 app folders, 0600 state and no immediate state symlinks", channel: "apps:capabilities", session: session, trace: trace, body: {
            let values = try snapshot.success("state").split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            try require(values.count == 4 && values.allSatisfy { $0 == 0 }, "App-state permissions, readability or symlink checks failed.")
        }) == false { failed += 1 }
        if let address = configuration.address, let host = address.host {
            if await check("trusted HTTPS for the supplied test app", channel: "apps:domains:check", session: session, trace: trace, body: {
                // Pin the request to the approved demo IP. Wrong DNS cannot contact another server.
                let command = "timeout 15 curl --noproxy '*' --proto '=https' --max-time 12 --silent --show-error --output /dev/null --write-out '%{http_code}' --resolve "
                    + DKTLiveProbe.shellQuote(host + ":443:178.105.239.176") + " " + DKTLiveProbe.shellQuote(address.absoluteString)
                let result = try DKTLiveProbe.run(arguments: ["-c", DKTLiveProbe.shellQuote(command)], configuration: configuration)
                let code = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                try require(result.status == 0 && (200..<400).contains(code), "The pinned test-app request did not return trusted HTTPS with a successful status.")
            }) == false { failed += 1 }
            if let expectedIP = configuration.expectedIP {
                if await check("every DNS answer matches the approved demo IP", channel: "apps:domains:check", session: session, trace: trace, body: {
                    let result = try DKTLiveProbe.run(arguments: ["-c", DKTLiveProbe.shellQuote("timeout 10 getent ahosts " + DKTLiveProbe.shellQuote(host))], configuration: configuration)
                    let observed = Set(result.output.split(separator: "\n").compactMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) })
                    try require(result.status == 0 && observed == Set([expectedIP]), "DNS contains an address outside the approved demo IP or returned no usable answer.")
                }) == false { failed += 1 }
            } else { await trace.append("not checked: DNS equality (no expected IP supplied)", notChecked: true) }
        } else {
            await trace.append("not checked: HTTPS and DNS (no test-app address supplied)", notChecked: true)
        }
        if failed > 0 { throw DKTLiveProbeFailure("\(failed) read-only live checks failed. See LIVE-LOG; no server changes were made.") }
    }

    private static func check(_ label: String, channel: String, session: DKTLiveRunSession,
                              trace: DKTLiveCheckTrace, body: @escaping @Sendable () throws -> Void) async -> Bool {
        await trace.append("started: " + label)
        do {
            try await session.perform(.read(channel: channel)) { try body() }
            await trace.append("passed: " + label)
            return true
        } catch {
            await trace.append("failed: " + label)
            return false
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw DKTLiveProbeFailure(message) }
    }
}

private struct DKTLiveProbeFailure: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct DKTLiveProbeConfiguration: Hashable, Sendable {
    let target: String
    let port: Int
    let address: URL?
    let expectedIP: String?

    static func load() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DKT_LIVE_SERVER_APPROVED_READ_ONLY"] == "1" else {
            throw XCTSkip("Live Linux checks are opt-in; no server contacted.")
        }
        let target = environment["DKT_LIVE_SERVER_TARGET"] ?? ""
        _ = try DKTLiveTarget.resolve(target)
        guard environment["DKT_LIVE_RUN_OWNER"] == "DKA", let evidencePath = environment["DKT_LIVE_FAKE_EVIDENCE"],
              !evidencePath.isEmpty else {
            throw DKTLiveProbeFailure("DKA must supply fresh passing fake-suite evidence before live checks.")
        }
        let evidence = try Self.evidence(path: evidencePath)
        guard FileManager.default.isReadableFile(atPath: evidence.logPath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: evidence.logPath),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            throw DKTLiveProbeFailure("The fake-suite result must link to a nonempty readable DKA test log.")
        }
        guard let port = Int(environment["DKT_LIVE_SERVER_SSH_PORT"] ?? "22"), port == 22 else {
            throw DKTLiveProbeFailure("The live checks use the approved SSH aliases on port 22 only.")
        }
        let rawAddress = environment["DKT_LIVE_SERVER_ADDRESS"] ?? ""
        let address: URL?
        if rawAddress.isEmpty { address = nil }
        else {
            guard target == DKTLiveTarget.demo.rawValue, let value = URL(string: rawAddress), value.scheme == "https", let host = value.host,
                  host.hasSuffix(".178-105-239-176.sslip.io"),
                  DKTLiveSafetyHarness.validTestName(String(host.dropLast(".178-105-239-176.sslip.io".count))),
                  value.port == nil || value.port == 443,
                  value.user == nil, value.password == nil, value.query == nil, value.fragment == nil else {
                throw DKTLiveProbeFailure("Only an HTTPS td-test-* address on the approved demo box may be checked. Store addresses and other hosts are refused.")
            }
            address = value
        }
        let rawIP = environment["DKT_LIVE_SERVER_EXPECTED_IP"] ?? ""
        if !rawIP.isEmpty {
            guard address != nil, target == DKTLiveTarget.demo.rawValue, rawIP == "178.105.239.176" else {
                throw DKTLiveProbeFailure("An expected IP is only valid with a test-app HTTPS address and must equal the approved demo IP.")
            }
        }
        return Self(target: target, port: port, address: address, expectedIP: rawIP.isEmpty ? nil : rawIP)
    }

    static func evidence(path: String? = nil) throws -> DKTFakeSuiteEvidence {
        guard let path = path ?? ProcessInfo.processInfo.environment["DKT_LIVE_FAKE_EVIDENCE"],
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, (1...65536).contains(size.intValue) else {
            throw DKTLiveProbeFailure("A bounded readable DKA fake-suite evidence file is required.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence: DKTFakeSuiteEvidence
        do { evidence = try decoder.decode(DKTFakeSuiteEvidence.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { throw DKTLiveProbeFailure("The DKA fake-suite evidence file is unreadable or invalid.") }
        try evidence.validate()
        return evidence
    }
}

private struct DKTLiveProbeSection: Sendable { let status: Int; let body: String }
private struct DKTLiveProbeSnapshot: Sendable {
    let sections: [String: DKTLiveProbeSection]
    func success(_ name: String) throws -> String {
        guard let section = sections[name], section.status == 0 else {
            throw DKTLiveProbeFailure("The read-only \(name) check is unavailable; run as a login with the required read access.")
        }
        return section.body
    }
    func object(_ name: String) throws -> [String: Any] {
        let body = try success(name)
        guard let data = body.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DKTLiveProbeFailure("The \(name) check did not return a valid object.")
        }
        return value
    }
    func array(_ name: String) throws -> [[String: Any]] {
        let body = try success(name)
        guard let data = body.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DKTLiveProbeFailure("The \(name) check did not return a valid list.")
        }
        return value
    }
    func inventory() throws -> DKTLiveInventory {
        try DKTLiveInventoryCollector.collect(.init(containers: Data(success("containers").utf8), images: Data(success("images").utf8),
            volumes: Data(success("volumes").utf8), networks: Data(success("networks").utf8),
            caddy: Data(success("caddy").utf8), serverPaths: success("paths")))
    }
}

private final class DKTLiveProbeCache: @unchecked Sendable {
    static let shared = DKTLiveProbeCache()
    private let lock = NSLock()
    private var cached: [DKTLiveProbeConfiguration: DKTLiveProbeSnapshot] = [:]
    func snapshot(configuration: DKTLiveProbeConfiguration, refresh: Bool = false) throws -> DKTLiveProbeSnapshot {
        return try lock.withLock {
            if !refresh, let value = cached[configuration] { return value }
            let result = try DKTLiveProbe.run(arguments: ["-s"], configuration: configuration, input: DKTLiveProbe.script(configuration: configuration))
            guard result.status == 0 else { throw DKTLiveProbeFailure("Read-only SSH checks did not finish. Check the existing trusted login; no interactive retry is attempted.") }
            var sections: [String: DKTLiveProbeSection] = [:]
            var current: String?
            var lines: [String] = []
            for line in result.output.components(separatedBy: "\n") {
                if line.hasPrefix("DKT-BEGIN ") { current = String(line.dropFirst(10)); lines = [] }
                else if line.hasPrefix("DKT-END "), let name = current {
                    let end = line.dropFirst(8).split(separator: " ")
                    guard end.count == 2, String(end[0]) == name, let status = Int(end[1]) else {
                        throw DKTLiveProbeFailure("Read-only probe framing is invalid.")
                    }
                    sections[name] = .init(status: status, body: lines.joined(separator: "\n"))
                    current = nil
                } else if current != nil { lines.append(line) }
            }
            let required: Set<String> = ["platform", "tools", "socket", "ping", "version", "listeners", "caddy", "containers", "images", "volumes", "networks", "paths", "state"]
            guard Set(sections.keys) == required, current == nil else {
                throw DKTLiveProbeFailure("Read-only probe did not return every required check.")
            }
            let snapshot = DKTLiveProbeSnapshot(sections: sections)
            cached[configuration] = snapshot
            return snapshot
        }
    }
}

private enum DKTLiveProbe {
    struct Result: Sendable { let status: Int32; let output: String }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func isLoopback(_ host: String) -> Bool {
        if host == "::1" { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }
    static func run(arguments: [String], configuration: DKTLiveProbeConfiguration, input: String = "") throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                             "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                             "-o", "ControlMaster=no", "-o", "ControlPath=none", "-p", String(configuration.port), "--", configuration.target,
                             "sh"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice // Never print remote stderr or returned config/secrets.
        process.standardInput = stdin
        defer {
            // Also close both pipe ends when launching or writing the child fails.
            try? stdin.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { throw DKTLiveProbeFailure("The existing SSH client could not start.") }
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 55, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate(); _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        var output = Data()
        while let chunk = try stdout.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard output.count + chunk.count <= 2 * 1024 * 1024 else {
                process.terminate()
                throw DKTLiveProbeFailure("Read-only probe exceeded its safe output limit.")
            }
            output.append(chunk)
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }

    static func script(configuration: DKTLiveProbeConfiguration) -> String {
        let stateRoot = configuration.target == DKTLiveTarget.demo.rawValue ? "/var/lib/td-test-apps" : "/var/lib/terminaldeck/apps"
        return "export DKT_STATE_ROOT=" + shellQuote(stateRoot) + "\n" + scriptBody
    }

    // Shell commands are the permitted server-side exception. They only read.
    private static let scriptBody = #"""
    export LC_ALL=C
    run_check() {
      name=$1
      shift
      printf 'DKT-BEGIN %s\n' "$name"
      "$@" 2>/dev/null
      result=$?
      printf '\nDKT-END %s %s\n' "$name" "$result"
    }
    run_check platform uname -s
    run_check tools sh -c 'for tool in curl ss stat find timeout; do command -v "$tool" >/dev/null || exit 1; done'
    run_check socket sh -c 'test -S /var/run/docker.sock && test -r /var/run/docker.sock && test -w /var/run/docker.sock || exit 1; mode=$(stat -c %a /var/run/docker.sock) || exit 1; test $((0$mode & 0007)) -eq 0'
    run_check ping timeout 12 curl --noproxy '*' --max-time 10 --silent --fail --unix-socket /var/run/docker.sock http://localhost/_ping
    run_check version timeout 12 curl --noproxy '*' --max-time 10 --silent --fail --unix-socket /var/run/docker.sock http://localhost/version
    run_check listeners timeout 5 ss -H -ltn
    run_check caddy timeout 12 curl --noproxy '*' --max-time 10 --silent --fail http://127.0.0.1:2019/config/
    run_check containers timeout 12 curl --noproxy '*' --max-time 10 --silent --fail --unix-socket /var/run/docker.sock 'http://localhost/containers/json?all=1'
    run_check images timeout 12 curl --noproxy '*' --max-time 10 --silent --fail --unix-socket /var/run/docker.sock http://localhost/images/json
    run_check volumes timeout 12 curl --noproxy '*' --max-time 10 --silent --fail --unix-socket /var/run/docker.sock http://localhost/volumes
    run_check networks timeout 12 curl --noproxy '*' --max-time 10 --silent --fail --unix-socket /var/run/docker.sock http://localhost/networks
    run_check paths timeout 8 sh -c '
      set -eu
      for root in /var/lib/terminaldeck/apps /var/lib/td-test-apps; do
        if test ! -e "$root" && test ! -L "$root"; then continue; fi
        test ! -L "$root" && test -d "$root" || exit 1
        test -r "$root" && test -x "$root" || exit 1
        find "$root" -mindepth 1 -maxdepth 1 -type d -printf "APP %p\n"
        find "$root" -type d -printf "FOLDER %p\n"
        find "$root" -type l -printf "FOLDER %p\n"
        find "$root" -type f -path "*/backups/*" -printf "BACKUP %p\n"
      done
      find /tmp -mindepth 1 -maxdepth 1 -type d -name "td-test-*" -printf "FOLDER %p\n"
      if test -d /var/lib/terminaldeck; then
        find /var/lib/terminaldeck -mindepth 1 -maxdepth 1 -type d -name "td-test-*" -printf "FOLDER %p\n"
      fi
      find /var/lib -mindepth 1 -maxdepth 1 -type d -name "td-test-*" ! -path /var/lib/td-test-apps -printf "FOLDER %p\n"
      find /etc/systemd/system -mindepth 1 -maxdepth 1 -name "td-test-*" -printf "BACKUP %p\n"
    '
    run_check state sh -c '
      root=$DKT_STATE_ROOT
      if test ! -e "$root" && test ! -L "$root"; then printf "MISSING\n"; exit 0; fi
      test ! -L "$root" || exit 1
      test -d "$root" && test -r "$root" && test -x "$root" || exit 1
      test "$(stat -c %a "$root")" = 700 || exit 1
      find "$root" -mindepth 1 -maxdepth 1 -type d ! -perm 0700 | wc -l
      find "$root" -mindepth 1 -maxdepth 2 -type f -name state.json ! -perm 0600 | wc -l
      find "$root" -mindepth 1 -maxdepth 2 -type l | wc -l
      find "$root" -mindepth 1 -maxdepth 1 -type d ! -readable | wc -l
    '
    """#
}

private enum DKTLiveLogWriter {
    private static let lock = NSLock()
    private static var path: URL {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return macos.appendingPathComponent("docker/LIVE-LOG.md")
    }
    static func validateWritable() throws {
        let descriptor = try openLog()
        _ = close(descriptor)
    }
    static func append(_ entry: DKTLiveRunRecord) throws {
        try lock.withLock {
            let handle = FileHandle(fileDescriptor: try openLog(), closeOnDealloc: true)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.markdown.utf8))
            try handle.synchronize()
        }
    }
    private static func openLog() throws -> Int32 {
        let descriptor = open(path.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DKTLiveProbeFailure("The repository LIVE-LOG.md must be an existing writable file, never a symlink or alternate destination.") }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG, information.st_nlink == 1 else {
            _ = close(descriptor)
            throw DKTLiveProbeFailure("The live log must be one ordinary repository file without hard links.")
        }
        return descriptor
    }
}
