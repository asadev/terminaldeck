import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BackendAppAccountTestPortDependencies: BackendAppAccountSignInDependencies {
    let configuration: BackendAccountConfiguration
    let profiles: [String: BackendAccountProfile]
    var broken = false
    var files: [String: NativeRPCValue] = [:]
    var nonempty: Set<String> = []
    init(profile: BackendAccountProfile, broken: Bool = false, files: [String: NativeRPCValue] = [:], nonempty: Set<String> = [], environment: [String: String] = [:]) throws {
        configuration = try .init(dataDirectory: URL(fileURLWithPath: "/fixture/data"), homeDirectory: URL(fileURLWithPath: "/fixture/home"), appName: "Terminal Deck", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/fixture/helper"), inheritedEnvironment: environment)
        profiles = [profile.id: profile]; self.broken = broken; self.files = files; self.nonempty = nonempty
    }
    func find(_ id: String) async throws -> BackendAccountProfile? { profiles[id] }
    func managed(_ profile: BackendAccountProfile) async -> Bool { false }
    func summaries() async throws -> [BackendAccountVaultSummary] { [] }
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary {
        .init(id: provider, onPath: "/opt/homebrew/bin/" + provider, runnable: broken ? nil : provider, version: "fixture", broken: broken, said: broken ? "Error: spawn codex ENOENT" : nil, usedAlternate: false, checkedAt: .distantPast)
    }
    func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        BackendAppAccountSignInParsing.accountEnvironment(profile, provider: provider, inherited: configuration.inheritedEnvironment, path: path, vaultVariables: configuration.vaultVariables)
    }
    func recheck(_ profile: BackendAccountProfile) async throws {}
    func readJSON(_ file: URL) -> NativeRPCValue { files[file.path] ?? .null }
    func nonEmptyFile(_ file: URL) -> Bool { nonempty.contains(file.path) }
}
func BackendAppAccountTestPortProfile(_ provider: String = "claude", system: Bool = false) -> BackendAccountProfile {
    .init(id: system ? "system" : "work", name: "Work", provider: provider, configDir: system ? "/fixture/home/." + provider : "/tmp/deck-test-profiles/work" + (provider == "codex" ? "-codex" : ""), system: system, color: "--accent", createdAt: 0, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
}
let BackendAppAccountTestPortSignedIn = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"someone@example.com","orgId":"0554ae97","orgName":"someone@example.com's Organization","subscriptionType":"max"}"#
let BackendAppAccountTestPortSignedOut = #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#
func BackendAppAccountTestPortService(_ dependencies: BackendAppAccountTestPortDependencies, executor: BackendAppSessionTestPortExecutor, clock: BackendAppSessionTestPortClock = .init()) -> BackendAppAccountSignInService {
    .init(dependencies: dependencies, executor: executor, clock: clock, authorizeMetadata: { _ in }, authorizeMutation: { _ in })
}
