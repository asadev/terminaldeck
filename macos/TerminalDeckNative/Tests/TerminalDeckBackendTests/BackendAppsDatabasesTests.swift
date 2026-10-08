import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APE database provisioning: Swift fakes, no servers")
struct BackendAppsDatabasesTests {
    @Test(arguments: ["postgres", "mysql", "redis", "mongodb"])
    func privateDatabaseKeepsDataAndMasksCredentials(kind: String) async throws {
        let fake = BackendAppsDatabaseFixture()
        let runtime = fake.runtime()
        let store = BackendAppsStore(runtime: runtime)
        let result = try await BackendAppsDatabases(runtime: runtime, store: store).create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: kind, version: nil)
        #expect(result["status"].string == "running")
        #expect(result["database"] == .missing)
        let calls = await fake.apiCalls
        let body = try #require(calls.first(where: { $0.path.hasPrefix("/containers/create?") })?.value)
        #expect(body["HostConfig"]["PortBindings"].fields?.isEmpty == true)
        #expect(body["HostConfig"]["NetworkMode"].string == "td-test-apps")
        #expect(body["Image"].string == BackendAppsDatabaseFixture.imageID)
        #expect(body["HostConfig"]["Mounts"].elements?.first?["Source"].string?.hasPrefix("td-test-") == true)
        let stored = try await store.read("fake-server", "td-test-data")
        #expect(stored["database"]["volumeName"].string == "td-test-td-test-data-data")
        let env = try await store.environment("fake-server", "td-test-data")
        let credential = try #require(env.first(where: { $0.key.contains("PASSWORD") })?.value)
        #expect(credential.count == 64)
        #expect(!result.compact.contains(credential))
        #expect(!(await fake.commands).contains(where: { $0.contains(credential) }))
        #expect(!calls.contains(where: { $0.method == "DELETE" }))
        if kind == "mongodb" { #expect(body["HostConfig"]["Tmpfs"]["/data/configdb"].string != nil) }
    }

    @Test func refusesUnapprovedUpstreamPullInLiveTestNamespace() async throws {
        let fake = BackendAppsDatabaseFixture()
        await fake.setMissingImage(true)
        let runtime = fake.runtime()
        do {
            _ = try await BackendAppsDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime)).create(serverID: "fake-server", appID: "td-test-data", name: "Test", kind: "postgres", version: nil)
            Issue.record("Missing test image became a successful database")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect((await fake.apiCalls).allSatisfy { $0.method == "GET" })
    }

    @Test func preservesConflictingSavedVolume() async throws {
        let fake = BackendAppsDatabaseFixture()
        await fake.setExistingVolume(true)
        let runtime = fake.runtime()
        do {
            _ = try await BackendAppsDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime)).create(serverID: "fake-server", appID: "td-test-data", name: "Test", kind: "mysql", version: nil)
            Issue.record("Existing data volume was reused")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(!(await fake.apiCalls).contains(where: { $0.method != "GET" }))
    }

    @Test func invalidKindsAndUnsupportedLayoutDoNotContactServer() async throws {
        let fake = BackendAppsDatabaseFixture()
        let runtime = fake.runtime()
        let service = BackendAppsDatabases(runtime: runtime, store: BackendAppsStore(runtime: runtime))
        for (kind, version) in [("sqlite", "1"), ("postgres", "18"), ("mysql", "8; touch /tmp/nope")] {
            do {
                _ = try await service.create(serverID: "fake-server", appID: "td-test-data", name: "Test", kind: kind, version: version)
                Issue.record("Invalid database software was accepted")
            } catch let error as NativeRPCError { #expect(["invalid-arguments", "unavailable"].contains(error.code)) }
        }
        #expect((await fake.commands).isEmpty)
        #expect((await fake.apiCalls).isEmpty)
    }
}

