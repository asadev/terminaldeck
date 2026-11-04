import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 4 Nov (Asad's recording of install #26): "imzapremium@gmail.com" was signed in as app.imatch.ae@gmail.com, so
/// Settings folded it into that row as a second copy, while Add account still refused the name as taken.
final class Accounts27TidyTests: XCTestCase {
    private func profile(_ id: String, _ name: String, provider: String = "claude", system: Bool = false, dir: String? = nil) -> BackendAccountProfile {
        .init(id: id, name: name, provider: provider, configDir: dir ?? "/fixture/" + id, system: system, color: "--accent", createdAt: 1)
    }
    private func login(_ folder: String, _ email: String?) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let state: NativeRPCValue = email.map { .object([.init("oauthAccount", .object([.init("emailAddress", .string($0))]))]) } ?? .object([])
        try state.encodedJSON().write(to: URL(fileURLWithPath: folder).appendingPathComponent(".claude.json"))
    }

    func testAMisnamedCopyIsRenamedToItsOwnLoginAndNothingElseMoves() {
        let profiles = [profile("system", "Default", system: true),
                        profile("app-imatch", "app.imatch.ae@gmail.com"), profile("imza", "imzapremium@gmail.com"),
                        profile("work", "Work"), profile("same", "same@x.com"), profile("api-key-0123456789abcdef01234567", "a@b.com"),
                        profile("free", "old@x.com")]
        let plan = BackendAccountTidy.plan(profiles, remembered: [
            "system": "else@x.com", "app-imatch": "app.imatch.ae@gmail.com", "imza": "App.Imatch.ae@gmail.com", "work": "w@x.com",
            "same": "SAME@x.com", "api-key-0123456789abcdef01234567": "z@x.com", "free": "new@x.com"])
        XCTAssertEqual(plan, [
            .init(id: "imza", from: "imzapremium@gmail.com", to: "app.imatch.ae@gmail.com (second copy)", login: "app.imatch.ae@gmail.com"),
            .init(id: "free", from: "old@x.com", to: "new@x.com", login: "new@x.com")])
        XCTAssertEqual(BackendAccountTidy.plan(profiles, remembered: [:]), [])
    }

    func testTheTidyCopiesTheListFirstRenamesThroughTheStoreAndThenFindsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-accounts27-" + UUID().uuidString)
        let original = root.appendingPathComponent("logins/one").path, copy = root.appendingPathComponent("logins/two").path
        let raw = BackendFoundationTestsAccountsObject([("version", .number(1)), ("profiles", .array([
            BackendFoundationTestsAccountsRawProfile("app-imatch", name: "app.imatch.ae@gmail.com", directory: original),
            BackendFoundationTestsAccountsRawProfile("imza", name: "imzapremium@gmail.com", directory: copy)]))])
        try login(original, "app.imatch.ae@gmail.com"); try login(copy, "app.imatch.ae@gmail.com")
        defer { try? FileManager.default.removeItem(at: root) }
        try await BackendFoundationTestsAccountsWithFixture(raw: raw) { f in
            let before = try Data(contentsOf: f.configuration.dataDirectory.appendingPathComponent("profiles.json"))
            let store = f.profiles, configuration = f.configuration
            let notes = Accounts27Notes()
            let done = await BackendAccountTidy.run(configuration: configuration, list: { try await store.list() },
                rename: { _ = try await store.rename(id: $0, name: $1) }, note: { notes.add($0) })
            XCTAssertEqual(done.map(\.to), ["app.imatch.ae@gmail.com (second copy)"])
            let names = try await store.list().filter { !$0.system }.map(\.name)
            XCTAssertEqual(names, ["app.imatch.ae@gmail.com", "app.imatch.ae@gmail.com (second copy)"])
            let backups = try FileManager.default.contentsOfDirectory(atPath: configuration.dataDirectory.path).filter { $0.hasPrefix("profiles.json.bak-tidy-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: configuration.dataDirectory.appendingPathComponent(backups[0])), before)
            XCTAssertTrue(notes.lines.contains { $0.contains("renamed “imzapremium@gmail.com” to “app.imatch.ae@gmail.com (second copy)”") })
            // The name is free again, and a second run has nothing to do (no second backup).
            let added = try await f.create("imzapremium@gmail.com")
            XCTAssertEqual(added.name, "imzapremium@gmail.com")
            let again = await BackendAccountTidy.run(configuration: configuration, list: { try await store.list() }, rename: { _ = try await store.rename(id: $0, name: $1) })
            XCTAssertEqual(again, [])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: configuration.dataDirectory.path).filter { $0.hasPrefix("profiles.json.bak-tidy-") }.count, 1)
        }
    }

    func testAddAccountNamesTheAccountThatHasTheNameOrFreesAMisnamedOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-accounts27-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "Accounts27", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/usr/bin/true"), inheritedEnvironment: [:])
        let real = root.appendingPathComponent("real").path, wrong = root.appendingPathComponent("wrong").path
        try login(real, "real@x.com"); try login(wrong, "other@x.com")
        let profiles = [profile("real", "real@x.com", dir: real), profile("wrong", "wanted@x.com", dir: wrong)]
        let renames = Accounts27Notes()
        do {
            try await BackendAccountTidy.freeName("REAL@x.com", provider: "claude", among: profiles, configuration: configuration) { renames.add($0 + "→" + $1) }
            XCTFail("A name an account really has must be refused.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "“real@x.com” is already one of your Claude Code accounts in Settings › Coding AIs. Press Sign in again on its row, or type another email address.")
        }
        try await BackendAccountTidy.freeName("wanted@x.com", provider: "claude", among: profiles, configuration: configuration) { renames.add($0 + "→" + $1) }
        try await BackendAccountTidy.freeName("nobody@x.com", provider: "claude", among: profiles, configuration: configuration) { renames.add($0 + "→" + $1) }
        XCTAssertEqual(renames.lines, ["wrong→other@x.com"])
    }

    func testTheStoreSaysWhichAccountAlreadyHasAName() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            _ = try await f.create("Work")
            do { _ = try await f.create("work"); XCTFail("duplicate") }
            catch { XCTAssertEqual(error.localizedDescription, "A Claude Code account called “work” already exists in Settings › Coding AIs. Press Sign in again on its row, or choose another name.") }
        }
    }

    func testThisMacsOwnLoginSignsInOnlyInItsOwnFolder() {
        let home = URL(fileURLWithPath: "/Users/me")
        let own = profile("system", "Default", system: true, dir: "/Users/me/.claude")
        XCTAssertTrue(BackendAccountOwnLogin.pinned(own, environment: [:], key: "CLAUDE_CONFIG_DIR", home: home))
        XCTAssertTrue(BackendAccountOwnLogin.pinned(own, environment: ["CLAUDE_CONFIG_DIR": "  "], key: "CLAUDE_CONFIG_DIR", home: home))
        XCTAssertFalse(BackendAccountOwnLogin.pinned(own, environment: ["CLAUDE_CONFIG_DIR": "/elsewhere"], key: "CLAUDE_CONFIG_DIR", home: home))
        let inherited = profile("system", "Default", system: true, dir: "/scratch/agent-homes/claude")
        XCTAssertTrue(BackendAccountOwnLogin.pinned(inherited, environment: ["CLAUDE_CONFIG_DIR": "/scratch/agent-homes/claude"], key: "CLAUDE_CONFIG_DIR", home: home))
        XCTAssertFalse(BackendAccountOwnLogin.pinned(profile("work", "Work", dir: "/Users/me/.claude"), environment: [:], key: "CLAUDE_CONFIG_DIR", home: home))
        XCTAssertEqual(BackendAccountTidy.claudeStateFile(configDir: nil, home: home).path, "/Users/me/.claude.json")
        XCTAssertEqual(BackendAccountTidy.claudeStateFile(configDir: "/x/y", home: home).path, "/x/y/.claude.json")
        XCTAssertEqual(BackendAccountTidy.rememberedEmail(.object([.init("oauthAccount", .object([.init("emailAddress", .string(" Me@X.com "))]))])), "me@x.com")
        XCTAssertNil(BackendAccountTidy.rememberedEmail(.object([])))
    }
}

