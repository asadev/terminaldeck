import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Asad, 12 Oct, on Hoot's sliders popover: "here we should only see efforts, model, permission level, and a drop down
/// to change the account", the context window "is dull cannot be clickable … whatever the window is actually applied it
/// just shows there", and "What Hoot can do things should not be here completely". Fixture data, no engine, no AI.
@MainActor final class HootQuickSettingsPopoverTests: XCTestCase {
    private func brain(provider: String = "claude", profile: String = "", effective: String = "claude-personal", model: String = "", context: String = "standard",
                       invoke: @escaping ROUTINESHootBrainModel.Invoke = { channel, _ in throw NativeRPCError.invalidArguments("Fixture called " + channel) }) -> ROUTINESHootBrainModel {
        ROUTINESHootBrainModel(snapshot: CodingAIJSON([
            "provider": provider, "profileId": effective,
            "choices": ["provider": provider, "profileId": profile, "model": model, "effort": "high", "permissionMode": "acceptEdits", "contextWindow": context],
            "accounts": [
                ["id": "claude-personal", "name": "Personal · Max", "provider": "claude", "installed": true, "signedIn": true],
                ["id": "claude-work", "name": "Work", "provider": "claude", "installed": true, "signedIn": true],
                ["id": "claude-old", "name": "Signed out", "provider": "claude", "installed": true, "signedIn": false],
                ["id": "codex-main", "name": "ChatGPT Pro", "provider": "codex", "installed": true, "signedIn": true],
                ["id": "gemini-none", "name": "Gemini", "provider": "gemini", "installed": false, "signedIn": false]],
            "catalog": ["codex": ["models": [["id": "gpt-stub", "name": "GPT Stub", "contextWindow": 272_000, "maxContextWindow": 872_000]],
                                  "featured": ["gpt-stub"], "defaultModel": "gpt-stub"]]] as [String: Any]), invoke: invoke)
    }

    func testOneAccountListAcrossEveryAIWithOnlyReadyAccounts() {
        let model = brain()
        XCTAssertEqual(model.accountGroups.map(\.title), ["Claude Code", "Codex"], "Gemini is not installed: no section")
        XCTAssertEqual(model.accountGroups.first?.accounts.map(\.name), ["Personal · Max", "Work"], "A signed-out account is not offered")
        XCTAssertEqual(model.accountGroups.last?.accounts.map(\.id), ["codex-main"])
        XCTAssertEqual(model.currentAccountID, "claude-personal", "Nothing saved: the account the app chose is the one ticked")
        XCTAssertEqual(model.currentAccountName, "Personal · Max")
    }