/// File and Engine callbacks model only the seam exercised here. Nothing launches a process.
actor BackendAppsDatabaseFixture {
    struct APICall: Sendable { let method: String; let path: String; let value: NativeRPCValue? }
    static let imageID = "sha256:" + String(repeating: "d", count: 64)
    static let sourceID = String(repeating: "a", count: 64)
    static let candidateID = String(repeating: "b", count: 64)
    private(set) var commands: [String] = []
    private(set) var apiCalls: [APICall] = []
    private(set) var files: [String: Data] = [:]
    private var missingImage = false
    private var existingVolume = false
    private var unavailableDependencies = false
    private var checksumFailure = false
    private var failRestore = false
    private var creations = 0
    var backupEntries: NativeRPCValue = .array([])
    nonisolated func runtime() -> BackendAppsRuntime {
        BackendAppsRuntime(execute: { [self] _, command, stdin, _, _ in try await execute(command, stdin) },
                           docker: { [self] _, method, path, body in try await docker(method, path, body) },
                           privateNetwork: "td-test-apps", resourcePrefix: "td-test", now: { 1_797_000_000_000 })
    }
    func setMissingImage(_ value: Bool) { missingImage = value }
    func setExistingVolume(_ value: Bool) { existingVolume = value }
    func setDependenciesUnavailable(_ value: Bool) { unavailableDependencies = value }
    func setChecksumFailure(_ value: Bool) { checksumFailure = value }
    func setRestoreFailure(_ value: Bool) { failRestore = value }
    func setBackupEntries(_ value: NativeRPCValue) { backupEntries = value }
    func seed(_ path: String, _ value: NativeRPCValue) throws { files[path] = try value.encodedJSON() }
    func seedEnvironment(_ path: String, _ contents: String) { files[path] = Data(contents.utf8) }

    private func execute(_ command: String, _ stdin: Data?) throws -> BackendServersRunResult {
        commands.append(command)
        let tokens = Self.words(command)
        let script = tokens.first == "sh" && tokens.dropFirst().first == "-c" ? tokens.dropFirst(2).first ?? "" : command
        if let stdin {
            if script.contains("mkdir -- "), let owner = Self.capture(#"cat > '([^']+/\.lock/owner)'"#, in: script) {
                guard files[owner] == nil else { return .init(code: 73, stdout: "") }
                files[owner] = stdin
                return .init(code: 0, stdout: "")
            }
            if let line = script.split(separator: "\n").first(where: { $0.hasPrefix("mv -f -- ") }),
               let path = Self.words(String(line)).last { files[path] = stdin }
            return .init(code: 0, stdout: "")
        }
        // A release is not a file read: its final word is the lock directory, not the cat target.
        // Model the same owner-token barrier as Store, before the generic read classifier below.
        if script.contains("rmdir -- "), let owner = Self.capture(#"cat -- '([^']+/\.lock/owner)'"#, in: script),
           let token = Self.capture(#"\)"\s*=\s*'([^']+)'"#, in: script) {
            guard let saved = files[owner], String(decoding: saved, as: UTF8.self) == token else { return .init(code: 1, stdout: "") }
            files[owner] = nil
            return .init(code: 0, stdout: "")
        }
        if (script.hasPrefix("test ! -L ") || script.hasPrefix("test -e ")), script.contains("cat -- "), let path = Self.words(script).last {
            guard let data = files[path] else { return .init(code: 44, stdout: "") }
            return .init(code: 0, stdout: String(decoding: data, as: UTF8.self))
        }
        if script.contains("command -v "), unavailableDependencies { return .init(code: 69, stdout: "", stderr: "fake-secret must not escape") }
        if script.contains("sha256sum \"$file\""), checksumFailure { return .init(code: 1, stdout: "") }
        if script.hasPrefix("set -eu; docker exec -i "), failRestore { return .init(code: 1, stdout: "") }
        if script.contains("sort_by(.createdAt) | reverse") { return .init(code: 0, stdout: backupEntries.compact) }
        if script.hasPrefix("sh "), script.contains("--already-locked"), let backupID = Self.words(script).last {
            return .init(code: 0, stdout: Self.manifest(id: backupID).compact)
        }
        return .init(code: 0, stdout: "")
    }
    private func docker(_ method: String, _ path: String, _ body: Data?) throws -> BackendAppsHTTPResponse {
        let value = try body.map { try NativeRPCValue.parseJSON($0) }
        apiCalls.append(APICall(method: method, path: path, value: value))
        if method == "GET", path.hasPrefix("/images/") {
            return try response(missingImage ? 404 : 200, BackendAppsValidation.object([("Id", .string(Self.imageID))]))
        }
        if method == "GET", path.hasPrefix("/volumes/") { return .init(status: existingVolume ? 200 : 404) }
        if method == "GET", path.hasPrefix("/networks/") {
            return try response(200, BackendAppsValidation.object([("Driver", .string("bridge")), ("Ingress", .bool(false)), ("Labels", BackendAppsValidation.object([("io.terminaldeck.managed", .string("true"))]))]))
        }
        if method == "POST", path.hasPrefix("/containers/create?") {
            creations += 1
            return try response(201, BackendAppsValidation.object([("Id", .string(path.contains("-restore-") ? Self.candidateID : Self.sourceID))]))
        }
        if method == "GET", path.hasPrefix("/containers/") {
            return try response(200, BackendAppsValidation.object([
                ("Image", .string(Self.imageID)),
                ("State", BackendAppsValidation.object([("Running", .bool(true)), ("Health", BackendAppsValidation.object([("Status", .string("healthy"))]))])),
                ("Config", BackendAppsValidation.object([("Labels", BackendAppsValidation.object([("io.terminaldeck.app", .string("td-test-data")), ("io.terminaldeck.managed", .string("true"))]))]))
            ]))
        }
        return .init(status: method == "GET" ? 200 : 201)
    }
    private func response(_ status: Int, _ value: NativeRPCValue) throws -> BackendAppsHTTPResponse { .init(status: status, body: try value.encodedJSON()) }
    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    static func manifest(id: String = "td-test-backup") -> NativeRPCValue {
        BackendAppsValidation.object([("id", .string(id)), ("appId", .string("td-test-data")), ("kind", .string("postgres")), ("imageId", .string(imageID)), ("bytes", .number(12)), ("sha256", .string(String(repeating: "c", count: 64))), ("createdAt", .number(1_797_000_000_000)), ("verified", .bool(true)), ("uploaded", .bool(false))])
    }
    static func app() -> NativeRPCValue {
        BackendAppsValidation.object([("id", .string("td-test-data")), ("name", .string("Test data")), ("kind", .string("postgres")), ("status", .string("running")), ("containerId", .string(sourceID)), ("database", BackendAppsValidation.object([("containerId", .string(sourceID)), ("volumeName", .string("td-test-original")), ("image", .string("postgres:17"))]))])
    }
    /// Decode quoted command arguments for the in-memory seam; never interpret or execute them.
    static func words(_ text: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, escape = false, started = false
        for character in text {
            if escape { current.append(character); escape = false; started = true; continue }
            if character == "\\", quote != "'" { escape = true; started = true; continue }
            if let held = quote {
                if character == held { quote = nil } else { current.append(character) }
                started = true; continue
            }
            if character == "'" || character == "\"" { quote = character; started = true; continue }
            if character.isWhitespace {
                if started { words.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        if started { words.append(current) }
        return words
    }
}