extension Accounts27TidyTests {
    /// The signed-out Mac login says who was last signed in, from what Claude Code itself still remembers.
    func testASignedOutLoginSaysTheAddressClaudeCodeRemembers() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            try NativeRPCValue.object([.init("oauthAccount", .object([.init("emailAddress", .string("asad@example.com"))]))]).encodedJSON()
                .write(to: f.configuration.homeDirectory.appendingPathComponent(".claude.json"))
            let found = try await f.profiles.find("system")
            let own = try XCTUnwrap(found)
            let out = BackendAppAccountSignInService(dependencies: Accounts27SignInDependencies(configuration: f.configuration, profiles: f.profiles),
                executor: BackendF4Executor(), clock: BackendAppSessionSystemClock(), authorizeMetadata: { _ in }, authorizeMutation: { _ in })
            let report = await out.read(own, refresh: true)
            XCTAssertEqual(report.state, "signed-out"); XCTAssertEqual(report.remembered, "asad@example.com")
            XCTAssertEqual(report.wireValue["remembered"].string, "asad@example.com")
            let signedIn = BackendAppAccountSignInService(dependencies: Accounts27SignInDependencies(configuration: f.configuration, profiles: f.profiles),
                executor: BackendF4Executor(answer: .init(stdout: #"{"loggedIn":true,"email":"asad@example.com"}"#, exitCode: 0)),
                clock: BackendAppSessionSystemClock(), authorizeMetadata: { _ in }, authorizeMutation: { _ in })
            let live = await signedIn.read(own, refresh: true)
            XCTAssertEqual(live.state, "signed-in"); XCTAssertNil(live.remembered); XCTAssertTrue(live.wireValue["remembered"].isNullish)
        }
    }
}

struct Accounts27SignInDependencies: BackendAppAccountSignInDependencies {
    let configuration: BackendAccountConfiguration
    let profiles: BackendAccountProfileStore
    func find(_ id: String) async throws -> BackendAccountProfile? { try await profiles.find(id) }
    func managed(_ profile: BackendAccountProfile) async -> Bool { await profiles.managed(profile) }
    func summaries() async throws -> [BackendAccountVaultSummary] { throw BackendAccountFailure("No vault runs in this process.") }
    func vaultUsable() async -> Bool { false }
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary {
        .init(id: provider, onPath: "/fixture/bin/" + provider, runnable: "/fixture/bin/" + provider, version: "fixture", broken: false, said: nil, usedAlternate: false, checkedAt: Date())
    }
    func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        BackendAppAccountSignInParsing.accountEnvironment(profile, provider: provider, inherited: configuration.inheritedEnvironment, path: path, vaultVariables: configuration.vaultVariables)
    }
    func recheck(_ profile: BackendAccountProfile) async throws {}
    func readJSON(_ file: URL) -> NativeRPCValue {
        guard let data = try? Data(contentsOf: file), let value = try? NativeRPCValue.parseJSON(data) else { return .null }
        return value
    }
    func nonEmptyFile(_ file: URL) -> Bool { false }
}

final class Accounts27Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