    private final class Calls { var list: [(String, [Any?])] = [] }
    /// The account is written to Hoot's row in Who uses what (SETTINGS-TRUTH line 74), never to a per-Hoot key; an account
    /// of another AI then switches Hoot to that AI.
    func testAnAccountOfAnotherAIWritesHootsRowAndSwitchesTheAI() async throws {
        let calls = Calls()
        let model = brain(invoke: { channel, args in
            calls.list.append((channel, args))
            let saved = args.first as? [String: Any] ?? [:]
            return CodingAIJSON(["provider": "codex", "profileId": "codex-main", "choices": channel == "hoot:ready:save" ? saved : [:], "accounts": []] as [String: Any])
        })
        model.selectAccount("codex-main", provider: "codex")
        for _ in 0..<200 where calls.list.count < 2 || model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.list.first?.0, "profiles:set-level")
        let args = calls.list.first?.1 ?? []
        XCTAssertEqual(args.count, 3)
        XCTAssertEqual(args.first.flatMap { $0 as? [String: String] }, ["kind": "seat", "key": "orchestrator"])
        XCTAssertEqual(args.count > 1 ? args[1] as? String : nil, "codex")
        XCTAssertEqual(args.last.flatMap { $0 as? String }, "codex-main")
        let save = calls.list.first { $0.0 == "hoot:ready:save" }?.1.first as? [String: Any]
        XCTAssertEqual(save?["provider"] as? String, "codex")
        XCTAssertTrue(save?["profileId"] is NSNull, "No per-Hoot account is saved any more")
        XCTAssertEqual(model.chosenProvider, "codex")
    }

    func testAnotherAccountOfTheSameAIOnlyWritesHootsRow() async throws {
        let calls = Calls()
        let model = brain(invoke: { channel, args in
            calls.list.append((channel, args))
            throw NativeRPCError.invalidArguments(channel == "profiles:set-level" ? "" : "quiet read")
        })
        model.selectAccount("claude-work", provider: "claude")
        for _ in 0..<100 where calls.list.isEmpty || model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.list.map { $0.0 }, ["profiles:set-level"])
        XCTAssertNotNil(model.problem, "A refused change says so")
        let ok = brain(invoke: { channel, args in
            calls.list.append((channel, args))
            if channel == "profiles:set-level" { return CodingAIJSON([String: Any]()) }
            throw NativeRPCError.invalidArguments("quiet read")
        })
        ok.selectAccount("claude-work", provider: "claude")
        for _ in 0..<100 where ok.currentAccountID != "claude-work" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ok.currentAccountID, "claude-work")
        XCTAssertEqual(ok.currentAccountName, "Work")
        XCTAssertFalse(calls.list.contains { $0.0 == "hoot:ready:save" }, "Same AI: only the row changes")
    }

    /// SETTINGS-TRUTH line 75: with no choice of Hoot's own, the switch shows the account's real Fast mode.
    func testFastModeShowsTheAccountsOwnStateWhenUnset() {
        func fast(saved: Any) -> Bool? {
            ROUTINESHootBrainModel(snapshot: CodingAIJSON(["provider": "claude", "choices": ["provider": "claude", "fastMode": saved],
                "catalog": ["claude": ["models": [[String: Any]](), "fastMode": ["available": true, "on": true]]]] as [String: Any])).fastMode
        }
        XCTAssertEqual(fast(saved: NSNull()), true, "The account's own Claude Code has it on")
        XCTAssertEqual(fast(saved: false), false, "Hoot's own choice wins")
    }

    func testTheContextWindowIsALineOnlyWhenItIsKnown() {
        XCTAssertEqual(brain(model: "opus", context: "1m").appliedWindowLabel, "1M tokens", "Claude's [1m] model: 1M is what is applied")
        XCTAssertNil(brain().appliedWindowLabel, "Claude, standard, nothing measured yet: no line rather than a guess")
        let measured = brain(); measured.measuredWindow = 200_000; measured.measuredProvider = "claude"
        XCTAssertEqual(measured.appliedWindowLabel, "200K tokens", "What the CLI itself reported")
        let other = brain(); other.measuredWindow = 200_000; other.measuredProvider = "codex"
        XCTAssertNil(other.appliedWindowLabel, "Another AI's reading is never shown for this one")
        XCTAssertEqual(brain(provider: "codex", effective: "codex-main").appliedWindowLabel, "272K tokens", "The installed Codex's own window for the model")
        XCTAssertEqual(brain(provider: "codex", effective: "codex-main", context: "max").appliedWindowLabel, "872K tokens")
    }

    func testThePopoverDrawsItsFourChoicesInLightAndDark() throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: HootQuickSettings(brain: brain(model: "opus", context: "1m"), live: false)
                .environment(\.colorScheme, dark ? .dark : .light).frame(width: HootQuickSettings.size.width, height: HootQuickSettings.size.height))
            host.frame = NSRect(origin: .zero, size: HootQuickSettings.size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertNil(host.window, "Drawn offscreen, never shown")
            guard let path = ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"], path.hasSuffix(".noindex") else { continue }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("hoot-quick-settings-\(dark ? "dark" : "light").png"))
        }
    }
}
