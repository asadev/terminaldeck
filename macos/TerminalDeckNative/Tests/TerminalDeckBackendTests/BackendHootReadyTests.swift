import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendHootReadyTests: XCTestCase {
    private func profile(_ provider: HootChatProvider, id: String? = nil) -> BackendAccountProfile {
        .init(id: id ?? "system:\(provider.rawValue)", name: provider.rawValue, provider: provider.rawValue,
              configDir: "/scratch/\(provider.rawValue)", system: id == nil, color: "#000000", createdAt: 0)
    }
    private func help(_ provider: HootChatProvider) throws -> String {
        var macos = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { macos.deleteLastPathComponent() }
        return try String(contentsOf: macos.appendingPathComponent("testing/suite/fixtures/" + provider.rawValue + "-help.txt"), encoding: .utf8)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HootReady-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func owner(_ root: URL, signed: Set<String>, installed: Set<String> = ["claude", "codex", "gemini"], enabled: Bool = true) -> BackendHootReadyDefaults {
        let profiles = HootReadyDefaults.providerOrder.map { profile($0) }
        return .init(settings: BackendAppSettingsStore(userData: root, writable: true), enabled: enabled,
                     profiles: { provider, _ in profiles.filter { $0.provider == provider.rawValue } },
                     available: { installed.contains($0.rawValue) }, signedIn: { profile, _ in signed.contains(profile.provider) })
    }
    

    func testAutomaticSignedInOrderAndNativeDefaults() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for (signed, expected) in [(Set(["claude", "codex", "gemini"]), HootChatProvider.claude),
                                  (Set(["codex", "gemini"]), .codex), (Set(["gemini"]), .gemini)] {
            let choice = try await owner(root, signed: signed).read(projectPath: "/scratch/hoot")
            XCTAssertEqual(choice.provider, expected); XCTAssertTrue(choice.ready)
            XCTAssertNil(choice.launchSettings.model)
            XCTAssertEqual(choice.launchSettings.effort, choice.provider == .gemini ? nil : "xhigh")
            let plan = try choice.launchPlan(privateDirectory: root, installedHelp: help(choice.provider))
            XCTAssertFalse(plan.arguments.contains("--model"))
            XCTAssertEqual(plan.arguments.contains("--effort"), choice.provider == .claude)
            let headless = try BackendHootChatLaunchPlan(provider: choice.provider, cwd: root.path, sessionID: nil, extra: [])
            XCTAssertTrue(choice.provider == .claude ? headless.arguments.contains("stream-json") : headless.arguments.contains(choice.provider == .codex ? "app-server" : "--acp"))
        }
    }
    func testMissingOrUnsignedAIIsInlineAndDoesNotPersistAFalseDefault() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let choice = try await owner(root, signed: []).read(projectPath: "/scratch/hoot")
        XCTAssertFalse(choice.ready); XCTAssertNil(choice.preferences.provider)
        XCTAssertEqual(HootReadyDefaults.signInLine + " Open settings", "Sign in to Claude, Codex or Gemini to start: Open settings")
        let available = try await owner(root, signed: ["claude", "codex"], installed: ["codex"]).read(projectPath: "/scratch/hoot")
        XCTAssertEqual(available.provider, .codex); XCTAssertTrue(available.ready)
        let fresh = try await owner(root, signed: ["gemini"]).read(projectPath: "/scratch/hoot")
        XCTAssertEqual(fresh.provider, .gemini, "read-only auto selection does not pin an unavailable provider")
    }
    func testSettingsPersistProviderAccountModelEffortAndUseSharedPolicy() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let defaults = owner(root, signed: ["claude", "codex"])
        let saved = try await defaults.save(HootReadyPreferences(provider: .codex, profileID: "system:codex", model: "gpt-test", effort: "high").wireValue, projectPath: "/scratch/hoot")
        XCTAssertEqual(saved.provider, .codex); XCTAssertEqual(saved.profile?.id, "system:codex")
        let reopened = try await owner(root, signed: ["claude", "codex"]).read(projectPath: "/scratch/hoot")
        XCTAssertEqual(reopened.preferences, saved.preferences)
        let plan = try reopened.launchPlan(privateDirectory: root, installedHelp: help(.codex))
        XCTAssertEqual(plan.arguments, ["--model", "gpt-test", "-c", "model_reasoning_effort=\"high\""])
        let automatic = try await defaults.save(HootReadyPreferences().wireValue, projectPath: "/scratch/hoot")
        XCTAssertNil(automatic.preferences.provider)
        XCTAssertEqual(automatic.provider, .claude)
    }
    func testWrongAccountUnsupportedEffortAndUnknownChoiceAreRejected() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let defaults = owner(root, signed: ["claude", "codex", "gemini"])
        for value in [HootReadyPreferences(provider: .claude, profileID: "system:codex").wireValue,
                      HootReadyPreferences(provider: .claude, effort: "ultra").wireValue,
                      HootReadyPreferences(provider: .gemini, effort: "high").wireValue,
                      NativeRPCValue.object([.init("permissionMode", .string("yolo"))])] {
            do { _ = try await defaults.save(value, projectPath: "/scratch/hoot"); XCTFail("invalid choices saved") } catch {}
        }
        let unchanged = try await defaults.read(projectPath: "/scratch/hoot")
        XCTAssertNil(unchanged.preferences.provider)
    }
    func testSavedUnsignedAccountIsNotSilentlyReplacedAndDisabledOwnerCannotRun() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await owner(root, signed: ["claude", "codex"]).save(HootReadyPreferences(provider: .codex, profileID: "system:codex").wireValue, projectPath: "/scratch/hoot")
        let offline = try await owner(root, signed: ["claude"]).read(projectPath: "/scratch/hoot")
        XCTAssertEqual(offline.provider, .codex); XCTAssertFalse(offline.ready)
        do { _ = try await owner(root, signed: ["claude"], enabled: false).read(projectPath: "/scratch/hoot"); XCTFail("WIP gate bypassed") } catch {}
        XCTAssertTrue(HootReadyDefaults.enabled([:])); XCTAssertFalse(HootReadyDefaults.enabled(["TD_HOOT_DISABLED": "1"]))
        XCTAssertTrue(HootReadyDefaults.enabled(["TD_WIP": "TAG,HOOT"]))
    }
    func testReturningFromSignInRefreshesTheSameOwnerWithoutAnOnboardingGate() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let codex = profile(.codex)
        let defaults = BackendHootReadyDefaults(settings: BackendAppSettingsStore(userData: root, writable: true), enabled: true,
            profiles: { provider, _ in provider == .codex ? [codex] : [] }, available: { $0 == .codex },
            signedIn: { _, refresh in refresh })
        let before = try await defaults.read(projectPath: "/scratch/hoot")
        XCTAssertFalse(before.ready)
        let after = try await defaults.read(projectPath: "/scratch/hoot", refresh: true)
        XCTAssertTrue(after.ready); XCTAssertEqual(after.provider, .codex)
        XCTAssertNil(after.preferences.provider, "sign-in refresh does not turn auto selection into a saved override")
    }
}
